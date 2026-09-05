//! Message routing and startup composition. Feature modules own orchestration.
const native_sdk = @import("native_sdk");
const theme = @import("theme.zig");
const canvas = native_sdk.canvas;
pub const Model = @import("app_types.zig").Model;
pub const Msg = @import("app_types.zig").Msg;
pub const Effects = @import("app_types.zig").Effects;
const workspace_actions = @import("workspace_actions.zig");
const terminal_actions = @import("terminal_actions.zig");
const settings_actions = @import("settings_actions.zig");
const agent_actions = @import("agent_actions.zig");
const sidebar_actions = @import("sidebar_actions.zig");
pub const preferences_load_key = settings_actions.preferences_load_key;
pub const preferences_write_key = settings_actions.preferences_write_key;
pub const profiles_load_key = settings_actions.profiles_load_key;
pub const profile_write_key = settings_actions.profile_write_key;
pub const sidebar_write_key = sidebar_actions.sidebar_write_key;
pub const flushSidebarWidth = sidebar_actions.flushSidebarWidth;
pub const resolvedToolExecutable = agent_actions.resolvedToolExecutable;
const profiles_mod = @import("profiles.zig");
const preferences_mod = @import("preferences.zig");

pub fn update(model: *Model, msg: Msg, fx: *Effects) void {
    defer agent_actions.acknowledge(model);
    defer model.observeUiMotion();
    // Restore owns an index cursor until the scan ends. Keep membership stable.
    defer if (!model.project_io.scanning()) switch (msg) {
        .git_done,
        .confirm_detach_project,
        .close_tab,
        .close_active_tab,
        => workspace_actions.collectUnused(model),
        .terminal_event => |event| {
            if (event.kind == .exit) workspace_actions.collectUnused(model);
        },
        else => {},
    };
    switch (msg) {
        .open_folder,
        .folder_selected,
        .folder_dialog_cancelled,
        .folder_dialog_failed,
        .select_workspace,
        .begin_create_worktree,
        .edit_create_branch,
        .cancel_create_worktree,
        .confirm_create_worktree,
        .request_remove_worktree,
        .cancel_remove_worktree,
        .confirm_remove_worktree,
        .request_detach_project,
        .cancel_detach_project,
        .confirm_detach_project,
        .worktrees_base_failed,
        .git_done,
        .git_wakeup,
        .store_done,
        => {
            workspace_actions.handle(model, msg, fx);
        },
        .open_terminal,
        .open_active_terminal,
        .activate_tab,
        .previous_tab,
        .next_tab,
        .tabs_scrolled,
        .close_tab,
        .close_active_tab,
        .terminal_event,
        => {
            terminal_actions.handle(model, msg, fx);
            if (msg == .terminal_event) workspace_actions.maybeFinishPendingTeardown(model, fx);
        },
        .open_preferences,
        .open_claude_preferences,
        .close_preferences,
        .show_preferences_general,
        .show_preferences_appearance,
        .show_preferences_worktrees,
        .show_preferences_claude,
        .show_preferences_codex,
        .edit_preferences_search,
        .toggle_preferences_reopen,
        .use_system_appearance,
        .use_light_appearance,
        .use_dark_appearance,
        .edit_preferences_base_dir,
        .save_preferences,
        .preferences_load_done,
        .preferences_db_done,
        .reload_profiles,
        .profiles_load_done,
        .profile_db_done,
        .new_profile,
        .select_profile,
        .confirm_profile_switch,
        .cancel_profile_switch,
        .request_delete_profile,
        .confirm_delete_profile,
        .cancel_delete_profile,
        .save_profile,
        .edit_profile_name,
        .edit_profile_model,
        .edit_profile_permission_mode,
        .edit_profile_effort_level,
        .edit_profile_provider,
        .edit_profile_approval_mode,
        .edit_profile_sandbox,
        .edit_profile_base_url,
        .edit_profile_append_prompt,
        .edit_profile_custom_env,
        .edit_profile_settings_json,
        .edit_profile_codex_profile,
        .toggle_profile_full_auto,
        .toggle_profile_dangerous_bypass,
        => {
            settings_actions.handle(model, msg, fx);
        },
        .agent_hook_event,
        .agent_setup_failed,
        .agent_tracking_failed,
        .tool_check_done,
        .toggle_agent_profiles,
        .launch_agent,
        .launch_profile,
        => {
            agent_actions.handle(model, msg, fx);
        },
        .sidebar_resized,
        .save_sidebar_width,
        .sidebar_width_saved,
        .toggle_sidebar,
        .dismiss_sidebar,
        => {
            sidebar_actions.handle(model, msg, fx);
        },
        .set_appearance => |appearance| model.appearance = appearance,
        .chrome_changed => |chrome| model.window_chrome = chrome,
    }
}

pub fn boot(model: *Model, fx: *Effects) void {
    model.status_text = "Loading preferences";
    fx.dbQuery(.{
        .key = settings_actions.preferences_load_key,
        .sql = preferences_mod.load_sql,
        .on_result = Effects.dbMsg(.preferences_load_done),
    });
    settings_actions.reloadProfiles(model, fx, "");
    agent_actions.startToolChecks(model, fx);
}

pub fn onChrome(chrome: native_sdk.WindowChrome) ?Msg {
    return .{ .chrome_changed = chrome };
}

pub fn onAppearance(appearance: native_sdk.Appearance) ?Msg {
    return .{ .set_appearance = appearance };
}

pub fn canopyTokens(model: *const Model) canvas.DesignTokens {
    const selected = if (model.preferences_edit.open) &model.preferences_edit.draft else &model.preferences_edit.saved;
    var tokens = theme.tokens(selected.effectiveAppearance(model.appearance));
    theme.applyGripHighlight(&tokens, model.sidebar.grip.value);
    return tokens;
}
