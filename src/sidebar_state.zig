//! Responsive navigation; frame-driven motion has no idle timer.
const std = @import("std");

const Motion = struct {
    value: f32 = 0,
    from: f32 = 0,
    target: f32 = 0,
    started: u64 = 0,
    duration_ns: u64 = @import("ui_motion.zig").panel_open_ns,

    fn set(self: *Motion, target: f32, now: u64, reduced: bool) void {
        if (reduced) {
            self.* = .{ .value = target, .target = target, .from = target, .duration_ns = self.duration_ns };
        } else if (self.target != target) {
            self.from = self.value;
            self.target = target;
            self.started = now;
        }
    }

    fn step(self: *Motion, now: u64) bool {
        if (self.value == self.target) return false;
        const t = @min(1, @as(f32, @floatFromInt(now -| self.started)) / @as(f32, @floatFromInt(self.duration_ns)));
        const eased = 1 - std.math.pow(f32, 1 - t, 3);
        self.value = if (t == 1) self.target else self.from + (self.target - self.from) * eased;
        return true;
    }
};

pub const State = struct {
    compact: bool = false,
    collapsed: bool = false,
    overlay_open: bool = false,
    initialized: bool = false,
    dock: Motion = .{ .value = 1, .from = 1, .target = 1 },
    overlay: Motion = .{},
    grip: Motion = .{},
    grip_active: bool = false,

    pub fn toggle(self: *State) void {
        if (self.compact) self.overlay_open = !self.overlay_open else self.collapsed = !self.collapsed;
    }

    pub fn advance(self: *State, width: f32, now: u64, reduced: bool) bool {
        const previous_dock = self.dock.value;
        const previous_overlay = self.overlay.value;
        const previous_compact = self.compact;
        const previous_grip = self.grip.value;
        const compact = width < 960;
        if (compact != self.compact) self.overlay_open = false;
        self.compact = compact;
        const snap = reduced or !self.initialized;
        self.initialized = true;
        const opening = !compact and !self.collapsed;
        if (self.dock.target != @as(f32, if (opening) 1 else 0)) self.dock.duration_ns = if (opening) @import("ui_motion.zig").panel_open_ns else @import("ui_motion.zig").panel_close_ns;
        const overlay_opening = compact and self.overlay_open;
        if (self.overlay.target != @as(f32, if (overlay_opening) 1 else 0)) self.overlay.duration_ns = if (overlay_opening) @import("ui_motion.zig").panel_open_ns else @import("ui_motion.zig").panel_close_ns;
        self.dock.set(if (!compact and !self.collapsed) 1 else 0, now, snap);
        self.overlay.set(if (compact and self.overlay_open) 1 else 0, now, snap);
        const grip_target: f32 = if (self.grip_active and !compact and !self.collapsed) 1 else 0;
        if (self.grip.target != grip_target) self.grip.duration_ns = if (grip_target == 1) 120_000_000 else 180_000_000;
        self.grip.set(grip_target, now, snap);
        const dock_changed = self.dock.step(now);
        const overlay_changed = self.overlay.step(now);
        const grip_changed = self.grip.step(now);
        return dock_changed or overlay_changed or grip_changed or previous_grip != self.grip.value or previous_dock != self.dock.value or previous_overlay != self.overlay.value or previous_compact != compact;
    }

    pub fn animating(self: State) bool {
        return self.dock.value != self.dock.target or self.overlay.value != self.overlay.target;
    }

    pub fn needsFrame(self: State) bool {
        return self.animating() or self.grip.value != self.grip.target;
    }
};

test "compact overlay, desktop preference, reversal and reduced motion" {
    var state: State = .{};
    _ = state.advance(1180, 0, false);
    _ = state.advance(860, 1, false);
    try std.testing.expect(state.animating());
    _ = state.advance(860, 200_000_001, false);
    try std.testing.expectEqual(@as(f32, 0), state.dock.value);
    state.toggle();
    _ = state.advance(860, 300_000_000, false);
    _ = state.advance(860, 390_000_000, false);
    try std.testing.expect(state.overlay.value > 0 and state.overlay.value < 1);
    state.toggle();
    _ = state.advance(860, 390_000_001, false);
    _ = state.advance(860, 600_000_001, false);
    try std.testing.expect(!state.animating());
    _ = state.advance(1180, 700_000_000, true);
    try std.testing.expectEqual(@as(f32, 1), state.dock.value);
    state.toggle();
    _ = state.advance(1180, 800_000_000, true);
    _ = state.advance(860, 900_000_000, true);
    state.toggle();
    _ = state.advance(860, 1_000_000_000, true);
    try std.testing.expectEqual(@as(f32, 1), state.overlay.value);
    _ = state.advance(1180, 1_100_000_000, true);
    try std.testing.expect(state.collapsed and !state.overlay_open and !state.animating());
    try std.testing.expectEqual(@as(f32, 0), state.dock.value);
}

test "grip hover reverses smoothly, stops requesting frames and never blocks dragging" {
    var state: State = .{};
    _ = state.advance(1180, 0, false);
    state.grip_active = true;
    _ = state.advance(1180, 1, false);
    try std.testing.expect(state.needsFrame());
    try std.testing.expect(!state.animating()); // resize reducer remains enabled
    _ = state.advance(1180, 60_000_001, false);
    const halfway = state.grip.value;
    try std.testing.expect(halfway > 0 and halfway < 1);
    state.grip_active = false;
    _ = state.advance(1180, 60_000_002, false);
    try std.testing.expectEqual(halfway, state.grip.value);
    _ = state.advance(1180, 240_000_002, false);
    try std.testing.expectEqual(@as(f32, 0), state.grip.value);
    try std.testing.expect(!state.needsFrame());
    state.grip_active = true;
    _ = state.advance(1180, 300_000_000, true);
    try std.testing.expectEqual(@as(f32, 1), state.grip.value);
    try std.testing.expect(!state.needsFrame());
    state.grip_active = false;
    _ = state.advance(1180, 310_000_000, true);
    try std.testing.expectEqual(@as(f32, 0), state.grip.value);
    try std.testing.expect(!state.needsFrame());
}
