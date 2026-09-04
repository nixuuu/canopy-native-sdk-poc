//! AppKit menu lifetime and enqueue-only wakeup; tab mutations stay in update.
const builtin = @import("builtin");
const sdk = @import("native_sdk");

extern fn canopy_close_tab_menu_create(*const fn (*anyopaque) callconv(.c) void, *anyopaque) ?*anyopaque;
extern fn canopy_close_tab_menu_update(*anyopaque, bool) void;
extern fn canopy_close_tab_menu_take(*anyopaque) bool;
extern fn canopy_close_tab_menu_destroy(*anyopaque) void;

fn notify(context: *anyopaque) callconv(.c) void {
    const runtime: *sdk.Runtime = @ptrCast(@alignCast(context));
    runtime.options.platform.services.wake() catch {};
}

pub const Host = struct {
    raw: ?*anyopaque = null,

    pub fn sync(self: *Host, runtime: *sdk.Runtime, enabled: bool) !void {
        if (builtin.os.tag != .macos) return;
        if (self.raw == null) self.raw = canopy_close_tab_menu_create(notify, runtime) orelse return error.CloseTabMenuUnavailable;
        canopy_close_tab_menu_update(self.raw.?, enabled);
    }

    pub fn takeClose(self: *Host) bool {
        if (builtin.os.tag != .macos) return false;
        return if (self.raw) |raw| canopy_close_tab_menu_take(raw) else false;
    }

    pub fn deinit(self: *Host) void {
        if (builtin.os.tag == .macos) if (self.raw) |raw| canopy_close_tab_menu_destroy(raw);
        self.raw = null;
    }
};
