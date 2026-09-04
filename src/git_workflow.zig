//! Git workflow vocabulary and zero-backlog admission, independent of processes.
const std = @import("std");
const workspaces = @import("workspaces.zig");

pub const Kind = enum {
    none,
    restore_check,
    detect_repo,
    list_worktrees,
    validate_branch,
    check_target,
    check_branch,
    create_branch,
    create_worktree,
    remove_status,
    remove_submodules,
    remove_unmerged,
    remove_worktree,

    pub const Group = enum { none, discovery, listing, creation, removal };

    pub fn group(self: Kind) Group {
        return switch (self) {
            .none => .none,
            .restore_check, .detect_repo => .discovery,
            .list_worktrees => .listing,
            .validate_branch, .check_target, .check_branch, .create_branch, .create_worktree => .creation,
            .remove_status, .remove_submodules, .remove_unmerged, .remove_worktree => .removal,
        };
    }
};

pub const Request = union(enum) {
    directory_exists: []const u8,
    repository_root: []const u8,
    list_worktrees: []const u8,
    validate_branch: []const u8,
    target_available: []const u8,
    branch_exists: struct { repo: []const u8, branch: []const u8 },
    create_branch: struct { repo: []const u8, branch: []const u8 },
    create_worktree: struct { repo: []const u8, path: []const u8, branch: []const u8 },
    status: []const u8,
    submodules: []const u8,
    unmerged: struct { repo: []const u8, branch: []const u8, detached: bool },
    remove_worktree: struct { repo: []const u8, path: []const u8, force: bool },
};

pub const Outcome = enum { success, negative, failure };
// Borrowed output is consumed synchronously, before the backend releases it.
// Porcelain decoding remains in the workspace store during this refactor.
pub const Result = struct { key: u64, outcome: Outcome, output: []const u8 };

pub const Operation = struct {
    kind: Kind = .none,
    key: u64 = 0,
    project_id: u64 = 0,
    workspace_id: u64 = 0,
    force: bool = false,
    target_path: workspaces.PathText = .{},
    branch: workspaces.BranchText = .{},

    // Returned strings borrow this operation and the store until execution.
    pub fn request(self: *const Operation, store: *workspaces.Store) ?Request {
        return switch (self.kind) {
            .none => null,
            .restore_check => .{ .directory_exists = (store.findProject(self.project_id) orelse return null).selected_path.slice() },
            .detect_repo => .{ .repository_root = (store.findProject(self.project_id) orelse return null).selected_path.slice() },
            .list_worktrees => .{ .list_worktrees = (store.findProject(self.project_id) orelse return null).repo_root.slice() },
            .validate_branch => .{ .validate_branch = self.branch.slice() },
            .check_target => .{ .target_available = self.target_path.slice() },
            .check_branch => .{ .branch_exists = .{ .repo = (store.findProject(self.project_id) orelse return null).repo_root.slice(), .branch = self.branch.slice() } },
            .create_branch => .{ .create_branch = .{ .repo = (store.findProject(self.project_id) orelse return null).repo_root.slice(), .branch = self.branch.slice() } },
            .create_worktree => .{ .create_worktree = .{ .repo = (store.findProject(self.project_id) orelse return null).repo_root.slice(), .path = self.target_path.slice(), .branch = self.branch.slice() } },
            .remove_status => .{ .status = (store.findWorktree(self.workspace_id) orelse return null).path.slice() },
            .remove_submodules => .{ .submodules = (store.findWorktree(self.workspace_id) orelse return null).path.slice() },
            .remove_unmerged => blk: {
                const tree = store.findWorktree(self.workspace_id) orelse return null;
                const detached = tree.branch.eql("(detached)");
                break :blk .{ .unmerged = .{
                    .repo = if (detached) tree.path.slice() else (store.findProject(self.project_id) orelse return null).repo_root.slice(),
                    .branch = if (detached) "HEAD" else tree.branch.slice(),
                    .detached = detached,
                } };
            },
            .remove_worktree => .{ .remove_worktree = .{ .repo = (store.findProject(self.project_id) orelse return null).repo_root.slice(), .path = self.target_path.slice(), .force = self.force } },
        };
    }

    pub fn progress(self: *const Operation) []const u8 {
        return switch (self.kind) {
            .none => "Ready",
            .restore_check => "Checking restored project",
            .detect_repo => "Inspecting folder",
            .list_worktrees => "Refreshing worktrees",
            .validate_branch => "Validating branch",
            .check_target => "Checking worktree target",
            .check_branch => "Checking branch availability",
            .create_branch => "Creating branch",
            .create_worktree => "Creating worktree",
            .remove_status => "Checking worktree safety",
            .remove_submodules => "Checking worktree submodules",
            .remove_unmerged => "Checking worktree submodules",
            .remove_worktree => "Removing worktree",
        };
    }

    pub const Transition = union(enum) { next: Operation, failed: []const u8 };

    pub fn advanceCreation(self: Operation, outcome: Outcome) Transition {
        var next = self;
        switch (self.kind) {
            .validate_branch => {
                if (outcome != .success) return .{ .failed = "That is not a valid Git branch name" };
                next.kind = .check_target;
            },
            .check_target => {
                if (outcome != .success) return .{ .failed = "The generated worktree target already exists" };
                next.kind = .check_branch;
            },
            .check_branch => {
                if (outcome != .negative) return .{ .failed = if (outcome == .success) "That local branch already exists" else "Git could not check branch availability" };
                next.kind = .create_branch;
            },
            .create_branch => {
                if (outcome != .success) return .{ .failed = "Git could not create the branch (it may now exist)" };
                next.kind = .create_worktree;
            },
            else => unreachable,
        }
        next.key = 0;
        return .{ .next = next };
    }
};

