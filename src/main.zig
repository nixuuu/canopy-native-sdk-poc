//! Canopy Native SDK proof of concept.
//!
//! Projects contain worktrees, worktrees own their terminal tabs, and every
//! process mutation leaves the view as an effect. Native SDK owns the PTY,
//! Ghostty VT state, input routing, resizing, selection, and rendering.

const std = @import("std");
const runner = @import("runner");
const native_sdk = @import("native_sdk");

pub const panic = std.debug.FullPanic(native_sdk.debug.capturePanic);

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;

const canvas_label = "main-canvas";
const window_width: f32 = 1180;
const window_height: f32 = 760;
const max_rendered_tab_buttons: usize = 12;
const terminal_bootstrap = "cd -- \"$1\" && exec /bin/zsh -il";

pub const WorkspaceRow = struct {
    id: u16,
    project: []const u8,
    name: []const u8,
    branch: []const u8,
    path: []const u8,
    kind: []const u8,
    terminal_title: []const u8,
};

/// Real local checkouts used by this PoC. Keeping them as model data makes
/// the eventual transition to persisted discovery data mechanical.
pub const workspace_catalog = [_]WorkspaceRow{
    .{
        .id = 1,
        .project = "Canopy Desktop",
        .name = "canopy-code",
        .branch = "next",
        .path = "/Users/nix/GIT/canopy-code",
        .kind = "main checkout",
        .terminal_title = "canopy-code · next",
    },
    .{
        .id = 2,
        .project = "Canopy Desktop",
        .name = "next",
        .branch = "main",
        .path = "/Users/nix/canopy/worktrees/canopy-code/next",
        .kind = "worktree",
        .terminal_title = "next · main",
    },
    .{
        .id = 3,
        .project = "Native SDK PoC",
        .name = "canopy-native-sdk-poc",
        .branch = "local PoC",
        .path = "/Volumes/1TB/GIT/canopy-native-sdk-poc",
        .kind = "project folder",
        .terminal_title = "Native SDK PoC",
    },
};

pub const TerminalPhase = enum { starting, running, closing, exited, failed };

pub const TerminalTab = struct {
    id: u64 = 0,
    workspace_id: u16 = 0,
    pty: u64 = 0,
    title: []const u8 = "",
    path: []const u8 = "",
    branch: []const u8 = "",
    phase: TerminalPhase = .starting,
    exit_code: i32 = 0,
    selected: bool = false,
};

pub const TabStore = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayListUnmanaged(TerminalTab) = .empty,
    free_pty_keys: std.ArrayListUnmanaged(u64) = .empty,

    pub fn create(allocator: std.mem.Allocator) !*TabStore {
        const store = try allocator.create(TabStore);
        store.* = .{ .allocator = allocator };
        return store;
    }

    pub fn destroy(store: *TabStore) void {
        const allocator = store.allocator;
        store.items.deinit(allocator);
        store.free_pty_keys.deinit(allocator);
        allocator.destroy(store);
    }

    fn allocatePtyKey(store: *TabStore, next: *u64) u64 {
        if (store.free_pty_keys.pop()) |key| return key;
        const key = next.*;
        next.* +%= 1;
        return key;
    }

    fn releasePtyKey(store: *TabStore, key: u64) void {
        store.free_pty_keys.append(store.allocator, key) catch {};
    }
};

