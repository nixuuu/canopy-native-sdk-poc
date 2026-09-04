//! Settings actions: one application feature boundary.
const types = @import("app_types.zig");
const Model = types.Model;
const Msg = types.Msg;
const Effects = types.Effects;
const native_sdk = @import("native_sdk");
const preferences_mod = @import("preferences.zig");
const profile_editor = @import("profile_editor.zig");
const profiles_mod = @import("profiles.zig");
const workspace_actions = @import("workspace_actions.zig");
const canvas = native_sdk.canvas;

pub const preferences_load_key = @import("effect_keys.zig").key(.preferences, 0);
pub const preferences_write_key = @import("effect_keys.zig").key(.preferences, 1);
pub const profiles_load_key = @import("effect_keys.zig").key(.profiles, 0);
pub const profile_write_key = @import("effect_keys.zig").key(.profiles, 1);
const preferences_upsert_sql = "INSERT OR REPLACE INTO preferences (key, value) VALUES (?1, ?2);";

pub fn openPreferences(model: *Model) void {
    if (model.preferences_edit.openDialog()) model.status_text = "Preferences opened";
}

pub fn closePreferences(model: *Model) void {
    if (!model.profile_edit.requestClose(model.profile_store) or !model.preferences_edit.closeDialog()) return;
    model.profile_edit.close(model.profile_store);
    model.status_text = "Preferences unchanged";
}

pub fn savePreferences(model: *Model, fx: *Effects) void {
    const prepared = switch (model.preferences_edit.prepareSave()) {
        .skip => return,
        .invalid => |message| {
            model.status_text = message;
            return;
        },
        .ready => |value| value,
    };
    const statements = [_]native_sdk.EffectDbStatement{
        .{ .sql = preferences_upsert_sql, .params = &.{ .{ .text = preferences_mod.key_reopen_last_workspace }, .{ .text = prepared.reopen } } },
        .{ .sql = preferences_upsert_sql, .params = &.{ .{ .text = preferences_mod.key_native_appearance }, .{ .text = prepared.appearance } } },
        .{ .sql = preferences_upsert_sql, .params = &.{ .{ .text = preferences_mod.key_worktrees_base_dir }, .{ .text = prepared.base_dir } } },
    };
    model.status_text = "Saving preferences";
    fx.dbExec(.{
        .key = preferences_write_key,
        .statements = &statements,
        .on_result = Effects.dbMsg(.preferences_db_done),
    });
}

pub fn openProfileSection(model: *Model, agent_type: profiles_mod.AgentType) void {
    if (model.profile_edit.loaded and !model.profile_edit.openAgent(model.profile_store, agent_type)) return;
    model.preferences_edit.select(if (agent_type == .codex) .codex else .claude);
}

pub fn reloadProfiles(model: *Model, fx: *Effects, select_database_id: []const u8) void {
    if (model.profile_edit.loading) return;
    model.profile_edit.beginReload(model.profile_store, select_database_id);
    fx.dbQuery(.{ .key = profiles_load_key, .sql = profiles_mod.load_sql, .on_result = Effects.dbMsg(.profiles_load_done) });
}

pub fn finishProfilesLoad(model: *Model) void {
    const agent = model.preferences_edit.agent() orelse .claude;
    if (!model.profile_edit.finishLoad(model.profile_store, agent)) model.status_text = "Agent profiles could not be loaded";
}

pub fn createProfileDraft(model: *Model) void {
    if (!model.preferencesProfileSelected()) return;
    const agent = model.preferences_edit.agent() orelse return;
    if (model.profile_edit.create(model.profile_store, agent)) |message| model.status_text = message;
}

