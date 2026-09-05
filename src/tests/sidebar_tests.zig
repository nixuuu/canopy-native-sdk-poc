const support = @import("support.zig");
const std = support.std;
const app = support.app;
const profiles = support.profiles;
const sdk = support.sdk;
const Stores = support.Stores;

test "sidebar saves only on commit, coalesces outstanding writes and ignores collapse geometry" {
    const stores = try Stores.init();
    defer stores.deinit();
    var model = app.initialModel(stores.tabs, stores.projects, stores.profiles);
    _ = model.sidebar_persistence.restore(300);
    model.sidebar_width = 300;
    var fx = app.Effects.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    for (301..421) |width| app.update(&model, .{ .sidebar_resized = @as(f32, @floatFromInt(width)) / (model.canvas_width - app.sidebar_divider_width) }, &fx);
    try std.testing.expectEqual(@as(usize, 0), fx.pendingDbCount());
    app.update(&model, .save_sidebar_width, &fx);
    try std.testing.expectEqual(@as(usize, 1), fx.pendingDbCount());
    try std.testing.expectEqual(@as(?u32, 420), model.sidebar_persistence.submitted);
    app.update(&model, .{ .sidebar_resized = 450 / (model.canvas_width - app.sidebar_divider_width) }, &fx);
    app.update(&model, .save_sidebar_width, &fx);
    try std.testing.expectEqual(@as(usize, 1), fx.pendingDbCount());
    try fx.feedDbResult(app.sidebar_write_key, .exec, .ok, "");
    while (fx.takeMsg()) |msg| app.update(&model, msg, &fx);
    app.update(&model, .save_sidebar_width, &fx);
    try std.testing.expectEqual(@as(?u32, 450), model.sidebar_persistence.submitted);
    try fx.feedDbResult(app.sidebar_write_key, .exec, .ok, "");
    while (fx.takeMsg()) |msg| app.update(&model, msg, &fx);
    _ = model.sidebar.advance(860, 0, true);
    app.update(&model, .{ .sidebar_resized = 0.001 }, &fx);
    app.update(&model, .save_sidebar_width, &fx);
    try std.testing.expectEqual(@as(u32, 450), model.sidebar_persistence.desired);
    try std.testing.expectEqual(@as(usize, 0), fx.pendingDbCount());
}

