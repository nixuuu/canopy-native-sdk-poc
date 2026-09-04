//! Model-owned terminal metadata; the selected backend owns PTY and rendering.

const std = @import("std");
const profiles = @import("profiles.zig");
const workspaces = @import("workspaces.zig");

pub const Phase = enum { starting, running, closing, exited, failed };
pub const Tool = enum { shell, claude, codex };

pub const Tab = struct {
    pending_launch: ?*@import("terminal_launch.zig").Pending = null,
    id: u64 = 0,
    workspace_id: u64 = 0,
    pty: u64 = 0,
    title: workspaces.NameText = .{},
    path: workspaces.PathText = .{},
    branch: workspaces.BranchText = .{},
    tool: Tool = .shell,
    profile_id: profiles.IdText = .{},
    phase: Phase = .starting,
    exit_code: i32 = 0,
};

pub const Row = struct {
    id: u64,
    pty: u64,
    title: []const u8,
    path: []const u8,
    branch: []const u8,
    tool: Tool,
    phase: Phase,
    exit_code: i32,
    selected: bool,
};

pub const Store = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayListUnmanaged(Tab) = .empty,
    free_pty_keys: std.ArrayListUnmanaged(u64) = .empty,

    pub fn create(allocator: std.mem.Allocator) !*Store {
        const store = try allocator.create(Store);
        store.* = .{ .allocator = allocator };
        return store;
    }

    pub fn destroy(store: *Store) void {
        const allocator = store.allocator;
        for (store.items.items) |tab| if (tab.pending_launch) |pending| pending.destroy();
        store.items.deinit(allocator);
        store.free_pty_keys.deinit(allocator);
        allocator.destroy(store);
    }

    pub fn allocatePtyKey(store: *Store, next: *u64) u64 {
        if (store.free_pty_keys.pop()) |key| return key;
        const key = next.*;
        next.* +%= 1;
        return key;
    }

    pub fn releasePtyKey(store: *Store, key: u64) void {
        store.free_pty_keys.append(store.allocator, key) catch {};
    }

    pub fn countForWorkspace(store: *const Store, workspace_id: u64) usize {
        var count: usize = 0;
        for (store.items.items) |tab| if (tab.workspace_id == workspace_id) {
            count += 1;
        };
        return count;
    }

    pub fn hasWorkspace(store: *const Store, workspace_id: u64) bool {
        return store.countForWorkspace(workspace_id) > 0;
    }

    pub fn replacementForWorkspace(store: *const Store, workspace_id: u64) u64 {
        var replacement: u64 = 0;
        for (store.items.items) |tab| {
            if (tab.workspace_id != workspace_id or tab.phase == .closing) continue;
            replacement = tab.id;
        }
        return replacement;
    }

    pub fn rows(store: *const Store, arena: std.mem.Allocator, workspace_id: u64, active_id: u64, limit: usize) []const Row {
        const workspace_count = store.countForWorkspace(workspace_id);
        var active_ordinal: usize = 0;
        var ordinal: usize = 0;
        for (store.items.items) |*tab| {
            if (tab.workspace_id != workspace_id) continue;
            if (tab.id == active_id) active_ordinal = ordinal;
            ordinal += 1;
        }

        const visible_count = @min(workspace_count, limit);
        const preferred_start = active_ordinal -| limit / 2;
        const start = @min(preferred_start, workspace_count -| visible_count);
        const out = arena.alloc(Row, visible_count) catch return &.{};
        ordinal = 0;
        var count: usize = 0;
        for (store.items.items) |*tab| {
            if (tab.workspace_id != workspace_id) continue;
            defer ordinal += 1;
            if (ordinal < start or ordinal >= start + visible_count) continue;
            out[count] = .{
                .id = tab.id,
                .pty = tab.pty,
                .title = tab.title.slice(),
                .path = tab.path.slice(),
                .branch = tab.branch.slice(),
                .tool = tab.tool,
                .phase = tab.phase,
                .exit_code = tab.exit_code,
                .selected = tab.id == active_id,
            };
            count += 1;
        }
        return out[0..count];
    }
};

test "rows keep the active tab inside bounded chrome" {
    const store = try Store.create(std.testing.allocator);
    defer store.destroy();
    for (0..20) |index| try store.items.append(std.testing.allocator, .{
        .id = index + 1,
        .workspace_id = 7,
        .pty = index + 100,
    });
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const projected = store.rows(arena.allocator(), 7, 18, 12);
    try std.testing.expectEqual(@as(usize, 12), projected.len);
    try std.testing.expect(projected[9].selected);
    try std.testing.expectEqual(@as(u64, 18), projected[9].id);
}
