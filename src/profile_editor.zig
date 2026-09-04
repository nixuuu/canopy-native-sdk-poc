//! Model-owned, non-secret draft for the agent profile editor.

const native_sdk = @import("native_sdk");
const profiles = @import("profiles.zig");

const canvas = native_sdk.canvas;

pub const TextField = enum {
    name,
    model,
    permission_mode,
    effort_level,
    provider,
    approval_mode,
    sandbox,
    base_url,
    append_system_prompt,
    custom_env,
    settings_json,
    profile,
};

pub const Draft = struct {
    runtime_id: u64 = 0,
    agent_type: profiles.AgentType = .claude,
    is_new: bool = false,
    is_default: bool = false,
    sort_index: i64 = 0,
    database_id: canvas.TextBuffer(profiles.max_profile_id_bytes) = .{},
    name: canvas.TextBuffer(profiles.max_profile_name_bytes) = .{},
    model: canvas.TextBuffer(profiles.max_pref_bytes) = .{},
    custom_env: canvas.TextBuffer(profiles.max_long_pref_bytes) = .{},
    settings_json: canvas.TextBuffer(profiles.max_long_pref_bytes) = .{},
    permission_mode: canvas.TextBuffer(profiles.max_pref_bytes) = .{},
    effort_level: canvas.TextBuffer(profiles.max_pref_bytes) = .{},
    append_system_prompt: canvas.TextBuffer(profiles.max_long_pref_bytes) = .{},
    base_url: canvas.TextBuffer(profiles.max_pref_bytes) = .{},
    provider: canvas.TextBuffer(profiles.max_pref_bytes) = .{},
    approval_mode: canvas.TextBuffer(profiles.max_pref_bytes) = .{},
    sandbox: canvas.TextBuffer(profiles.max_pref_bytes) = .{},
    full_auto: bool = false,
    dangerously_bypass_approvals_and_sandbox: bool = false,
    profile: canvas.TextBuffer(profiles.max_pref_bytes) = .{},

    pub fn applyTextEdit(draft: *Draft, field: TextField, edit: canvas.TextInputEvent) void {
        switch (field) {
            .name => draft.name.apply(edit),
            .model => draft.model.apply(edit),
            .permission_mode => draft.permission_mode.apply(edit),
            .effort_level => draft.effort_level.apply(edit),
            .provider => draft.provider.apply(edit),
            .approval_mode => draft.approval_mode.apply(edit),
            .sandbox => draft.sandbox.apply(edit),
            .base_url => draft.base_url.apply(edit),
            .append_system_prompt => draft.append_system_prompt.apply(edit),
            .custom_env => draft.custom_env.apply(edit),
            .settings_json => draft.settings_json.apply(edit),
            .profile => draft.profile.apply(edit),
        }
    }

    pub fn load(draft: *Draft, source: *const profiles.Profile) void {
        draft.* = .{
            .runtime_id = source.runtime_id,
            .agent_type = source.agent_type,
            .is_default = source.is_default,
            .sort_index = source.sort_index,
        };
        draft.database_id.set(source.id.slice());
        draft.name.set(source.name.slice());
        draft.model.set(source.prefs.model.slice());
        draft.custom_env.set(source.prefs.custom_env.slice());
        draft.settings_json.set(source.prefs.settings_json.slice());
        draft.permission_mode.set(source.prefs.permission_mode.slice());
        draft.effort_level.set(source.prefs.effort_level.slice());
        draft.append_system_prompt.set(source.prefs.append_system_prompt.slice());
        draft.base_url.set(source.prefs.base_url.slice());
        draft.provider.set(source.prefs.provider.slice());
        draft.approval_mode.set(source.prefs.approval_mode.slice());
        draft.sandbox.set(source.prefs.sandbox.slice());
        draft.full_auto = source.prefs.full_auto;
        draft.dangerously_bypass_approvals_and_sandbox = source.prefs.dangerously_bypass_approvals_and_sandbox;
        draft.profile.set(source.prefs.profile.slice());
    }

    pub fn create(draft: *Draft, agent_type: profiles.AgentType, name: []const u8, sort_index: i64, database_id: []const u8) void {
        draft.* = .{ .agent_type = agent_type, .is_new = true, .sort_index = sort_index };
        draft.database_id.set(database_id);
        draft.name.set(name);
    }

    pub fn toPrefs(draft: *const Draft) profiles.Prefs {
        var prefs: profiles.Prefs = .{};
        _ = prefs.model.set(draft.model.text());
        _ = prefs.custom_env.set(draft.custom_env.text());
        _ = prefs.settings_json.set(draft.settings_json.text());
        _ = prefs.permission_mode.set(draft.permission_mode.text());
        _ = prefs.effort_level.set(draft.effort_level.text());
        _ = prefs.append_system_prompt.set(draft.append_system_prompt.text());
        _ = prefs.base_url.set(draft.base_url.text());
        _ = prefs.provider.set(draft.provider.text());
        _ = prefs.approval_mode.set(draft.approval_mode.text());
        _ = prefs.sandbox.set(draft.sandbox.text());
        prefs.full_auto = draft.full_auto;
        prefs.dangerously_bypass_approvals_and_sandbox = draft.dangerously_bypass_approvals_and_sandbox;
        _ = prefs.profile.set(draft.profile.text());
        return prefs;
    }
};
