//! Workspace dialog drafts and selections; Git/PTTY effects remain in main.
const std = @import("std");
const canvas = @import("native_sdk").canvas;
const git = @import("git_workflow.zig");
const workspaces = @import("workspaces.zig");

pub const Create = struct {
    open: bool = false,
    project_id: u64 = 0,
    branch: canvas.TextBuffer(workspaces.max_branch_bytes) = .{},
    select_after_refresh: workspaces.PathText = .{},
    failed: bool = false,

    pub fn begin(self: *Create, project_id: u64) void {
        self.project_id = project_id;
        self.branch.clear();
        self.open = true;
    }

    pub fn cancel(self: *Create) void {
        self.open = false;
        self.project_id = 0;
        self.branch.clear();
    }

    pub fn submitted(self: *Create) void {
        self.open = false;
    }

    pub fn trackCheckout(self: *Create, target: []const u8, failed: bool) void {
        self.failed = failed;
        _ = self.select_after_refresh.set(target);
    }

    pub fn finishRefresh(self: *Create, project_id: u64) void {
        if (project_id == self.project_id) self.project_id = 0;
    }
};

pub const Removal = struct {
    open: bool = false,
    workspace_id: u64 = 0,
    safety: git.RemovalSafety = .{},

    pub fn begin(self: *Removal, workspace_id: u64) void {
        self.workspace_id = workspace_id;
        self.safety = .{};
        self.open = false;
    }

    pub fn review(self: *Removal) void {
        self.open = true;
    }

    pub fn cancel(self: *Removal) void {
        self.open = false;
        self.workspace_id = 0;
    }

    pub fn submitted(self: *Removal) void {
        self.open = false;
    }
};

pub const Detach = struct {
    open: bool = false,
    project_id: u64 = 0,

    pub fn begin(self: *Detach, project_id: u64) void {
        self.project_id = project_id;
        self.open = true;
    }

    pub fn cancel(self: *Detach) void {
        self.open = false;
        self.project_id = 0;
    }

    pub fn submitted(self: *Detach) void {
        self.open = false;
    }
};

pub const State = struct { create: Create = .{}, removal: Removal = .{}, detach: Detach = .{} };

test "create dialog separates cancellation from submitted refresh state" {
    var state: State = .{};
    state.create.begin(7);
    state.create.branch.set("feature/test");
    state.create.submitted();
    state.create.trackCheckout("/tmp/feature", true);
    try std.testing.expect(!state.create.open and state.create.project_id == 7);
    try std.testing.expect(state.create.failed);
    try std.testing.expectEqualStrings("/tmp/feature", state.create.select_after_refresh.slice());
    state.create.finishRefresh(7);
    try std.testing.expectEqual(@as(u64, 0), state.create.project_id);
    state.create.begin(8);
    state.create.cancel();
    try std.testing.expectEqual(@as(u64, 0), state.create.project_id);
    try std.testing.expectEqualStrings("", state.create.branch.text());
}

test "removal and detach targets stay independent" {
    var state: State = .{};
    state.removal.begin(11);
    state.removal.safety.dirty = true;
    state.removal.review();
    state.detach.begin(22);
    try std.testing.expect(state.removal.open and state.detach.open);
    state.removal.submitted();
    state.detach.cancel();
    try std.testing.expectEqual(@as(u64, 11), state.removal.workspace_id);
    try std.testing.expectEqual(@as(u64, 0), state.detach.project_id);
}
