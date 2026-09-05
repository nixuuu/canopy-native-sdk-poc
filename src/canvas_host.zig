//! The app's narrow adapter to retained-canvas host internals.
pub const label = "main-canvas";
pub const window_id = 1;

pub fn requestFrame(runtime: anytype) !void {
    if (runtime.findViewIndex(window_id, label)) |index| try runtime.requestCanvasFrameForView(index);
}

/// null means there is no canvas yet, not an idle pointer.
pub fn pointerDown(runtime: anytype) ?bool {
    const index = runtime.findViewIndex(window_id, label) orelse return null;
    return runtime.views[index].canvas_widget_pressed_id != 0;
}

pub fn gripActive(runtime: anytype) bool {
    const index = runtime.findViewIndex(window_id, label) orelse return false;
    const view = &runtime.views[index];
    const layout = runtime.canvasWidgetLayout(window_id, label) catch return false;
    for (layout.nodes) |node| {
        if (node.widget.kind == .split_divider and
            (node.widget.id == view.canvas_widget_hovered_id or node.widget.id == view.canvas_widget_pressed_id)) return true;
    }
    return false;
}

/// Claim before invoking native code: AppKit may synchronously reenter us.
pub const InstallGate = struct {
    claimed: bool = false,

    pub fn claim(self: *InstallGate, installed: bool) bool {
        if (!installed or self.claimed) return false;
        self.claimed = true;
        return true;
    }
};

test "native configuration can only be claimed once after UI installation" {
    const testing = @import("std").testing;
    var gate: InstallGate = .{};
    try testing.expect(!gate.claim(false));
    try testing.expect(gate.claim(true));
    try testing.expect(!gate.claim(true)); // synchronous reentrant callback
    try testing.expect(!gate.claim(false));
}

/// Authored global-key in terminal-workspace.native, independent of its label.
pub const terminal_viewport_id = @import("native_sdk").canvas.globalWidgetId(.column, .{ .str = "canopy-terminal-viewport" });

/// Descendant layout stays at its destination during retained split motion.
/// Native views must use the visible pane bounds, not that uncropped width.
pub fn terminalViewport(layout: @import("native_sdk").canvas.WidgetLayoutTree) ?@import("native_sdk").geometry.RectF {
    const Rect = @import("native_sdk").geometry.RectF;
    for (layout.nodes) |node| {
        if (node.widget.id != terminal_viewport_id) continue;
        var bounds = node.frame;
        var parent = node.parent_index;
        while (parent) |index| : (parent = layout.nodes[index].parent_index) {
            if (layout.nodes[index].parent_index) |ancestor| {
                if (layout.nodes[ancestor].widget.kind == .split) bounds = Rect.intersection(bounds, layout.nodes[index].frame);
            }
        }
        return if (bounds.width > 0 and bounds.height > 0) bounds else null;
    }
    return null;
}
