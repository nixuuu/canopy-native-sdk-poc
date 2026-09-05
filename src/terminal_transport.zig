//! Transport selection; terminal lifecycle decisions belong to terminal_controller.
const sdk = @import("native_sdk");
const tabs = @import("terminal_tabs.zig");
const launch = @import("terminal_launch.zig");
const std = @import("std");

pub fn start(ghostty: bool, tracked: bool, allocator: std.mem.Allocator, tab: *tabs.Tab, argv: []const []const u8, env: []const sdk.PtyEnvEntry, fx: anytype) !void {
    if (ghostty or tracked) {
        tab.pending_launch = try launch.Pending.create(allocator, tab.path.slice(), argv, env);
    } else {
        const Effects = @TypeOf(fx.*);
        fx.ptySpawn(.{ .key = tab.pty, .argv = argv, .cols = 100, .rows = 30, .term = "xterm-256color", .env = env, .on_event = Effects.ptyMsg(.terminal_event) });
    }
}

pub fn close(ghostty: bool, fx: anytype, key: u64) void {
    // Ghostty reconciles the model's closing state on the same host boundary.
    if (!ghostty) fx.ptyKill(key);
}
pub fn forget(ghostty: bool, fx: anytype, key: u64) void {
    if (!ghostty) fx.ptyForget(key);
}
