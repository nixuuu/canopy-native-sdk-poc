//! Host-only credentials and registration. The model sees readiness and sanitized events.
const std = @import("std");
const sdk = @import("native_sdk");
const Server = @import("agent_hook_server.zig").Server;
const keys = @import("effect_keys.zig");

pub const Host = struct {
    server: ?*Server = null,
    failed_reported: bool = false,

    pub fn deinit(self: *Host) void {
        if (self.server) |server| server.destroy();
        self.server = null;
    }
    fn ensure(self: *Host, fx: anytype) !*Server {
        if (self.server) |server| {
            if (server.failed.load(.acquire)) return error.HookReceiverFailed;
            return server;
        }
        const Effects = @TypeOf(fx.*);
        const channel = fx.openChannel(.{ .key = keys.key(.agent_hooks, 1), .on_event = Effects.channelMsg(.agent_hook_event), .max_pending = 32 });
        if (!channel.live()) return error.HookChannelUnavailable;
        errdefer fx.closeChannel(keys.key(.agent_hooks, 1));
        self.server = try Server.create(channel);
        return self.server.?;
    }

    pub fn reconcile(self: *Host, runtime: anytype, ui: anytype) !void {
        if (!ui.model.use_agent_hooks) return;
        if (self.server) |server| {
            server.prune(ui.model.tab_store.items.items);
            if (server.failed.load(.acquire) and !self.failed_reported) {
                self.failed_reported = true;
                try ui.dispatch(runtime, 1, .agent_tracking_failed);
            }
        }
        // A cancelled launch has no PTY exit callback to wait for yet.
        var closing = ui.model.tab_store.items.items.len;
        while (closing > 0) {
            closing -= 1;
            const tab = &ui.model.tab_store.items.items[closing];
            if (tab.tool != .shell and tab.phase == .closing and tab.pending_launch != null) {
                const key = tab.pty;
                tab.pending_launch.?.destroy();
                tab.pending_launch = null;
                try ui.dispatch(runtime, 1, .{ .terminal_event = .{ .key = key, .kind = .exit, .reason = .cancelled } });
            }
        }
        var index: usize = 0;
        while (index < ui.model.tab_store.items.items.len) : (index += 1) {
            const tab = &ui.model.tab_store.items.items[index];
            if (tab.tool == .shell or tab.phase != .starting or tab.agent.registered) continue;
            const pending = tab.pending_launch orelse continue;
            const tab_id = tab.id;
            self.prepare(tab_id, pending, &ui.effects) catch |err| {
                std.debug.print("canopy: agent hook setup failed ({s})\n", .{@errorName(err)});
                pending.destroy();
                tab.pending_launch = null;
                try ui.dispatch(runtime, 1, .{ .agent_setup_failed = tab_id });
                continue;
            };
            tab.agent.registered = true;
            if (!ui.model.use_ghostty) {
                const Effects = @TypeOf(ui.effects);
                ui.effects.ptySpawn(.{ .key = tab.pty, .argv = pending.argv, .env = pending.sdk_env, .cols = 100, .rows = 30, .term = "xterm-256color", .on_event = Effects.ptyMsg(.terminal_event) });
                pending.destroy();
                tab.pending_launch = null;
            }
        }
    }

    pub fn prune(self: *Host, tabs: anytype) void {
        if (self.server) |server| server.prune(tabs);
    }

    fn prepare(self: *Host, tab: u64, pending: anytype, fx: anytype) !void {
        const server = try self.ensure(fx);
        const token = try server.register(tab);
        errdefer server.unregister(tab);
        var port_buffer: [8]u8 = undefined;
        var path_buffer: [64]u8 = undefined;
        const port = try std.fmt.bufPrint(&port_buffer, "{d}", .{server.port});
        const path = try std.fmt.bufPrint(&path_buffer, "/session/{d}", .{tab});
        try pending.appendEnvironment(&.{ .{ .name = "CANOPY_HOOK_PORT", .value = port }, .{ .name = "CANOPY_HOOK_PATH", .value = path }, .{ .name = "CANOPY_HOOK_TOKEN", .value = &token }, .{ .name = "CANOPY_HOOK_COMMAND", .value = @import("agent_hook_config.zig").hook_body }, .{ .name = "CANOPY_STATUS_COMMAND", .value = @import("agent_hook_config.zig").status_body } });
    }
};
