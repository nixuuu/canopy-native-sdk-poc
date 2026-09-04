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
    remove_worktree,

    pub const Group = enum { none, discovery, listing, creation, removal };

    pub fn group(self: Kind) Group {
        return switch (self) {
            .none => .none,
            .restore_check, .detect_repo => .discovery,
            .list_worktrees => .listing,
            .validate_branch, .check_target, .check_branch, .create_branch, .create_worktree => .creation,
            .remove_status, .remove_worktree => .removal,
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
    inspect: struct { repo: []const u8, path: []const u8 },
    remove_worktree: struct { repo: []const u8, path: []const u8, force: bool, approved: ?RemovalSafety = null },
};

pub const Failure = enum {
    not_repository,
    not_found,
    invalid_input,
    access_denied,
    locked,
    branch_in_use,
    unsafe_worktree,
    too_large,
    io,
    internal,
    pub fn message(self: Failure) []const u8 {
        return switch (self) {
            .not_repository => "The folder is not a supported Git repository",
            .not_found => "Git could not find the repository or worktree",
            .invalid_input => "Git rejected the operation parameters",
            .access_denied => "Git could not access the repository",
            .locked => "The worktree is locked; unlock it before removal",
            .branch_in_use => "That branch is already checked out",
            .unsafe_worktree => "Git refused removal without the approved safety snapshot",
            .too_large => "The repository result exceeds application limits",
            .io => "Git could not read or update the repository",
            .internal => "Git operation failed internally",
        };
    }
};
pub const Outcome = enum { success, negative, failure };
pub const Value = union(enum) {
    ok,
    exists: bool,
    root: workspaces.PathText,
    worktrees: []const workspaces.SnapshotEntry,
    safety: RemovalSafety,
    changed: RemovalSafety,
    failure: Failure,
};
// Only worktrees borrows response memory, through the synchronous consumer call.
pub const Result = struct {
    key: u64,
    value: Value,
    pub fn outcome(self: Result) Outcome {
        return switch (self.value) {
            .failure => .failure,
            .exists => |yes| if (yes) .success else .negative,
            else => .success,
        };
    }
};

pub const RemovalSafety = struct {
    dirty: bool = false,
    status_hash: u64 = 0,
    has_submodules: bool = false,
    unmerged_count: usize = 0,
    head: [20]u8 = @splat(0),
    detached: bool = false,
    branch: workspaces.BranchText = .{},
    missing: bool = false,

    pub fn hasWarnings(self: RemovalSafety) bool {
        return self.dirty or self.has_submodules or self.unmerged_count > 0 or self.missing;
    }
    pub fn matches(self: RemovalSafety, approved: RemovalSafety) bool {
        return self.status_hash == approved.status_hash and self.dirty == approved.dirty and self.has_submodules == approved.has_submodules and
            self.unmerged_count == approved.unmerged_count and self.detached == approved.detached and
            self.missing == approved.missing and std.mem.eql(u8, &self.head, &approved.head) and self.branch.eql(approved.branch.slice());
    }
};

pub const Operation = struct {
    kind: Kind = .none,
    key: u64 = 0,
    project_id: u64 = 0,
    workspace_id: u64 = 0,
    force: bool = false,
    approved: ?RemovalSafety = null,
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
            .remove_status => .{ .inspect = .{
                .repo = (store.projectForWorkspace(self.workspace_id) orelse return null).repo_root.slice(),
                .path = (store.findWorktree(self.workspace_id) orelse return null).path.slice(),
            } },
            .remove_worktree => .{ .remove_worktree = .{ .repo = (store.findProject(self.project_id) orelse return null).repo_root.slice(), .path = self.target_path.slice(), .force = self.force, .approved = self.approved } },
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
    completion_ready: bool = false,
    next_key: u64 = @import("effect_keys.zig").first(.git),

    pub fn notified(self: *Lane, key: u64) void {
        if (self.busy() and self.active.key == key) self.completion_ready = true;
    }

    pub fn busy(self: *const Lane) bool {
        return self.active.kind != .none;
    }

    pub fn begin(self: *Lane, operation: Operation) ?u64 {
        if (self.busy() or operation.kind == .none) return null;
        self.completion_ready = false;
        self.active = operation;
        self.active.key = @import("effect_keys.zig").advance(&self.next_key);
        return self.active.key;
    }

    pub fn finish(self: *Lane, key: u64) ?Operation {
        if (!self.busy() or self.active.key != key) return null;
        const operation = self.active;
        self.completion_ready = false;
        self.active = .{};
        return operation;
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
        .remove_status, .remove_worktree => try std.testing.expectEqual(Kind.Group.removal, kind.group()),
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

test "removal safety compares HEAD even when warning counts are unchanged" {
    const approved: RemovalSafety = .{};
    var current = approved;
    current.head[0] = 1;
    try std.testing.expect(!current.matches(approved));
}

test "inspection always targets the actual worktree regardless of cached branch" {
    const store = try workspaces.Store.create(std.testing.allocator);
    defer store.destroy();
    const attached = store.attachPlaceholder("/tmp/root").?;
    try std.testing.expect(store.markGit(attached.project_id, "/tmp/root"));
    const tree = store.findWorktree(attached.workspace_id).?;
    _ = tree.path.set("/tmp/detached tree");
    _ = tree.branch.set("old cached branch");
    const operation: Operation = .{ .kind = .remove_status, .workspace_id = tree.id };
    const request = operation.request(store).?.inspect;
    try std.testing.expectEqualStrings("/tmp/detached tree", request.path);
}
