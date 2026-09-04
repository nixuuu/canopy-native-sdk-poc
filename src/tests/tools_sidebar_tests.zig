const support = @import("support.zig");
const std = support.std;
const app = support.app;
const sdk = support.sdk;

// Exercise compiled markup bindings, not just hand-constructed messages.
fn launcher(model: *app.Model, label: []const u8, height: f32) !struct { id: u64, msg: app.Msg } {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ui = sdk.canvas.Ui(app.Msg).init(arena.allocator());
    const tree = try ui.finalize(app.CompiledCanopyView.build(&ui, model));
    const nodes = try arena.allocator().alloc(sdk.canvas.WidgetLayoutNode, 1024);
    const layout = try sdk.canvas.layoutWidgetTree(tree.root, sdk.geometry.RectF.init(0, 0, 1180, 760), nodes);
    for (layout.nodes) |node| {
        if (!std.mem.eql(u8, node.widget.semantics.label, label)) continue;
        try std.testing.expectApproxEqAbs(height, node.frame.height, 0.01);
        return .{ .id = node.widget.id, .msg = tree.msgForPointer(node.widget.id, .up) orelse return error.MissingAction };
    }
    return error.MissingLauncher;
}

test "shared launcher routes each agent and preserves compact single-profile rows" {
    const stores = try support.Stores.init();
    defer stores.deinit();
    const attached = stores.projects.attachPlaceholder("/tmp/tool-sidebar").?;
    var model = app.initialModel(stores.tabs, stores.projects, stores.profiles);
    model.active_workspace_id = attached.workspace_id;
    model.profile_edit.loaded = true;
    model.tools.pending_checks = 0;
    _ = model.tools.setExecutable(.claude, "/usr/local/bin/claude");
    _ = model.tools.setExecutable(.codex, "/usr/local/bin/codex");
    _ = try support.addProfile(stores, 1, .claude, "Default");
    _ = try support.addProfile(stores, 2, .codex, "Default");
    const claude = try launcher(&model, "Launch Claude Code", 28);
    const codex = try launcher(&model, "Launch Codex", 28);
    try std.testing.expectEqual(support.profiles.AgentType.claude, claude.msg.launch_agent);
    try std.testing.expectEqual(support.profiles.AgentType.codex, codex.msg.launch_agent);
    try std.testing.expect(claude.id != codex.id);
    model.tools.claude.executable.len = 0;
    try std.testing.expectEqual(codex.id, (try launcher(&model, "Launch Codex", 28)).id);
}

test "shared launcher expands agent profiles independently and preserves profile actions" {
    const stores = try support.Stores.init();
    defer stores.deinit();
    const attached = stores.projects.attachPlaceholder("/tmp/tool-profiles").?;
    var model = app.initialModel(stores.tabs, stores.projects, stores.profiles);
    model.active_workspace_id = attached.workspace_id;
    model.profile_edit.loaded = true;
    model.tools.pending_checks = 0;
    _ = model.tools.setExecutable(.claude, "/usr/local/bin/claude");
    _ = model.tools.setExecutable(.codex, "/usr/local/bin/codex");
    _ = try support.addProfile(stores, 1, .claude, "Claude default");
    _ = try support.addProfile(stores, 2, .claude, "Claude review");
    _ = try support.addProfile(stores, 3, .codex, "Codex default");
    _ = try support.addProfile(stores, 4, .codex, "Codex review");
    var fx = app.Effects.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    try std.testing.expectError(error.MissingLauncher, launcher(&model, "Claude review", 24));
    app.update(&model, (try launcher(&model, "Claude Code profiles", 28)).msg, &fx);
    try std.testing.expect(model.tools.claude.expanded and !model.tools.codex.expanded);
    try std.testing.expectEqual(@as(u64, 2), (try launcher(&model, "Claude review", 24)).msg.launch_profile);
    app.update(&model, (try launcher(&model, "Codex profiles", 28)).msg, &fx);
    try std.testing.expect(model.tools.claude.expanded and model.tools.codex.expanded);
    try std.testing.expectEqual(@as(u64, 4), (try launcher(&model, "Codex review", 24)).msg.launch_profile);
    app.update(&model, (try launcher(&model, "Claude Code profiles", 28)).msg, &fx);
    try std.testing.expect(!model.tools.claude.expanded and model.tools.codex.expanded);
    try std.testing.expectError(error.MissingLauncher, launcher(&model, "Claude review", 24));
}