pub fn saveProfile(model: *Model, fx: *Effects) void {
    var json_buffer: [profiles_mod.max_encoded_bytes]u8 = undefined;
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

pub fn deleteProfile(model: *Model, fx: *Effects) void {
    const id = model.profile_edit.prepareDelete(model.profile_store) orelse return;
    model.status_text = "Deleting agent profile";
    fx.dbExec(.{
        .key = profile_write_key,
        .statements = &.{.{ .sql = "DELETE FROM agent_profiles WHERE id = ?1;", .params = &.{.{ .text = id }} }},
        .on_result = Effects.dbMsg(.profile_db_done),
    });
}

pub fn handlePreferencesLoadResult(model: *Model, fx: *Effects, result: native_sdk.EffectDbResult) void {
    if (result.key != preferences_load_key) return;
    switch (result.kind) {
        .page => {
            if (result.outcome == .ok) {
                model.preferences_edit.loadPage(result.bytes);
            } else {
                model.preferences_edit.load_valid = false;
            }
        },
        .done => {
            model.preferences_edit.finishLoad(result.outcome == .ok);
            finishPreferencesLoad(model, fx);
        },
        .exec => model.preferences_edit.load_valid = false,
    }
}

pub fn handlePreferencesWriteResult(model: *Model, result: native_sdk.EffectDbResult) void {
    if (result.key != preferences_write_key or result.kind != .exec) return;
    const completion = model.preferences_edit.finishSave(result.outcome == .ok, result.outcome == .busy);
    if (!completion.handled) return;
    if (completion.committed) {
        const base_dir = if (model.preferences_edit.saved.worktrees_base_dir.len > 0)
            model.preferences_edit.saved.worktrees_base_dir.slice()
        else
            model.default_worktrees_base.slice();
        _ = model.project_store.setWorktreesBase(base_dir);
        model.worktrees_base_serial +%= 1;
    }
    model.status_text = completion.message;
}

pub fn handleProfilesLoadResult(model: *Model, result: native_sdk.EffectDbResult) void {
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

pub fn handleProfileWriteResult(model: *Model, fx: *Effects, result: native_sdk.EffectDbResult) void {
    if (result.key != profile_write_key or result.kind != .exec) return;
    const completed = model.profile_edit.finishWrite(result.outcome == .ok, result.outcome == .busy);
    if (completed.reload) reloadProfiles(model, fx, completed.select_id.slice());
    model.status_text = completed.message;
}

pub fn editProfileDraft(model: *Model, field: profile_editor.TextField, edit: canvas.TextInputEvent) void {
    model.profile_edit.edit(field, edit);
}

pub fn finishPreferencesLoad(model: *Model, fx: *Effects) void {
    if (model.sidebar_persistence.restore(model.preferences_edit.saved.sidebar_width)) |width| model.sidebar_width = width;
    const base_dir = if (model.preferences_edit.saved.worktrees_base_dir.len > 0)
        model.preferences_edit.saved.worktrees_base_dir.slice()
    else
        model.default_worktrees_base.slice();
    _ = model.project_store.setWorktreesBase(base_dir);
    model.worktrees_base_serial +%= 1;
    workspace_actions.beginProjectRestore(model, fx);
}

pub fn handle(model: *Model, msg: Msg, fx: *Effects) void {
    switch (msg) {
        .open_preferences => openPreferences(model),
        .open_claude_preferences => {
            openPreferences(model);
            openProfileSection(model, .claude);
        },
        .close_preferences => closePreferences(model),
        .show_preferences_general => model.preferences_edit.select(.general),
        .show_preferences_appearance => model.preferences_edit.select(.appearance),
        .show_preferences_worktrees => model.preferences_edit.select(.worktrees),
        .show_preferences_claude => openProfileSection(model, .claude),
        .show_preferences_codex => openProfileSection(model, .codex),
        .edit_preferences_search => |edit| model.preferences_edit.search.apply(edit),
        .toggle_preferences_reopen => model.preferences_edit.toggleReopen(),
        .use_system_appearance => model.preferences_edit.setAppearance(.system),
        .use_light_appearance => model.preferences_edit.setAppearance(.light),
        .use_dark_appearance => model.preferences_edit.setAppearance(.dark),
        .edit_preferences_base_dir => |edit| model.preferences_edit.editBaseDir(edit),
        .save_preferences => savePreferences(model, fx),
        .preferences_load_done => |result| handlePreferencesLoadResult(model, fx, result),
        .preferences_db_done => |result| handlePreferencesWriteResult(model, result),
        .reload_profiles => {
            if (model.profile_edit.requestReload(model.profile_store)) reloadProfiles(model, fx, model.profile_edit.draft.database_id.text());
        },
        .profiles_load_done => |result| handleProfilesLoadResult(model, result),
        .profile_db_done => |result| handleProfileWriteResult(model, fx, result),
        .new_profile => createProfileDraft(model),
        .select_profile => |id| model.profile_edit.select(model.profile_store, id),
        .confirm_profile_switch => {
            if (model.profile_edit.confirmSwitch(model.profile_store)) |target| switch (target) {
                .agent, .new => |agent| model.preferences_edit.select(if (agent == .codex) .codex else .claude),
                .close => {
                    _ = model.preferences_edit.closeDialog();
                },
                .profile => {},
                .reload => reloadProfiles(model, fx, model.profile_edit.draft.database_id.text()),
            };
        },
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
        else => unreachable,
    }
}
