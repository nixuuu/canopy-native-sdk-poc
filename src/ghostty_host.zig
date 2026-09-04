//! Native SDK view adoption and Ghostty lifecycle, confined to the UI thread.
const std = @import("std");
const sdk = @import("native_sdk");
const geometry = sdk.geometry;
const config = @import("ghostty_config.zig");
const bridge = @import("ghostty_abi.zig").c;

const allocator = std.heap.page_allocator;
const container = "ghostty-surface";
fn notify(context: ?*anyopaque) callconv(.c) void {
    const runtime: *sdk.Runtime = @ptrCast(@alignCast(context orelse return));
    runtime.options.platform.services.wake() catch {};
}

/// Match the never-reused tab id before translating a native callback to Msg.
/// Delayed callbacks for a closed tab must not target a recycled PTY key.
pub fn dispatchEvent(runtime: anytype, ui: anytype, event: bridge.canopy_ghostty_event) !void {
    for (ui.model.tab_store.items.items) |tab| {
        if (tab.id != event.tab) continue;
        switch (event.kind) {
            bridge.CANOPY_GHOSTTY_PROCESS_EXIT => try ui.dispatch(runtime, 1, .{ .terminal_event = .{ .key = tab.pty, .kind = .exit, .code = event.code } }),
            bridge.CANOPY_GHOSTTY_CLOSE_TAB => try ui.dispatch(runtime, 1, .{ .close_tab = tab.id }),
            bridge.CANOPY_GHOSTTY_NEW_TERMINAL => try ui.dispatch(runtime, 1, .open_active_terminal),
            bridge.CANOPY_GHOSTTY_DISMISS_SIDEBAR => try ui.dispatch(runtime, 1, .dismiss_sidebar),
            else => {},
        }
        return;
    }
}
pub const Host = struct {
    raw: ?*anyopaque = null,
    surfaces: std.AutoHashMapUnmanaged(u64, *anyopaque) = .empty,
    installed: bool = false,
    mounted: u64 = 0,
    overlay_active: bool = false,
    frame: ?geometry.RectF = null,
    observed_tab_count: usize = 0,
    observed_next_tab_id: u64 = 0,

    pub fn deinit(self: *Host) void {
        if (self.raw) |raw| bridge.canopy_ghostty_destroy(raw);
        self.surfaces.deinit(allocator);
        self.* = .{};
    }

    pub fn detach(self: *Host, runtime: *sdk.Runtime) void {
        if (self.mounted != 0) {
            if (self.raw) |raw| bridge.canopy_ghostty_visibility(raw, self.mounted, false, false);
            runtime.releaseViewSurface(1, container) catch {};
            if (self.installed) _ = runtime.updateView(1, container, .{ .visible = false }) catch {};
        }
        self.mounted = 0;
    }

    pub fn reconcile(self: *Host, runtime: *sdk.Runtime, ui: anytype, snapshot: *const config.Snapshot) !void {
        const model = &ui.model;
        if (self.raw == null and model.tab_store.items.items.len == 0) return;
        if (self.raw == null) {
            var arena = std.heap.ArenaAllocator.init(allocator);
            defer arena.deinit();
            var paths: std.ArrayList([*:0]const u8) = .empty;
            for (snapshot.sources.items) |source| if (source.layer == .user) {
                try paths.append(arena.allocator(), try arena.allocator().dupeZ(u8, source.path));
            };
            self.raw = bridge.canopy_ghostty_create(paths.items.ptr, paths.items.len) orelse return error.GhosttyInitializationFailed;
            bridge.canopy_ghostty_set_wakeup(self.raw.?, notify, runtime);
        }
        const raw = self.raw.?;
        bridge.canopy_ghostty_tick(raw);
        // Callback identity is the monotonically increasing tab id, never a
        // recycled PTY key. Dispatch only after returning from Ghostty callbacks.
        var event: bridge.canopy_ghostty_event = undefined;
        while (bridge.canopy_ghostty_next_event(raw, &event)) {
            try dispatchEvent(runtime, ui, event);
        }
        var index: usize = 0;
        while (index < model.tab_store.items.items.len) {
            const tab = &model.tab_store.items.items[index];
            if (tab.phase == .closing) {
                const key = tab.pty;
                if (self.mounted == tab.id) self.detach(runtime);
                bridge.canopy_ghostty_close(raw, tab.id);
                _ = self.surfaces.remove(tab.id);
                try ui.dispatch(runtime, 1, .{ .terminal_event = .{ .key = key, .kind = .exit, .reason = .cancelled } });
                continue;
            }
            if (tab.pending_launch) |pending| {
                const key = tab.pty;
                const command = if (snapshot.hasExplicitEnvironment("NO_COLOR")) pending.original_command else pending.command;
                const surface = bridge.canopy_ghostty_surface(raw, tab.id, pending.cwd, command, pending.env.ptr, pending.env.len);
                pending.destroy();
                tab.pending_launch = null;
                if (surface) |view| {
                    self.surfaces.put(allocator, tab.id, view) catch |err| {
                        bridge.canopy_ghostty_close(raw, tab.id);
                        return err;
                    };
                    bridge.canopy_ghostty_visibility(raw, tab.id, false, false);
                    try ui.dispatch(runtime, 1, .{ .terminal_event = .{ .key = key, .kind = .output } });
                } else try ui.dispatch(runtime, 1, .{ .terminal_event = .{ .key = key, .kind = .exit, .reason = .spawn_failed } });
            }
            index += 1;
        }
        // Exited tabs may be removed without another process-exit callback.
        // Sweep only on membership changes, never on each render/input event.
        // A hash set keeps the common all-tabs-alive path linear, not quadratic.
        if (self.observed_tab_count != model.tab_store.items.items.len or self.observed_next_tab_id != model.terminal_state.next_tab_id) {
            var live: std.AutoHashMapUnmanaged(u64, void) = .empty;
            defer live.deinit(allocator);
            for (model.tab_store.items.items) |tab| try live.put(allocator, tab.id, {});
            while (true) {
                var obsolete: ?u64 = null;
                var keys = self.surfaces.keyIterator();
                while (keys.next()) |id| {
                    if (!live.contains(id.*)) {
                        obsolete = id.*;
                        break;
                    }
                }
                const id = obsolete orelse break;
                if (self.mounted == id) self.detach(runtime);
                bridge.canopy_ghostty_close(raw, id);
                _ = self.surfaces.remove(id);
            }
            self.observed_tab_count = model.tab_store.items.items.len;
            self.observed_next_tab_id = model.terminal_state.next_tab_id;
        }

        const blocked = model.terminalActionsBlocked();
        const selected = model.terminal_state.active(model.active_workspace_id);
        const layout = runtime.canvasWidgetLayout(1, "main-canvas") catch return;
        var frame: ?geometry.RectF = null;
        if (!blocked) for (layout.nodes) |node| {
            if (std.mem.eql(u8, node.widget.semantics.label, "Ghostty terminal viewport") and node.frame.width > 0 and node.frame.height > 0) {
                frame = node.frame;
                break;
            }
        };
        const view = self.surfaces.get(selected);
        if (frame == null or view == null) {
            self.detach(runtime);
            return;
        }
        const covered = std.math.clamp(model.sidebarOverlayWidth() - frame.?.x, 0, @max(0, frame.?.width - 1));
        frame.?.x += covered;
        frame.?.width -= covered;
        if (!self.installed) {
            _ = try runtime.createView(.{ .window_id = 1, .label = container, .kind = .stack, .parent = "main-canvas", .frame = frame.?, .layer = 1, .visible = false });
            self.installed = true;
        }
        if (self.frame == null or !std.meta.eql(self.frame.?, frame.?)) {
            if (self.mounted == selected) bridge.canopy_ghostty_begin_layout(raw, selected);
            _ = try runtime.updateView(1, container, .{ .frame = frame.? });
            self.frame = frame;
        }
        if (self.mounted != selected) {
            self.detach(runtime);
            _ = try runtime.updateView(1, container, .{ .visible = true });
            try runtime.adoptViewSurface(1, container, view.?);
            self.mounted = selected;
            bridge.canopy_ghostty_visibility(raw, selected, true, true);
        }
        bridge.canopy_ghostty_cover(raw, selected, covered, model.sidebarOverlayVisible());
        if (self.overlay_active != model.sidebarOverlayVisible()) {
            self.overlay_active = model.sidebarOverlayVisible();
            if (self.overlay_active) {
                try runtime.focusView(1, "main-canvas");
            } else bridge.canopy_ghostty_visibility(raw, selected, true, true);
        }
    }
};

