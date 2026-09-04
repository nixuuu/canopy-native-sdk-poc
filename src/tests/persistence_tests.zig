const support = @import("support.zig");
const std = support.std;
const app = support.app;
const profiles = support.profiles;
const Stores = support.Stores;

test "project persistence coalesces writes and picker waits for restore" {
    const stores = try Stores.init();
    defer stores.deinit();
    const one = stores.projects.attachPlaceholder("/tmp/persist-one").?;
    const two = stores.projects.attachPlaceholder("/tmp/persist-two").?;
    var model = app.initialModel(stores.tabs, stores.projects, stores.profiles);
    defer model.terminal_state.deinit(std.testing.allocator);
    try std.testing.expect(model.project_io.configure("/tmp/canopy-projects.store"));
    var fx = app.Effects.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    app.update(&model, .open_folder, &fx);
    try std.testing.expectEqual(@as(u64, 0), model.picker_serial);
    model.project_io.skipRestore();

    app.update(&model, .{ .request_detach_project = one.project_id }, &fx);
    app.update(&model, .confirm_detach_project, &fx);
    try std.testing.expectEqual(@as(usize, 1), fx.pendingFileCount());
    try std.testing.expect(std.mem.indexOf(u8, fx.pendingFileAt(0).?.bytes, "/tmp/persist-two") != null);
    app.update(&model, .{ .request_detach_project = two.project_id }, &fx);
    app.update(&model, .confirm_detach_project, &fx);
    try std.testing.expectEqual(@as(usize, 1), fx.pendingFileCount());
    try std.testing.expect(model.project_io.write_dirty);

    const first_key = fx.pendingFileAt(0).?.key;
    try fx.feedFileResult(first_key, .ok, "");
    while (fx.takeMsg()) |msg| app.update(&model, msg, &fx);
    try std.testing.expectEqual(@as(usize, 1), fx.pendingFileCount());
    try std.testing.expectEqualStrings("CANOPY_PROJECTS_V1\n", fx.pendingFileAt(0).?.bytes);
}

test "detach waits for every owned terminal and leaves unrelated sessions running" {
    const stores = try Stores.init();
    defer stores.deinit();
    const first = stores.projects.attachPlaceholder("/tmp/detach-first").?;
    const other = stores.projects.attachPlaceholder("/tmp/detach-other").?;
    var model = app.initialModel(stores.tabs, stores.projects, stores.profiles);
    defer model.terminal_state.deinit(std.testing.allocator);
    try std.testing.expect(model.project_io.configure("/tmp/canopy-detach.store"));
    var fx = app.Effects.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    app.update(&model, .{ .open_terminal = first.workspace_id }, &fx);
    const pty_one = fx.pendingPtyAt(0).?.key;
    app.update(&model, .{ .open_terminal = first.workspace_id }, &fx);
    const pty_two = fx.pendingPtyAt(1).?.key;
    app.update(&model, .{ .open_terminal = other.workspace_id }, &fx);
    const pty_other = fx.pendingPtyAt(2).?.key;
    app.update(&model, .{ .request_detach_project = first.project_id }, &fx);
    app.update(&model, .confirm_detach_project, &fx);
    try std.testing.expect(model.busy());
    try std.testing.expect(fx.ptyKillRequested(pty_one));
    try std.testing.expect(fx.ptyKillRequested(pty_two));
    try std.testing.expect(!fx.ptyKillRequested(pty_other));
    app.update(&model, .{ .request_detach_project = other.project_id }, &fx);
    app.update(&model, .confirm_detach_project, &fx);
    app.update(&model, .{ .open_terminal = first.workspace_id }, &fx);
    try std.testing.expectEqual(@as(usize, 3), stores.tabs.items.items.len);
    try std.testing.expectEqual(first.project_id, model.teardown.closing_project);
    try fx.feedPtyExit(pty_two, -1, 0, .cancelled, 0);
    while (fx.takeMsg()) |msg| app.update(&model, msg, &fx);
    try std.testing.expect(stores.projects.findProject(first.project_id).?.attached);
    try std.testing.expectEqual(@as(usize, 0), fx.pendingFileCount());
    try fx.feedPtyExit(pty_one, -1, 0, .cancelled, 0);
    while (fx.takeMsg()) |msg| app.update(&model, msg, &fx);
    try std.testing.expect(!model.busy());
    try std.testing.expect(!stores.projects.findProject(first.project_id).?.attached);
    try std.testing.expect(stores.projects.findProject(other.project_id).?.attached);
    try std.testing.expectEqual(@as(usize, 1), stores.tabs.items.items.len);
    try std.testing.expectEqual(pty_other, stores.tabs.items.items[0].pty);
    try std.testing.expectEqual(other.workspace_id, model.active_workspace_id);
    try std.testing.expectEqual(@as(usize, 1), fx.pendingFileCount());
}

test "preferences save commits one SQLite transaction into application state" {
    const stores = try Stores.init();
    defer stores.deinit();
    var model = app.initialModel(stores.tabs, stores.projects, stores.profiles);
    defer model.terminal_state.deinit(std.testing.allocator);
    model.preferences_edit.loaded = true;
    try std.testing.expect(model.default_worktrees_base.set("/tmp/default-worktrees"));
    var fx = app.Effects.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    app.update(&model, .open_preferences, &fx);
    app.update(&model, .toggle_preferences_reopen, &fx);
    app.update(&model, .use_dark_appearance, &fx);
    model.preferences_edit.base_dir.set("/tmp/custom-worktrees");
    model.preferences_edit.dirty = true;
    app.update(&model, .save_preferences, &fx);
    try std.testing.expect(model.preferences_edit.saving);
    try std.testing.expectEqual(@as(usize, 1), fx.pendingDbCount());

    try fx.feedDbResult(app.preferences_write_key, .exec, .ok, "");
    while (fx.takeMsg()) |msg| app.update(&model, msg, &fx);
    try std.testing.expect(model.preferences_edit.open);
    try std.testing.expect(!model.preferences_edit.dirty);
    try std.testing.expect(!model.preferences_edit.saved.reopen_last_workspace);
    try std.testing.expectEqual(@import("../preferences.zig").AppearanceMode.dark, model.preferences_edit.saved.appearance_mode);
    try std.testing.expectEqualStrings("/tmp/custom-worktrees", stores.projects.worktrees_base.slice());
    try std.testing.expectEqual(@as(u64, 1), model.worktrees_base_serial);
}
