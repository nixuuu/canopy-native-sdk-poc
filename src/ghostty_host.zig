//! Native SDK view adoption and Ghostty lifecycle, confined to the UI thread.
const std = @import("std");
const sdk = @import("native_sdk");
const geometry = sdk.geometry;
const config = @import("ghostty_config.zig");
const launch = @import("terminal_launch.zig");
const Event = extern struct { tab: u64, kind: c_int, code: c_int };
extern fn canopy_ghostty_create(files: [*]const [*:0]const u8, count: usize) ?*anyopaque;
extern fn canopy_ghostty_set_wakeup(host: *anyopaque, notify: *const fn (*anyopaque) callconv(.c) void, context: *anyopaque) void;
extern fn canopy_ghostty_destroy(host: *anyopaque) void;
extern fn canopy_ghostty_tick(host: *anyopaque) void;
extern fn canopy_ghostty_next_event(host: *anyopaque, event: *Event) bool;
extern fn canopy_ghostty_surface(host: *anyopaque, tab: u64, cwd: [*:0]const u8, command: [*:0]const u8, env: [*]const launch.Env, count: usize) ?*anyopaque;
extern fn canopy_ghostty_close(host: *anyopaque, tab: u64) void;
extern fn canopy_ghostty_visibility(host: *anyopaque, tab: u64, visible: bool, focus: bool) void;
extern fn canopy_ghostty_cover(host: *anyopaque, tab: u64, covered: f64, overlay: bool) void;
extern fn canopy_ghostty_begin_layout(host: *anyopaque, tab: u64) void;

const allocator = std.heap.page_allocator;
const container = "ghostty-surface";
fn notify(context: *anyopaque) callconv(.c) void {
    const runtime: *sdk.Runtime = @ptrCast(@alignCast(context));
    runtime.options.platform.services.wake() catch {};
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
        if (self.raw) |raw| canopy_ghostty_destroy(raw);
        self.surfaces.deinit(allocator);
        self.* = .{};
    }

    pub fn detach(self: *Host, runtime: *sdk.Runtime) void {
        if (self.mounted != 0) {
            if (self.raw) |raw| canopy_ghostty_visibility(raw, self.mounted, false, false);
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
            self.raw = canopy_ghostty_create(paths.items.ptr, paths.items.len) orelse return error.GhosttyInitializationFailed;
            canopy_ghostty_set_wakeup(self.raw.?, notify, runtime);
        }
        const raw = self.raw.?;
        canopy_ghostty_tick(raw);
        // Callback identity is the monotonically increasing tab id, never a
        // recycled PTY key. Dispatch only after returning from Ghostty callbacks.
        var event: Event = undefined;
        while (canopy_ghostty_next_event(raw, &event)) {
            for (model.tab_store.items.items) |tab| {
                if (tab.id != event.tab) continue;
                switch (event.kind) {
                    1 => try ui.dispatch(runtime, 1, .{ .terminal_event = .{ .key = tab.pty, .kind = .exit, .code = event.code } }),
                    2 => try ui.dispatch(runtime, 1, .{ .close_tab = tab.id }),
                    3 => try ui.dispatch(runtime, 1, .open_active_terminal),
                    4 => try ui.dispatch(runtime, 1, .dismiss_sidebar),
                    else => {},
                }
                break;
            }
        }
        var index: usize = 0;
        while (index < model.tab_store.items.items.len) {
            const tab = &model.tab_store.items.items[index];
            if (tab.phase == .closing) {
                const key = tab.pty;
                if (self.mounted == tab.id) self.detach(runtime);
                canopy_ghostty_close(raw, tab.id);
                _ = self.surfaces.remove(tab.id);
                try ui.dispatch(runtime, 1, .{ .terminal_event = .{ .key = key, .kind = .exit, .reason = .cancelled } });
                continue;
            }
            if (tab.pending_launch) |pending| {
                const key = tab.pty;
                const command = if (snapshot.hasExplicitEnvironment("NO_COLOR")) pending.original_command else pending.command;
                const surface = canopy_ghostty_surface(raw, tab.id, pending.cwd, command, pending.env.ptr, pending.env.len);
                pending.destroy();
                tab.pending_launch = null;
                if (surface) |view| {
                    self.surfaces.put(allocator, tab.id, view) catch |err| {
                        canopy_ghostty_close(raw, tab.id);
                        return err;
                    };
                    canopy_ghostty_visibility(raw, tab.id, false, false);
                    try ui.dispatch(runtime, 1, .{ .terminal_event = .{ .key = key, .kind = .output } });
                } else try ui.dispatch(runtime, 1, .{ .terminal_event = .{ .key = key, .kind = .exit, .reason = .spawn_failed } });
            }
            index += 1;
        }
        // Exited tabs may be removed without another process-exit callback.
        // Sweep only on membership changes, never on each render/input event.
        // A hash set keeps the common all-tabs-alive path linear, not quadratic.
        if (self.observed_tab_count != model.tab_store.items.items.len or self.observed_next_tab_id != model.next_tab_id) {
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
                canopy_ghostty_close(raw, id);
                _ = self.surfaces.remove(id);
            }
            self.observed_tab_count = model.tab_store.items.items.len;
            self.observed_next_tab_id = model.next_tab_id;
        }

        const blocked = model.terminalActionsBlocked();
        const selected = model.active_tab_by_workspace.get(model.active_workspace_id) orelse 0;
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
            if (self.mounted == selected) canopy_ghostty_begin_layout(raw, selected);
            _ = try runtime.updateView(1, container, .{ .frame = frame.? });
            self.frame = frame;
        }
        if (self.mounted != selected) {
            self.detach(runtime);
            _ = try runtime.updateView(1, container, .{ .visible = true });
            try runtime.adoptViewSurface(1, container, view.?);
            self.mounted = selected;
            canopy_ghostty_visibility(raw, selected, true, true);
        }
        canopy_ghostty_cover(raw, selected, covered, model.sidebarOverlayVisible());
        if (self.overlay_active != model.sidebarOverlayVisible()) {
            self.overlay_active = model.sidebarOverlayVisible();
            if (self.overlay_active) {
                try runtime.focusView(1, "main-canvas");
            } else canopy_ghostty_visibility(raw, selected, true, true);
        }
    }
};
