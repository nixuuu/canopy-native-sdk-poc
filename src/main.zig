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
const profile_editor = @import("profile_editor.zig");
const profiles_mod = @import("profiles.zig");
const terminal_tabs = @import("terminal_tabs.zig");
const theme = @import("theme.zig");
const tool_launch = @import("tool_launch.zig");
const workspaces = @import("workspaces.zig");
const git_workflow = @import("git_workflow.zig");
const git_cli = @import("git_cli.zig");

pub const panic = std.debug.FullPanic(native_sdk.debug.capturePanic);

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;

const canvas_host = @import("canvas_host.zig");
const canvas_label = canvas_host.label;
extern fn canopy_use_compact_titlebar() void;
const window_width: f32 = 1180;
pub const sidebar_divider_width: f32 = 3;
const window_height: f32 = 760;
const max_rendered_tab_buttons: usize = 12;
const fallback_user_shell = "/bin/zsh";
const terminal_bootstrap = "cd -- \"$1\" && exec \"$2\" -l";

pub const TerminalPhase = terminal_tabs.Phase;
pub const TerminalTool = terminal_tabs.Tool;
pub const TerminalTab = terminal_tabs.Tab;
pub const TerminalTabRow = terminal_tabs.Row;
pub const TabStore = terminal_tabs.Store;
pub const PreferencesSection = enum { general, appearance, worktrees, claude, codex };

pub const PathPayload = struct {
    bytes: [workspaces.max_path_bytes]u8 = @splat(0),
    len: usize = 0,

    pub fn from(path: []const u8) ?PathPayload {
        if (path.len == 0 or path.len > workspaces.max_path_bytes) return null;
        var payload: PathPayload = .{};
        @memcpy(payload.bytes[0..path.len], path);
        payload.len = path.len;
        return payload;
    }

    pub fn slice(payload: *const PathPayload) []const u8 {
        return payload.bytes[0..payload.len];
    }
};

const GitOperation = git_workflow.Operation;

