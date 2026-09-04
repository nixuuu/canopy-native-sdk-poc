//! Canopy Native SDK proof of concept.
//!
//! Projects contain worktrees, worktrees own their terminal tabs, and every
//! process mutation leaves the view as a host request. On macOS full Ghostty
//! owns the PTY and renderer; Native SDK owns the application chrome.

const std = @import("std");
const builtin = @import("builtin");
const runner = @import("runner");
const native_sdk = @import("native_sdk");
const preferences_mod = @import("preferences.zig");
const ghostty_config_mod = @import("ghostty_config.zig");
const profiles_mod = @import("profiles.zig");
const terminal_tabs = @import("terminal_tabs.zig");
const workspaces = @import("workspaces.zig");
const model_mod = @import("model.zig");
const messages = @import("messages.zig");

pub const panic = std.debug.FullPanic(native_sdk.debug.capturePanic);

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;

const canvas_host = @import("canvas_host.zig");
const canvas_label = canvas_host.label;
extern fn canopy_use_compact_titlebar() void;
const window_width = model_mod.window_width;
pub const sidebar_divider_width = model_mod.sidebar_divider_width;
const window_height: f32 = 760;
const fallback_user_shell = model_mod.fallback_user_shell;

pub const TerminalPhase = terminal_tabs.Phase;
pub const TerminalTool = terminal_tabs.Tool;
pub const TerminalTab = terminal_tabs.Tab;
pub const TerminalTabRow = terminal_tabs.Row;
pub const TabStore = terminal_tabs.Store;
pub const PreferencesSection = model_mod.PreferencesSection;
pub const Model = model_mod.Model;

pub const PathPayload = messages.PathPayload;

pub const Msg = messages.Msg;

const CanopyApp = native_sdk.UiApp(Model, Msg);
const app_controller = @import("app_controller.zig");
pub const Effects = app_controller.Effects;
pub const update = app_controller.update;
pub const boot = app_controller.boot;
pub const onChrome = app_controller.onChrome;
pub const onAppearance = app_controller.onAppearance;
pub const canopyTokens = app_controller.canopyTokens;
pub const flushSidebarWidth = app_controller.flushSidebarWidth;
pub const preferences_load_key = app_controller.preferences_load_key;
pub const preferences_write_key = app_controller.preferences_write_key;
pub const profiles_load_key = app_controller.profiles_load_key;
pub const profile_write_key = app_controller.profile_write_key;
pub const sidebar_write_key = app_controller.sidebar_write_key;
pub const resolvedToolExecutable = app_controller.resolvedToolExecutable;

pub const AppUi = canvas.Ui(Msg);
pub const app_markup = @embedFile("app.native");
const app_markup_sources = [_]canvas.ui_markup.SourceFile{
    .{ .path = "components/primitives.native", .source = @embedFile("components/primitives.native") },
    .{ .path = "components/titlebar.native", .source = @embedFile("components/titlebar.native") },
    .{ .path = "components/project-sidebar.native", .source = @embedFile("components/project-sidebar.native") },
    .{ .path = "components/tools-sidebar.native", .source = @embedFile("components/tools-sidebar.native") },
    .{ .path = "components/terminal-workspace.native", .source = @embedFile("components/terminal-workspace.native") },
    .{ .path = "components/empty-state.native", .source = @embedFile("components/empty-state.native") },
    .{ .path = "components/dialogs.native", .source = @embedFile("components/dialogs.native") },
    .{ .path = "components/preferences.native", .source = @embedFile("components/preferences.native") },
    .{ .path = "components/preferences-header.native", .source = @embedFile("components/preferences-header.native") },
    .{ .path = "components/preferences-sidebar.native", .source = @embedFile("components/preferences-sidebar.native") },
    .{ .path = "components/preferences-general.native", .source = @embedFile("components/preferences-general.native") },
    .{ .path = "components/preferences-appearance.native", .source = @embedFile("components/preferences-appearance.native") },
    .{ .path = "components/preferences-worktrees.native", .source = @embedFile("components/preferences-worktrees.native") },
    .{ .path = "components/profile-preferences.native", .source = @embedFile("components/profile-preferences.native") },
};
const app_compiled_sources = [_]canvas.ui_markup.SourceFile{.{ .path = "app.native", .source = app_markup }} ++ app_markup_sources;
pub const CompiledCanopyView = canvas.CompiledMarkupImports(Model, Msg, "app.native", &app_compiled_sources);
// The SDK schema generator requires STRICT tables. Electron Canopy's shipped
// table is intentionally ordinary SQLite, so keep this tiny migration explicit
// to preserve its structural compatibility for a future importer.
const preferences_migrations = [_]native_sdk.relational_store.Migration{
    .{
        .version = 1,
        .name = "electron-compatible-preferences",
        .sql = preferences_mod.ensure_schema_sql,
    },
    .{
        .version = 2,
        .name = "electron-compatible-agent-profiles",
        .sql = profiles_mod.migration_sql,
    },
};

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

