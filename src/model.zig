//! Application model and Native markup projections. No host effects live here.
const std = @import("std");
const native_sdk = @import("native_sdk");
const canvas = native_sdk.canvas;
const preferences_editor = @import("preferences_editor.zig");
const profile_editor = @import("profile_editor.zig");
const profiles_mod = @import("profiles.zig");
const project_persistence = @import("project_persistence.zig");
const terminal_controller = @import("terminal_controller.zig");
const terminal_tabs = @import("terminal_tabs.zig");
const tool_registry = @import("tool_registry.zig");
const workspaces = @import("workspaces.zig");
const workspace_dialogs = @import("workspace_dialogs.zig");
const git_workflow = @import("git_workflow.zig");

pub const window_width: f32 = 1180;
pub const sidebar_divider_width: f32 = 3;
const max_rendered_tab_buttons: usize = 12;
pub const fallback_user_shell = "/bin/zsh";

pub const TerminalTool = terminal_tabs.Tool;
pub const TerminalTabRow = terminal_tabs.Row;
pub const TabStore = terminal_tabs.Store;
pub const PreferencesSection = preferences_editor.Section;

pub const Model = struct {
    use_ghostty: bool = false,
    project_store: *workspaces.Store = undefined,
    profile_store: *profiles_mod.Store = undefined,
    active_workspace_id: u64 = 0,
    tab_store: *TabStore = undefined,
    terminal_state: terminal_controller.State = .{},
    sidebar_width: f32 = 210,
    sidebar_persistence: @import("sidebar_persistence.zig").State = .{},
    canvas_width: f32 = window_width,
    sidebar: @import("sidebar_state.zig").State = .{},
    window_chrome: native_sdk.WindowChrome = .{},
    appearance: native_sdk.Appearance = .{},
    status_text: []const u8 = "Ready",
    picker_serial: u64 = 0,
    git: git_workflow.Lane = .{},
    workspace_dialogs: workspace_dialogs.State = .{},
    teardown: @import("teardown_state.zig").State = .idle,
    project_io: project_persistence.State = .{},
    preferences_edit: preferences_editor.State = .{},
    preferences_db_path: workspaces.PathText = .{},
    default_worktrees_base: workspaces.PathText = .{},
    worktrees_base_serial: u64 = 0,
    profile_edit: profile_editor.State = .{},
    tools: tool_registry.State = .{},
    user_shell: workspaces.PathText = .{},

    pub const view_unbound = .{
        "sidebar_persistence",
        "window_chrome",
        "sidebar_width",
        "canvas_width",
        "sidebar",
        "terminalActionsBlocked",
        "canCloseActiveTab",
        "active_workspace_id",
        "project_store",
        "profile_store",
        "tab_store",
        "terminal_state",
        "appearance",
        "picker_serial",
        "git",
        "workspace_dialogs",
        "teardown",
        "project_io",
        "preferences_edit",
        "preferences_db_path",
        "default_worktrees_base",
        "worktrees_base_serial",
        "profile_edit",
        "tools",
        "user_shell",
        "userShell",
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
        return switch (tool) {
            .shell => false,
            .claude => model.tools.setExecutable(.claude, executable),
            .codex => model.tools.setExecutable(.codex, executable),
        };
    }

    pub fn toolExecutable(model: *const Model, tool: TerminalTool) []const u8 {
        return switch (tool) {
            .shell => model.userShell(),
            .claude, .codex => model.tools.executable(tool),
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
        return !model.project_io.ready() or model.busy();
    }

    pub fn busy(model: *const Model) bool {
        return model.git.busy() or model.teardown.busy();
    }

    pub fn createBranchText(model: *const Model) []const u8 {
        return model.workspace_dialogs.create.branch.text();
    }

    pub fn createDisabled(model: *const Model) bool {
        return model.workspace_dialogs.create.branch.text().len == 0 or model.busy();
    }

    pub fn createProjectName(model: *const Model) []const u8 {
        const project = model.project_store.findProject(model.workspace_dialogs.create.project_id) orelse return "repository";
        return project.name.slice();
    }

    pub fn removeWorktreeName(model: *const Model) []const u8 {
        const worktree = model.project_store.findWorktree(model.workspace_dialogs.removal.workspace_id) orelse return "worktree";
        return worktree.name.slice();
    }

    pub fn removeWorktreePath(model: *const Model) []const u8 {
        const worktree = model.project_store.findWorktree(model.workspace_dialogs.removal.workspace_id) orelse return "";
        return worktree.path.slice();
    }

    pub fn removeHasWarnings(model: *const Model) bool {
        return model.workspace_dialogs.removal.safety.hasWarnings();
    }

    pub fn removeDirty(model: *const Model) bool {
        return model.workspace_dialogs.removal.safety.dirty;
    }

    pub fn removeHasSubmodules(model: *const Model) bool {
        return model.workspace_dialogs.removal.safety.has_submodules;
    }

    pub fn removeUnmergedCount(model: *const Model) usize {
        return model.workspace_dialogs.removal.safety.unmerged_count;
    }

    pub fn detachProjectName(model: *const Model) []const u8 {
        const project = model.project_store.findProject(model.workspace_dialogs.detach.project_id) orelse return "project";
        return project.name.slice();
    }

    pub fn preferencesGeneralSelected(model: *const Model) bool {
        return model.preferences_edit.section == .general;
    }

    pub fn preferencesAppearanceSelected(model: *const Model) bool {
        return model.preferences_edit.section == .appearance;
    }

    pub fn preferencesWorktreesSelected(model: *const Model) bool {
        return model.preferences_edit.section == .worktrees;
    }

    pub fn preferencesClaudeSelected(model: *const Model) bool {
        return model.preferences_edit.section == .claude;
    }

    pub fn preferencesCodexSelected(model: *const Model) bool {
        return model.preferences_edit.section == .codex;
    }

    pub fn preferencesProfileSelected(model: *const Model) bool {
        return model.preferences_edit.profileSelected();
    }

    fn preferencesBasicSelected(model: *const Model) bool {
        return !model.preferencesProfileSelected();
    }

    pub fn preferencesShowSave(model: *const Model) bool {
        return model.preferencesBasicSelected() and model.preferences_edit.dirty;
    }

    pub fn preferencesSectionTitle(model: *const Model) []const u8 {
        return model.preferences_edit.title();
    }

    pub fn preferencesSectionDescription(model: *const Model) []const u8 {
        return model.preferences_edit.description();
    }

    pub fn preferencesSearchText(model: *const Model) []const u8 {
        return model.preferences_edit.search.text();
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
        return model.preferences_edit.draft.reopen_last_workspace;
    }

    pub fn preferencesAppearanceSystem(model: *const Model) bool {
        return model.preferences_edit.draft.appearance_mode == .system;
    }

    pub fn preferencesAppearanceLight(model: *const Model) bool {
        return model.preferences_edit.draft.appearance_mode == .light;
    }

    pub fn preferencesAppearanceDark(model: *const Model) bool {
        return model.preferences_edit.draft.appearance_mode == .dark;
    }

    pub fn preferencesBaseDirText(model: *const Model) []const u8 {
        return model.preferences_edit.base_dir.text();
    }

    pub fn preferencesBaseDirInvalid(model: *const Model) bool {
        return model.preferences_edit.baseDirInvalid();
    }

    pub fn preferencesSaveDisabled(model: *const Model) bool {
        return model.preferences_edit.saving or !model.preferences_edit.dirty or model.preferencesBaseDirInvalid();
    }

    pub fn preferencesDisabled(model: *const Model) bool {
        return !model.preferences_edit.loaded or model.preferences_edit.saving or model.profile_edit.saving();
    }

    pub fn preferencesSaveLabel(model: *const Model) []const u8 {
        return if (model.preferences_edit.saving) "Saving..." else "Save";
    }

    pub fn preferencesDefaultBaseDir(model: *const Model) []const u8 {
        return model.default_worktrees_base.slice();
    }

    pub fn toolsReady(model: *const Model) bool {
        return model.profile_edit.loaded and model.tools.ready();
    }

    pub fn toolsLoading(model: *const Model) bool {
        return !model.toolsReady();
    }

    pub fn noAgentToolsAvailable(model: *const Model) bool {
        return model.tools.noAgentsAvailable();
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
        const agent_type = model.preferences_edit.agent() orelse .claude;
        return model.profile_store.rows(arena, agent_type, model.profile_edit.selected_id);
    }

    pub fn claudeRunningCount(model: *const Model) usize {
        return model.runningCount(.claude);
    }

    pub fn codexRunningCount(model: *const Model) usize {
        return model.runningCount(.codex);
    }

    pub fn claude_available(model: *const Model) bool {
        return model.tools.claude.available();
    }

    pub fn codex_available(model: *const Model) bool {
        return model.tools.codex.available();
    }

    pub fn claude_expanded(model: *const Model) bool {
        return model.tools.claude.expanded;
    }

    pub fn codex_expanded(model: *const Model) bool {
        return model.tools.codex.expanded;
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

    pub fn profileControlsDisabled(model: *const Model) bool {
        return !model.profile_edit.loaded or model.profile_edit.busy();
    }
    pub fn removeMissing(model: *const Model) bool {
        return model.workspace_dialogs.removal.safety.missing;
    }

    pub fn profileSaveDisabled(model: *const Model) bool {
        const name = std.mem.trim(u8, model.profile_edit.draft.name.text(), " ");
        return model.profile_edit.busy() or !model.profile_edit.dirty or name.len == 0;
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
        return model.profile_edit.pending_delete != null and model.profile_edit.pending_switch == null;
    }

    fn runningCount(model: *const Model, tool: TerminalTool) usize {
        var count: usize = 0;
        for (model.tab_store.items.items) |tab| {
            if (tab.workspace_id == model.active_workspace_id and tab.tool == tool and tab.phase != .closing and tab.phase != .exited and tab.phase != .failed) count += 1;
        }
        return count;
    }

    fn preferencesSearchMatches(model: *const Model, haystack: []const u8) bool {
        return model.preferences_edit.searchMatches(haystack);
    }

    pub fn activeTabId(model: *const Model, workspace_id: u64) u64 {
        return model.terminal_state.active(workspace_id);
    }

    pub fn terminalActionsBlocked(model: *const Model) bool {
        return model.preferences_edit.open or model.workspace_dialogs.create.open or model.workspace_dialogs.removal.open or model.workspace_dialogs.detach.open or model.profileSwitchDialogOpen() or model.profileDeleteDialogOpen();
    }

    pub fn preferences_open(model: *const Model) bool {
        return model.preferences_edit.open and !model.profileSwitchDialogOpen() and !model.profileDeleteDialogOpen();
    }

    pub fn preferences_dirty(model: *const Model) bool {
        return model.preferences_edit.dirty;
    }

    pub fn create_dialog_open(model: *const Model) bool {
        return model.workspace_dialogs.create.open;
    }

    pub fn remove_dialog_open(model: *const Model) bool {
        return model.workspace_dialogs.removal.open;
    }

    pub fn detach_dialog_open(model: *const Model) bool {
        return model.workspace_dialogs.detach.open;
    }

    pub fn canCloseActiveTab(model: *const Model) bool {
        return !model.terminalActionsBlocked() and model.activeTabId(model.active_workspace_id) != 0;
    }

    pub fn setActiveTab(model: *Model, workspace_id: u64, tab_id: u64) void {
        model.terminal_state.select(model.tab_store, workspace_id, tab_id);
    }

    pub fn setStorePath(model: *Model, path: []const u8) void {
        _ = model.project_io.configure(path);
    }
};
