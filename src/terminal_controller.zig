//! Terminal identity, selection and metadata lifecycle, independent of PTY effects.
const std = @import("std");
const tabs = @import("terminal_tabs.zig");

pub const Identity = struct { tab_id: u64, pty_key: u64 };
pub const Removed = struct { pty_key: u64, workspace_id: u64 };
pub const Close = union(enum) { missing, removed: Removed, waiting: u64 };
pub const Output = enum { missing, ignored, running };
pub const Exit = union(enum) { missing, removed: Removed, completed: tabs.Phase };

pub const State = struct {
    active_by_workspace: std.AutoHashMapUnmanaged(u64, u64) = .empty,
    next_tab_id: u64 = 1,
    next_pty_key: u64 = @import("effect_keys.zig").first(.pty),

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        self.active_by_workspace.deinit(allocator);
        self.* = .{};
    }

    pub fn active(self: *const State, workspace_id: u64) u64 {
        return self.active_by_workspace.get(workspace_id) orelse 0;
    }

    pub fn select(self: *State, store: *const tabs.Store, workspace_id: u64, tab_id: u64) void {
        if (tab_id == 0) {
            _ = self.active_by_workspace.remove(workspace_id);
            return;
        }
        self.active_by_workspace.put(store.allocator, workspace_id, tab_id) catch {};
    }

    pub fn allocate(self: *State, store: *tabs.Store) Identity {
        const identity: Identity = .{
            .tab_id = self.next_tab_id,
            .pty_key = store.allocatePtyKey(&self.next_pty_key),
        };
        self.next_tab_id +%= 1;
        return identity;
    }

    pub fn rollback(self: *State, store: *tabs.Store, identity: Identity) void {
        _ = self;
        store.releasePtyKey(identity.pty_key);
    }

    pub fn removeAt(self: *State, store: *tabs.Store, index: usize) Removed {
        const removed = store.items.orderedRemove(index);
        if (removed.pending_launch) |pending| pending.destroy();
        store.releasePtyKey(removed.pty);
        if (self.active(removed.workspace_id) == removed.id) {
            self.select(store, removed.workspace_id, store.replacementForWorkspace(removed.workspace_id));
        }
        return .{ .pty_key = removed.pty, .workspace_id = removed.workspace_id };
    }

    pub fn activate(self: *State, store: *const tabs.Store, workspace_id: u64, tab_id: u64) bool {
        for (store.items.items) |tab| {
            if (tab.id != tab_id or tab.workspace_id != workspace_id) continue;
            self.select(store, workspace_id, tab_id);
            return true;
        }
        return false;
    }

    pub fn close(self: *State, store: *tabs.Store, tab_id: u64) Close {
        var index: ?usize = null;
        for (store.items.items, 0..) |tab, candidate| {
            if (tab.id == tab_id) {
                index = candidate;
                break;
            }
        }
        const found = index orelse return .missing;
        const tab = &store.items.items[found];
        if (tab.phase == .closing) return .missing;
        if (tab.phase == .exited or tab.phase == .failed) return .{ .removed = self.removeAt(store, found) };
        tab.phase = .closing;
        if (self.active(tab.workspace_id) == tab_id) {
            self.select(store, tab.workspace_id, store.replacementForWorkspace(tab.workspace_id));
        }
        return .{ .waiting = tab.pty };
    }

    pub fn closeWorkspace(self: *State, store: *tabs.Store, workspace_id: u64, sink: anytype) void {
        var index = store.items.items.len;
        while (index > 0) {
            index -= 1;
            const tab = store.items.items[index];
            if (tab.workspace_id == workspace_id) sink.closed(self.close(store, tab.id));
        }
    }

    pub fn output(_: *State, store: *tabs.Store, pty_key: u64) Output {
        for (store.items.items) |*tab| {
            if (tab.pty != pty_key) continue;
            if (tab.phase == .closing) return .ignored;
            tab.phase = .running;
            return .running;
        }
        return .missing;
    }

    pub fn exit(self: *State, store: *tabs.Store, pty_key: u64, code: i32, clean: bool) Exit {
        for (store.items.items, 0..) |*tab, index| {
            if (tab.pty != pty_key) continue;
            if (tab.phase == .closing) return .{ .removed = self.removeAt(store, index) };
            tab.exit_code = code;
            tab.phase = if (clean) .exited else .failed;
            return .{ .completed = tab.phase };
        }
        return .missing;
    }

    pub fn cycle(self: *State, store: *const tabs.Store, workspace_id: u64, forward: bool) ?u64 {
        const count = store.countForWorkspace(workspace_id);
        if (count < 2) return null;
        const selected = self.active(workspace_id);
        var ordinal: usize = 0;
        var selected_ordinal: usize = 0;
        for (store.items.items) |tab| {
            if (tab.workspace_id != workspace_id) continue;
            if (tab.id == selected) selected_ordinal = ordinal;
            ordinal += 1;
        }
        const target = if (forward)
            (selected_ordinal + 1) % count
        else if (selected_ordinal == 0)
            count - 1
        else
            selected_ordinal - 1;
        ordinal = 0;
        for (store.items.items) |tab| {
            if (tab.workspace_id != workspace_id) continue;
            if (ordinal == target) {
                self.select(store, workspace_id, tab.id);
                return tab.id;
            }
            ordinal += 1;
        }
        return null;
    }
};

