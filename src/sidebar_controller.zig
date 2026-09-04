//! Sidebar host coordination; animation/persistence state stays in the model.
const std = @import("std");
const sdk = @import("native_sdk");
const canvas_host = @import("canvas_host.zig");
const Pending = @import("geometry_updates.zig").Pending;

// ui is Canopy's UiApp and reduce is its existing typed update function.
// Structural parameters keep this module independent of main.zig and allow
// deterministic event-order tests without starting a macOS window or a PTY.
pub const Controller = struct {
    pending: Pending = .{},

    pub fn hasPendingGeometry(self: *const Controller) bool {
        return self.pending.any();
    }

    /// true consumes a staged geometry event; other events still go to UiApp.
    pub fn prepareEvent(self: *Controller, runtime: anytype, ui: anytype, event: sdk.Event, comptime reduce: anytype) !bool {
        if (self.stage(ui, event)) {
            try canvas_host.requestFrame(runtime);
            return true;
        }
        if (event == .gpu_surface_frame and std.mem.eql(u8, event.gpu_surface_frame.label, canvas_host.label)) {
            const pending = self.pending.take();
            // A drag fraction belongs to the OLD layout. Apply it before
            // adopting the new width, then perform at most one rebuild.
            if (pending.sidebar) |fraction| reduce(&ui.model, .{ .sidebar_resized = fraction }, &ui.effects);
            ui.model.canvas_width = event.gpu_surface_frame.size.width;
            const moved = ui.model.sidebar.advance(ui.model.canvas_width, event.gpu_surface_frame.timestamp_ns, ui.model.appearance.reduce_motion);
            if (pending.resize) |resize| {
                try ui.app().event(runtime, .{ .gpu_surface_resized = resize });
            } else if (ui.installed and (pending.sidebar != null or moved)) try ui.rebuild(runtime, canvas_host.window_id);
        }
        if (event == .gpu_surface_resized and std.mem.eql(u8, event.gpu_surface_resized.label, canvas_host.label)) {
            ui.model.canvas_width = event.gpu_surface_resized.frame.width;
        }
        return false;
    }

    pub fn finishEvent(self: *const Controller, runtime: anytype, ui: anytype) !void {
        if (!self.hasPendingGeometry() and ui.model.sidebar_persistence.canSave()) {
            if (canvas_host.pointerDown(runtime)) |down| {
                if (!down) try ui.dispatch(runtime, canvas_host.window_id, .save_sidebar_width);
            }
        }
        // Read interaction after a potential save/rebuild, just as UiApp does.
        const grip_active = !ui.model.terminalActionsBlocked() and !ui.model.sidebar.compact and
            !ui.model.sidebar.collapsed and canvas_host.gripActive(runtime);
        const grip_changed = ui.model.sidebar.grip_active != grip_active;
        ui.model.sidebar.grip_active = grip_active;
        if (ui.model.sidebar.needsFrame() or grip_changed) try canvas_host.requestFrame(runtime);
    }

    pub fn flushPending(self: *Controller, ui: anytype, comptime reduce: anytype) void {
        if (self.pending.take().sidebar) |fraction| reduce(&ui.model, .{ .sidebar_resized = fraction }, &ui.effects);
    }

    fn stage(self: *Controller, ui: anytype, event: sdk.Event) bool {
        if (!ui.installed) return false;
        switch (event) {
            .gpu_surface_resized => |resize| {
                if (!std.mem.eql(u8, resize.label, canvas_host.label)) return false;
                self.pending.recordResize(resize);
                return true;
            },
            .canvas_widget_resize => |resize| {
                if (!std.mem.eql(u8, resize.view_label, canvas_host.label)) return false;
                const tree = ui.tree orelse return false;
                const msg = tree.msgForResize(resize.id, resize.fraction) orelse return false;
                if (msg != .sidebar_resized) return false;
                self.pending.sidebar = msg.sidebar_resized;
                return true;
            },
            else => return false,
        }
    }
};