pub const Lane = struct {
    active: Operation = .{},
    next_key: u64 = 10_000,

    pub fn busy(self: *const Lane) bool {
        return self.active.kind != .none;
    }

    pub fn begin(self: *Lane, operation: Operation) ?u64 {
        if (self.busy() or operation.kind == .none) return null;
        self.active = operation;
        self.active.key = self.next_key;
        self.next_key +%= 1;
        if (self.next_key == 0) self.next_key = 10_000;
        return self.active.key;
    }

    pub fn finish(self: *Lane, key: u64) ?Operation {
        if (!self.busy() or self.active.key != key) return null;
        const operation = self.active;
        self.active = .{};
        return operation;
    }
};

pub const RemovalSafety = struct {
    dirty: bool = false,
    has_submodules: bool = false,
    unmerged_count: usize = 0,

    pub fn hasWarnings(self: RemovalSafety) bool {
        return self.dirty or self.has_submodules or self.unmerged_count > 0;
    }

    pub fn matches(self: RemovalSafety, approved: RemovalSafety) bool {
        return std.meta.eql(self, approved);
    }

    pub fn recordStatus(self: *RemovalSafety, outcome: Outcome, output: []const u8) void {
        self.dirty = outcome != .success or std.mem.trim(u8, output, " \r\n").len > 0;
    }

    pub fn recordSubmodules(self: *RemovalSafety, outcome: Outcome, output: []const u8) void {
        self.has_submodules = if (outcome == .success) std.mem.trim(u8, output, " \r\n").len > 0 else outcome != .negative;
    }

    pub fn recordUnmerged(self: *RemovalSafety, outcome: Outcome, output: []const u8) void {
        self.unmerged_count = 0;
        if (outcome != .success) {
            self.unmerged_count = 1;
            return;
        }
        var lines = std.mem.splitScalar(u8, output, '\n');
        while (lines.next()) |line| if (std.mem.trim(u8, line, " \r").len > 0) {
            self.unmerged_count += 1;
        };
    }
};

