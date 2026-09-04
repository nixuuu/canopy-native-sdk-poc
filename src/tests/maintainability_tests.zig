//! Regressions for the concrete failures identified in the architecture review.
const support = @import("support.zig");
const std = support.std;
const app = support.app;
const profiles = support.profiles;
const editor = @import("../profile_editor.zig");
const preferences = @import("../preferences_editor.zig");
const a = std.testing.allocator;

fn profileStore() !*profiles.Store {
    const store = try profiles.Store.create(a);
    errdefer store.destroy();
    for ([_]profiles.AgentType{ .claude, .codex }) |agent| {
        var profile: profiles.Profile = .{ .runtime_id = if (agent == .claude) 1 else 2, .agent_type = agent };
        _ = profile.id.set(@tagName(agent));
        _ = profile.name.set("Default");
        try store.items.append(a, profile);
    }
    return store;
}

test "all profile navigation preserves dirty drafts until explicit confirmation" {
    const store = try profileStore();
    defer store.destroy();
    var state: editor.State = .{ .loaded = true };
    state.load(store, 1);
    state.draft.model.set("unsaved");
    state.dirty = true;
    try std.testing.expect(!state.openAgent(store, .codex));
    try std.testing.expectEqualStrings("unsaved", state.draft.model.text());
    state.cancelSwitch();
    try std.testing.expect(state.dirty and state.draft.agent_type == .claude);
    try std.testing.expect(state.create(store, .claude) == null);
    try std.testing.expect(state.pending_switch.? == .new);
    state.cancelSwitch();
    try std.testing.expect(!state.requestReload(store));
    state.cancelSwitch();
    try std.testing.expect(!state.requestClose(store));
    state.cancelSwitch();
    try std.testing.expect(!state.openAgent(store, .codex));
    try std.testing.expect(state.confirmSwitch(store).? == .agent);
    try std.testing.expect(!state.dirty and state.draft.agent_type == .codex);
}

test "preference write freezes edits and commits only submitted snapshot" {
    var state: preferences.State = .{ .loaded = true };
    try std.testing.expect(state.openDialog());
    state.setAppearance(.dark);
    const sent = state.prepareSave().ready;
    try std.testing.expectEqualStrings("dark", sent.appearance);
    state.setAppearance(.light);
    state.toggleReopen();
    try std.testing.expectEqual(.dark, state.draft.appearance_mode);
    try std.testing.expect(state.draft.reopen_last_workspace);
    try std.testing.expect(state.finishSave(true, false).committed);
    try std.testing.expectEqual(.dark, state.saved.appearance_mode);
    try std.testing.expect(!state.dirty);
    try std.testing.expect(!state.finishSave(true, false).handled);
}

test "profile write freezes text toggles and navigation and retains failed draft" {
    const store = try profileStore();
    defer store.destroy();
    var state: editor.State = .{ .loaded = true };
    state.load(store, 2);
    state.draft.model.set("saved model");
    state.dirty = true;
    var buffer: [profiles.max_encoded_bytes]u8 = undefined;
    try std.testing.expect(state.prepareSave(store, &buffer) == .ready);
    state.edit(.model, .{ .insert_text = "different" });
    state.toggleFullAuto();
    try std.testing.expect(!state.openAgent(store, .claude));
    try std.testing.expectEqualStrings("saved model", state.draft.model.text());
    try std.testing.expect(!state.draft.full_auto);
    try std.testing.expect(!state.finishWrite(false, true).reload);
    try std.testing.expect(state.dirty and !state.saving());
}

test "failed profile reload preserves previous snapshot and remains retryable" {
    const store = try profileStore();
    defer store.destroy();
    var state: editor.State = .{ .loaded = true };
    state.load(store, 1);
    state.beginReload(store, "claude");
    try std.testing.expectEqual(@as(usize, 2), store.items.items.len);
    try std.testing.expect(state.loaded and state.loading);
    try std.testing.expect(!store.appendEncodedPage("malformed"));
    state.load_valid = false;
    try std.testing.expect(!state.finishLoad(store, .claude));
    try std.testing.expect(state.loaded and !state.loading);
    try std.testing.expectEqual(@as(usize, 2), store.items.items.len);
    state.beginReload(store, "codex");
    var replacement: profiles.Profile = .{ .runtime_id = 9, .agent_type = .codex };
    _ = replacement.id.set("codex");
    _ = replacement.name.set("Updated");
    try store.pending_items.append(a, replacement);
    try std.testing.expect(state.finishLoad(store, .codex));
    try std.testing.expectEqual(@as(usize, 1), store.items.items.len);
    try std.testing.expectEqualStrings("Updated", state.draft.name.text());
}

