//! Approved teardown owns one target until terminal exit and safety recheck.
//! No process or persistence effects live here.
const std = @import("std");
const RemovalSafety = @import("git_workflow.zig").RemovalSafety;

pub const Removal = struct { workspace_id: u64, approved: RemovalSafety };
pub const Target = union(enum) { workspace: u64, project: u64 };
pub const Next = union(enum) { recheck: u64, detach: u64 };
pub const Review = union(enum) { initial, changed, remove: struct { workspace_id: u64, force: bool } };

pub const State = union(enum) {
    idle,
    closing_worktree: Removal,
    rechecking_worktree: Removal,
    closing_project: u64,

    pub fn busy(self: State) bool {
        return self != .idle;
    }

    pub fn waitingFor(self: State) ?Target {
        return if (self == .rechecking_worktree) null else self.target();
    }

    pub fn target(self: State) ?Target {
        return switch (self) {
            .closing_worktree, .rechecking_worktree => |removal| .{ .workspace = removal.workspace_id },
            .closing_project => |id| .{ .project = id },
            else => null,
        };
    }

    // Claim the transition before dispatching an effect: duplicate exit
    // callbacks cannot start a second preflight or detach a project twice.
    pub fn terminalsClosed(self: *State) ?Next {
        switch (self.*) {
            .closing_worktree => |removal| {
                self.* = .{ .rechecking_worktree = removal };
                return .{ .recheck = removal.workspace_id };
            },
            .closing_project => |id| {
                self.* = .idle;
                return .{ .detach = id };
            },
            else => return null,
        }
    }

    pub fn reviewed(self: *State, safety: RemovalSafety) Review {
        const removal = switch (self.*) {
            .rechecking_worktree => |value| value,
            else => return .initial,
        };
        self.* = .idle;
        if (!safety.matches(removal.approved)) return .changed;
        return .{ .remove = .{ .workspace_id = removal.workspace_id, .force = safety.hasWarnings() } };
    }
};

test "worktree teardown advances once and only removes the approved safety state" {
    var state: State = .{ .closing_worktree = .{ .workspace_id = 7, .approved = .{} } };
    try std.testing.expectEqual(@as(u64, 7), state.waitingFor().?.workspace);
    try std.testing.expectEqual(@as(u64, 7), state.terminalsClosed().?.recheck);
    try std.testing.expect(state.busy());
    try std.testing.expect(state.waitingFor() == null);
    try std.testing.expect(state.terminalsClosed() == null);
    const removal = state.reviewed(.{}).remove;
    try std.testing.expectEqual(@as(u64, 7), removal.workspace_id);
    try std.testing.expect(!removal.force);
    try std.testing.expect(!state.busy());
    try std.testing.expectEqual(Review.initial, state.reviewed(.{}));
}

test "changed safety requires new approval and project completion is one shot" {
    var state: State = .{ .closing_worktree = .{ .workspace_id = 8, .approved = .{} } };
    _ = state.terminalsClosed();
    const warnings: RemovalSafety = .{ .unmerged_count = 1 };
    try std.testing.expectEqual(Review.changed, state.reviewed(warnings));
    try std.testing.expect(!state.busy());
    state = .{ .closing_worktree = .{ .workspace_id = 8, .approved = warnings } };
    _ = state.terminalsClosed();
    try std.testing.expect(state.reviewed(warnings).remove.force);
    state = .{ .closing_project = 9 };
    try std.testing.expectEqual(@as(u64, 9), state.waitingFor().?.project);
    try std.testing.expectEqual(@as(u64, 9), state.terminalsClosed().?.detach);
    try std.testing.expect(state.terminalsClosed() == null);
    try std.testing.expect(!state.busy());
}
