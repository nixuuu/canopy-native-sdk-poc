//! Deterministic checks of the production controller's event ordering.
const std = @import("std");
const sdk = @import("native_sdk");
const Controller = @import("sidebar_controller.zig").Controller;
const canvas_host = @import("canvas_host.zig");
const testing = std.testing;

const Step = enum { reduce, resize, rebuild, forward, save };
const Log = struct {
    items: [16]Step = undefined,
    len: usize = 0,
    fn add(self: *Log, step: Step) void {
        self.items[self.len] = step;
        self.len += 1;
    }
};
const Msg = union(enum) { sidebar_resized: f32, other_resize: f32, save_sidebar_width };
const Tree = struct {
    pub fn msgForResize(_: Tree, id: u64, fraction: f32) ?Msg {
        return switch (id) {
            17 => .{ .sidebar_resized = fraction },
            18 => .{ .other_resize = fraction },
            else => null,
        };
    }
};
const Model = struct {
    canvas_width: f32 = 1000,
    applied_at_width: f32 = 0,
    sidebar_width: f32 = 210,
    sidebar: @import("sidebar_state.zig").State = .{},
    sidebar_persistence: @import("sidebar_persistence.zig").State = .{},
    appearance: sdk.Appearance = .{},
    blocked: bool = false,
    pub fn terminalActionsBlocked(self: *const Model) bool {
        return self.blocked;
    }
};
const Effects = struct { log: *Log };
fn reduce(model: *Model, msg: Msg, effects: *Effects) void {
    switch (msg) {
        .sidebar_resized => |fraction| {
            effects.log.add(.reduce);
            model.applied_at_width = model.canvas_width;
            model.sidebar_width = fraction * (model.canvas_width - 3);
        },
        else => unreachable,
    }
}
const Runtime = struct {
    has_view: bool = true,
    fail_frame: bool = false,
    frames: usize = 0,
    nodes: []const sdk.canvas.WidgetLayoutNode = &.{},
    views: [1]struct { canvas_widget_pressed_id: u64 = 0, canvas_widget_hovered_id: u64 = 0 } = .{.{}},
    pub fn findViewIndex(self: *Runtime, id: u64, label: []const u8) ?usize {
        return if (self.has_view and id == 1 and std.mem.eql(u8, label, canvas_host.label)) 0 else null;
    }
    pub fn requestCanvasFrameForView(self: *Runtime, _: usize) !void {
        if (self.fail_frame) return error.FrameUnavailable;
        self.frames += 1;
    }
    pub fn canvasWidgetLayout(self: *Runtime, _: u64, _: []const u8) !sdk.canvas.WidgetLayoutTree {
        return .{ .nodes = self.nodes };
    }
};
const Ui = struct {
    installed: bool = true,
    model: Model = .{},
    effects: Effects,
    tree: ?Tree = .{},
    resize_width: f32 = 0,
    resize_scale: f32 = 0,
    clear_hover_on_save: bool = false,

    pub fn app(self: *Ui) Proxy {
        return .{ .ui = self };
    }
    const Proxy = struct {
        ui: *Ui,
        pub fn event(self: Proxy, _: *Runtime, event_value: sdk.Event) !void {
            if (event_value == .gpu_surface_resized) {
                self.ui.effects.log.add(.resize);
                self.ui.resize_width = self.ui.model.canvas_width;
                self.ui.resize_scale = event_value.gpu_surface_resized.scale_factor;
            } else self.ui.effects.log.add(.forward);
        }
    };
    pub fn rebuild(self: *Ui, _: *Runtime, _: u64) !void {
        self.effects.log.add(.rebuild);
    }
    pub fn dispatch(self: *Ui, runtime: *Runtime, _: u64, msg: Msg) !void {
        try testing.expect(msg == .save_sidebar_width);
        self.effects.log.add(.save);
        _ = self.model.sidebar_persistence.begin();
        if (self.clear_hover_on_save) runtime.views[0].canvas_widget_hovered_id = 0;
    }
};

