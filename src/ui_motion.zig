//! Short, interruptible chrome motion driven only by the presented-frame clock.
const std = @import("std");
const sdk = @import("native_sdk");
pub const quick_ms: u32 = 150;
pub const surface_ms: u32 = 250;
pub const panel_open_ns: u64 = 250_000_000;
pub const panel_close_ns: u64 = 180_000_000;
const Pulse = struct {
    value: f32 = 1,
    start: ?u64 = null,
    fn begin(self: *Pulse, reduced: bool) void {
        self.* = .{ .value = if (reduced) 1 else 0 };
    }
    fn advance(self: *Pulse, now: u64, duration: u32, reduced: bool) bool {
        if (self.value == 1) return false;
        const old = self.value;
        if (reduced) {
            self.* = .{};
            return true;
        }
        if (self.start == null) self.start = now;
        const t = @min(1, @as(f32, @floatFromInt(now -| self.start.?)) / @as(f32, @floatFromInt(@as(u64, duration) * 1_000_000)));
        self.value = 1 - std.math.pow(f32, 1 - t, 3);
        return old != self.value;
    }
};
const TabPose = struct { id: u64 = 0, index: usize = 0, delta: f32 = 0, pulse: Pulse = .{} };
pub const State = struct {
    initialized: bool = false,
    selected: u64 = 0,
    modal: u8 = 0,
    section: usize = 0,
    tab: Pulse = .{},
    surface: Pulse = .{},
    content: Pulse = .{},
    poses: [@import("tab_strip.zig").limit]TabPose = @splat(.{}),
    pub fn observe(self: *State, selected: u64, modal: u8, section: usize, reduced: bool) void {
        if (self.initialized) {
            if (selected != self.selected) self.tab.begin(reduced or selected == 0);
            if (modal != self.modal) {
                self.surface.begin(reduced or modal == 0);
                self.content = .{};
            } else if (modal != 0 and section != self.section) self.content.begin(reduced);
        }
        self.initialized = true;
        self.selected = selected;
        self.modal = modal;
        self.section = section;
    }
    pub fn observeTabs(self: *State, ids: []const u64, reset: bool, reduced: bool) void {
        var next: @TypeOf(self.poses) = @splat(.{});
        const stride = @import("tab_strip.zig").tab_width + @import("tab_strip.zig").gap;
        for (ids, 0..) |id, index| {
            next[index] = .{ .id = id, .index = index };
            if (reset or reduced) continue;
            for (self.poses) |old| if (old.id == id) {
                if (old.index == index) {
                    next[index] = old;
                    break;
                }
                next[index].delta = old.delta * (1 - old.pulse.value) + (@as(f32, @floatFromInt(old.index)) - @as(f32, @floatFromInt(index))) * stride;
                next[index].pulse.begin(false);
                break;
            };
        }
        self.poses = next;
    }
    fn tabOffset(self: *const State, id: u64) f32 {
        for (self.poses) |pose| if (pose.id == id) return pose.delta * (1 - pose.pulse.value);
        return 0;
    }
    pub fn advance(self: *State, now: u64, reduced: bool) bool {
        const tab = self.tab.advance(now, quick_ms, reduced);
        const surface = self.surface.advance(now, surface_ms, reduced);
        const content = self.content.advance(now, quick_ms, reduced);
        var reordered = false;
        for (&self.poses) |*pose| reordered = pose.pulse.advance(now, quick_ms, reduced) or reordered;
        return tab or surface or content or reordered;
    }
    pub fn active(self: *const State) bool {
        for (self.poses) |pose| if (pose.pulse.value < 1) return true;
        return self.tab.value < 1 or self.surface.value < 1 or self.content.value < 1;
    }
};

pub const Target = struct {
    id: sdk.canvas.ObjectId = 0,
    kind: enum { surface, tab, content },
    tab_id: u64 = 0,
    selected: bool = false,
};

pub fn presentation(state: *const State, target: Target) sdk.Runtime.CanvasWidgetPresentation {
    const progress = switch (target.kind) {
        .surface => state.surface.value,
        .content => state.content.value,
        .tab => if (target.selected) state.tab.value else 1,
    };
    const distance: f32 = switch (target.kind) {
        .surface => 8,
        .content => 4,
        .tab => -4,
    };
    return .{
        .id = target.id,
        .transform = sdk.canvas.Affine.translate(if (target.kind == .tab) state.tabOffset(target.tab_id) else 0, distance * (1 - progress)),
        // Large opaque surfaces keep their fast copy/composite path. Fading
        // every pixel of a dialog costs more than moving the prepared surface.
        .opacity = if (target.kind != .surface and progress < 1) 0.85 + 0.15 * progress else 1,
    };
}

