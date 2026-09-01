const std = @import("std");
const app = @import("main.zig");

test "workspace catalog preserves project and worktree identity" {
    try std.testing.expectEqual(@as(usize, 3), app.workspace_catalog.len);
    try std.testing.expectEqualStrings("next", app.workspace_catalog[0].branch);
    try std.testing.expectEqualStrings("worktree", app.workspace_catalog[1].kind);
    try std.testing.expect(app.workspace_catalog[0].id != app.workspace_catalog[1].id);
}

test "tabs are projected per active worktree" {
    const store = try app.TabStore.create(std.testing.allocator);
    defer store.destroy();
    var model = app.initialModel(store);
    try store.items.append(store.allocator, .{ .id = 7, .workspace_id = 1, .pty = 41, .title = "one" });
    try store.items.append(store.allocator, .{ .id = 8, .workspace_id = 2, .pty = 42, .title = "two" });
    model.active_tab_by_workspace[0] = 7;

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const visible = model.tabs(arena_state.allocator());
    try std.testing.expectEqual(@as(usize, 1), visible.len);
    try std.testing.expectEqual(@as(u16, 7), visible[0].id);
    try std.testing.expect(visible[0].selected);
}

test "tab storage grows beyond the historical four-session limit" {
    const store = try app.TabStore.create(std.testing.allocator);
    defer store.destroy();
    var model = app.initialModel(store);
    for (0..64) |index| {
        try store.items.append(store.allocator, .{
            .id = @intCast(index + 1),
            .workspace_id = 1,
            .pty = @intCast(index + 1),
            .phase = .running,
        });
    }
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    try std.testing.expectEqual(@as(usize, 64), store.items.items.len);
    try std.testing.expectEqual(@as(usize, 12), model.tabs(arena_state.allocator()).len);
}