test "profile decoding fails atomically and preserves unknown JSON on edit-save" {
    var prefs: profiles.Prefs = .{};
    _ = prefs.model.set("previous");
    try std.testing.expect(!profiles.decodePrefs(&prefs, "{broken"));
    try std.testing.expectEqualStrings("previous", prefs.model.slice());
    var too_long: [profiles.max_pref_bytes + 1]u8 = @splat('x');
    const bad = try std.fmt.allocPrint(a, "{{\"model\":\"{s}\"}}", .{&too_long});
    defer a.free(bad);
    try std.testing.expect(!profiles.decodePrefs(&prefs, bad));
    try std.testing.expectEqualStrings("previous", prefs.model.slice());
    try std.testing.expect(profiles.decodePrefs(&prefs, "{\"model\":\"old\",\"futureSetting\":{\"enabled\":true}}"));
    var profile: profiles.Profile = .{ .runtime_id = 1, .agent_type = .codex, .prefs = prefs };
    var draft: editor.Draft = .{};
    draft.load(&profile);
    draft.model.set("new");
    const edited = draft.toPrefs();
    var buffer: [profiles.max_encoded_bytes]u8 = undefined;
    const json = profiles.encodePrefs(&edited, &buffer).?;
    const decoded = try std.json.parseFromSlice(std.json.Value, a, json, .{});
    defer decoded.deinit();
    try std.testing.expect(decoded.value.object.get("futureSetting").?.object.get("enabled").?.bool);
    try std.testing.expectEqualStrings("new", decoded.value.object.get("model").?.string);
}

test "worktree snapshot failure preserves membership and collection waits for terminal owners" {
    const workspaces = support.workspaces;
    const store = try workspaces.Store.create(a);
    defer store.destroy();
    const attached = store.attachPlaceholder("/tmp/root").?;
    try std.testing.expect(@import("worktree_fixture.zig").apply(store, attached.project_id, "worktree /tmp/root\nbranch refs/heads/main\n\nworktree /tmp/linked\nbranch refs/heads/test\n\n"));
    const linked = store.findProject(attached.project_id).?.worktrees.items[1].id;
    var entries = try @import("worktree_fixture.zig").decode(a, "worktree /tmp/root\nbranch refs/heads/main\n\nworktree /tmp/root\nbranch refs/heads/other\n\n");
    defer entries.deinit(a);
    try std.testing.expectError(error.DuplicateWorktree, store.applySnapshot(attached.project_id, entries.items));
    try std.testing.expect(store.findWorktree(linked).?.active);
    const Owners = struct {
        held: u64,
        pub fn hasWorkspace(self: @This(), id: u64) bool {
            return self.held == id;
        }
    };
    try std.testing.expect(store.removeWorktree(linked));
    store.collectUnused(Owners{ .held = linked });
    try std.testing.expect(store.findWorktree(linked) != null);
    store.collectUnused(Owners{ .held = 0 });
    try std.testing.expect(store.findWorktree(linked) == null);
    try std.testing.expect(store.detach(attached.project_id));
    store.collectUnused(Owners{ .held = attached.workspace_id });
    try std.testing.expect(store.findProject(attached.project_id) != null);
    store.collectUnused(Owners{ .held = 0 });
    try std.testing.expectEqual(@as(usize, 0), store.projects.items.len);
}

