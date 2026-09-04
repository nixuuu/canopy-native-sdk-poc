//! Coalesced persistence of the user-selected width, never disclosure geometry.
const std = @import("std");

pub const State = struct {
    desired: u32 = 210,
    saved: ?u32 = null,
    submitted: ?u32 = null,
    loaded: bool = false,
    touched: bool = false,
    dirty: bool = false,

    pub fn edit(self: *State, width: f32) void {
        if (!std.math.isFinite(width) or width < 1 or width > 100_000) return;
        const value: u32 = @intFromFloat(@round(width));
        if (self.touched and self.desired == value) return;
        self.desired = value;
        self.touched = true;
        self.dirty = self.saved == null or self.saved.? != value;
    }

    pub fn restore(self: *State, width: ?f32) ?f32 {
        self.loaded = true;
        self.saved = if (width) |value| @intFromFloat(@max(210, @floor(value))) else null;
        if (self.touched) {
            self.dirty = self.needsFlush();
            return null;
        }
        if (self.saved) |value| self.desired = value;
        return @floatFromInt(self.desired);
    }

    pub fn begin(self: *State) ?u32 {
        if (!self.canSave()) return null;
        self.submitted = self.desired;
        self.dirty = false;
        return self.desired;
    }

    pub fn finish(self: *State, success: bool) void {
        const value = self.submitted orelse return;
        self.submitted = null;
        if (success) self.saved = value;
        // A failed write is retried only after another edit or at shutdown,
        // not on every frame. A successful stale completion saves the latest
        // desired value on the next idle (non-dragging) host boundary.
        self.dirty = success and self.needsFlush();
    }

    pub fn needsFlush(self: State) bool {
        return self.touched and (self.saved == null or self.saved.? != self.desired);
    }

    pub fn canSave(self: State) bool {
        return self.loaded and self.dirty and self.submitted == null;
    }
};

test "width writes coalesce and failed writes do not spin" {
    var state: State = .{};
    try std.testing.expectEqual(@as(?f32, 320), state.restore(320));
    for (321..421) |width| state.edit(@floatFromInt(width));
    try std.testing.expectEqual(@as(?u32, 420), state.begin());
    state.edit(450);
    try std.testing.expectEqual(@as(?u32, null), state.begin());
    state.finish(true);
    try std.testing.expectEqual(@as(?u32, 450), state.begin());
    state.finish(false);
    try std.testing.expectEqual(@as(?u32, null), state.begin());
    try std.testing.expect(state.needsFlush());
    state.edit(460);
    try std.testing.expectEqual(@as(?u32, 460), state.begin());
    state.finish(true);
    try std.testing.expect(!state.needsFlush());
}

test "late restore cannot overwrite a width chosen by the user" {
    var state: State = .{};
    state.edit(420);
    try std.testing.expectEqual(@as(?u32, null), state.begin());
    try std.testing.expectEqual(@as(?f32, null), state.restore(300));
    try std.testing.expectEqual(@as(?u32, 420), state.begin());
}