fn resize(width: f32) sdk.Event {
    return .{ .gpu_surface_resized = .{ .label = canvas_host.label, .frame = sdk.geometry.RectF.init(0, 0, width, 700), .scale_factor = 2 } };
}
fn drag(id: u64, fraction: f32) sdk.Event {
    return .{ .canvas_widget_resize = .{ .view_label = canvas_host.label, .id = id, .fraction = fraction } };
}
fn frame(width: f32) sdk.Event {
    return .{ .gpu_surface_frame = .{ .label = canvas_host.label, .size = sdk.geometry.SizeF.init(width, 700), .timestamp_ns = 1, .scale_factor = 2 } };
}

test "mixed geometry storm uses old width for drag and resizes once before forwarding frame" {
    var log: Log = .{};
    var ui: Ui = .{ .effects = .{ .log = &log } };
    var runtime: Runtime = .{};
    var controller: Controller = .{};
    for (0..120) |index| {
        try testing.expect(try controller.prepareEvent(&runtime, &ui, drag(17, 0.4), reduce));
        try testing.expect(try controller.prepareEvent(&runtime, &ui, resize(@floatFromInt(1181 + index)), reduce));
    }
    try testing.expectEqual(@as(usize, 0), log.len);
    try testing.expect(controller.hasPendingGeometry());
    try testing.expect(!try controller.prepareEvent(&runtime, &ui, frame(1300), reduce));
    try ui.app().event(&runtime, frame(1300));
    try testing.expectEqualSlices(Step, &.{ .reduce, .resize, .forward }, log.items[0..log.len]);
    try testing.expectEqual(@as(f32, 1000), ui.model.applied_at_width);
    try testing.expectApproxEqAbs(@as(f32, 398.8), ui.model.sidebar_width, 0.001);
    try testing.expectEqual(@as(f32, 1300), ui.resize_width);
    try testing.expectEqual(@as(f32, 2), ui.resize_scale);
    try testing.expect(!controller.hasPendingGeometry());
}

test "uninstalled or foreign events bypass staging and cannot drain main geometry" {
    var log: Log = .{};
    var ui: Ui = .{ .installed = false, .effects = .{ .log = &log } };
    var runtime: Runtime = .{};
    var controller: Controller = .{};
    try testing.expect(!try controller.prepareEvent(&runtime, &ui, resize(1200), reduce));
    try testing.expectEqual(@as(f32, 1200), ui.model.canvas_width);
    try testing.expect(!try controller.prepareEvent(&runtime, &ui, drag(17, 0.4), reduce));
    try testing.expectEqual(@as(usize, 0), runtime.frames);
    ui.installed = true;
    try testing.expect(try controller.prepareEvent(&runtime, &ui, drag(17, 0.4), reduce));
    try testing.expect(!try controller.prepareEvent(&runtime, &ui, drag(18, 0.6), reduce));
    var foreign = frame(2000);
    foreign.gpu_surface_frame.label = "other-canvas";
    try testing.expect(!try controller.prepareEvent(&runtime, &ui, foreign, reduce));
    try testing.expect(controller.hasPendingGeometry());
    try testing.expectEqual(@as(f32, 1200), ui.model.canvas_width);
    controller.flushPending(&ui, reduce);
    controller.flushPending(&ui, reduce);
    try testing.expectEqualSlices(Step, &.{.reduce}, log.items[0..log.len]);
}

test "drag-only frame rebuilds once and a frame request failure preserves staged input" {
    var log: Log = .{};
    var ui: Ui = .{ .effects = .{ .log = &log } };
    var runtime: Runtime = .{ .fail_frame = true };
    var controller: Controller = .{};
    try testing.expectError(error.FrameUnavailable, controller.prepareEvent(&runtime, &ui, drag(17, 0.3), reduce));
    try testing.expect(controller.hasPendingGeometry());
    runtime.fail_frame = false;
    _ = try controller.prepareEvent(&runtime, &ui, frame(1000), reduce);
    try testing.expectEqualSlices(Step, &.{ .reduce, .rebuild }, log.items[0..log.len]);
}

