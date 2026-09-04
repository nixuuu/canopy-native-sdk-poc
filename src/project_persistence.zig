//! Project snapshot read/write sequencing without host file effects.
const std = @import("std");
const workspaces = @import("workspaces.zig");

pub const Restore = union(enum) { ready, waiting_read, scanning: usize };
pub const Write = union(enum) { unavailable, deferred, start: u64 };
pub const WriteFinish = enum { ignored, idle, restart };

pub const State = struct {
    path: workspaces.PathText = .{},
    restore: Restore = .ready,
    next_write_key: u64 = @import("effect_keys.zig").first(.projects),
    active_write_key: ?u64 = null,
    write_dirty: bool = false,

    pub fn configure(self: *State, path: []const u8) bool {
        if (!self.path.set(path)) return false;
        self.restore = if (path.len == 0) .ready else .waiting_read;
        return true;
    }

    pub fn ready(self: *const State) bool {
        return self.restore == .ready;
    }

    pub fn scanning(self: *const State) bool {
        return self.restore == .scanning;
    }

    pub fn skipRestore(self: *State) void {
        self.restore = .ready;
    }

    pub fn beginRead(self: *const State) ?[]const u8 {
        if (self.restore != .waiting_read or self.path.len == 0) return null;
        return self.path.slice();
    }

    pub fn beginScan(self: *State) void {
        self.restore = .{ .scanning = 0 };
    }

    pub fn nextAttachedProject(self: *State, store: *const workspaces.Store) ?u64 {
        var index = switch (self.restore) {
            .scanning => |value| value,
            else => return null,
        };
        while (index < store.projects.items.len) {
            const project = store.projects.items[index];
            index += 1;
            self.restore = .{ .scanning = index };
            if (project.attached) return project.id;
        }
        self.restore = .ready;
        return null;
    }

    pub fn requestWrite(self: *State) Write {
        if (self.path.len == 0) return .unavailable;
        if (self.active_write_key != null) {
            self.write_dirty = true;
            return .deferred;
        }
        const key = @import("effect_keys.zig").advance(&self.next_write_key);
        self.active_write_key = key;
        return .{ .start = key };
    }

    pub fn writeFinished(self: *State, key: u64) WriteFinish {
        if (self.active_write_key != key) return .ignored;
        self.active_write_key = null;
        if (!self.write_dirty) return .idle;
        self.write_dirty = false;
        return .restart;
    }
};

test "restore scans attached projects exactly once" {
    const store = try workspaces.Store.create(std.testing.allocator);
    defer store.destroy();
    const first = store.attachPlaceholder("/tmp/first").?;
    const detached = store.attachPlaceholder("/tmp/detached").?;
    const last = store.attachPlaceholder("/tmp/last").?;
    _ = store.detach(detached.project_id);
    var state: State = .{};
    try std.testing.expect(state.configure("/tmp/projects.store"));
    try std.testing.expect(!state.ready());
    try std.testing.expectEqualStrings("/tmp/projects.store", state.beginRead().?);
    state.beginScan();
    try std.testing.expectEqual(first.project_id, state.nextAttachedProject(store).?);
    try std.testing.expectEqual(last.project_id, state.nextAttachedProject(store).?);
    try std.testing.expect(state.nextAttachedProject(store) == null);
    try std.testing.expect(state.ready());
}

test "writes coalesce without queuing multiple host effects" {
    var state: State = .{};
    try std.testing.expectEqual(Write.unavailable, state.requestWrite());
    try std.testing.expect(state.configure("/tmp/projects.store"));
    try std.testing.expectEqual(@import("effect_keys.zig").first(.projects), state.requestWrite().start);
    try std.testing.expectEqual(Write.deferred, state.requestWrite());
    try std.testing.expect(state.active_write_key != null and state.write_dirty);
    try std.testing.expectEqual(WriteFinish.ignored, state.writeFinished(999));
    try std.testing.expectEqual(WriteFinish.restart, state.writeFinished(@import("effect_keys.zig").first(.projects)));
    try std.testing.expectEqual(@import("effect_keys.zig").first(.projects) + 1, state.requestWrite().start);
    try std.testing.expectEqual(WriteFinish.idle, state.writeFinished(@import("effect_keys.zig").first(.projects) + 1));
    try std.testing.expect(state.active_write_key == null and !state.write_dirty);
}