pub const Model = struct {
    use_ghostty: bool = false,
    project_store: *workspaces.Store = undefined,
    profile_store: *profiles_mod.Store = undefined,
    active_workspace_id: u64 = 0,
    active_tab_by_workspace: std.AutoHashMapUnmanaged(u64, u64) = .empty,
    tab_store: *TabStore = undefined,
    next_tab_id: u64 = 1,
    next_pty_key: u64 = 1,
    sidebar_width: f32 = 210,
    sidebar_persistence: @import("sidebar_persistence.zig").State = .{},
    canvas_width: f32 = window_width,
    sidebar: @import("sidebar_state.zig").State = .{},
    window_chrome: native_sdk.WindowChrome = .{},
    appearance: native_sdk.Appearance = .{},
    status_text: []const u8 = "Ready",
    picker_serial: u64 = 0,
    git: git_workflow.Lane = .{},
    create_dialog_open: bool = false,
    create_project_id: u64 = 0,
    create_branch: canvas.TextBuffer(workspaces.max_branch_bytes) = .{},
    remove_dialog_open: bool = false,
    remove_workspace_id: u64 = 0,
    remove_safety: git_workflow.RemovalSafety = .{},
    remove_rechecking: bool = false,
    approved_remove_safety: git_workflow.RemovalSafety = .{},
    detach_dialog_open: bool = false,
    detach_project_id: u64 = 0,
    pending_remove_workspace_id: u64 = 0,
    pending_remove_force: bool = false,
    pending_remove_recheck: bool = false,
    pending_detach_project_id: u64 = 0,
    select_after_refresh: workspaces.PathText = .{},
    create_failed: bool = false,
    store_path: workspaces.PathText = .{},
    restore_ready: bool = true,
    restore_scan_active: bool = false,
    restore_scan_index: usize = 0,
    next_store_key: u64 = 9_100,
    persist_write_active: bool = false,
    persist_dirty: bool = false,
    preferences_saved: preferences_mod.Values = .{},
    preferences_draft: preferences_mod.Values = .{},
    preferences_open: bool = false,
    preferences_dirty: bool = false,
    preferences_section: PreferencesSection = .general,
    preferences_loaded: bool = false,
    preferences_load_valid: bool = true,
    preferences_saving: bool = false,
    preferences_base_dir: canvas.TextBuffer(workspaces.max_path_bytes) = .{},
    preferences_search: canvas.TextBuffer(128) = .{},
    preferences_db_path: workspaces.PathText = .{},
    default_worktrees_base: workspaces.PathText = .{},
    worktrees_base_serial: u64 = 0,
    profile_edit: profile_editor.State = .{},
    claude_expanded: bool = false,
    codex_expanded: bool = false,
    claude_available: bool = false,
    codex_available: bool = false,
    tool_checks_remaining: u8 = 2,
    user_shell: workspaces.PathText = .{},
    claude_executable: workspaces.PathText = .{},
    codex_executable: workspaces.PathText = .{},

    pub const view_unbound = .{
        "sidebar_persistence",
        "window_chrome",
        "sidebar_width",
        "canvas_width",
        "sidebar",
        "terminalActionsBlocked",
        "canCloseActiveTab",
        "active_tab_by_workspace",
        "active_workspace_id",
        "project_store",
        "profile_store",
        "tab_store",
        "next_tab_id",
        "next_pty_key",
        "appearance",
        "picker_serial",
        "git",
        "create_project_id",
        "create_branch",
        "remove_workspace_id",
        "remove_safety",
        "remove_rechecking",
        "approved_remove_safety",
        "detach_project_id",
        "pending_remove_workspace_id",
        "pending_remove_force",
        "pending_remove_recheck",
        "pending_detach_project_id",
        "select_after_refresh",
        "create_failed",
        "store_path",
        "restore_ready",
        "restore_scan_active",
        "restore_scan_index",
        "next_store_key",
        "persist_write_active",
        "persist_dirty",
        "preferences_saved",
        "preferences_draft",
        "preferences_dirty",
        "preferences_section",
        "preferences_loaded",
        "preferences_load_valid",
        "preferences_saving",
        "preferences_base_dir",
        "preferences_search",
        "preferences_db_path",
        "default_worktrees_base",
        "worktrees_base_serial",
        "profile_edit",
        "claude_expanded",
        "codex_expanded",
        "claude_available",
        "codex_available",
        "tool_checks_remaining",
        "user_shell",
        "userShell",
        "claude_executable",
        "codex_executable",
        "busy",
        "activeWorkspacePath",
        "activeWorkspaceBranch",
    };

    pub fn setUserShell(model: *Model, shell: []const u8) void {
        const trimmed = std.mem.trim(u8, shell, " \t\r\n");
        model.user_shell.len = 0;
        if (trimmed.len == 0 or !std.fs.path.isAbsolute(trimmed) or std.mem.indexOfScalar(u8, trimmed, 0) != null) return;
        _ = model.user_shell.set(trimmed);
    }

    pub fn userShell(model: *const Model) []const u8 {
        return if (model.user_shell.len > 0) model.user_shell.slice() else fallback_user_shell;
    }

    pub fn setToolExecutable(model: *Model, tool: TerminalTool, executable: []const u8) bool {
        const target = switch (tool) {
            .shell => return false,
            .claude => &model.claude_executable,
            .codex => &model.codex_executable,
        };
        target.len = 0;
        if (executable.len == 0 or !std.fs.path.isAbsolute(executable) or std.mem.indexOfScalar(u8, executable, 0) != null) return false;
        return target.set(executable);
    }

    pub fn toolExecutable(model: *const Model, tool: TerminalTool) []const u8 {
        return switch (tool) {
            .shell => model.userShell(),
            .claude => model.claude_executable.slice(),
            .codex => model.codex_executable.slice(),
        };
    }

    // Align authored controls with the OS-reported traffic-light centerline.
    pub fn titlebarHeight(model: *const Model) f32 {
        // AppKit's reserved toolbar band may be taller than its visible
        // controls. Center the compact bar on the actual button cluster.
        return if (model.window_chrome.buttons.height > 0)
            @max(40, 2 * (model.titlebarControlsTop() + 14))
        else
            @max(40, model.window_chrome.insets.top);
    }

    pub fn titlebarControlsTop(model: *const Model) f32 {
        const buttons = model.window_chrome.buttons;
        return if (buttons.height > 0) @max(0, buttons.y + buttons.height / 2 - 14) else @max(6, model.window_chrome.insets.top / 2 - 14);
    }

    pub fn titlebarLeading(model: *const Model) f32 {
        return @max(6, model.window_chrome.insets.left);
    }

    pub fn titlebarTrailing(model: *const Model) f32 {
        return @max(6, model.window_chrome.insets.right);
    }

    pub fn titlebarSideWidth(model: *const Model) f32 {
        // Equal side columns keep the title at the WINDOW center, regardless
        // of traffic-light placement or the current set of toolbar actions.
        return @max(220, @max(model.titlebarLeading() + 32, model.titlebarTrailing() + 214));
    }

    pub fn sidebarFraction(model: *const Model) f32 {
        return @max(0.000001, model.sidebar_width * model.sidebar.dock.value / @max(1, model.canvas_width - sidebar_divider_width));
    }

    pub fn sidebarDividerWidth(_: *const Model) f32 {
        return sidebar_divider_width;
    }

    pub fn sidebarDockVisible(model: *const Model) bool {
        return model.sidebar.dock.value > 0;
    }

    pub fn sidebarDockMinimum(model: *const Model) f32 {
        return if (!model.sidebar.compact and !model.sidebar.collapsed and !model.sidebar.animating()) 210 else 0;
    }

    pub fn sidebarOverlayVisible(model: *const Model) bool {
        return model.sidebar.overlay.value > 0 or model.sidebar.overlay_open;
    }

    pub fn sidebarOverlayWidth(model: *const Model) f32 {
        return model.sidebarOverlayFullWidth() * model.sidebar.overlay.value;
    }

    pub fn sidebarOverlayFullWidth(model: *const Model) f32 {
        return @min(@max(280, model.sidebar_width), model.canvas_width - 80);
    }

    pub fn sidebarOverlayFraction(model: *const Model) f32 {
        return @max(0.000001, model.sidebarOverlayWidth() / @max(1, model.canvas_width - 1));
    }

    pub fn sidebarToggleLabel(model: *const Model) []const u8 {
        return if (if (model.sidebar.compact) model.sidebar.overlay_open else !model.sidebar.collapsed) "Hide sidebar" else "Show sidebar";
    }

    pub fn sidebarRows(model: *const Model, arena: std.mem.Allocator) []const workspaces.SidebarRow {
        return model.project_store.sidebarRows(arena, model.active_workspace_id);
    }

    pub fn tabs(model: *const Model, arena: std.mem.Allocator) []const TerminalTabRow {
        return model.tab_store.rows(arena, model.active_workspace_id, model.activeTabId(model.active_workspace_id), max_rendered_tab_buttons);
    }

    pub fn activeWorkspaceTerminalCount(model: *const Model) usize {
        return model.tab_store.countForWorkspace(model.active_workspace_id);
    }

    pub fn hasTabs(model: *const Model) bool {
        return model.tab_store.hasWorkspace(model.active_workspace_id);
    }

    pub fn activeWorkspaceName(model: *const Model) []const u8 {
        const workspace = model.project_store.findWorktree(model.active_workspace_id) orelse return "No project";
        return workspace.name.slice();
    }

    pub fn activeWorkspacePath(model: *const Model) []const u8 {
        const workspace = model.project_store.findWorktree(model.active_workspace_id) orelse return "";
        return workspace.path.slice();
    }

    pub fn activeWorkspaceBranch(model: *const Model) []const u8 {
        const workspace = model.project_store.findWorktree(model.active_workspace_id) orelse return "";
        return workspace.branch.slice();
    }

    pub fn hasProjects(model: *const Model) bool {
        return model.project_store.hasProjects();
    }

    pub fn projectCount(model: *const Model) usize {
        return model.project_store.attachedCount();
    }

    pub fn gitBusy(model: *const Model) bool {
        return model.busy();
    }

    pub fn attachDisabled(model: *const Model) bool {
        return !model.restore_ready or model.busy();
    }

    pub fn busy(model: *const Model) bool {
        return model.git.busy();
    }

    pub fn createBranchText(model: *const Model) []const u8 {
        return model.create_branch.text();
    }

    pub fn createDisabled(model: *const Model) bool {
        return model.create_branch.text().len == 0 or model.busy();
    }

    pub fn createProjectName(model: *const Model) []const u8 {
        const project = model.project_store.findProject(model.create_project_id) orelse return "repository";
        return project.name.slice();
    }

    pub fn removeWorktreeName(model: *const Model) []const u8 {
        const worktree = model.project_store.findWorktree(model.remove_workspace_id) orelse return "worktree";
        return worktree.name.slice();
    }

    pub fn removeWorktreePath(model: *const Model) []const u8 {
        const worktree = model.project_store.findWorktree(model.remove_workspace_id) orelse return "";
        return worktree.path.slice();
    }

    pub fn removeHasWarnings(model: *const Model) bool {
        return model.remove_safety.hasWarnings();
    }

    pub fn removeDirty(model: *const Model) bool {
        return model.remove_safety.dirty;
    }

    pub fn removeHasSubmodules(model: *const Model) bool {
        return model.remove_safety.has_submodules;
    }

    pub fn removeUnmergedCount(model: *const Model) usize {
        return model.remove_safety.unmerged_count;
    }

    pub fn detachProjectName(model: *const Model) []const u8 {
        const project = model.project_store.findProject(model.detach_project_id) orelse return "project";
        return project.name.slice();
    }

    pub fn preferencesGeneralSelected(model: *const Model) bool {
        return model.preferences_section == .general;
    }

    pub fn preferencesAppearanceSelected(model: *const Model) bool {
        return model.preferences_section == .appearance;
    }

    pub fn preferencesWorktreesSelected(model: *const Model) bool {
        return model.preferences_section == .worktrees;
    }

    pub fn preferencesClaudeSelected(model: *const Model) bool {
        return model.preferences_section == .claude;
    }

    pub fn preferencesCodexSelected(model: *const Model) bool {
        return model.preferences_section == .codex;
    }

    pub fn preferencesProfileSelected(model: *const Model) bool {
        return model.preferences_section == .claude or model.preferences_section == .codex;
    }

    fn preferencesBasicSelected(model: *const Model) bool {
        return !model.preferencesProfileSelected();
    }

    pub fn preferencesShowSave(model: *const Model) bool {
        return model.preferencesBasicSelected() and model.preferences_dirty;
    }

    pub fn preferencesSectionTitle(model: *const Model) []const u8 {
        return switch (model.preferences_section) {
            .general => "General",
            .appearance => "Appearance",
            .worktrees => "Worktrees",
            .claude => "Claude",
            .codex => "Codex",
        };
    }

    pub fn preferencesSectionDescription(model: *const Model) []const u8 {
        return switch (model.preferences_section) {
            .general => "Startup behavior and workspace restoration",
            .appearance => "Application color mode and accessibility",
            .worktrees => "Defaults used when creating Git worktrees",
            .claude => "Claude Code integration",
            .codex => "Codex integration",
        };
    }

    pub fn preferencesSearchText(model: *const Model) []const u8 {
        return model.preferences_search.text();
    }

    pub fn showPreferencesGeneralNav(model: *const Model) bool {
        return model.preferencesSearchMatches("General startup reopen workspace status");
    }

    pub fn showPreferencesAppearanceNav(model: *const Model) bool {
        return model.preferencesSearchMatches("Appearance theme color mode accessibility");
    }

    pub fn showPreferencesWorktreesNav(model: *const Model) bool {
        return model.preferencesSearchMatches("Worktrees Git directory base path");
    }

    pub fn showPreferencesClaudeNav(model: *const Model) bool {
        return model.preferencesSearchMatches("Claude Anthropic model permission effort provider");
    }

    pub fn showPreferencesCodexNav(model: *const Model) bool {
        return model.preferencesSearchMatches("Codex OpenAI model approval sandbox profile");
    }

    pub fn preferencesReopenLast(model: *const Model) bool {
        return model.preferences_draft.reopen_last_workspace;
    }

    pub fn preferencesAppearanceSystem(model: *const Model) bool {
        return model.preferences_draft.appearance_mode == .system;
    }

    pub fn preferencesAppearanceLight(model: *const Model) bool {
        return model.preferences_draft.appearance_mode == .light;
    }

    pub fn preferencesAppearanceDark(model: *const Model) bool {
        return model.preferences_draft.appearance_mode == .dark;
    }

    pub fn preferencesBaseDirText(model: *const Model) []const u8 {
        return model.preferences_base_dir.text();
    }

    pub fn preferencesBaseDirInvalid(model: *const Model) bool {
        const value = std.mem.trim(u8, model.preferences_base_dir.text(), " ");
        return value.len > 0 and !std.fs.path.isAbsolute(value);
    }

    pub fn preferencesSaveDisabled(model: *const Model) bool {
        return model.preferences_saving or !model.preferences_dirty or model.preferencesBaseDirInvalid();
    }

    pub fn preferencesDisabled(model: *const Model) bool {
        return !model.preferences_loaded or model.preferences_saving or model.profile_edit.saving();
    }

    pub fn preferencesSaveLabel(model: *const Model) []const u8 {
        return if (model.preferences_saving) "Saving..." else "Save";
    }

    pub fn preferencesDefaultBaseDir(model: *const Model) []const u8 {
        return model.default_worktrees_base.slice();
    }

    pub fn toolsReady(model: *const Model) bool {
        return model.profile_edit.loaded and model.tool_checks_remaining == 0;
    }

    pub fn toolsLoading(model: *const Model) bool {
        return !model.toolsReady();
    }

    pub fn noAgentToolsAvailable(model: *const Model) bool {
        return !model.claude_available and !model.codex_available;
    }

    pub fn claudeHasMultipleProfiles(model: *const Model) bool {
        return model.profile_store.count(.claude) > 1;
    }

    pub fn codexHasMultipleProfiles(model: *const Model) bool {
        return model.profile_store.count(.codex) > 1;
    }

    pub fn claudeProfileCount(model: *const Model) usize {
        return model.profile_store.count(.claude);
    }

    pub fn codexProfileCount(model: *const Model) usize {
        return model.profile_store.count(.codex);
    }

    pub fn claudeProfiles(model: *const Model, arena: std.mem.Allocator) []const profiles_mod.ProfileRow {
        return model.profile_store.rows(arena, .claude, 0);
    }

    pub fn codexProfiles(model: *const Model, arena: std.mem.Allocator) []const profiles_mod.ProfileRow {
        return model.profile_store.rows(arena, .codex, 0);
    }

    pub fn profileRows(model: *const Model, arena: std.mem.Allocator) []const profiles_mod.ProfileRow {
        const agent_type: profiles_mod.AgentType = if (model.preferences_section == .codex) .codex else .claude;
        return model.profile_store.rows(arena, agent_type, model.profile_edit.selected_id);
    }

    pub fn claudeRunningCount(model: *const Model) usize {
        return model.runningCount(.claude);
    }

    pub fn codexRunningCount(model: *const Model) usize {
        return model.runningCount(.codex);
    }

    pub fn profileNameText(model: *const Model) []const u8 {
        return model.profile_edit.draft.name.text();
    }

    pub fn profileModelText(model: *const Model) []const u8 {
        return model.profile_edit.draft.model.text();
    }

    pub fn profileBaseUrlText(model: *const Model) []const u8 {
        return model.profile_edit.draft.base_url.text();
    }

    pub fn profileAppendPromptText(model: *const Model) []const u8 {
        return model.profile_edit.draft.append_system_prompt.text();
    }

    pub fn profileCustomEnvText(model: *const Model) []const u8 {
        return model.profile_edit.draft.custom_env.text();
    }

    pub fn profileSettingsJsonText(model: *const Model) []const u8 {
        return model.profile_edit.draft.settings_json.text();
    }

    pub fn profileCodexConfigProfileText(model: *const Model) []const u8 {
        return model.profile_edit.draft.profile.text();
    }

    pub fn profilePermissionValue(model: *const Model) []const u8 {
        return model.profile_edit.draft.permission_mode.text();
    }

    pub fn profileEffortValue(model: *const Model) []const u8 {
        return model.profile_edit.draft.effort_level.text();
    }

    pub fn profileProviderValue(model: *const Model) []const u8 {
        return model.profile_edit.draft.provider.text();
    }

    pub fn profileApprovalValue(model: *const Model) []const u8 {
        return model.profile_edit.draft.approval_mode.text();
    }

    pub fn profileSandboxValue(model: *const Model) []const u8 {
        return model.profile_edit.draft.sandbox.text();
    }

    pub fn profileFullAuto(model: *const Model) bool {
        return model.profile_edit.draft.full_auto;
    }

    pub fn profileDangerousBypass(model: *const Model) bool {
        return model.profile_edit.draft.dangerously_bypass_approvals_and_sandbox;
    }

    pub fn profileSaveDisabled(model: *const Model) bool {
        const name = std.mem.trim(u8, model.profile_edit.draft.name.text(), " ");
        return model.profile_edit.saving() or !model.profile_edit.dirty or name.len == 0;
    }

    pub fn profileSaveLabel(model: *const Model) []const u8 {
        return if (model.profile_edit.saving()) "Saving..." else "Save profile";
    }

    pub fn profileDeleteName(model: *const Model) []const u8 {
        const profile = model.profile_store.find(model.profile_edit.pending_delete orelse return "profile") orelse return "profile";
        return profile.name.slice();
    }

    pub fn profileSwitchDialogOpen(model: *const Model) bool {
        return model.profile_edit.pending_switch != null;
    }
    pub fn profileDeleteDialogOpen(model: *const Model) bool {
        return model.profile_edit.pending_delete != null;
    }

    fn runningCount(model: *const Model, tool: TerminalTool) usize {
        var count: usize = 0;
        for (model.tab_store.items.items) |tab| {
            if (tab.workspace_id == model.active_workspace_id and tab.tool == tool and tab.phase != .closing and tab.phase != .exited and tab.phase != .failed) count += 1;
        }
        return count;
    }

    fn preferencesSearchMatches(model: *const Model, haystack: []const u8) bool {
        const needle = std.mem.trim(u8, model.preferences_search.text(), " ");
        if (needle.len == 0) return true;
        if (needle.len > haystack.len) return false;
        for (0..haystack.len - needle.len + 1) |start| {
            if (std.ascii.eqlIgnoreCase(haystack[start .. start + needle.len], needle)) return true;
        }
        return false;
    }

    fn activeTabId(model: *const Model, workspace_id: u64) u64 {
        return model.active_tab_by_workspace.get(workspace_id) orelse 0;
    }

    pub fn terminalActionsBlocked(model: *const Model) bool {
        return model.preferences_open or model.create_dialog_open or model.remove_dialog_open or model.detach_dialog_open or model.profileSwitchDialogOpen() or model.profileDeleteDialogOpen();
    }

    pub fn canCloseActiveTab(model: *const Model) bool {
        return !model.terminalActionsBlocked() and model.activeTabId(model.active_workspace_id) != 0;
    }

    fn setActiveTab(model: *Model, workspace_id: u64, tab_id: u64) void {
        model.active_tab_by_workspace.put(model.tab_store.allocator, workspace_id, tab_id) catch {};
    }

    fn setStorePath(model: *Model, path: []const u8) void {
        if (model.store_path.set(path) and path.len > 0) model.restore_ready = false;
    }
};

