//! Geometry shared by tab chrome and selection visibility; no host calls.
const std = @import("std");
pub const tab_width: f32 = 180;
pub const gap: f32 = 6;
pub const inset: f32 = 4;
pub const limit: usize = 12;

pub const Geometry = struct {
    first_index: usize,
    content: f32,
    viewport: f32,
    selected_x: f32,
    overflow: bool,
    pub fn maxOffset(self: Geometry) f32 {
        return @max(0, self.content - self.viewport);
    }
};
pub fn geometry(width: f32, count: usize, selected: usize) Geometry {
    const visible = @min(count, limit);
    const start = @min(selected -| limit / 2, count -| visible);
    const content = @as(f32, @floatFromInt(visible)) * (tab_width + gap) - (if (visible > 0) gap else @as(f32, 0));
    const available = @max(0, width - inset * 2);
    const overflow = count > limit or content > available;
    return .{ .first_index = start, .content = content, .viewport = @max(0, available - (if (overflow) @as(f32, 60) else 0)), .selected_x = @as(f32, @floatFromInt(selected -| start)) * (tab_width + gap), .overflow = overflow };
}
pub const State = struct {
    offset: f32 = 0,
    workspace: u64 = 0,
    selected: u64 = 0,
    viewport: f32 = 0,
    pub fn sync(self: *State, workspace: u64, selected: u64, layout: Geometry) bool {
        const previous = self.offset;
        const reveal = self.workspace != workspace or self.selected != selected or self.viewport != layout.viewport;
        if (self.workspace != workspace) self.offset = 0;
        if (reveal) {
            if (layout.selected_x < self.offset) self.offset = layout.selected_x;
            if (layout.selected_x + tab_width > self.offset + layout.viewport) self.offset = layout.selected_x + tab_width - layout.viewport;
        }
        self.offset = std.math.clamp(self.offset, 0, layout.maxOffset());
        self.workspace = workspace;
        self.selected = selected;
        self.viewport = layout.viewport;
        return previous != self.offset;
    }
};

test "navigation only appears for overflow including windowed tabs" {
    const t = std.testing;
    try t.expect(!geometry(520, 1, 0).overflow);
    try t.expect(!geometry(520, 2, 0).overflow);
    try t.expect(geometry(520, 3, 0).overflow);
    try t.expect(!geometry(374, 2, 0).overflow);
    try t.expect(geometry(373, 2, 0).overflow);
    try t.expect(geometry(4000, 13, 12).overflow);
}
test "selection resize and workspace switch reveal tabs without fighting user scrolling" {
    const t = std.testing;
    var state: State = .{};
    _ = state.sync(1, 8, geometry(700, 8, 7));
    try t.expect(state.offset > 0);
    state.offset = 20;
    _ = state.sync(1, 8, geometry(700, 8, 7));
    try t.expectEqual(@as(f32, 20), state.offset);
    _ = state.sync(1, 8, geometry(520, 8, 7));
    try t.expect(state.offset > 20);
    _ = state.sync(2, 9, geometry(520, 1, 0));
    try t.expectEqual(@as(f32, 0), state.offset);
}