pub fn initialModel(tab_store: *TabStore, project_store: *workspaces.Store, profile_store: *profiles_mod.Store) Model {
    return .{ .tab_store = tab_store, .project_store = project_store, .profile_store = profile_store };
}

fn sidebarKey(key: canvas.WidgetKeyboardEvent) ?Msg {
    return if (std.ascii.eqlIgnoreCase(key.key, "escape")) .dismiss_sidebar else null;
}

fn appOptions(io: std.Io) CanopyApp.Options {
    return .{
        .name = "canopy-native-sdk-poc",
        .scene = shell_scene,
        .canvas_label = canvas_label,
        .update_fx = update,
        .init_fx = boot,
        .tokens_fn = canopyTokens,
        .on_appearance = onAppearance,
        .view = CompiledCanopyView.build,
        .markup = if (builtin.mode == .Debug)
            .{ .source = app_markup, .sources = &app_markup_sources, .watch_path = "src/app.native", .io = io }
        else
            null,
        .on_chrome = onChrome,
        .on_key = sidebarKey,
    };
}

const CanopyHost = struct {
    chrome_install: canvas_host.InstallGate = .{},
    sidebar_controller: @import("sidebar_controller.zig").Controller = .{},
    menu: @import("app_menu.zig").Host = .{},
    terminals: @import("ghostty_host.zig").Host = .{},
    ui_app: *CanopyApp,
    io: std.Io,
    // Host-only, not Model: raw Ghostty directives can contain secrets and
    // must not be serialized into UI snapshots or session fingerprints.
    ghostty_config: ?*const ghostty_config_mod.Snapshot = null,
    handled_picker_serial: u64 = 0,
    handled_worktrees_base_serial: u64 = 0,

    fn create(
        allocator: std.mem.Allocator,
        io: std.Io,
        tab_store: *TabStore,
        project_store: *workspaces.Store,
        profile_store: *profiles_mod.Store,
        store_path: []const u8,
        preferences_db_path: []const u8,
        default_worktrees_base: []const u8,
        user_shell: []const u8,
    ) !*CanopyHost {
        const host = try allocator.create(CanopyHost);
        errdefer allocator.destroy(host);
        const ui_app = try CanopyApp.create(allocator, appOptions(io));
        ui_app.model = initialModel(tab_store, project_store, profile_store);
        ui_app.model.use_ghostty = builtin.os.tag == .macos;
        ui_app.model.setStorePath(store_path);
        _ = ui_app.model.preferences_db_path.set(preferences_db_path);
        _ = ui_app.model.default_worktrees_base.set(default_worktrees_base);
        ui_app.model.setUserShell(user_shell);
        host.* = .{ .ui_app = ui_app, .io = io };
        return host;
    }

    fn destroy(host: *CanopyHost, allocator: std.mem.Allocator) void {
        host.menu.deinit();
        host.terminals.deinit();
        host.ui_app.model.terminal_state.deinit(host.ui_app.model.tab_store.allocator);
        host.ui_app.destroy();
        allocator.destroy(host);
    }

    fn app(host: *CanopyHost) native_sdk.App {
        return .{
            .context = host,
            .name = "canopy-native-sdk-poc",
            .scene_fn = scene,
            .event_fn = event,
            .stop_fn = stop,
        };
    }

    fn scene(_: *anyopaque) anyerror!native_sdk.ShellConfig {
        return shell_scene;
    }

    fn event(context: *anyopaque, runtime: *native_sdk.Runtime, event_value: native_sdk.Event) anyerror!void {
        const host: *CanopyHost = @ptrCast(@alignCast(context));
        if (try host.sidebar_controller.prepareEvent(runtime, host.ui_app, event_value, update)) return;
        try host.ui_app.app().event(runtime, event_value);
        try host.synchronizeNativeState(runtime);
        try host.sidebar_controller.finishEvent(runtime, host.ui_app);
    }

    fn synchronizeNativeState(host: *CanopyHost, runtime: *native_sdk.Runtime) !void {
        while (host.menu.takeClose()) try host.ui_app.dispatch(runtime, 1, .close_active_tab);
        try host.ensureWorktreesBase(runtime);
        try host.presentPendingFolderDialog(runtime);
        if (builtin.os.tag == .macos and !host.sidebar_controller.hasPendingGeometry()) try host.terminals.reconcile(runtime, host.ui_app, host.ghostty_config.?);
        try host.menu.sync(runtime, host.ui_app.model.canCloseActiveTab());
        // AppKit can synchronously emit resizes when its toolbar style changes.
        // Do this only after UiApp has finished installation, with the guard
        // already set so a reentrant callback cannot initialize UI twice.
        if (builtin.os.tag == .macos and host.chrome_install.claim(host.ui_app.installed)) {
            canopy_use_compact_titlebar();
        }
    }

    fn ensureWorktreesBase(host: *CanopyHost, runtime: *native_sdk.Runtime) !void {
        const serial = host.ui_app.model.worktrees_base_serial;
        if (serial == host.handled_worktrees_base_serial) return;
        host.handled_worktrees_base_serial = serial;
        const path = host.ui_app.model.project_store.worktrees_base.slice();
        if (path.len == 0) return;
        std.Io.Dir.cwd().createDirPath(host.io, path) catch {
            try host.ui_app.dispatch(runtime, 1, .worktrees_base_failed);
        };
    }

    fn stop(context: *anyopaque, runtime: *native_sdk.Runtime) anyerror!void {
        const host: *CanopyHost = @ptrCast(@alignCast(context));
        host.sidebar_controller.flushPending(host.ui_app, update);
        host.menu.deinit();
        if (builtin.os.tag == .macos) host.terminals.detach(runtime);
        host.terminals.deinit();
        try host.ui_app.app().stop(runtime);
        if (runtime.options.relational_store) |binding| {
            if (!flushSidebarWidth(&host.ui_app.model, binding)) std.debug.print("canopy: final sidebar width save failed\n", .{});
        }
        host.flushProjectsOnStop() catch |err| std.debug.print("canopy: final project snapshot failed ({s})\n", .{@errorName(err)});
    }

    fn flushProjectsOnStop(host: *CanopyHost) !void {
        const model = &host.ui_app.model;
        if (model.project_io.path.len == 0) return;
        var buffer: [workspaces.max_store_bytes]u8 = undefined;
        const bytes = model.project_store.serializeAttached(&buffer) orelse return error.ProjectStoreTooLarge;
        var atomic = try std.Io.Dir.cwd().createFileAtomic(host.io, model.project_io.path.slice(), .{ .make_path = true, .replace = true });
        defer atomic.deinit(host.io);
        try atomic.file.writePositionalAll(host.io, bytes, 0);
        try atomic.file.sync(host.io);
        try atomic.replace(host.io);
    }

    fn presentPendingFolderDialog(host: *CanopyHost, runtime: *native_sdk.Runtime) !void {
        const serial = host.ui_app.model.picker_serial;
        if (serial == host.handled_picker_serial) return;
        host.handled_picker_serial = serial;
        var path_buffer: [native_sdk.platform.max_dialog_paths_bytes]u8 = undefined;
        const result = runtime.showOpenDialog(.{
            .title = "Attach Project Folder",
            .allow_directories = true,
            .allow_multiple = false,
        }, &path_buffer) catch {
            try host.ui_app.dispatch(runtime, 1, .folder_dialog_failed);
            return;
        };
        if (result.count == 0) {
            try host.ui_app.dispatch(runtime, 1, .folder_dialog_cancelled);
            return;
        }
        const payload = PathPayload.from(result.paths) orelse {
            try host.ui_app.dispatch(runtime, 1, .folder_dialog_failed);
            return;
        };
        try host.ui_app.dispatch(runtime, 1, .{ .folder_selected = payload });
    }
};