pub const Msg = union(enum) {
    open_folder,
    folder_selected: PathPayload,
    folder_dialog_cancelled,
    folder_dialog_failed,
    select_workspace: u64,
    open_terminal: u64,
    open_active_terminal,
    activate_tab: u64,
    previous_tab,
    next_tab,
    close_tab: u64,
    close_active_tab,
    begin_create_worktree: u64,
    edit_create_branch: canvas.TextInputEvent,
    cancel_create_worktree,
    confirm_create_worktree,
    request_remove_worktree: u64,
    cancel_remove_worktree,
    confirm_remove_worktree,
    request_detach_project: u64,
    cancel_detach_project,
    confirm_detach_project,
    open_preferences,
    open_claude_preferences,
    close_preferences,
    show_preferences_general,
    show_preferences_appearance,
    show_preferences_worktrees,
    show_preferences_claude,
    show_preferences_codex,
    edit_preferences_search: canvas.TextInputEvent,
    toggle_preferences_reopen,
    use_system_appearance,
    use_light_appearance,
    use_dark_appearance,
    edit_preferences_base_dir: canvas.TextInputEvent,
    save_preferences,
    preferences_load_done: native_sdk.EffectDbResult,
    preferences_db_done: native_sdk.EffectDbResult,
    worktrees_base_failed,
    profiles_load_done: native_sdk.EffectDbResult,
    profile_db_done: native_sdk.EffectDbResult,
    tool_check_done: native_sdk.EffectExit,
    toggle_claude_profiles,
    toggle_codex_profiles,
    launch_claude,
    launch_codex,
    launch_profile: u64,
    new_profile,
    select_profile: u64,
    confirm_profile_switch,
    cancel_profile_switch,
    request_delete_profile: u64,
    confirm_delete_profile,
    cancel_delete_profile,
    save_profile,
    edit_profile_name: canvas.TextInputEvent,
    edit_profile_model: canvas.TextInputEvent,
    edit_profile_permission_mode: canvas.TextInputEvent,
    edit_profile_effort_level: canvas.TextInputEvent,
    edit_profile_provider: canvas.TextInputEvent,
    edit_profile_approval_mode: canvas.TextInputEvent,
    edit_profile_sandbox: canvas.TextInputEvent,
    edit_profile_base_url: canvas.TextInputEvent,
    edit_profile_append_prompt: canvas.TextInputEvent,
    edit_profile_custom_env: canvas.TextInputEvent,
    edit_profile_settings_json: canvas.TextInputEvent,
    edit_profile_codex_profile: canvas.TextInputEvent,
    toggle_profile_full_auto,
    toggle_profile_dangerous_bypass,
    git_done: native_sdk.EffectExit,
    store_done: native_sdk.EffectFileResult,
    terminal_event: native_sdk.EffectPtyEvent,
    sidebar_resized: f32,
    save_sidebar_width,
    sidebar_width_saved: native_sdk.EffectDbResult,
    toggle_sidebar,
    dismiss_sidebar,
    set_appearance: native_sdk.Appearance,
    chrome_changed: native_sdk.WindowChrome,

    pub const view_unbound = .{
        "save_sidebar_width",
        "sidebar_width_saved",
        "folder_selected",
        "folder_dialog_cancelled",
        "folder_dialog_failed",
        "preferences_load_done",
        "preferences_db_done",
        "worktrees_base_failed",
        "profiles_load_done",
        "profile_db_done",
        "tool_check_done",
        "git_done",
        "store_done",
        "terminal_event",
        "close_active_tab",
        "set_appearance",
        "chrome_changed",
    };
};