pub const Model = struct {
    active_workspace_id: u16 = 1,
    active_tab_by_workspace: [workspace_catalog.len]u64 = @splat(0),
    tab_store: *TabStore = undefined,
    next_tab_id: u64 = 1,
    next_pty_key: u64 = 1,
    sidebar_fraction: f32 = 0.255,
    chrome_leading: f32 = 76,
    status_text: []const u8 = "Ready",

    pub const view_unbound = .{
        "active_tab_by_workspace",
        "tab_store",
        "next_tab_id",
        "next_pty_key",
    };

    pub fn canopyWorkspaces(_: *const Model) []const WorkspaceRow {
        return workspace_catalog[0..2];
    }

    pub fn nativeWorkspaces(_: *const Model) []const WorkspaceRow {
        return workspace_catalog[2..3];
    }

    pub fn tabs(model: *const Model, arena: std.mem.Allocator) []const TerminalTab {
        const stored = model.tab_store.items.items;
        var workspace_count: usize = 0;
        var active_ordinal: usize = 0;
        const active = model.activeTabId(model.active_workspace_id);
        for (stored) |tab| {
            if (tab.workspace_id != model.active_workspace_id) continue;
            if (tab.id == active) active_ordinal = workspace_count;
            workspace_count += 1;
        }
        const visible_count = @min(workspace_count, max_rendered_tab_buttons);
        const half = max_rendered_tab_buttons / 2;
        const preferred_start = active_ordinal -| half;
        const start = @min(preferred_start, workspace_count -| visible_count);
        const out = arena.alloc(TerminalTab, visible_count) catch return &.{};
        var ordinal: usize = 0;
        var count: usize = 0;
        for (stored) |tab| {
            if (tab.workspace_id != model.active_workspace_id) continue;
            defer ordinal += 1;
            if (ordinal < start or ordinal >= start + visible_count) continue;
            out[count] = tab;
            out[count].selected = tab.id == active;
            count += 1;
        }
        return out[0..count];
    }

    pub fn activeWorkspaceTerminalCount(model: *const Model) usize {
        var count: usize = 0;
        for (model.tab_store.items.items) |tab| {
            if (tab.workspace_id == model.active_workspace_id) count += 1;
        }
        return count;
    }

    pub fn hasTabs(model: *const Model) bool {
        for (model.tab_store.items.items) |tab| {
            if (tab.workspace_id == model.active_workspace_id) return true;
        }
        return false;
    }

    pub fn activeWorkspaceName(model: *const Model) []const u8 {
        return model.workspace(model.active_workspace_id).?.name;
    }

    pub fn activeWorkspacePath(model: *const Model) []const u8 {
        return model.workspace(model.active_workspace_id).?.path;
    }

    pub fn activeWorkspaceBranch(model: *const Model) []const u8 {
        return model.workspace(model.active_workspace_id).?.branch;
    }

    pub fn workspace(_: *const Model, id: u16) ?*const WorkspaceRow {
        for (&workspace_catalog) |*entry| {
            if (entry.id == id) return entry;
        }
        return null;
    }

    fn workspaceIndex(id: u16) ?usize {
        for (workspace_catalog, 0..) |entry, index| {
            if (entry.id == id) return index;
        }
        return null;
    }

    fn activeTabId(model: *const Model, workspace_id: u16) u64 {
        const index = workspaceIndex(workspace_id) orelse return 0;
        return model.active_tab_by_workspace[index];
    }

    fn setActiveTab(model: *Model, workspace_id: u16, tab_id: u64) void {
        const index = workspaceIndex(workspace_id) orelse return;
        model.active_tab_by_workspace[index] = tab_id;
    }
};

pub const Msg = union(enum) {
    select_workspace: u16,
    open_terminal: u16,
    open_active_terminal,
    activate_tab: u64,
    previous_tab,
    next_tab,
    close_tab: u64,
    terminal_event: native_sdk.EffectPtyEvent,
    sidebar_resized: f32,
    chrome_changed: native_sdk.WindowChrome,

    pub const view_unbound = .{ "terminal_event", "chrome_changed" };
};

const CanopyApp = native_sdk.UiApp(Model, Msg);
pub const Effects = native_sdk.Effects(Msg);