test "sidebar width survives a real SQLite close and reopen without changing other preferences" {
    const prefs = @import("../preferences.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [4096]u8 = undefined;
    const path_len = try tmp.dir.realPath(std.testing.io, &path_buffer);
    const path = path_buffer[0..path_len];
    const stores = try Stores.init();
    defer stores.deinit();
    var model = app.initialModel(stores.tabs, stores.projects, stores.profiles);
    {
        var db = try sdk.relational_store.Database.open(std.testing.allocator, path);
        defer db.deinit();
        try std.testing.expectEqual(sdk.relational_store.Outcome.ok, db.exec(&.{
            .{ .sql = prefs.ensure_schema_sql },
            .{ .sql = "INSERT INTO preferences (key,value) VALUES ('fontSize','18'),('sidebar.width','300');" },
        }));
        _ = model.sidebar_persistence.restore(300);
        model.sidebar_persistence.edit(420);
        // Last drag is still unsaved when shutdown starts.
        try std.testing.expect(app.flushSidebarWidth(&model, db.binding()));
        try std.testing.expect(!model.sidebar_persistence.needsFlush());
    }
    var reopened = try sdk.relational_store.Database.open(std.testing.allocator, path);
    defer reopened.deinit();
    const Capture = struct {
        values: prefs.Values = .{},
        valid: bool = true,
        fn page(context: *anyopaque, bytes: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.valid = self.valid and prefs.decodePage(&self.values, bytes);
        }
    };
    var captured: Capture = .{};
    try std.testing.expectEqual(sdk.relational_store.Outcome.ok, reopened.query(prefs.load_sql, &.{}, &captured, Capture.page));
    try std.testing.expect(captured.valid);
    try std.testing.expectEqual(@as(u8, 18), captured.values.font_size);
    var restarted = app.initialModel(stores.tabs, stores.projects, stores.profiles);
    restarted.preferences_edit.pending_load = captured.values;
    var fx = app.Effects.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    app.update(&restarted, .{ .preferences_load_done = .{ .key = app.preferences_load_key, .kind = .done, .outcome = .ok } }, &fx);
    try std.testing.expectEqual(@as(f32, 420), restarted.sidebar_width);
    try std.testing.expect(!restarted.sidebar_persistence.dirty);
}

test "sidebar grip paints one flat darker block even on hover and press" {
    for ([_]sdk.Appearance{ .{ .color_scheme = .dark }, .{ .color_scheme = .light } }) |appearance| {
        const tokens = @import("../theme.zig").tokens(appearance);
        const color = tokens.controls.split_divider.background.?;
        try std.testing.expect(color.r < tokens.colors.surface.r);
        for (0..3) |state| {
            var commands: [16]sdk.canvas.CanvasCommand = undefined;
            var builder = sdk.canvas.Builder.init(&commands);
            const rect = sdk.geometry.RectF.init(210, 52, 3, 650);
            try sdk.canvas.emitWidgetTree(&builder, .{
                .id = 123,
                .kind = .split_divider,
                .frame = rect,
                .state = .{ .hovered = state == 1, .pressed = state == 2 },
            }, tokens);
            const list = builder.displayList();
            try std.testing.expectEqual(@as(usize, 1), list.commands.len);
            try std.testing.expect(list.commands[0] == .fill_rect);
            try std.testing.expectEqual(rect, list.commands[0].fill_rect.rect);
            try std.testing.expectEqual(color, list.commands[0].fill_rect.fill.color);
        }
    }
}

test "sidebar divider has a full height hit band clear of the terminal and native scroll region" {
    const stores = try Stores.init();
    defer stores.deinit();
    var model = app.initialModel(stores.tabs, stores.projects, stores.profiles);
    defer model.terminal_state.deinit(std.testing.allocator);
    const attached = stores.projects.attachPlaceholder("/tmp/sidebar-handle-test").?;
    model.active_workspace_id = attached.workspace_id;
    model.use_ghostty = true;
    try stores.tabs.items.append(stores.tabs.allocator, .{ .id = 1, .workspace_id = attached.workspace_id, .pty = 1, .phase = .running });
    model.terminal_state.select(stores.tabs, attached.workspace_id, 1);
    for ([_]f32{ 960, 1180, 1733 }) |width| {
        model.canvas_width = width;
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var ui = sdk.canvas.Ui(app.Msg).init(arena.allocator());
        const tree = try ui.finalize(app.CompiledCanopyView.build(&ui, &model));
        const nodes = try arena.allocator().alloc(sdk.canvas.WidgetLayoutNode, 1024);
        const layout = try sdk.canvas.layoutWidgetTree(tree.root, sdk.geometry.RectF.init(0, 0, width, 760), nodes);
        var divider: ?sdk.canvas.WidgetLayoutNode = null;
        for (layout.nodes) |node| {
            if (node.widget.kind == .split_divider) divider = node;
        }
        const handle = divider orelse return error.MissingDivider;
        try std.testing.expectApproxEqAbs(@as(f32, 3), handle.frame.width, 0.001);
        // Both outer edges and the middle, at the top, middle and bottom.
        for ([_]f32{ 0.5, 1.5, 2.5 }) |x| {
            for ([_]f32{ 1, handle.frame.height / 2, handle.frame.height - 1 }) |y| {
                const hit = layout.hitTest(sdk.geometry.PointF.init(handle.frame.x + x, handle.frame.y + y)) orelse return error.MissingHit;
                try std.testing.expectEqual(handle.widget.id, hit.id);
            }
        }
        var terminal_found = false;
        var scroll_found = false;
        for (layout.nodes) |node| {
            if (std.mem.eql(u8, node.widget.semantics.label, "Ghostty terminal viewport")) {
                terminal_found = true;
                try std.testing.expect(node.frame.x >= handle.frame.maxX());
            }
            if (std.mem.eql(u8, node.widget.semantics.label, "Projects and worktrees")) {
                scroll_found = true;
                // Fraction -> points can differ by a float32 ULP; native
                // geometry snaps these edges to the same device pixel.
                try std.testing.expect(node.frame.maxX() <= handle.frame.x + 0.001);
            }
        }
        try std.testing.expect(terminal_found and scroll_found);
    }
}

test "titlebar centers controls on native traffic lights and title on the window" {
    const stores = try Stores.init();
    defer stores.deinit();
    var model = app.initialModel(stores.tabs, stores.projects, stores.profiles);
    const attached = stores.projects.attachPlaceholder("/tmp/a-long-project-name-for-titlebar-alignment").?;
    model.active_workspace_id = attached.workspace_id;
    var fx = app.Effects.init(std.testing.allocator);
    defer fx.deinit();
    const samples = [_]sdk.WindowChrome{
        .{ .insets = .{ .top = 38, .left = 78 }, .buttons = sdk.geometry.RectF.init(12, 12, 54, 14) },
        .{ .insets = .{ .top = 66, .left = 98 }, .buttons = sdk.geometry.RectF.init(20, 19, 58, 14) },
        .{ .insets = .{ .top = 52, .left = 98 }, .buttons = sdk.geometry.RectF.init(20, 19, 58, 14) },
        .{ .insets = .{ .top = 64, .left = 100 }, .buttons = sdk.geometry.RectF.init(20, 24, 60, 16) },
        .{ .insets = .{ .top = 52, .right = 98 }, .buttons = sdk.geometry.RectF.init(782, 16, 58, 16) },
        .{}, // fullscreen: no phantom traffic-light gutter
    };
    for (samples) |chrome| {
        app.update(&model, .{ .chrome_changed = chrome }, &fx);
        const center_y = if (chrome.buttons.height > 0) chrome.buttons.y + chrome.buttons.height / 2 else 20;
        for ([_]f32{ 860, 1180, 1733 }) |width| {
            model.canvas_width = width;
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            var ui = sdk.canvas.Ui(app.Msg).init(arena.allocator());
            const tree = try ui.finalizeWithTokens(app.CompiledCanopyView.build(&ui, &model), @import("../theme.zig").tokens(.{}));
            const nodes = try arena.allocator().alloc(sdk.canvas.WidgetLayoutNode, 1024);
            const layout = try sdk.canvas.layoutWidgetTree(tree.root, sdk.geometry.RectF.init(0, 0, width, 760), nodes);
            var header_depth: ?u16 = null;
            var buttons: usize = 0;
            var title_found = false;
            for (layout.nodes) |node| {
                if (std.mem.eql(u8, node.widget.semantics.label, "Canopy title bar")) {
                    header_depth = @intCast(node.depth);
                    try std.testing.expectApproxEqAbs(@max(@as(f32, 40), center_y * 2), node.frame.height, 0.01);
                    continue;
                }
                const depth = header_depth orelse continue;
                if (node.depth <= depth) break;
                if (node.widget.kind == .button or node.widget.kind == .icon_button) {
                    buttons += 1;
                    try std.testing.expectApproxEqAbs(@as(f32, 28), node.frame.height, 0.01);
                    try std.testing.expectApproxEqAbs(center_y, node.frame.y + node.frame.height / 2, 0.01);
                    try std.testing.expect(node.frame.x >= chrome.insets.left);
                    try std.testing.expect(node.frame.maxX() <= width - chrome.insets.right);
                }
                if (node.widget.kind == .text and std.mem.eql(u8, node.widget.text, model.activeWorkspaceName())) {
                    title_found = true;
                    try std.testing.expectApproxEqAbs(width / 2, node.frame.x + node.frame.width / 2, 0.01);
                    try std.testing.expectApproxEqAbs(center_y, node.frame.y + node.frame.height / 2, 0.01);
                }
            }
            try std.testing.expectEqual(@as(usize, 4), buttons);
            try std.testing.expect(title_found);
        }
    }
    try std.testing.expectEqual(@as(f32, 6), model.titlebarLeading());
}

test "compact sidebar overlay leaves terminal layout unchanged and dismisses on selection" {
    const stores = try Stores.init();
    defer stores.deinit();
    var model = app.initialModel(stores.tabs, stores.projects, stores.profiles);
    defer model.terminal_state.deinit(std.testing.allocator);
    const attached = stores.projects.attachPlaceholder("/tmp/sidebar-overlay-test").?;
    model.active_workspace_id = attached.workspace_id;
    model.use_ghostty = true;
    try stores.tabs.items.append(stores.tabs.allocator, .{ .id = 1, .workspace_id = attached.workspace_id, .pty = 1, .phase = .running });
    model.terminal_state.select(stores.tabs, attached.workspace_id, 1);
    model.canvas_width = 860;
    _ = model.sidebar.advance(860, 0, true);
    var viewport: ?sdk.geometry.RectF = null;
    for ([_]bool{ false, true, false }) |open| {
        model.sidebar.overlay_open = open;
        _ = model.sidebar.advance(860, 1, true);
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var ui = sdk.canvas.Ui(app.Msg).init(arena.allocator());
        const tree = try ui.finalize(app.CompiledCanopyView.build(&ui, &model));
        const nodes = try arena.allocator().alloc(sdk.canvas.WidgetLayoutNode, 1024);
        const layout = try sdk.canvas.layoutWidgetTree(tree.root, sdk.geometry.RectF.init(0, 0, 860, 760), nodes);
        var trees: usize = 0;
        var found = false;
        for (layout.nodes) |node| {
            if (node.widget.semantics.role == .tree) trees += 1;
            if (!std.mem.eql(u8, node.widget.semantics.label, "Ghostty terminal viewport")) continue;
            found = true;
            if (viewport) |previous| try std.testing.expectEqual(previous, node.frame);
            viewport = node.frame;
        }
        try std.testing.expect(found);
        try std.testing.expectEqual(@as(usize, if (open) 1 else 0), trees);
    }
    model.sidebar.overlay_open = true;
    var fx = app.Effects.init(std.testing.allocator);
    defer fx.deinit();
    app.update(&model, .{ .select_workspace = attached.workspace_id }, &fx);
    try std.testing.expect(!model.sidebar.overlay_open);
    try std.testing.expectEqual(@as(usize, 1), stores.tabs.items.items.len);
}

test "sidebar keeps logical width across window resize and restores after clamping" {
    const stores = try Stores.init();
    defer stores.deinit();
    var model = app.initialModel(stores.tabs, stores.projects, stores.profiles);
    const attached = stores.projects.attachPlaceholder("/tmp/sidebar-width-test").?;
    model.active_workspace_id = attached.workspace_id;
    var fx = app.Effects.init(std.testing.allocator);
    defer fx.deinit();

    // A real divider message selects 420 points at the current viewport.
    app.update(&model, .{ .sidebar_resized = 420 / (model.canvas_width - app.sidebar_divider_width) }, &fx);
    try std.testing.expectApproxEqAbs(@as(f32, 420), model.sidebar_width, 0.001);
    for ([_]f32{ 1180, 1600, 860, 1180, 2000 }) |width| {
        model.canvas_width = width;
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var ui = sdk.canvas.Ui(app.Msg).init(arena.allocator());
        const tree = try ui.finalize(app.CompiledCanopyView.build(&ui, &model));
        const nodes = try arena.allocator().alloc(sdk.canvas.WidgetLayoutNode, 1024);
        const layout = try sdk.canvas.layoutWidgetTree(tree.root, sdk.geometry.RectF.init(0, 0, width, 760), nodes);
        var sidebar_id: u64 = 0;
        for (layout.nodes) |node| {
            if (node.widget.kind == .split) {
                sidebar_id = node.widget.children[0].id;
                break;
            }
        }
        try std.testing.expect(sidebar_id != 0);
        var found = false;
        for (layout.nodes) |node| {
            if (node.widget.id != sidebar_id) continue;
            found = true;
            try std.testing.expectApproxEqAbs(@min(@as(f32, 420), width - app.sidebar_divider_width - 520), node.frame.width, 0.01);
        }
        try std.testing.expect(found);
        try std.testing.expectApproxEqAbs(@as(f32, 420), model.sidebar_width, 0.001);
    }
    // A later drag uses the current viewport, not the startup window size.
    app.update(&model, .{ .sidebar_resized = 300 / (model.canvas_width - app.sidebar_divider_width) }, &fx);
    model.canvas_width = 1180;
    try std.testing.expectApproxEqAbs(@as(f32, 300), model.sidebarFraction() * (model.canvas_width - app.sidebar_divider_width), 0.001);
}