const CanopyApp = native_sdk.UiApp(Model, Msg);
pub const Effects = native_sdk.Effects(Msg);

/// One zero-backlog lane for every Git workflow. A running command owns the
/// lane until its exact EffectExit arrives; callers are rejected, never queued.
/// Native SDK spawn has no execution timeout, so slow repositories are allowed
/// to finish naturally without a polling loop creating more host work.
fn spawnGit(model: *Model, fx: *Effects, operation: GitOperation) void {
    if (model.git.busy()) {
        model.status_text = "Another Git operation is still running";
        return;
    }
    const request = operation.request(model.project_store) orelse return;
    const key = model.git.begin(operation) orelse return;
    git_cli.execute(fx, key, request) catch {
        _ = model.git.finish(key);
        model.status_text = "Branch name is too long";
        return;
    };
    model.status_text = operation.progress();
}

fn detectRepository(model: *Model, fx: *Effects, project_id: u64) void {
    spawnGit(model, fx, .{ .kind = .detect_repo, .project_id = project_id });
}

fn refreshWorktrees(model: *Model, fx: *Effects, project_id: u64) void {
    const project = model.project_store.findProject(project_id) orelse return;
    if (!project.is_git) return;
    spawnGit(model, fx, .{ .kind = .list_worktrees, .project_id = project_id });
}

fn validateNewBranch(model: *Model, fx: *Effects, project_id: u64, branch: []const u8, target_path: []const u8) void {
    var operation = GitOperation{ .kind = .validate_branch, .project_id = project_id };
    if (!operation.branch.set(branch) or !operation.target_path.set(target_path)) {
        model.status_text = "Branch name or worktree path is too long";
        return;
    }
    spawnGit(model, fx, operation);
}

const store_read_key: u64 = 9_001;

fn persistProjects(model: *Model, fx: *Effects) void {
    if (model.store_path.len == 0) return;
    if (model.persist_write_active) {
        model.persist_dirty = true;
        return;
    }
    var buffer: [workspaces.max_store_bytes]u8 = undefined;
    const bytes = model.project_store.serializeAttached(&buffer) orelse {
        model.status_text = "Too many attached projects to persist";
        return;
    };
    const key = model.next_store_key;
    model.next_store_key +%= 1;
    if (model.next_store_key < 9_100) model.next_store_key = 9_100;
    model.persist_write_active = true;
    fx.writeFile(.{
        .key = key,
        .path = model.store_path.slice(),
        .bytes = bytes,
        .on_result = Effects.fileMsg(.store_done),
    });
}

fn detectNextRestoredProject(model: *Model, fx: *Effects) void {
    if (!model.restore_scan_active or model.git.busy()) return;
    while (model.restore_scan_index < model.project_store.projects.items.len) {
        const index = model.restore_scan_index;
        model.restore_scan_index += 1;
        const project = &model.project_store.projects.items[index];
        if (!project.attached) continue;
        spawnGit(model, fx, .{ .kind = .restore_check, .project_id = project.id });
        return;
    }
    model.restore_scan_active = false;
    model.status_text = if (model.project_store.hasProjects()) "Projects restored" else "Ready";
}

fn preflightRemoveStatus(model: *Model, fx: *Effects, workspace_id: u64) void {
    const worktree = model.project_store.findWorktree(workspace_id) orelse return;
    if (worktree.is_main or !worktree.active) return;
    spawnGit(model, fx, .{ .kind = .remove_status, .workspace_id = workspace_id });
}

fn preflightRemoveSubmodules(model: *Model, fx: *Effects, workspace_id: u64) void {
    spawnGit(model, fx, .{ .kind = .remove_submodules, .workspace_id = workspace_id });
}

fn finishRemovePreflight(model: *Model, fx: *Effects) void {
    if (!model.remove_rechecking) {
        model.remove_dialog_open = true;
        model.status_text = "Review worktree removal";
        return;
    }
    model.remove_rechecking = false;
    if (!model.remove_safety.matches(model.approved_remove_safety)) {
        model.remove_dialog_open = true;
        model.status_text = "Worktree safety state changed; review again";
        return;
    }
    const workspace_id = model.pending_remove_workspace_id;
    model.pending_remove_workspace_id = 0;
    model.pending_remove_force = model.removeHasWarnings();
    executeWorktreeRemoval(model, fx, workspace_id, model.pending_remove_force);
    model.pending_remove_force = false;
}

fn preflightRemoveUnmerged(model: *Model, fx: *Effects, workspace_id: u64) void {
    const worktree = model.project_store.findWorktree(workspace_id) orelse return;
    const project = model.project_store.projectForWorkspace(workspace_id) orelse return;
    if (worktree.branch.eql("(unknown)")) {
        model.remove_safety.unmerged_count = 1;
        finishRemovePreflight(model, fx);
        return;
    }
    spawnGit(model, fx, .{ .kind = .remove_unmerged, .project_id = project.id, .workspace_id = workspace_id });
}

fn executeWorktreeRemoval(model: *Model, fx: *Effects, workspace_id: u64, force: bool) void {
    const worktree = model.project_store.findWorktree(workspace_id) orelse return;
    const project = model.project_store.projectForWorkspace(workspace_id) orelse return;
    var operation = GitOperation{ .kind = .remove_worktree, .project_id = project.id, .workspace_id = workspace_id, .force = force };
    _ = operation.target_path.set(worktree.path.slice());
    spawnGit(model, fx, operation);
}

// Borrowed launch data: startTerminal copies metadata and the selected backend
// takes ownership of argv/env before the caller releases its temporary arena.
const TerminalStartSpec = struct {
    workspace: *const workspaces.Worktree,
    title: []const u8,
    tool: TerminalTool = .shell,
    profile_id: []const u8 = "",
    argv: []const []const u8,
    env: []const native_sdk.PtyEnvEntry,
};

fn startTerminal(model: *Model, fx: *Effects, spec: TerminalStartSpec) void {
    const tab_id = model.next_tab_id;
    const pty_key = model.tab_store.allocatePtyKey(&model.next_pty_key);
    model.next_tab_id +%= 1;
    var tab = TerminalTab{
        .id = tab_id,
        .workspace_id = spec.workspace.id,
        .pty = pty_key,
        .tool = spec.tool,
    };
    _ = tab.title.set(spec.title);
    _ = tab.path.set(spec.workspace.path.slice());
    _ = tab.branch.set(spec.workspace.branch.slice());
    _ = tab.profile_id.set(spec.profile_id);
    model.tab_store.items.append(model.tab_store.allocator, tab) catch {
        model.tab_store.releasePtyKey(pty_key);
        model.status_text = if (spec.tool == .shell) "The host could not allocate another terminal tab" else "The host could not allocate another tool tab";
        return;
    };
    model.setActiveTab(spec.workspace.id, tab_id);
    model.status_text = switch (spec.tool) {
        .shell => "Starting login shell",
        .claude => "Starting Claude Code",
        .codex => "Starting Codex",
    };

    if (model.use_ghostty) {
        const added = &model.tab_store.items.items[model.tab_store.items.items.len - 1];
        added.pending_launch = @import("terminal_launch.zig").Pending.create(model.tab_store.allocator, spec.workspace.path.slice(), spec.argv, spec.env) catch {
            added.phase = .failed;
            model.status_text = "Could not prepare Ghostty session";
            return;
        };
        return;
    }
    fx.ptySpawn(.{
        .key = pty_key,
        .argv = spec.argv,
        .cols = 100,
        .rows = 30,
        .term = "xterm-256color",
        .env = spec.env,
        .on_event = Effects.ptyMsg(.terminal_event),
    });
}

fn openTerminal(model: *Model, fx: *Effects, workspace_id: u64) void {
    if (!model.project_store.workspaceAvailable(workspace_id)) return;
    const workspace = model.project_store.findWorktree(workspace_id) orelse return;
    if (!workspace.active) return;
    model.active_workspace_id = workspace_id;

    // cwd/shell remain argv data, not interpolated shell source. The neutral
    // wrapper changes cwd, then the login shell owns startup and environment.
    const user_shell = model.userShell();
    startTerminal(model, fx, .{
        .workspace = workspace,
        .title = workspace.name.slice(),
        .argv = &.{ "/bin/sh", "-c", terminal_bootstrap, "canopy-shell", workspace.path.slice(), user_shell },
        .env = &.{
            .{ .name = "SHELL", .value = user_shell },
            .{ .name = "COLORTERM", .value = "truecolor" },
        },
    });
}

