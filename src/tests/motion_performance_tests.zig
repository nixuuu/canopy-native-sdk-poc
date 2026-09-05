const support = @import("support.zig");
const std = support.std;
const sdk = support.sdk;
const app = support.app;
const canvas = sdk.canvas;
const a = std.testing.allocator;
const c = @import("../agent_hook_server.zig").c;
const Ui = sdk.UiApp(app.Model, app.Msg);

fn now() u64 {
    var ts: c.struct_timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
    return @as(u64, @intCast(ts.tv_sec)) * 1_000_000_000 + @as(u64, @intCast(ts.tv_nsec));
}
fn stats(name: []const u8, values: []u64) void {
    std.mem.sort(u64, values, {}, std.sort.asc(u64));
    std.debug.print("motion-cpu case={s} frames={d} p50_us={d} p90_us={d} max_us={d}\n", .{ name, values.len, values[values.len / 2] / 1000, values[values.len * 9 / 10] / 1000, values[values.len - 1] / 1000 });
}

test "retained motion skips rebuild layout and accessibility while keeping transformed hit targets" {
    const stores = try support.Stores.init();
    defer stores.deinit();
    const harness = try sdk.TestHarness().create(a, .{ .size = sdk.geometry.SizeF.init(1180, 760) });
    defer harness.destroy(a);
    harness.null_platform.gpu_surfaces = true;
    harness.null_platform.gpu_surface_scroll_drivers = true;
    const views = [_]sdk.ShellView{.{ .label = "main-canvas", .kind = .gpu_surface, .fill = true }};
    const windows = [_]sdk.ShellWindow{.{ .label = "main", .title = "Motion benchmark", .width = 1180, .height = 760, .views = &views }};
    const ui = try Ui.create(std.heap.page_allocator, .{ .name = "motion-benchmark", .scene = .{ .windows = &windows }, .canvas_label = "main-canvas", .update_fx = app.update, .view = app.buildCanopyView, .tokens_fn = app.canopyTokens });
    defer ui.destroy();
    ui.model = app.initialModel(stores.tabs, stores.projects, stores.profiles);
    defer ui.model.terminal_state.deinit(a);
    ui.effects.executor = .fake;
    ui.model.use_ghostty = true;
    var path_buffer: [80]u8 = undefined;
    for (0..50) |i| {
        const path = try std.fmt.bufPrint(&path_buffer, "/tmp/motion-workspace-{d}", .{i});
        ui.model.active_workspace_id = stores.projects.attachPlaceholder(path).?.workspace_id;
    }
    try stores.tabs.items.append(a, .{ .id = 1, .pty = 1, .workspace_id = ui.model.active_workspace_id, .phase = .running });
    ui.model.setActiveTab(ui.model.active_workspace_id, 1);
    ui.model.preferences_edit.open = true;
    ui.model.preferences_edit.loaded = true;
    ui.model.ui_motion.observe(1, 0, 0, false);
    ui.model.ui_motion.observe(1, 1, 0, false);
    try harness.start(ui.app());
    try harness.runtime.dispatchPlatformEvent(ui.app(), .{ .gpu_surface_frame = .{ .label = "main-canvas", .size = sdk.geometry.SizeF.init(1180, 760), .scale_factor = 1, .frame_index = 1, .timestamp_ns = 1_000_000_000 } });

    // Fifty projects produce one hundred rows, but only the viewport's
    // window may become retained layout or consume icon path storage.
    try std.testing.expect((try harness.runtime.canvasWidgetLayout(1, "main-canvas")).nodes.len < 500);

    // A custom stationary backdrop must still block native worktree scrollers.
    // Preferences' own scroll regions remain usable above the modal catcher.
    const modal_layout = try harness.runtime.canvasWidgetLayout(1, "main-canvas");
    var blocked_drivers: usize = 0;
    var modal_drivers: usize = 0;
    for (harness.null_platform.scrollDrivers()) |driver| {
        var inside_dialog = false;
        for (modal_layout.nodes, 0..) |node, index| {
            if (node.widget.id != driver.id) continue;
            var current: ?usize = index;
            while (current) |ancestor| {
                if (modal_layout.nodes[ancestor].widget.kind == .dialog) {
                    inside_dialog = true;
                    break;
                }
                current = modal_layout.nodes[ancestor].parent_index;
            }
            break;
        }
        if (inside_dialog) {
            try std.testing.expectEqual(@as(u32, 0), driver.occluder_mask);
            modal_drivers += 1;
        } else {
            try std.testing.expect(driver.occluder_mask != 0);
            blocked_drivers += 1;
        }
    }
    try std.testing.expect(blocked_drivers > 0);
    try std.testing.expect(modal_drivers > 0);

    const benchmark = c.getenv("CANOPY_BENCH_MOTION") != null;
    const samples: usize = if (benchmark) 100 else 4;
    var full_samples: [100]u64 = undefined;
    var retained_samples: [100]u64 = undefined;
    for (full_samples[0..samples], 0..) |*sample, i| {
        ui.model.ui_motion.surface.value = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(samples));
        const begin = now();
        try ui.rebuild(&harness.runtime, 1);
        sample.* = now() - begin;
    }
    const generation = ui.build_generation;
    harness.runtime.frame_profile.enabled = true;
    harness.runtime.frame_profile.reset();
    var host: @import("../ui_motion.zig").Host = .{};
    for (retained_samples[0..samples], 0..) |*sample, i| {
        ui.model.ui_motion.surface.value = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(samples));
        const begin = now();
        _ = try host.apply(&harness.runtime, ui);
        sample.* = now() - begin;
    }
    try std.testing.expectEqual(generation, ui.build_generation);
    try std.testing.expectEqual(@as(u64, 0), harness.runtime.frame_profile.stats(.layout).total);
    try std.testing.expectEqual(@as(u64, 0), harness.runtime.frame_profile.stats(.reconcile).total);
    try std.testing.expectEqual(@as(u64, 0), harness.runtime.frame_profile.stats(.a11y).total);
    ui.model.ui_motion.surface.value = 0;
    _ = try host.apply(&harness.runtime, ui);
    const layout = try harness.runtime.canvasWidgetLayout(1, "main-canvas");
    var checked = false;
    for (layout.nodes) |node| {
        if (!std.mem.eql(u8, node.widget.semantics.label, "Close settings")) continue;
        const point = sdk.geometry.PointF.init(node.frame.x + node.frame.width / 2, node.frame.y + 1);
        const moved_hit = layout.hitTest(.{ .x = point.x, .y = point.y + 8 }) orelse return error.MissingHit;
        try std.testing.expectEqual(node.widget.id, moved_hit.id);
        if (layout.hitTest(point)) |old_hit| try std.testing.expect(old_hit.id != node.widget.id);
        checked = true;
    }
    try std.testing.expect(checked);
    if (benchmark) {
        stats("full-rebuild", full_samples[0..samples]);
        stats("retained-presentation", retained_samples[0..samples]);
    }

    const view_index = harness.runtime.findViewIndex(1, "main-canvas").?;
    const revision = harness.runtime.views[view_index].widget_revision;
    try std.testing.expect(!(try host.apply(&harness.runtime, ui)));
    try std.testing.expectEqual(revision, harness.runtime.views[view_index].widget_revision);
    const root_id = ui.tree.?.root.id;
    try std.testing.expectError(error.InvalidCommand, harness.runtime.setCanvasWidgetPresentation(1, "main-canvas", &.{ .{ .id = root_id, .opacity = 0.5 }, .{ .id = root_id, .opacity = std.math.nan(f32) } }));
    try std.testing.expectEqual(revision, harness.runtime.views[view_index].widget_revision);
    try std.testing.expect(!(try harness.runtime.setCanvasWidgetPresentation(1, "main-canvas", &.{.{ .id = std.math.maxInt(u64) }})));
    // Sidebar travel uses retained split geometry; the native viewport is
    // clipped to the moving pane instead of using an oversized destination.
    ui.model.preferences_edit.open = false;
    ui.model.ui_motion.surface.value = 1;
    ui.model.sidebar.collapsed = true;
    ui.model.sidebar.dock.value = 1;
    ui.model.sidebar.dock.target = 0;
    try ui.rebuild(&harness.runtime, 1);
    const sidebar_generation = ui.build_generation;
    harness.runtime.frame_profile.reset();
    const split_id = canvas.globalWidgetId(.split, .{ .str = "sidebar-dock" });
    for ([_]f32{ 0.18, 0.14, 0.10, 0.04 }) |fraction| {
        _ = try harness.runtime.setCanvasWidgetSplitPresentation(1, "main-canvas", split_id, fraction);
        const frame = @import("../canvas_host.zig").terminalViewport(try harness.runtime.canvasWidgetLayout(1, "main-canvas")) orelse return error.MissingViewport;
        try std.testing.expectApproxEqAbs(fraction * 1177 + 3, frame.x, 0.1);
        try std.testing.expectApproxEqAbs(@as(f32, 1180), frame.x + frame.width, 0.1);
    }
    try std.testing.expectEqual(sidebar_generation, ui.build_generation);
    try std.testing.expectEqual(@as(u64, 0), harness.runtime.frame_profile.stats(.layout).total);
    ui.model.sidebar.dock.value = 0;
    try ui.rebuild(&harness.runtime, 1);
    try std.testing.expect(!(try harness.runtime.setCanvasWidgetSplitPresentation(1, "main-canvas", split_id, 0)));
    ui.model.sidebar.collapsed = false;
    ui.model.sidebar.dock.value = 1;
    ui.model.sidebar.dock.target = 1;
    try ui.rebuild(&harness.runtime, 1);
    var scroll_id: u64 = 0;
    for ((try harness.runtime.canvasWidgetLayout(1, "main-canvas")).nodes) |node| {
        if (std.mem.eql(u8, node.widget.semantics.label, "Projects and worktrees")) {
            try std.testing.expect(node.widget.layout.virtualized);
            scroll_id = node.widget.id;
        }
    }
    try std.testing.expect(scroll_id != 0);
    const scroll_frame = (try harness.runtime.canvasWidgetLayout(1, "main-canvas")).findById(scroll_id).?.frame;
    try harness.runtime.dispatchPlatformEvent(ui.app(), .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "main-canvas",
        .timestamp_ns = 2_000_000_000,
        .kind = .scroll,
        .x = scroll_frame.x + 20,
        .y = scroll_frame.y + 20,
        .delta_y = 200,
    } });
    const scrolled = (try harness.runtime.canvasWidgetLayout(1, "main-canvas")).findById(scroll_id).?.widget.value;
    try std.testing.expect(scrolled > 0);
    try ui.rebuild(&harness.runtime, 1);
    const final_layout = try harness.runtime.canvasWidgetLayout(1, "main-canvas");
    try std.testing.expectEqual(scrolled, final_layout.findById(scroll_id).?.widget.value);
    try std.testing.expect(final_layout.nodes.len < 500);
}