fn openTerminal(model: *Model, fx: *Effects, workspace_id: u16) void {
    const workspace = model.workspace(workspace_id) orelse return;
    model.active_workspace_id = workspace_id;

    const tab_id = model.next_tab_id;
    const pty_key = model.tab_store.allocatePtyKey(&model.next_pty_key);
    model.next_tab_id +%= 1;

    model.tab_store.items.append(model.tab_store.allocator, .{
        .id = tab_id,
        .workspace_id = workspace_id,
        .pty = pty_key,
        .title = workspace.terminal_title,
        .path = workspace.path,
        .branch = workspace.branch,
    }) catch {
        model.tab_store.releasePtyKey(pty_key);
        model.status_text = "The host could not allocate another terminal tab";
        return;
    };
    model.setActiveTab(workspace_id, tab_id);
    model.status_text = "Starting login shell";

    // The path is argv data, not interpolated shell source. $1 lets zsh do a
    // safe `cd` even when a future configured project contains whitespace.
    fx.ptySpawn(.{
        .key = pty_key,
        .argv = &.{ "/bin/zsh", "-c", terminal_bootstrap, "canopy", workspace.path },
        .cols = 100,
        .rows = 30,
        .term = "xterm-256color",
        .on_event = Effects.ptyMsg(.terminal_event),
    });
}

fn removeTab(model: *Model, index: usize) void {
    const removed = model.tab_store.items.orderedRemove(index);
    model.tab_store.releasePtyKey(removed.pty);

    if (model.activeTabId(removed.workspace_id) == removed.id) {
        var replacement: u64 = 0;
        for (model.tab_store.items.items) |tab| {
            if (tab.workspace_id != removed.workspace_id or tab.phase == .closing) continue;
            replacement = tab.id;
        }
        model.setActiveTab(removed.workspace_id, replacement);
    }
}

fn closeTerminal(model: *Model, fx: *Effects, tab_id: u64) void {
    var found: ?usize = null;
    for (model.tab_store.items.items, 0..) |tab, index| {
        if (tab.id == tab_id) {
            found = index;
            break;
        }
    }
    const index = found orelse return;
    const phase = model.tab_store.items.items[index].phase;
    if (phase == .exited or phase == .failed) {
        removeTab(model, index);
        model.status_text = "Terminal closed";
        return;
    }

    model.tab_store.items.items[index].phase = .closing;
    fx.ptyKill(model.tab_store.items.items[index].pty);
    if (model.activeTabId(model.tab_store.items.items[index].workspace_id) == tab_id) {
        var replacement: u64 = 0;
        for (model.tab_store.items.items) |tab| {
            if (tab.workspace_id != model.tab_store.items.items[index].workspace_id or tab.id == tab_id or tab.phase == .closing) continue;
            replacement = tab.id;
        }
        model.setActiveTab(model.tab_store.items.items[index].workspace_id, replacement);
    }
    model.status_text = "Closing terminal";
}

fn cycleTab(model: *Model, forward: bool) void {
    const tabs = model.tab_store.items.items;
    const count = model.activeWorkspaceTerminalCount();
    if (count < 2) return;
    const active = model.activeTabId(model.active_workspace_id);
    var ordinal: usize = 0;
    var active_ordinal: usize = 0;
    for (tabs) |tab| {
        if (tab.workspace_id != model.active_workspace_id) continue;
        if (tab.id == active) active_ordinal = ordinal;
        ordinal += 1;
    }
    const target = if (forward)
        (active_ordinal + 1) % count
    else if (active_ordinal == 0)
        count - 1
    else
        active_ordinal - 1;
    ordinal = 0;
    for (tabs) |tab| {
        if (tab.workspace_id != model.active_workspace_id) continue;
        if (ordinal == target) {
            model.setActiveTab(tab.workspace_id, tab.id);
            model.status_text = "Terminal focused";
            return;
        }
        ordinal += 1;
    }
}

