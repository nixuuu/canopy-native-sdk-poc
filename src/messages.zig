//! Typed UI and host-effect message contract.
const native_sdk = @import("native_sdk");
const canvas = native_sdk.canvas;
const profiles_mod = @import("profiles.zig");
const workspaces = @import("workspaces.zig");

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
    toggle_agent_profiles: profiles_mod.AgentType,
    launch_agent: profiles_mod.AgentType,
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
    git_done: @import("git_workflow.zig").Result,
    git_wakeup: native_sdk.EffectChannelEvent,
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
        "git_wakeup",
        "store_done",
        "terminal_event",
        "close_active_tab",
        "set_appearance",
        "chrome_changed",
    };
};