/// Initial pose during a real model rebuild. Subsequent animation frames
/// update retained presentation directly and never revisit this tree builder.
pub fn decorate(comptime Msg: type, ui: *sdk.canvas.Ui(Msg), node: sdk.canvas.Ui(Msg).Node, state: *const State) sdk.canvas.Ui(Msg).Node {
    var result = node;
    // Canopy already owns a stationary dimming panel around every dialog.
    // The SDK's additional scrim includes a full-window backdrop blur; moving
    // it with the dialog forces a full raster pass on every animation sample.
    if (node.widget.kind == .dialog) result.widget.paint_scrim = false;
    if (state.active()) {
        var target: ?Target = if (node.widget.kind == .dialog) .{ .kind = .surface } else null;
        if (node.global_key) |key| if (key == .str and std.mem.eql(u8, key.str, "preferences-content")) {
            target = .{ .kind = .content };
        };
        if (comptime @hasField(Msg, "activate_tab")) {
            if (node.on_press) |message| switch (message) {
                .activate_tab => |id| target = .{ .kind = .tab, .tab_id = id, .selected = node.widget.state.selected },
                else => {},
            };
        }
        if (target) |value| {
            const pose = presentation(state, value);
            result.widget.transform = pose.transform;
            result.widget.opacity = pose.opacity;
        }
    }
    // Copy only paths that changed, not the entire UI tree on every update.
    var children: ?[]@TypeOf(node) = null;
    for (node.nodes, 0..) |child, index| {
        const next = decorate(Msg, ui, child, state);
        if (next.nodes.ptr == child.nodes.ptr and next.widget.paint_scrim == child.widget.paint_scrim and
            next.widget.opacity == child.widget.opacity and std.meta.eql(next.widget.transform, child.widget.transform)) continue;
        if (children == null) children = ui.arena.dupe(@TypeOf(node), node.nodes) catch return node;
        children.?[index] = next;
    }
    if (children) |nodes| result.nodes = nodes;
    return result;
}

/// Resolve identities once per source-tree generation, not once per frame.
/// The bounded buffer covers the 12-tab strip, dialog and settings content.
pub const Host = struct {
    generation: ?u64 = null,
    targets: [16]Target = undefined,
    count: usize = 0,
    fn collect(self: *Host, tree: anytype, widget: sdk.canvas.Widget) void {
        var target: ?Target = if (widget.kind == .dialog) .{ .id = widget.id, .kind = .surface } else null;
        if (widget.id == sdk.canvas.globalWidgetId(.column, .{ .str = "preferences-content" })) target = .{ .id = widget.id, .kind = .content };
        if (tree.msgFor(widget.id, .press)) |message| switch (message) {
            .activate_tab => |id| target = .{ .id = widget.id, .kind = .tab, .tab_id = id, .selected = widget.state.selected },
            else => {},
        };
        if (target) |value| {
            std.debug.assert(self.count < self.targets.len);
            self.targets[self.count] = value;
            self.count += 1;
        }
        for (widget.children) |child| self.collect(tree, child);
    }
    pub fn apply(self: *Host, runtime: anytype, ui: anytype) !bool {
        const tree = ui.tree orelse return false;
        if (self.generation != ui.build_generation) {
            self.count = 0;
            self.collect(tree, tree.root);
            self.generation = ui.build_generation;
        }
        var poses: [16]sdk.Runtime.CanvasWidgetPresentation = undefined;
        for (self.targets[0..self.count], poses[0..self.count]) |target, *pose| pose.* = presentation(&ui.model.ui_motion, target);
        return runtime.setCanvasWidgetPresentation(@import("canvas_host.zig").window_id, @import("canvas_host.zig").label, poses[0..self.count]);
    }
};

test "chrome motion settles idles and snaps when reduced motion is enabled mid-flight" {
    const t = std.testing;
    var state: State = .{};
    state.observe(0, 0, 0, false);
    try t.expect(!state.active());
    state.observe(1, 1, 0, false);
    _ = state.advance(1, false);
    _ = state.advance(100_000_001, false);
    try t.expect(state.surface.value > 0 and state.surface.value < 1);
    _ = state.advance(300_000_001, false);
    try t.expect(!state.active());
    try t.expect(!state.advance(900_000_001, false));
    state.observe(2, 1, 1, false);
    _ = state.advance(1_000_000_001, true);
    try t.expect(!state.active());
    state.observe(3, 0, 1, true);
    try t.expect(!state.active());
}

test "closing a tab repositions survivors continuously and reduced motion removes travel" {
    const t = std.testing;
    var state: State = .{};
    state.observeTabs(&.{ 1, 2, 3 }, true, false);
    state.observeTabs(&.{ 2, 3 }, false, false);
    try t.expectEqual(@as(f32, 186), state.tabOffset(2));
    _ = state.advance(1, false);
    _ = state.advance(50_000_001, false);
    const previous = state.tabOffset(3);
    state.observeTabs(&.{3}, false, false);
    try t.expectApproxEqAbs(previous + 186, state.tabOffset(3), 0.01);
    _ = state.advance(60_000_001, true);
    try t.expectEqual(@as(f32, 0), state.tabOffset(3));
    try t.expect(!state.active());
}
