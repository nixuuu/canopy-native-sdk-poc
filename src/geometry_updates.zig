//! Latest-wins geometry staging, bounded independently of mouse event rate.
const std = @import("std");
const sdk = @import("native_sdk");

pub const Pending = struct {
    resize: ?sdk.platform.GpuSurfaceResizeEvent = null,
    sidebar: ?f32 = null,

    pub fn recordResize(self: *Pending, event: sdk.platform.GpuSurfaceResizeEvent) void {
        self.resize = event;
        // The platform event's label storage is transient; this channel owns
        // only Canopy's main canvas, so retain its static identity instead.
        self.resize.?.label = "main-canvas";
    }

    pub fn any(self: Pending) bool {
        return self.resize != null or self.sidebar != null;
    }

    pub fn take(self: *Pending) Pending {
        const pending = self.*;
        self.* = .{};
        return pending;
    }
};

test "geometry storms keep only the latest resize and divider position" {
    var pending: Pending = .{};
    for (0..240) |i| {
        pending.recordResize(.{ .label = "temporary label", .frame = sdk.geometry.RectF.init(0, 0, 1000, @floatFromInt(600 + i)), .scale_factor = 2 });
        pending.sidebar = @as(f32, @floatFromInt(i)) / 1000;
    }
    const final = pending.take();
    try std.testing.expectEqual(@as(f32, 839), final.resize.?.frame.height);
    try std.testing.expectEqual(@as(f32, 2), final.resize.?.scale_factor);
    try std.testing.expectEqualStrings("main-canvas", final.resize.?.label);
    try std.testing.expectEqual(@as(f32, 0.239), final.sidebar.?);
    try std.testing.expect(!pending.any());
    try std.testing.expect(!pending.take().any());
}