pub fn main(init: std.process.Init) !void {
    var ghostty_config = ghostty_config_mod.Snapshot.init(init.gpa);
    defer ghostty_config.deinit();
    try ghostty_config.loadEnvironment(init.io, init.environ_map);
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--inspect-ghostty-config")) {
            var buffer: [4096]u8 = undefined;
            var stdout = std.Io.File.stdout().writer(init.io, &buffer);
            try ghostty_config.writeSummary(init.gpa, &stdout.interface);
            try stdout.interface.flush();
            return;
        }
    }
    std.debug.print("canopy: Ghostty config loaded ({d} sources, {d} diagnostics; full renderer on macOS)\n", .{ ghostty_config.sources.items.len, ghostty_config.diagnostics.items.len });
    const tab_store = try TabStore.create(std.heap.page_allocator);
    defer tab_store.destroy();
    const project_store = try workspaces.Store.create(std.heap.page_allocator);
    defer project_store.destroy();
    const profile_store = try profiles_mod.Store.create(std.heap.page_allocator);
    defer profile_store.destroy();
    const env = native_sdk.debug.envFromMap(init.environ_map);
    const user_shell = init.environ_map.get("SHELL") orelse fallback_user_shell;
    const platform = native_sdk.app_dirs.currentPlatform();
    var worktree_base_buffer: [workspaces.max_path_bytes]u8 = undefined;
    const home = env.home orelse return error.MissingHome;
    const default_worktrees_base = try std.fmt.bufPrint(&worktree_base_buffer, "{s}/canopy/worktrees", .{home});
    if (!project_store.setWorktreesBase(default_worktrees_base)) return error.InvalidWorktreesBase;
    std.Io.Dir.cwd().createDirPath(init.io, default_worktrees_base) catch {};
    var data_dir_buffer: [workspaces.max_path_bytes]u8 = undefined;
    var store_path_buffer: [workspaces.max_path_bytes]u8 = undefined;
    var preferences_db_path_buffer: [workspaces.max_path_bytes]u8 = undefined;
    var store_path: []const u8 = "";
    var preferences_db_path: []const u8 = "";
    if (native_sdk.app_dirs.resolveOne(.{ .name = "tech.itsol.canopy.native-poc" }, platform, env, .data, &data_dir_buffer)) |data_dir| {
        std.Io.Dir.cwd().createDirPath(init.io, data_dir) catch {};
        store_path = native_sdk.app_dirs.join(platform, &store_path_buffer, &.{ data_dir, "projects.store" }) catch "";
        preferences_db_path = native_sdk.app_dirs.join(platform, &preferences_db_path_buffer, &.{ data_dir, "app.db" }) catch "";
    } else |_| {}
    const host = try CanopyHost.create(
        std.heap.page_allocator,
        init.io,
        tab_store,
        project_store,
        profile_store,
        store_path,
        preferences_db_path,
        default_worktrees_base,
        user_shell,
    );
    defer host.destroy(std.heap.page_allocator);
    host.ghostty_config = &ghostty_config;

    try runner.runWithOptions(host.app(), .{
        .app_name = "canopy-native-sdk-poc",
        .window_title = "Canopy",
        .bundle_id = "tech.itsol.canopy.native-poc",
        .icon_path = "assets/icon.png",
        .default_frame = geometry.RectF.init(0, 0, window_width, window_height),
        .js_window_api = false,
        .relational_migrations = &preferences_migrations,
        .security = .{
            .permissions = &app_permissions,
            .navigation = .{ .allowed_origins = &.{ "zero://inline", "zero://app" } },
        },
    }, init);
}

test {
    _ = @import("ghostty_host.zig");
    _ = @import("canvas_host.zig");
    _ = @import("sidebar_controller_tests.zig");
    _ = @import("geometry_updates.zig");
    _ = @import("ghostty_config_tests.zig");
    _ = @import("db_page.zig");
    _ = @import("tests.zig");
    _ = @import("profiles.zig");
    _ = @import("terminal_tabs.zig");
    _ = @import("theme.zig");
    _ = @import("tool_launch.zig");
}