pub fn update(model: *Model, msg: Msg, fx: *Effects) void {
    switch (msg) {
        .select_workspace => |id| if (model.workspace(id) != null) {
            model.active_workspace_id = id;
            model.status_text = "Worktree selected";
        },
        .open_terminal => |id| openTerminal(model, fx, id),
        .open_active_terminal => openTerminal(model, fx, model.active_workspace_id),
        .activate_tab => |id| {
            for (model.tab_store.items.items) |tab| {
                if (tab.id != id or tab.workspace_id != model.active_workspace_id) continue;
                model.setActiveTab(tab.workspace_id, id);
                model.status_text = "Terminal focused";
                return;
            }
        },
        .previous_tab => cycleTab(model, false),
        .next_tab => cycleTab(model, true),
        .close_tab => |id| closeTerminal(model, fx, id),
        .terminal_event => |event| {
            var index: usize = 0;
            while (index < model.tab_store.items.items.len) : (index += 1) {
                if (model.tab_store.items.items[index].pty != event.key) continue;
                switch (event.kind) {
                    .output => {
                        if (model.tab_store.items.items[index].phase != .closing) {
                            model.tab_store.items.items[index].phase = .running;
                            model.status_text = "Shell running";
                        }
                    },
                    .exit => {
                        if (model.tab_store.items.items[index].phase == .closing) {
                            removeTab(model, index);
                            model.status_text = "Terminal closed";
                        } else {
                            model.tab_store.items.items[index].exit_code = event.code;
                            model.tab_store.items.items[index].phase = if (event.reason == .exited) .exited else .failed;
                            model.status_text = if (event.reason == .exited) "Shell exited" else "Shell failed";
                        }
                    },
                    .write => unreachable,
                }
                return;
            }
        },
        .sidebar_resized => |fraction| model.sidebar_fraction = fraction,
        .chrome_changed => |chrome| model.chrome_leading = @max(76, chrome.insets.left + 64),
    }
}

pub fn boot(model: *Model, fx: *Effects) void {
    openTerminal(model, fx, model.active_workspace_id);
}

pub fn onChrome(chrome: native_sdk.WindowChrome) ?Msg {
    return .{ .chrome_changed = chrome };
}

pub const AppUi = canvas.Ui(Msg);
pub const app_markup = @embedFile("app.native");

const app_permissions = [_][]const u8{
    native_sdk.security.permission_command,
    native_sdk.security.permission_view,
};
const shell_views = [_]native_sdk.ShellView{.{
    .label = canvas_label,
    .kind = .gpu_surface,
    .fill = true,
    .role = "Canopy workspace",
    .accessibility_label = "Canopy",
    .gpu_backend = .metal,
    .gpu_pixel_format = .bgra8_unorm,
    .gpu_present_mode = .timer,
    .gpu_alpha_mode = .@"opaque",
    .gpu_color_space = .srgb,
    .gpu_vsync = true,
}};
const shell_windows = [_]native_sdk.ShellWindow{.{
    .label = "main",
    .title = "Canopy",
    .width = window_width,
    .height = window_height,
    .min_width = 860,
    .min_height = 560,
    .titlebar = .hidden_inset_tall,
    .views = &shell_views,
}};
const shell_scene: native_sdk.ShellConfig = .{ .windows = &shell_windows };

pub fn initialModel(tab_store: *TabStore) Model {
    return .{ .tab_store = tab_store };
}

pub fn main(init: std.process.Init) !void {
    const tab_store = try TabStore.create(std.heap.page_allocator);
    defer tab_store.destroy();
    const app_state = try CanopyApp.create(std.heap.page_allocator, .{
        .name = "canopy-native-sdk-poc",
        .scene = shell_scene,
        .canvas_label = canvas_label,
        .update_fx = update,
        .init_fx = boot,
        .markup = .{ .source = app_markup, .watch_path = "src/app.native", .io = init.io },
        .on_chrome = onChrome,
    });
    defer app_state.destroy();
    app_state.model = initialModel(tab_store);

    try runner.runWithOptions(app_state.app(), .{
        .app_name = "canopy-native-sdk-poc",
        .window_title = "Canopy",
        .bundle_id = "tech.itsol.canopy.native-poc",
        .icon_path = "assets/icon.png",
        .default_frame = geometry.RectF.init(0, 0, window_width, window_height),
        .js_window_api = false,
        .security = .{
            .permissions = &app_permissions,
            .navigation = .{ .allowed_origins = &.{ "zero://inline", "zero://app" } },
        },
    }, init);
}

test {
    _ = @import("tests.zig");
}
