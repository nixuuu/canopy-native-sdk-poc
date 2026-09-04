const support = @import("support.zig");
const std = support.std;
const app = support.app;
const profiles = support.profiles;
const workspaces = support.workspaces;
const Stores = support.Stores;

test "empty store exposes the attach-project state" {
    const stores = try Stores.init();
    defer stores.deinit();
    var model = app.initialModel(stores.tabs, stores.projects, stores.profiles);
    defer model.terminal_state.deinit(std.testing.allocator);
    try std.testing.expect(!model.hasProjects());
    try std.testing.expectEqual(@as(usize, 0), model.projectCount());
}

test "attached folder appears as a selected workspace" {
    const stores = try Stores.init();
    defer stores.deinit();
    var model = app.initialModel(stores.tabs, stores.projects, stores.profiles);
    defer model.terminal_state.deinit(std.testing.allocator);
    const attached = stores.projects.attachPlaceholder("/tmp/canopy-test-project").?;
    model.active_workspace_id = attached.workspace_id;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const rows = model.sidebarRows(arena_state.allocator());
    try std.testing.expectEqual(@as(usize, 2), rows.len);
    try std.testing.expectEqual(workspaces.RowKind.project, rows[0].kind);
    try std.testing.expectEqualStrings("canopy-test-project", rows[1].name);
    try std.testing.expect(rows[1].selected);
}