test "lane rejects overlap and stale completions without allocating another key" {
    var lane: Lane = .{};
    const key = lane.begin(.{ .kind = .detect_repo, .project_id = 7 }).?;
    try std.testing.expect(lane.begin(.{ .kind = .list_worktrees }) == null);
    try std.testing.expectEqual(key + 1, lane.next_key);
    try std.testing.expect(lane.finish(key + 1) == null);
    try std.testing.expect(lane.busy());
    try std.testing.expectEqual(@as(u64, 7), lane.finish(key).?.project_id);
    try std.testing.expect(lane.finish(key) == null);
    try std.testing.expect(!lane.busy());
}

test "every Git operation belongs to one explicit result group" {
    for (std.enums.values(Kind)) |kind| switch (kind) {
        .none => try std.testing.expectEqual(Kind.Group.none, kind.group()),
        .restore_check, .detect_repo => try std.testing.expectEqual(Kind.Group.discovery, kind.group()),
        .list_worktrees => try std.testing.expectEqual(Kind.Group.listing, kind.group()),
        .validate_branch, .check_target, .check_branch, .create_branch, .create_worktree => try std.testing.expectEqual(Kind.Group.creation, kind.group()),
        .remove_status, .remove_submodules, .remove_unmerged, .remove_worktree => try std.testing.expectEqual(Kind.Group.removal, kind.group()),
    };
}

test "creation transitions keep context and stop on unsuccessful checks" {
    var operation: Operation = .{ .kind = .validate_branch, .project_id = 7, .key = 10_000 };
    _ = operation.branch.set("feature/test");
    _ = operation.target_path.set("/tmp/new tree");
    const steps = [_]struct { result: Outcome, next: Kind }{
        .{ .result = .success, .next = .check_target },
        .{ .result = .success, .next = .check_branch },
        .{ .result = .negative, .next = .create_branch },
        .{ .result = .success, .next = .create_worktree },
    };
    for (steps) |step| {
        try std.testing.expect(operation.advanceCreation(.failure) == .failed);
        if (operation.kind == .check_branch) try std.testing.expect(operation.advanceCreation(.success) == .failed);
        operation = operation.advanceCreation(step.result).next;
        try std.testing.expectEqual(step.next, operation.kind);
        try std.testing.expectEqual(@as(u64, 7), operation.project_id);
        try std.testing.expectEqual(@as(u64, 0), operation.key);
        try std.testing.expectEqualStrings("feature/test", operation.branch.slice());
        try std.testing.expectEqualStrings("/tmp/new tree", operation.target_path.slice());
    }
}

test "removal safety treats failed checks as warnings and compares the complete snapshot" {
    var safety: RemovalSafety = .{};
    const approved = safety;
    safety.recordStatus(.failure, "");
    safety.recordSubmodules(.failure, "");
    safety.recordUnmerged(.failure, "");
    try std.testing.expect(safety.dirty and safety.has_submodules and safety.unmerged_count == 1);
    try std.testing.expect(safety.hasWarnings() and !safety.matches(approved));
    safety.recordStatus(.success, " \r\n");
    safety.recordSubmodules(.negative, "");
    safety.recordUnmerged(.success, "\n");
    try std.testing.expect(!safety.hasWarnings() and safety.matches(approved));
    safety.recordUnmerged(.success, "first commit\r\n\nsecond commit\n");
    try std.testing.expectEqual(@as(usize, 2), safety.unmerged_count);
    try std.testing.expect(!safety.matches(approved));
}

test "detached history request uses the worktree HEAD instead of repository branch" {
    const store = try workspaces.Store.create(std.testing.allocator);
    defer store.destroy();
    const attached = store.attachPlaceholder("/tmp/root").?;
    try std.testing.expect(store.markGit(attached.project_id, "/tmp/root"));
    const tree = store.findWorktree(attached.workspace_id).?;
    _ = tree.path.set("/tmp/detached tree");
    _ = tree.branch.set("(detached)");
    const operation: Operation = .{ .kind = .remove_unmerged, .project_id = attached.project_id, .workspace_id = tree.id };
    const request = operation.request(store).?.unmerged;
    try std.testing.expect(request.detached);
    try std.testing.expectEqualStrings("/tmp/detached tree", request.repo);
    try std.testing.expectEqualStrings("HEAD", request.branch);
}