test "native viewport uses a stable global key independent of accessibility label" {
    const stores = try support.Stores.init();
    defer stores.deinit();
    var model = app.initialModel(stores.tabs, stores.projects, stores.profiles);
    defer model.terminal_state.deinit(a);
    model.use_ghostty = true;
    model.active_workspace_id = stores.projects.attachPlaceholder("/tmp/viewport").?.workspace_id;
    try stores.tabs.items.append(a, .{ .id = 1, .pty = 1, .workspace_id = model.active_workspace_id });
    model.setActiveTab(model.active_workspace_id, 1);
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    // Build through the same compiled markup used by the app.
    var ui = support.sdk.canvas.Ui(app.Msg).init(arena.allocator());
    const tree = try ui.finalize(app.CompiledCanopyView.build(&ui, &model));
    const nodes = try arena.allocator().alloc(support.sdk.canvas.WidgetLayoutNode, 1024);
    const layout = try support.sdk.canvas.layoutWidgetTree(tree.root, support.sdk.geometry.RectF.init(0, 0, 1180, 760), nodes);
    var found = false;
    for (layout.nodes) |node| {
        if (node.widget.id == @import("../canvas_host.zig").terminal_viewport_id) {
            found = true;
            try std.testing.expect(node.frame.width > 0);
        }
    }
    try std.testing.expect(found);
}

test "metadata collection cannot shift the active restore cursor" {
    const stores = try support.Stores.init();
    defer stores.deinit();
    const first = stores.projects.attachPlaceholder("/tmp/first").?;
    const second = stores.projects.attachPlaceholder("/tmp/second").?;
    var model = app.initialModel(stores.tabs, stores.projects, stores.profiles);
    defer model.terminal_state.deinit(a);
    var fx = app.Effects.init(a);
    defer fx.deinit();
    fx.executor = .fake;
    model.project_io.beginScan();
    try std.testing.expectEqual(first.project_id, model.project_io.nextAttachedProject(stores.projects).?);
    try std.testing.expect(stores.projects.detach(first.project_id));
    app.update(&model, .{ .git_done = .{ .key = 1, .value = .ok } }, &fx);
    try std.testing.expectEqual(second.project_id, model.project_io.nextAttachedProject(stores.projects).?);
    try std.testing.expect(model.project_io.nextAttachedProject(stores.projects) == null);
    app.update(&model, .{ .git_done = .{ .key = 1, .value = .ok } }, &fx);
    try std.testing.expect(stores.projects.findProject(first.project_id) == null);
}

test "profile confirmation is the sole active dialog while preferences retain the draft" {
    const stores = try support.Stores.init();
    defer stores.deinit();
    var model = app.initialModel(stores.tabs, stores.projects, stores.profiles);
    defer model.terminal_state.deinit(a);
    model.preferences_edit.open = true;
    model.profile_edit.pending_switch = .{ .agent = .codex };
    model.profile_edit.draft.model.set("keep draft");
    model.profile_edit.dirty = true;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var ui = support.sdk.canvas.Ui(app.Msg).init(arena.allocator());
    const tree = try ui.finalize(app.CompiledCanopyView.build(&ui, &model));
    const nodes = try arena.allocator().alloc(support.sdk.canvas.WidgetLayoutNode, 1024);
    const layout = try support.sdk.canvas.layoutWidgetTree(tree.root, support.sdk.geometry.RectF.init(0, 0, 1180, 760), nodes);
    var dialogs: usize = 0;
    var confirmation = false;
    for (layout.nodes) |node| {
        if (node.widget.kind == .dialog) {
            dialogs += 1;
            confirmation = std.mem.eql(u8, node.widget.semantics.label, "Discard Profile Changes");
        }
    }
    try std.testing.expectEqual(@as(usize, 1), dialogs);
    try std.testing.expect(confirmation and model.preferences_edit.open);
    try std.testing.expectEqualStrings("keep draft", model.profile_edit.draft.model.text());
}

test "collecting a retired worktree preserves a valid active workspace" {
    const stores = try support.Stores.init();
    defer stores.deinit();
    const attached = stores.projects.attachPlaceholder("/tmp/root").?;
    try std.testing.expect(@import("worktree_fixture.zig").apply(stores.projects, attached.project_id, "worktree /tmp/root\nbranch refs/heads/main\n\nworktree /tmp/retired\nbranch refs/heads/test\n\n"));
    const retired = stores.projects.findProject(attached.project_id).?.worktrees.items[1].id;
    var model = app.initialModel(stores.tabs, stores.projects, stores.profiles);
    defer model.terminal_state.deinit(a);
    model.active_workspace_id = retired;
    try std.testing.expect(stores.projects.removeWorktree(retired));
    @import("../workspace_actions.zig").collectUnused(&model);
    try std.testing.expect(stores.projects.findWorktree(retired) == null);
    try std.testing.expectEqual(attached.workspace_id, model.active_workspace_id);
}