fn removeTab(model: *Model, fx: *Effects, index: usize) void {
    const removed = model.tab_store.items.orderedRemove(index);
    if (removed.pending_launch) |pending| pending.destroy();
    if (!model.use_ghostty) fx.ptyForget(removed.pty);
    model.tab_store.releasePtyKey(removed.pty);

    if (model.activeTabId(removed.workspace_id) == removed.id) {
        model.setActiveTab(removed.workspace_id, model.tab_store.replacementForWorkspace(removed.workspace_id));
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
        removeTab(model, fx, index);
        model.status_text = "Terminal closed";
        return;
    }

    model.tab_store.items.items[index].phase = .closing;
    if (!model.use_ghostty) fx.ptyKill(model.tab_store.items.items[index].pty);
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

fn hasTabsForWorkspace(model: *const Model, workspace_id: u64) bool {
    for (model.tab_store.items.items) |tab| {
        if (tab.workspace_id == workspace_id) return true;
    }
    return false;
}

fn hasTabsForProject(model: *Model, project_id: u64) bool {
    for (model.tab_store.items.items) |tab| {
        const project = model.project_store.projectForWorkspace(tab.workspace_id) orelse continue;
        if (project.id == project_id) return true;
    }
    return false;
}

fn closeTabsForWorkspace(model: *Model, fx: *Effects, workspace_id: u64) void {
    for (model.tab_store.items.items) |*tab| {
        if (tab.workspace_id != workspace_id or tab.phase == .closing) continue;
        if (tab.phase == .exited or tab.phase == .failed) continue;
        tab.phase = .closing;
        if (!model.use_ghostty) fx.ptyKill(tab.pty);
    }
    // Already-ended tabs have no terminal event left to await.
    var index = model.tab_store.items.items.len;
    while (index > 0) {
        index -= 1;
        const tab = model.tab_store.items.items[index];
        if (tab.workspace_id == workspace_id and (tab.phase == .exited or tab.phase == .failed)) removeTab(model, fx, index);
    }
}

fn closeTabsForProject(model: *Model, fx: *Effects, project_id: u64) void {
    const project = model.project_store.findProject(project_id) orelse return;
    for (project.worktrees.items) |worktree| closeTabsForWorkspace(model, fx, worktree.id);
}

fn maybeFinishPendingTeardown(model: *Model, fx: *Effects) void {
    if (model.pending_remove_workspace_id != 0 and !hasTabsForWorkspace(model, model.pending_remove_workspace_id)) {
        const workspace_id = model.pending_remove_workspace_id;
        if (model.pending_remove_recheck) {
            model.pending_remove_recheck = false;
            model.remove_rechecking = true;
            model.remove_safety = .{};
            preflightRemoveStatus(model, fx, workspace_id);
        }
    }
    if (model.pending_detach_project_id != 0 and !hasTabsForProject(model, model.pending_detach_project_id)) {
        const project_id = model.pending_detach_project_id;
        model.pending_detach_project_id = 0;
        _ = model.project_store.detach(project_id);
        if (model.project_store.projectForWorkspace(model.active_workspace_id)) |active_project| {
            if (active_project.id == project_id) model.active_workspace_id = model.project_store.firstWorkspaceId();
        } else if (model.active_workspace_id != 0) {
            model.active_workspace_id = model.project_store.firstWorkspaceId();
        }
        persistProjects(model, fx);
        model.status_text = "Project detached";
    }
}

pub const preferences_write_key: u64 = 8_001;
const preferences_upsert_sql = "INSERT OR REPLACE INTO preferences (key, value) VALUES (?1, ?2);";

fn openPreferences(model: *Model) void {
    if (!model.preferences_loaded or model.preferences_saving) return;
    model.preferences_draft = model.preferences_saved;
    model.preferences_base_dir.set(model.preferences_saved.worktrees_base_dir.slice());
    model.preferences_search.clear();
    model.preferences_dirty = false;
    model.preferences_section = .general;
    model.preferences_open = true;
    model.status_text = "Preferences opened";
}

fn closePreferences(model: *Model) void {
    if (model.preferences_saving or model.profile_edit.saving()) return;
    model.preferences_draft = model.preferences_saved;
    model.preferences_base_dir.clear();
    model.preferences_search.clear();
    model.preferences_dirty = false;
    model.preferences_open = false;
    model.profile_edit.close(model.profile_store);
    model.status_text = "Preferences unchanged";
}

fn savePreferences(model: *Model, fx: *Effects) void {
    if (!model.preferences_open or !model.preferences_dirty or model.preferences_saving or model.preferencesBaseDirInvalid()) return;
    const base_dir = std.mem.trim(u8, model.preferences_base_dir.text(), " ");
    model.preferences_draft.worktrees_base_dir.len = 0;
    if (base_dir.len > 0 and !model.preferences_draft.worktrees_base_dir.set(base_dir)) {
        model.status_text = "Worktree base directory is too long";
        return;
    }

    const reopen_value = if (model.preferences_draft.reopen_last_workspace) "true" else "false";
    const appearance_value = @tagName(model.preferences_draft.appearance_mode);
    const statements = [_]native_sdk.EffectDbStatement{
        .{ .sql = preferences_upsert_sql, .params = &.{ .{ .text = preferences_mod.key_reopen_last_workspace }, .{ .text = reopen_value } } },
        .{ .sql = preferences_upsert_sql, .params = &.{ .{ .text = preferences_mod.key_native_appearance }, .{ .text = appearance_value } } },
        .{ .sql = preferences_upsert_sql, .params = &.{ .{ .text = preferences_mod.key_worktrees_base_dir }, .{ .text = model.preferences_draft.worktrees_base_dir.slice() } } },
    };
    model.preferences_saving = true;
    model.status_text = "Saving preferences";
    fx.dbExec(.{
        .key = preferences_write_key,
        .statements = &statements,
        .on_result = Effects.dbMsg(.preferences_db_done),
    });
}

fn commitPreferences(model: *Model) void {
    model.preferences_saved = model.preferences_draft;
    const base_dir = if (model.preferences_saved.worktrees_base_dir.len > 0)
        model.preferences_saved.worktrees_base_dir.slice()
    else
        model.default_worktrees_base.slice();
    _ = model.project_store.setWorktreesBase(base_dir);
    model.worktrees_base_serial +%= 1;
    model.preferences_saving = false;
    model.preferences_dirty = false;
    model.status_text = "Preferences saved";
}

pub const profiles_load_key: u64 = 8_002;
pub const profile_write_key: u64 = 8_003;
const claude_check_key: u64 = 8_100;
const codex_check_key: u64 = 8_101;

fn openProfileSection(model: *Model, agent_type: profiles_mod.AgentType) void {
    if (!model.profile_edit.openAgent(model.profile_store, agent_type)) return;
    model.preferences_section = if (agent_type == .codex) .codex else .claude;
}

fn reloadProfiles(model: *Model, fx: *Effects, select_database_id: []const u8) void {
    model.profile_edit.beginReload(model.profile_store, select_database_id);
    fx.dbQuery(.{ .key = profiles_load_key, .sql = profiles_mod.load_sql, .on_result = Effects.dbMsg(.profiles_load_done) });
}

fn finishProfilesLoad(model: *Model) void {
    const agent: profiles_mod.AgentType = if (model.preferences_section == .codex) .codex else .claude;
    if (!model.profile_edit.finishLoad(model.profile_store, agent)) model.status_text = "Agent profiles could not be loaded";
}

fn createProfileDraft(model: *Model) void {
    if (!model.preferencesProfileSelected()) return;
    const agent: profiles_mod.AgentType = if (model.preferences_section == .codex) .codex else .claude;
    if (model.profile_edit.create(model.profile_store, agent)) |message| model.status_text = message;
}

fn saveProfile(model: *Model, fx: *Effects) void {
    var json_buffer: [profiles_mod.max_long_pref_bytes * 3]u8 = undefined;
    const save = switch (model.profile_edit.prepareSave(model.profile_store, &json_buffer)) {
        .skip => return,
        .invalid => |message| {
            model.status_text = message;
            return;
        },
        .ready => |prepared| prepared,
    };
    const statements = if (save.is_new)
        [_]native_sdk.EffectDbStatement{.{
            .sql = "INSERT INTO agent_profiles (id, agent_type, name, is_default, sort_index, prefs_json, api_key_enc) VALUES (?1, ?2, ?3, 0, ?4, ?5, NULL);",
            .params = &.{ .{ .text = save.id }, .{ .text = @tagName(save.agent) }, .{ .text = save.name }, .{ .integer = save.sort_index }, .{ .text = save.prefs_json } },
        }}
    else
        [_]native_sdk.EffectDbStatement{.{
            .sql = "UPDATE agent_profiles SET name = ?1, prefs_json = ?2, sort_index = ?3, updated_at = datetime('now') WHERE id = ?4;",
            .params = &.{ .{ .text = save.name }, .{ .text = save.prefs_json }, .{ .integer = save.sort_index }, .{ .text = save.id } },
        }};
    model.status_text = "Saving agent profile";
    fx.dbExec(.{ .key = profile_write_key, .statements = &statements, .on_result = Effects.dbMsg(.profile_db_done) });
}

fn deleteProfile(model: *Model, fx: *Effects) void {
    const id = model.profile_edit.prepareDelete(model.profile_store) orelse return;
    model.status_text = "Deleting agent profile";
    fx.dbExec(.{
        .key = profile_write_key,
        .statements = &.{.{ .sql = "DELETE FROM agent_profiles WHERE id = ?1;", .params = &.{.{ .text = id }} }},
        .on_result = Effects.dbMsg(.profile_db_done),
    });
}

fn startToolChecks(model: *Model, fx: *Effects) void {
    model.tool_checks_remaining = 2;
    model.claude_available = false;
    model.codex_available = false;
    model.claude_executable.len = 0;
    model.codex_executable.len = 0;
    const shell = model.userShell();
    // Absolute /usr/bin/which resolves external executables from the PATH
    // produced by the user's login shell, ignoring aliases/functions. The
    // collected path is reused verbatim for PTY launch so discovery and start
    // cannot drift to different global installations.
    fx.spawn(.{ .key = claude_check_key, .argv = &.{ shell, "-lc", "/usr/bin/which claude" }, .output = .collect, .on_exit = Effects.exitMsg(.tool_check_done) });
    fx.spawn(.{ .key = codex_check_key, .argv = &.{ shell, "-lc", "/usr/bin/which codex" }, .output = .collect, .on_exit = Effects.exitMsg(.tool_check_done) });
}

pub const resolvedToolExecutable = tool_launch.resolvedExecutable;

fn toolAvailable(model: *const Model, tool: TerminalTool) bool {
    return switch (tool) {
        .shell => true,
        .claude => model.claude_available and model.claude_executable.len > 0,
        .codex => model.codex_available and model.codex_executable.len > 0,
    };
}

fn toolTitle(model: *const Model, workspace_id: u64, tool: TerminalTool, profile: *const profiles_mod.Profile, out: []u8) ?[]const u8 {
    var base_buffer: [profiles_mod.max_profile_name_bytes + 32]u8 = undefined;
    const base = if (profile.name.eql("Default"))
        profile.agent_type.displayName()
    else
        std.fmt.bufPrint(&base_buffer, "{s} ({s})", .{ profile.agent_type.displayName(), profile.name.slice() }) catch return null;
    var same: usize = 0;
    for (model.tab_store.items.items) |tab| {
        if (tab.workspace_id == workspace_id and tab.tool == tool) {
            const title = tab.title.slice();
            const numbered = title.len > base.len + 2 and std.mem.startsWith(u8, title, base) and std.mem.eql(u8, title[base.len .. base.len + 2], " #");
            if (std.mem.eql(u8, title, base) or numbered) same += 1;
        }
    }
    if (same == 0) return std.fmt.bufPrint(out, "{s}", .{base}) catch null;
    return std.fmt.bufPrint(out, "{s} #{d}", .{ base, same + 1 }) catch null;
}

fn spawnProfileTool(model: *Model, fx: *Effects, profile: *const profiles_mod.Profile) void {
    const workspace = model.project_store.findWorktree(model.active_workspace_id) orelse return;
    if (!workspace.active) return;
    const tool: TerminalTool = switch (profile.agent_type) {
        .claude => .claude,
        .codex => .codex,
    };
    if (!toolAvailable(model, tool)) {
        model.status_text = if (tool == .claude) "Claude Code is not available in the login shell" else "Codex is not available in the login shell";
        return;
    }

    var env_arena = std.heap.ArenaAllocator.init(model.tab_store.allocator);
    defer env_arena.deinit();
    const launch = tool_launch.Spec.build(
        env_arena.allocator(),
        model.userShell(),
        workspace.path.slice(),
        model.toolExecutable(tool),
        profile,
    ) orelse return;

    var title_buffer: [workspaces.max_name_bytes]u8 = undefined;
    const title = toolTitle(model, workspace.id, tool, profile, &title_buffer) orelse profile.agent_type.displayName();
    startTerminal(model, fx, .{
        .workspace = workspace,
        .title = title,
        .tool = tool,
        .profile_id = profile.id.slice(),
        .argv = launch.argv(),
        .env = launch.env(),
    });
}

fn launchDefaultTool(model: *Model, fx: *Effects, agent_type: profiles_mod.AgentType) void {
    if (!model.profile_edit.loaded) return;
    const profile = model.profile_store.default(agent_type) orelse return;
    spawnProfileTool(model, fx, profile);
}

fn launchProfileTool(model: *Model, fx: *Effects, runtime_id: u64) void {
    if (!model.profile_edit.loaded) return;
    const profile = model.profile_store.find(runtime_id) orelse return;
    spawnProfileTool(model, fx, profile);
}

fn handlePreferencesLoadResult(model: *Model, fx: *Effects, result: native_sdk.EffectDbResult) void {
    if (result.key != preferences_load_key) return;
    switch (result.kind) {
        .page => if (result.outcome != .ok or !preferences_mod.decodePage(&model.preferences_saved, result.bytes)) {
            model.preferences_load_valid = false;
        },
        .done => {
            if (result.outcome != .ok) model.preferences_load_valid = false;
            finishPreferencesLoad(model, fx);
        },
        .exec => model.preferences_load_valid = false,
    }
}

fn handlePreferencesWriteResult(model: *Model, result: native_sdk.EffectDbResult) void {
    if (result.key != preferences_write_key or result.kind != .exec) return;
    if (result.outcome == .ok) {
        commitPreferences(model);
    } else {
        model.preferences_saving = false;
        model.status_text = if (result.outcome == .busy) "Preferences database is busy; try again" else "Preferences could not be saved";
    }
}

fn handleProfilesLoadResult(model: *Model, result: native_sdk.EffectDbResult) void {
    if (result.key != profiles_load_key) return;
    switch (result.kind) {
        .page => if (result.outcome != .ok or !model.profile_store.appendEncodedPage(result.bytes)) {
            model.profile_edit.load_valid = false;
        },
        .done => {
            if (result.outcome != .ok) model.profile_edit.load_valid = false;
            finishProfilesLoad(model);
        },
        .exec => model.profile_edit.load_valid = false,
    }
}

fn handleProfileWriteResult(model: *Model, fx: *Effects, result: native_sdk.EffectDbResult) void {
    if (result.key != profile_write_key or result.kind != .exec) return;
    const completed = model.profile_edit.finishWrite(result.outcome == .ok, result.outcome == .busy);
    if (completed.reload) reloadProfiles(model, fx, completed.select_id.slice());
    model.status_text = completed.message;
}

fn handleToolCheckResult(model: *Model, exit: native_sdk.EffectExit) void {
    const resolved = if (exit.reason == .exited and exit.code == 0) resolvedToolExecutable(exit.output) else null;
    if (exit.key == claude_check_key) {
        model.claude_available = if (resolved) |path| model.setToolExecutable(.claude, path) else false;
    } else if (exit.key == codex_check_key) {
        model.codex_available = if (resolved) |path| model.setToolExecutable(.codex, path) else false;
    } else return;
    if (model.tool_checks_remaining > 0) model.tool_checks_remaining -= 1;
}

fn editProfileDraft(model: *Model, field: profile_editor.TextField, edit: canvas.TextInputEvent) void {
    model.profile_edit.edit(field, edit);
}

fn handleStoreResult(model: *Model, fx: *Effects, result: native_sdk.EffectFileResult) void {
    if (result.op == .read) {
        model.restore_ready = true;
        if (result.outcome == .ok) {
            _ = model.project_store.restoreAttached(result.bytes);
            model.active_workspace_id = model.project_store.firstWorkspaceId();
            model.restore_scan_active = true;
            model.restore_scan_index = 0;
            detectNextRestoredProject(model, fx);
        } else {
            model.status_text = "Ready";
        }
    } else if (result.op == .write) {
        model.persist_write_active = false;
        if (result.outcome != .ok) model.status_text = "Attached projects could not be persisted";
        if (model.persist_dirty) {
            model.persist_dirty = false;
            persistProjects(model, fx);
        }
    }
}

fn handleTerminalEvent(model: *Model, fx: *Effects, event: native_sdk.EffectPtyEvent) void {
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
                    removeTab(model, fx, index);
                    model.status_text = "Terminal closed";
                } else {
                    model.tab_store.items.items[index].exit_code = event.code;
                    model.tab_store.items.items[index].phase = if (event.reason == .exited) .exited else .failed;
                    model.status_text = if (event.reason == .exited) "Shell exited" else "Shell failed";
                }
            },
            .write => unreachable,
        }
        maybeFinishPendingTeardown(model, fx);
        return;
    }
}