test "native events route by tab identity and ignore retired or unknown callbacks" {
    const Msg = union(enum) { terminal_event: sdk.EffectPtyEvent, close_tab: u64, open_active_terminal, dismiss_sidebar };
    const Tabs = @import("terminal_tabs.zig").Store;
    const Ui = struct {
        model: struct { tab_store: *Tabs },
        messages: [8]Msg = undefined,
        count: usize = 0,
        pub fn dispatch(self: *@This(), _: void, _: u64, msg: Msg) !void {
            self.messages[self.count] = msg;
            self.count += 1;
        }
    };
    const tabs = try Tabs.create(std.testing.allocator);
    defer tabs.destroy();
    try tabs.items.append(std.testing.allocator, .{ .id = 11, .pty = 7 });
    var ui: Ui = .{ .model = .{ .tab_store = tabs } };
    for ([_]bridge.canopy_ghostty_event_kind{
        bridge.CANOPY_GHOSTTY_PROCESS_EXIT, bridge.CANOPY_GHOSTTY_CLOSE_TAB,
        bridge.CANOPY_GHOSTTY_NEW_TERMINAL, bridge.CANOPY_GHOSTTY_DISMISS_SIDEBAR,
    }) |kind| try dispatchEvent({}, &ui, .{ .tab = 11, .kind = kind, .code = -3 });
    try std.testing.expectEqual(@as(u64, 7), ui.messages[0].terminal_event.key);
    try std.testing.expectEqual(@as(i32, -3), ui.messages[0].terminal_event.code);
    try std.testing.expectEqual(@as(u64, 11), ui.messages[1].close_tab);
    try std.testing.expect(ui.messages[2] == .open_active_terminal);
    try std.testing.expect(ui.messages[3] == .dismiss_sidebar);
    tabs.items.items[0].id = 12; // a new tab reused PTY 7
    try dispatchEvent({}, &ui, .{ .tab = 11, .kind = bridge.CANOPY_GHOSTTY_CLOSE_TAB, .code = 0 });
    try dispatchEvent({}, &ui, .{ .tab = 12, .kind = 99, .code = 0 });
    try std.testing.expectEqual(@as(usize, 4), ui.count);
    try dispatchEvent({}, &ui, .{ .tab = 12, .kind = bridge.CANOPY_GHOSTTY_CLOSE_TAB, .code = 0 });
    try std.testing.expectEqual(@as(u64, 12), ui.messages[4].close_tab);
}
