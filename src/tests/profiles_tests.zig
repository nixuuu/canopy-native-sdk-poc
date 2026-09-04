const support = @import("support.zig");
const std = support.std;
const app = support.app;
const profiles = support.profiles;
const Stores = support.Stores;
const addProfile = support.addProfile;

test "profile switch confirmation preserves edits on cancel and discards only on confirm" {
    const stores = try Stores.init();
    defer stores.deinit();
    _ = try addProfile(stores, 1, .claude, "First");
    _ = try addProfile(stores, 2, .claude, "Second");
    var model = app.initialModel(stores.tabs, stores.projects, stores.profiles);
    model.profile_edit.loaded = true;
    var fx = app.Effects.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    app.update(&model, .show_preferences_claude, &fx);
    model.profile_edit.draft.name.set("Unsaved");
    model.profile_edit.dirty = true;
    app.update(&model, .{ .select_profile = 2 }, &fx);
    try std.testing.expect(model.profileSwitchDialogOpen());
    try std.testing.expectEqual(@as(u64, 1), model.profile_edit.selected_id);
    app.update(&model, .cancel_profile_switch, &fx);
    try std.testing.expect(model.profile_edit.dirty and !model.profileSwitchDialogOpen());
    try std.testing.expectEqualStrings("Unsaved", model.profile_edit.draft.name.text());
    app.update(&model, .{ .select_profile = 2 }, &fx);
    app.update(&model, .confirm_profile_switch, &fx);
    try std.testing.expect(!model.profile_edit.dirty and !model.profileSwitchDialogOpen());
    try std.testing.expectEqual(@as(u64, 2), model.profile_edit.selected_id);
    try std.testing.expectEqualStrings("Second", model.profile_edit.draft.name.text());
    try std.testing.expectEqual(@as(usize, 0), fx.pendingDbCount());
}

test "failed profile save preserves draft and can be retried without switching during write" {
    const stores = try Stores.init();
    defer stores.deinit();
    _ = try addProfile(stores, 1, .claude, "First");
    _ = try addProfile(stores, 2, .claude, "Second");
    var model = app.initialModel(stores.tabs, stores.projects, stores.profiles);
    model.profile_edit.loaded = true;
    var fx = app.Effects.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    app.update(&model, .show_preferences_claude, &fx);
    model.profile_edit.draft.name.set("Edited");
    model.profile_edit.dirty = true;
    app.update(&model, .save_profile, &fx);
    app.update(&model, .{ .select_profile = 2 }, &fx);
    try std.testing.expectEqual(@as(u64, 1), model.profile_edit.selected_id);
    try std.testing.expectEqual(@as(usize, 1), fx.pendingDbCount());
    try fx.feedDbResult(app.profile_write_key, .exec, .busy, "");
    while (fx.takeMsg()) |msg| app.update(&model, msg, &fx);
    try std.testing.expect(!model.profile_edit.saving() and model.profile_edit.dirty);
    try std.testing.expectEqualStrings("Edited", model.profile_edit.draft.name.text());
    try std.testing.expectEqual(@as(usize, 0), fx.pendingDbCount());
    app.update(&model, .save_profile, &fx);
    try std.testing.expectEqual(@as(usize, 1), fx.pendingDbCount());
}

test "profile editor saves compatible prefs JSON before reloading rows" {
    const stores = try Stores.init();
    defer stores.deinit();
    var model = app.initialModel(stores.tabs, stores.projects, stores.profiles);
    defer model.terminal_state.deinit(std.testing.allocator);
    _ = try addProfile(stores, 1, .codex, "Default");
    model.preferences_edit.loaded = true;
    model.profile_edit.loaded = true;
    var fx = app.Effects.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    app.update(&model, .open_preferences, &fx);
    app.update(&model, .show_preferences_codex, &fx);
    model.profile_edit.draft.model.set("gpt-5.6");
    model.profile_edit.draft.sandbox.set("workspace-write");
    model.profile_edit.draft.full_auto = true;
    model.profile_edit.dirty = true;
    app.update(&model, .save_profile, &fx);
    try std.testing.expect(model.profile_edit.saving());
    try std.testing.expectEqual(@as(usize, 1), fx.pendingDbCount());

    try fx.feedDbResult(app.profile_write_key, .exec, .ok, "");
    while (fx.takeMsg()) |msg| app.update(&model, msg, &fx);
    try std.testing.expect(!model.profile_edit.saving());
    try std.testing.expectEqual(@as(usize, 1), fx.pendingDbCount());
}