fn handleGitResult(model: *Model, fx: *Effects, exit: git_workflow.Result) void {
    const operation = model.git.finish(exit.key) orelse return;
    const outcome = exit.outcome;
    const succeeded = outcome == .success;
    switch (operation.kind) {
        .restore_check => if (succeeded) {
            detectRepository(model, fx, operation.project_id);
        } else {
            _ = model.project_store.detach(operation.project_id);
            model.active_workspace_id = model.project_store.firstWorkspaceId();
            persistProjects(model, fx);
            detectNextRestoredProject(model, fx);
        },
        .detect_repo => {
            if (succeeded) {
                const root = std.mem.trim(u8, exit.output, " \r\n");
                if (model.project_store.findAttachedByKey(root)) |existing| {
                    if (existing.id != operation.project_id) {
                        _ = model.project_store.detach(operation.project_id);
                        model.active_workspace_id = for (existing.worktrees.items) |worktree| {
                            if (worktree.active) break worktree.id;
                        } else 0;
                        persistProjects(model, fx);
                        refreshWorktrees(model, fx, existing.id);
                        return;
                    }
                }
                if (model.project_store.markGit(operation.project_id, root)) {
                    refreshWorktrees(model, fx, operation.project_id);
                } else {
                    model.status_text = "The Git root path is invalid";
                    detectNextRestoredProject(model, fx);
                }
            } else {
                model.status_text = "Folder attached";
                detectNextRestoredProject(model, fx);
            }
        },
        .list_worktrees => {
            if (succeeded) {
                _ = model.project_store.applyWorktreePorcelain(operation.project_id, exit.output);
                const project = model.project_store.findProject(operation.project_id) orelse return;
                var selected: u64 = 0;
                if (model.select_after_refresh.len > 0) {
                    for (project.worktrees.items) |worktree| {
                        if (worktree.active and worktree.path.eql(model.select_after_refresh.slice())) selected = worktree.id;
                    }
                    model.select_after_refresh.len = 0;
                }
                if (selected == 0) {
                    for (project.worktrees.items) |worktree| {
                        if (worktree.active) {
                            selected = worktree.id;
                            break;
                        }
                    }
                }
                if (selected != 0 and (model.active_workspace_id == 0 or operation.project_id == model.create_project_id or model.restore_scan_active)) model.active_workspace_id = selected;
                if (operation.project_id == model.create_project_id) model.create_project_id = 0;
                if (model.create_failed) {
                    model.create_failed = false;
                    model.status_text = "Worktree creation failed; branch retained and Git state refreshed";
                } else {
                    model.status_text = "Worktrees refreshed";
                }
            } else {
                if (model.create_failed) {
                    model.create_failed = false;
                    model.status_text = "Worktree creation failed; inspect Git state manually";
                } else {
                    model.status_text = "Could not list Git worktrees";
                }
            }
            detectNextRestoredProject(model, fx);
        },
        .validate_branch, .check_target, .check_branch, .create_branch => {
            switch (operation.advanceCreation(outcome)) {
                .next => |next| spawnGit(model, fx, next),
                .failed => |message| model.status_text = message,
            }
        },
        .create_worktree => if (succeeded) {
            _ = model.select_after_refresh.set(operation.target_path.slice());
            refreshWorktrees(model, fx, operation.project_id);
        } else {
            model.create_failed = true;
            _ = model.select_after_refresh.set(operation.target_path.slice());
            refreshWorktrees(model, fx, operation.project_id);
        },
        .remove_status => {
            model.remove_safety.recordStatus(outcome, exit.output);
            preflightRemoveSubmodules(model, fx, operation.workspace_id);
        },
        .remove_submodules => {
            model.remove_safety.recordSubmodules(outcome, exit.output);
            preflightRemoveUnmerged(model, fx, operation.workspace_id);
        },
        .remove_unmerged => {
            model.remove_safety.recordUnmerged(outcome, exit.output);
            finishRemovePreflight(model, fx);
        },
        .remove_worktree => if (succeeded) {
            _ = model.project_store.removeWorktree(operation.workspace_id);
            if (model.active_workspace_id == operation.workspace_id) model.active_workspace_id = model.project_store.firstWorkspaceId();
            refreshWorktrees(model, fx, operation.project_id);
        } else {
            model.status_text = "Git refused to remove the worktree";
        },
        .none => {},
    }
}