test "persistence waits for mounted canvas, settled geometry and pointer release" {
    var log: Log = .{};
    var ui: Ui = .{ .effects = .{ .log = &log } };
    _ = ui.model.sidebar_persistence.restore(300);
    ui.model.sidebar_persistence.edit(350);
    var runtime: Runtime = .{ .has_view = false };
    var controller: Controller = .{};
    try controller.finishEvent(&runtime, &ui);
    runtime.has_view = true;
    controller.pending.sidebar = 0.3;
    try controller.finishEvent(&runtime, &ui);
    _ = controller.pending.take();
    runtime.views[0].canvas_widget_pressed_id = 17;
    try controller.finishEvent(&runtime, &ui);
    try testing.expectEqual(@as(usize, 0), log.len);
    runtime.views[0].canvas_widget_pressed_id = 0;
    try controller.finishEvent(&runtime, &ui);
    try controller.finishEvent(&runtime, &ui);
    try testing.expectEqualSlices(Step, &.{.save}, log.items[0..log.len]);
    try testing.expectEqual(@as(usize, 0), runtime.frames);
}

test "hover reads SDK identities after save and holds highlight through dragging" {
    const nodes = [_]sdk.canvas.WidgetLayoutNode{.{ .widget = .{ .kind = .split_divider, .id = 17 }, .frame = sdk.geometry.RectF.init(210, 40, 3, 600), .depth = 0 }};
    var log: Log = .{};
    var ui: Ui = .{ .effects = .{ .log = &log }, .clear_hover_on_save = true };
    _ = ui.model.sidebar_persistence.restore(300);
    ui.model.sidebar_persistence.edit(350);
    var runtime: Runtime = .{ .nodes = &nodes };
    runtime.views[0].canvas_widget_hovered_id = 17;
    var controller: Controller = .{};
    try controller.finishEvent(&runtime, &ui);
    try testing.expect(!ui.model.sidebar.grip_active); // save changed the live interaction
    try testing.expectEqual(@as(usize, 0), runtime.frames);
    runtime.views[0].canvas_widget_pressed_id = 17;
    try controller.finishEvent(&runtime, &ui);
    try testing.expect(ui.model.sidebar.grip_active);
    try testing.expectEqual(@as(usize, 1), runtime.frames);
    ui.model.blocked = true;
    try controller.finishEvent(&runtime, &ui);
    try testing.expect(!ui.model.sidebar.grip_active);
    try testing.expectEqual(@as(usize, 2), runtime.frames);
    try controller.finishEvent(&runtime, &ui);
    try testing.expectEqual(@as(usize, 2), runtime.frames);
}

test "retained sidebar motion only rebuilds for structural cleanup at settle" {
    var log: Log = .{};
    var ui: Ui = .{ .effects = .{ .log = &log } };
    var runtime: Runtime = .{};
    var controller: Controller = .{ .retained_motion = true };
    _ = ui.model.sidebar.advance(1180, 1, false);
    ui.model.sidebar.collapsed = true;
    var sample = frame(1180);
    sample.gpu_surface_frame.size.width = 1180;
    sample.gpu_surface_frame.timestamp_ns = 10;
    _ = try controller.prepareEvent(&runtime, &ui, sample, reduce);
    try testing.expectEqual(@as(usize, 0), log.len);
    for (1..10) |i| {
        sample.gpu_surface_frame.timestamp_ns = 10 + i * 16_000_000;
        _ = try controller.prepareEvent(&runtime, &ui, sample, reduce);
    }
    try testing.expectEqual(@as(usize, 0), log.len);
    sample.gpu_surface_frame.timestamp_ns = 200_000_010;
    _ = try controller.prepareEvent(&runtime, &ui, sample, reduce);
    try testing.expectEqualSlices(Step, &.{.rebuild}, log.items[0..log.len]);
}
