const support = @import("support.zig");
const std = support.std;
const sdk = support.sdk;
const canvas = sdk.canvas;
const app = support.app;
const a = std.testing.allocator;

test "tab strip has separated hit areas and only shows navigation for hidden tabs" {
    const stores = try support.Stores.init();
    defer stores.deinit();
    var model = app.initialModel(stores.tabs, stores.projects, stores.profiles);
    defer model.terminal_state.deinit(a);
    model.active_workspace_id = stores.projects.attachPlaceholder("/tmp/tab-strip").?.workspace_id;
    for ([_]usize{ 1, 2, 4, 14 }) |count| {
        stores.tabs.items.clearRetainingCapacity();
        for (0..count) |index| try stores.tabs.items.append(a, .{ .id = index + 1, .pty = index + 1, .workspace_id = model.active_workspace_id });
        model.setActiveTab(model.active_workspace_id, count);
        for ([_]f32{ 860, 1180, 2560 }) |width| {
            model.canvas_width = width;
            _ = model.syncTabStrip();
            var arena = std.heap.ArenaAllocator.init(a);
            defer arena.deinit();
            var ui = canvas.Ui(app.Msg).init(arena.allocator());
            const tree = try ui.finalize(app.CompiledCanopyView.build(&ui, &model));
            const nodes = try arena.allocator().alloc(canvas.WidgetLayoutNode, 2048);
            const layout = try canvas.layoutWidgetTree(tree.root, sdk.geometry.RectF.init(0, 0, width, 760), nodes);
            var scroll: ?sdk.geometry.RectF = null;
            var selected: ?sdk.geometry.RectF = null;
            var previous: ?sdk.geometry.RectF = null;
            var next: ?sdk.geometry.RectF = null;
            const strip_id = canvas.globalWidgetId(.row, .{ .str = "terminal-tab-strip" });
            for (layout.nodes) |node| {
                if (std.mem.eql(u8, node.widget.semantics.label, "Terminal tabs")) {
                    scroll = node.frame;
                    try std.testing.expectEqual(canvas.globalWidgetId(.scroll_view, .{ .str = "terminal-tabs" }), node.widget.id);
                }
                if (std.mem.eql(u8, node.widget.semantics.label, "Previous terminal")) previous = node.frame;
                if (std.mem.eql(u8, node.widget.semantics.label, "Next terminal")) next = node.frame;
                if (node.widget.semantics.role == .tab and node.widget.state.selected) selected = node.frame;
                var parent = node.parent_index;
                while (parent) |index| : (parent = layout.nodes[index].parent_index) {
                    if (layout.nodes[index].widget.id == strip_id) try std.testing.expect(node.widget.kind != .badge);
                }
            }
            try std.testing.expectEqual(model.tabsOverflow(), previous != null);
            try std.testing.expectEqual(model.tabsOverflow(), next != null);
            try std.testing.expect(scroll != null and selected != null);
            try std.testing.expect(selected.?.x >= scroll.?.x - 0.1);
            try std.testing.expect(selected.?.x + selected.?.width <= scroll.?.x + scroll.?.width + 0.1);
            if (previous) |button| try std.testing.expectApproxEqAbs(@as(f32, 6), scroll.?.x - button.x - button.width, 0.01);
            if (next) |button| try std.testing.expectApproxEqAbs(@as(f32, 6), button.x - scroll.?.x - scroll.?.width, 0.01);
        }
    }
}

const DecoratorModel = struct {};
const DecoratorMsg = union(enum) { noop };
const DecoratorApp = sdk.UiApp(DecoratorModel, DecoratorMsg);
fn decoratorUpdate(_: *DecoratorModel, _: DecoratorMsg) void {}
fn decoratorView(ui: *DecoratorApp.Ui, _: *const DecoratorModel) DecoratorApp.Ui.Node {
    return ui.el(.column, .{}, .{ui.text(.{}, "Compiled")});
}
fn decorate(_: *DecoratorApp.Ui, _: *const DecoratorModel, node: DecoratorApp.Ui.Node) DecoratorApp.Ui.Node {
    var result = node;
    result.widget.transform = canvas.Affine.translate(0, 4);
    return result;
}
test "SDK view decoration applies equally to compiled and reloaded markup" {
    const harness = try sdk.TestHarness().create(a, .{ .size = sdk.geometry.SizeF.init(400, 300) });
    defer harness.destroy(a);
    harness.null_platform.gpu_surfaces = true;
    const views = [_]sdk.ShellView{.{ .label = "main-canvas", .kind = .gpu_surface, .fill = true }};
    const windows = [_]sdk.ShellWindow{.{ .label = "main", .title = "Decorator test", .width = 400, .height = 300, .views = &views }};
    const ui = try DecoratorApp.create(a, .{
        .name = "decorator-test",
        .scene = .{ .windows = &windows },
        .canvas_label = "main-canvas",
        .update = decoratorUpdate,
        .view = decoratorView,
        .decorate_view = decorate,
        .markup = .{ .source = "<text>Markup</text>" },
    });
    defer ui.destroy();
    try harness.start(ui.app());
    try harness.runtime.dispatchPlatformEvent(ui.app(), .{ .gpu_surface_frame = .{ .label = "main-canvas", .size = sdk.geometry.SizeF.init(400, 300), .scale_factor = 1, .frame_index = 1, .timestamp_ns = 1_000_000_000 } });
    try std.testing.expectEqual(@as(f32, 4), ui.tree.?.root.transform.ty);
    try ui.reloadMarkup("<text>Reloaded</text>");
    try ui.rebuild(&harness.runtime, 1);
    try std.testing.expectEqualStrings("Reloaded", ui.tree.?.root.text);
    try std.testing.expectEqual(@as(f32, 4), ui.tree.?.root.transform.ty);
}

test "motion transforms complete chrome subtrees but never native terminal viewports" {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var ui = canvas.Ui(DecoratorMsg).init(arena.allocator());
    var motion: @import("../ui_motion.zig").State = .{};
    motion.observe(0, 0, 0, false);
    motion.observe(1, 1, 0, false);
    const original = ui.el(.column, .{}, .{
        ui.el(.dialog, .{}, .{ui.text(.{}, "Surface content")}),
        ui.el(.column, .{ .global_key = .{ .str = "canopy-terminal-viewport" } }, .{}),
    });
    const result = @import("../ui_motion.zig").decorate(DecoratorMsg, &ui, original, &motion);
    try std.testing.expectEqual(@as(f32, 8), result.nodes[0].widget.transform.ty);
    try std.testing.expect(result.nodes[0].widget.scrim);
    try std.testing.expect(!result.nodes[0].widget.paint_scrim);
    try std.testing.expectEqual(@as(f32, 1), result.nodes[0].widget.opacity);
    try std.testing.expectEqual(canvas.Affine.identity(), result.nodes[1].widget.transform);
    _ = motion.advance(1, true);
    const reduced = @import("../ui_motion.zig").decorate(DecoratorMsg, &ui, original, &motion);
    try std.testing.expectEqual(canvas.Affine.identity(), reduced.nodes[0].widget.transform);
}