pub fn update(model: *Model, msg: Msg, fx: *Effects) void {
    switch (msg) {
        .open_folder => if (!model.restore_ready) {
            model.status_text = "Restoring attached projects";
        } else if (!model.busy()) {
            model.picker_serial +%= 1;
            model.status_text = "Choose a project folder";
        },
        .folder_selected => |payload| {
            if (!model.restore_ready or model.busy()) return;
            const attached = model.project_store.attachPlaceholder(payload.slice()) orelse {
                model.status_text = "That folder path cannot be attached";
                return;
            };
            model.active_workspace_id = attached.workspace_id;
            persistProjects(model, fx);
            detectRepository(model, fx, attached.project_id);
        },
        .folder_dialog_cancelled => model.status_text = "Folder selection cancelled",
        .folder_dialog_failed => model.status_text = "The folder picker could not be opened",
        .select_workspace => |id| if (model.project_store.workspaceAvailable(id)) {
            model.active_workspace_id = id;
            model.sidebar.overlay_open = false;
            model.status_text = "Worktree selected";
        },
        .open_terminal => |id| {
            model.sidebar.overlay_open = false;
            openTerminal(model, fx, id);
        },
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
        .close_active_tab => if (model.canCloseActiveTab()) closeTerminal(model, fx, model.activeTabId(model.active_workspace_id)),
        .begin_create_worktree => |project_id| {
            const project = model.project_store.findProject(project_id) orelse return;
            if (!project.attached or !project.is_git or model.busy()) return;
            model.create_project_id = project_id;
            model.create_branch.clear();
            model.create_dialog_open = true;
        },
        .edit_create_branch => |edit| model.create_branch.apply(edit),
        .cancel_create_worktree => {
            model.create_dialog_open = false;
            model.create_project_id = 0;
            model.create_branch.clear();
        },
        .confirm_create_worktree => {
            if (model.busy()) return;
            const project = model.project_store.findProject(model.create_project_id) orelse return;
            const branch = std.mem.trim(u8, model.create_branch.text(), " ");
            if (branch.len == 0) return;
            var target_buffer: [workspaces.max_path_bytes]u8 = undefined;
            const target = model.project_store.makeWorktreePath(project, branch, model.git.next_key, &target_buffer) orelse {
                model.status_text = "Could not derive a safe worktree path";
                return;
            };
            const project_id = model.create_project_id;
            model.create_dialog_open = false;
            validateNewBranch(model, fx, project_id, branch, target);
        },
        .request_remove_worktree => |workspace_id| {
            if (model.busy()) return;
            if (!model.project_store.workspaceAvailable(workspace_id)) return;
            const worktree = model.project_store.findWorktree(workspace_id) orelse return;
            if (worktree.is_main or !worktree.active) return;
            model.remove_workspace_id = workspace_id;
            model.remove_safety = .{};
            model.remove_rechecking = false;
            model.pending_remove_workspace_id = 0;
            model.pending_remove_recheck = false;
            preflightRemoveStatus(model, fx, workspace_id);
        },
        .cancel_remove_worktree => {
            model.remove_dialog_open = false;
            model.remove_workspace_id = 0;
            model.pending_remove_workspace_id = 0;
            model.pending_remove_recheck = false;
            model.remove_rechecking = false;
        },
        .confirm_remove_worktree => {
            const workspace_id = model.remove_workspace_id;
            if (workspace_id == 0 or model.busy()) return;
            model.remove_dialog_open = false;
            model.approved_remove_safety = model.remove_safety;
            model.pending_remove_workspace_id = workspace_id;
            model.pending_remove_recheck = true;
            closeTabsForWorkspace(model, fx, workspace_id);
            maybeFinishPendingTeardown(model, fx);
        },
        .request_detach_project => |project_id| {
            const project = model.project_store.findProject(project_id) orelse return;
            if (!project.attached) return;
            model.detach_project_id = project_id;
            model.detach_dialog_open = true;
        },
        .cancel_detach_project => {
            model.detach_dialog_open = false;
            model.detach_project_id = 0;
        },
        .confirm_detach_project => {
            const project_id = model.detach_project_id;
            if (project_id == 0 or model.busy()) return;
            model.detach_dialog_open = false;
            model.pending_detach_project_id = project_id;
            closeTabsForProject(model, fx, project_id);
            maybeFinishPendingTeardown(model, fx);
        },
        .open_preferences => openPreferences(model),
        .open_claude_preferences => {
            openPreferences(model);
            openProfileSection(model, .claude);
        },
        .close_preferences => closePreferences(model),
        .show_preferences_general => model.preferences_section = .general,
        .show_preferences_appearance => model.preferences_section = .appearance,
        .show_preferences_worktrees => model.preferences_section = .worktrees,
        .show_preferences_claude => openProfileSection(model, .claude),
        .show_preferences_codex => openProfileSection(model, .codex),
        .edit_preferences_search => |edit| model.preferences_search.apply(edit),
        .toggle_preferences_reopen => {
            model.preferences_draft.reopen_last_workspace = !model.preferences_draft.reopen_last_workspace;
            model.preferences_dirty = true;
        },
        .use_system_appearance => {
            model.preferences_draft.appearance_mode = .system;
            model.preferences_dirty = true;
        },
        .use_light_appearance => {
            model.preferences_draft.appearance_mode = .light;
            model.preferences_dirty = true;
        },
        .use_dark_appearance => {
            model.preferences_draft.appearance_mode = .dark;
            model.preferences_dirty = true;
        },
        .edit_preferences_base_dir => |edit| {
            model.preferences_base_dir.apply(edit);
            model.preferences_dirty = true;
        },
        .save_preferences => savePreferences(model, fx),
        .preferences_load_done => |result| handlePreferencesLoadResult(model, fx, result),
        .preferences_db_done => |result| handlePreferencesWriteResult(model, result),
        .worktrees_base_failed => model.status_text = "Worktree base directory could not be created",
        .profiles_load_done => |result| handleProfilesLoadResult(model, result),
        .profile_db_done => |result| handleProfileWriteResult(model, fx, result),
        .tool_check_done => |exit| handleToolCheckResult(model, exit),
        .toggle_claude_profiles => model.claude_expanded = !model.claude_expanded,
        .toggle_codex_profiles => model.codex_expanded = !model.codex_expanded,
        .launch_claude => {
            model.sidebar.overlay_open = false;
            launchDefaultTool(model, fx, .claude);
        },
        .launch_codex => {
            model.sidebar.overlay_open = false;
            launchDefaultTool(model, fx, .codex);
        },
        .launch_profile => |id| {
            model.sidebar.overlay_open = false;
            launchProfileTool(model, fx, id);
        },
        .new_profile => createProfileDraft(model),
        .select_profile => |id| model.profile_edit.select(model.profile_store, id),
        .confirm_profile_switch => model.profile_edit.confirmSwitch(model.profile_store),
        .cancel_profile_switch => model.profile_edit.cancelSwitch(),
        .request_delete_profile => |id| model.profile_edit.requestDelete(id),
        .confirm_delete_profile => deleteProfile(model, fx),
        .cancel_delete_profile => model.profile_edit.cancelDelete(),
        .save_profile => saveProfile(model, fx),
        .edit_profile_name => |edit| editProfileDraft(model, .name, edit),
        .edit_profile_model => |edit| editProfileDraft(model, .model, edit),
        .edit_profile_permission_mode => |edit| editProfileDraft(model, .permission_mode, edit),
        .edit_profile_effort_level => |edit| editProfileDraft(model, .effort_level, edit),
        .edit_profile_provider => |edit| editProfileDraft(model, .provider, edit),
        .edit_profile_approval_mode => |edit| editProfileDraft(model, .approval_mode, edit),
        .edit_profile_sandbox => |edit| editProfileDraft(model, .sandbox, edit),
        .edit_profile_base_url => |edit| editProfileDraft(model, .base_url, edit),
        .edit_profile_append_prompt => |edit| editProfileDraft(model, .append_system_prompt, edit),
        .edit_profile_custom_env => |edit| editProfileDraft(model, .custom_env, edit),
        .edit_profile_settings_json => |edit| editProfileDraft(model, .settings_json, edit),
        .edit_profile_codex_profile => |edit| editProfileDraft(model, .profile, edit),
        .toggle_profile_full_auto => model.profile_edit.toggleFullAuto(),
        .toggle_profile_dangerous_bypass => model.profile_edit.toggleDangerousBypass(),
        .git_done => |exit| handleGitResult(model, fx, git_cli.result(exit)),
        .store_done => |result| handleStoreResult(model, fx, result),
        .terminal_event => |event| handleTerminalEvent(model, fx, event),
        .sidebar_resized => |fraction| {
            if (!model.sidebar.compact and !model.sidebar.collapsed and !model.sidebar.animating() and std.math.isFinite(fraction)) {
                const width = @max(210, std.math.clamp(fraction, 0, 1) * @max(1, model.canvas_width - sidebar_divider_width));
                if (model.sidebar_width != width) {
                    model.sidebar_width = width;
                    model.sidebar_persistence.edit(width);
                }
            }
        },
        .save_sidebar_width => saveSidebarWidth(model, fx),
        .sidebar_width_saved => |result| if (result.key == sidebar_write_key and result.kind == .exec) {
            model.sidebar_persistence.finish(result.outcome == .ok);
            if (result.outcome != .ok) model.status_text = "Could not save sidebar width";
        },
        .toggle_sidebar => model.sidebar.toggle(),
        .dismiss_sidebar => model.sidebar.overlay_open = false,
        .set_appearance => |appearance| model.appearance = appearance,
        .chrome_changed => |chrome| model.window_chrome = chrome,
    }
}