test "terminal identities stay monotonic while PTY keys are recycled" {
    const store = try tabs.Store.create(std.testing.allocator);
    defer store.destroy();
    var state: State = .{};
    defer state.deinit(std.testing.allocator);
    const first = state.allocate(store);
    try store.items.append(store.allocator, .{ .id = first.tab_id, .workspace_id = 7, .pty = first.pty_key });
    state.select(store, 7, first.tab_id);
    const removed = state.removeAt(store, 0);
    try std.testing.expectEqual(first.pty_key, removed.pty_key);
    try std.testing.expectEqual(@as(u64, 0), state.active(7));
    try std.testing.expectEqual(@as(usize, 0), state.active_by_workspace.count());
    const second = state.allocate(store);
    try std.testing.expect(second.tab_id > first.tab_id);
    try std.testing.expectEqual(first.pty_key, second.pty_key);
}

test "activation and cycling remain workspace scoped" {
    const store = try tabs.Store.create(std.testing.allocator);
    defer store.destroy();
    var state: State = .{};
    defer state.deinit(std.testing.allocator);
    for ([_]tabs.Tab{
        .{ .id = 1, .workspace_id = 7, .pty = 11 },
        .{ .id = 2, .workspace_id = 8, .pty = 12 },
        .{ .id = 3, .workspace_id = 7, .pty = 13 },
    }) |tab| try store.items.append(store.allocator, tab);
    try std.testing.expect(!state.activate(store, 7, 2));
    try std.testing.expect(state.activate(store, 7, 1));
    try std.testing.expectEqual(@as(?u64, 3), state.cycle(store, 7, true));
    try std.testing.expectEqual(@as(?u64, 1), state.cycle(store, 7, true));
    try std.testing.expectEqual(@as(?u64, 3), state.cycle(store, 7, false));
    try std.testing.expectEqual(@as(u64, 0), state.active(8));
}

test "close and process events retire a tab exactly once" {
    const store = try tabs.Store.create(std.testing.allocator);
    defer store.destroy();
    var state: State = .{};
    defer state.deinit(std.testing.allocator);
    try store.items.append(store.allocator, .{ .id = 1, .workspace_id = 7, .pty = 11 });
    try store.items.append(store.allocator, .{ .id = 2, .workspace_id = 7, .pty = 12 });
    state.select(store, 7, 1);
    try std.testing.expectEqual(@as(u64, 11), state.close(store, 1).waiting);
    try std.testing.expectEqual(@as(u64, 2), state.active(7));
    try std.testing.expectEqual(Output.ignored, state.output(store, 11));
    try std.testing.expectEqual(tabs.Phase.closing, store.items.items[0].phase);
    try std.testing.expectEqual(@as(u64, 11), state.exit(store, 11, 0, false).removed.pty_key);
    try std.testing.expectEqual(@as(usize, 1), store.items.items.len);
    try std.testing.expectEqual(Exit.missing, state.exit(store, 11, 0, true));
    try std.testing.expectEqual(tabs.Phase.starting, store.items.items[0].phase);
    try std.testing.expectEqual(Output.running, state.output(store, 12));
    try std.testing.expectEqual(tabs.Phase.running, store.items.items[0].phase);
    try std.testing.expectEqual(tabs.Phase.failed, state.exit(store, 12, 9, false).completed);
    try std.testing.expectEqual(@as(i32, 9), store.items.items[0].exit_code);
    try std.testing.expectEqual(@as(u64, 12), state.close(store, 2).removed.pty_key);
    try std.testing.expectEqual(@as(usize, 0), store.items.items.len);
}