pub const preferences_load_key: u64 = 8_000;
pub const sidebar_write_key: u64 = 8_004;

fn saveSidebarWidth(model: *Model, fx: *Effects) void {
    const width = model.sidebar_persistence.begin() orelse return;
    var buffer: [16]u8 = undefined;
    const value = std.fmt.bufPrint(&buffer, "{d}", .{width}) catch unreachable;
    fx.dbExec(.{
        .key = sidebar_write_key,
        .statements = &.{.{ .sql = preferences_mod.sidebar_upsert_sql, .params = &.{.{ .text = value }} }},
        .on_result = Effects.dbMsg(.sidebar_width_saved),
    });
}

// Shutdown uses the still-live runtime binding after Effects have stopped, so
// a queued completion or final drag sample cannot lose the latest width.
pub fn flushSidebarWidth(model: *Model, binding: native_sdk.relational_store.Binding) bool {
    if (!model.sidebar_persistence.needsFlush()) return true;
    var buffer: [16]u8 = undefined;
    const width = model.sidebar_persistence.desired;
    const value = std.fmt.bufPrint(&buffer, "{d}", .{width}) catch unreachable;
    const outcome = binding.exec_fn(binding.context, &.{.{ .sql = preferences_mod.sidebar_upsert_sql, .params = &.{.{ .text = value }} }});
    if (outcome != .ok) return false;
    model.sidebar_persistence.saved = width;
    model.sidebar_persistence.dirty = false;
    model.sidebar_persistence.submitted = null;
    return true;
}

fn beginProjectRestore(model: *Model, fx: *Effects) void {
    if (!model.preferences_saved.reopen_last_workspace) {
        model.restore_ready = true;
        model.status_text = "Ready";
    } else if (model.store_path.len > 0) {
        fx.readFile(.{
            .key = store_read_key,
            .path = model.store_path.slice(),
            .on_result = Effects.fileMsg(.store_done),
        });
    } else if (model.active_workspace_id != 0) {
        openTerminal(model, fx, model.active_workspace_id);
    }
}

fn finishPreferencesLoad(model: *Model, fx: *Effects) void {
    if (!model.preferences_load_valid) model.preferences_saved = .{};
    if (model.sidebar_persistence.restore(model.preferences_saved.sidebar_width)) |width| model.sidebar_width = width;
    model.preferences_draft = model.preferences_saved;
    model.preferences_loaded = true;
    const base_dir = if (model.preferences_saved.worktrees_base_dir.len > 0)
        model.preferences_saved.worktrees_base_dir.slice()
    else
        model.default_worktrees_base.slice();
    _ = model.project_store.setWorktreesBase(base_dir);
    model.worktrees_base_serial +%= 1;
    beginProjectRestore(model, fx);
}

pub fn boot(model: *Model, fx: *Effects) void {
    model.status_text = "Loading preferences";
    fx.dbQuery(.{
        .key = preferences_load_key,
        .sql = preferences_mod.load_sql,
        .on_result = Effects.dbMsg(.preferences_load_done),
    });
    reloadProfiles(model, fx, "");
    startToolChecks(model, fx);
}

pub fn onChrome(chrome: native_sdk.WindowChrome) ?Msg {
    return .{ .chrome_changed = chrome };
}

pub fn onAppearance(appearance: native_sdk.Appearance) ?Msg {
    return .{ .set_appearance = appearance };
}

pub fn canopyTokens(model: *const Model) canvas.DesignTokens {
    const selected = if (model.preferences_open) &model.preferences_draft else &model.preferences_saved;
    var tokens = theme.tokens(selected.effectiveAppearance(model.appearance));
    theme.applyGripHighlight(&tokens, model.sidebar.grip.value);
    return tokens;
}

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
        host.ui_app.model.active_tab_by_workspace.deinit(host.ui_app.model.tab_store.allocator);
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
        if (model.store_path.len == 0) return;
        var buffer: [workspaces.max_store_bytes]u8 = undefined;
        const bytes = model.project_store.serializeAttached(&buffer) orelse return error.ProjectStoreTooLarge;
        var atomic = try std.Io.Dir.cwd().createFileAtomic(host.io, model.store_path.slice(), .{ .make_path = true, .replace = true });
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
