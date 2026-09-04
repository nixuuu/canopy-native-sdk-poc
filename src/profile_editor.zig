//! Profile editing, validation and write lifecycle. No SQL execution or UI IO.

const native_sdk = @import("native_sdk");
const std = @import("std");
const fields = @import("profile_fields.zig");
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
    extra_json: profiles.LongPrefText = .{},
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
            inline else => |tag| @field(draft, @tagName(tag)).apply(edit),
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
        inline for (fields.text) |field| @field(draft, field.name).set(@field(source.prefs, field.name).slice());
        inline for (fields.boolean) |field| @field(draft, field.name) = @field(source.prefs, field.name);
        draft.extra_json = source.prefs.extra_json;
    }

    pub fn create(draft: *Draft, agent_type: profiles.AgentType, name: []const u8, sort_index: i64, database_id: []const u8) void {
        draft.* = .{ .agent_type = agent_type, .is_new = true, .sort_index = sort_index };
        draft.database_id.set(database_id);
        draft.name.set(name);
    }

    pub fn toPrefs(draft: *const Draft) profiles.Prefs {
        var prefs: profiles.Prefs = .{ .extra_json = draft.extra_json };
        inline for (fields.text) |field| _ = @field(prefs, field.name).set(@field(draft, field.name).text());
        inline for (fields.boolean) |field| @field(prefs, field.name) = @field(draft, field.name);
        return prefs;
    }

    pub fn choicesValid(draft: *const Draft) bool {
        inline for (fields.text) |field| {
            if (@field(draft, field.name).truncated or !fields.valid(field, @field(draft, field.name).text())) return false;
        }
        return !draft.name.truncated;
    }
};

pub const Navigation = union(enum) { profile: u64, agent: profiles.AgentType, new: profiles.AgentType, close, reload };
pub const Write = enum { none, save, delete };
pub const Save = struct {
    is_new: bool,
    id: []const u8,
    agent: profiles.AgentType,
    name: []const u8,
    sort_index: i64,
    prefs_json: []const u8,
};
pub const Preparation = union(enum) { skip, invalid: []const u8, ready: Save };
pub const WriteResult = struct { reload: bool, message: []const u8, select_id: profiles.IdText = .{} };

pub const State = struct {
    loaded: bool = false,
    load_valid: bool = true,
    loading: bool = false,
    write: Write = .none,
    selected_id: u64 = 0,
    draft: Draft = .{},
    dirty: bool = false,
    pending_switch: ?Navigation = null,
    pending_delete: ?u64 = null,
    select_after_load: profiles.IdText = .{},

    pub fn busy(self: *const State) bool {
        return self.saving() or self.loading;
    }

    pub fn saving(self: *const State) bool {
        return self.write != .none;
    }

    pub fn load(self: *State, store: *profiles.Store, id: u64) void {
        const profile = store.find(id) orelse return;
        self.selected_id = id;
        self.draft.load(profile);
        self.dirty = false;
    }

    fn requestNavigation(self: *State, store: *profiles.Store, target: Navigation) bool {
        if (!self.loaded or self.busy()) return false;
        const same = switch (target) {
            .profile => |id| id == self.selected_id,
            .agent => |agent| self.draft.agent_type == agent and (self.selected_id != 0 or self.draft.is_new),
            else => false,
        };
        if (same) return true;
        if (self.dirty) {
            self.pending_switch = target;
            return false;
        }
        self.applyNavigation(store, target);
        return true;
    }

    fn applyNavigation(self: *State, store: *profiles.Store, target: Navigation) void {
        switch (target) {
            .profile => |id| self.load(store, id),
            .agent => |agent| {
                if (store.default(agent)) |profile| self.load(store, profile.runtime_id);
            },
            .new => |agent| {
                _ = self.createDraft(store, agent);
            },
            .close => {
                self.close(store);
            },
            .reload => {},
        }
    }

    pub fn openAgent(self: *State, store: *profiles.Store, agent: profiles.AgentType) bool {
        return self.requestNavigation(store, .{ .agent = agent });
    }

    pub fn select(self: *State, store: *profiles.Store, id: u64) void {
        _ = self.requestNavigation(store, .{ .profile = id });
    }

    pub fn requestReload(self: *State, store: *profiles.Store) bool {
        if (!self.loaded) return !self.busy();
        return self.requestNavigation(store, .reload);
    }

    pub fn requestClose(self: *State, store: *profiles.Store) bool {
        if (!self.loaded) return !self.busy();
        return self.requestNavigation(store, .close);
    }

    pub fn confirmSwitch(self: *State, store: *profiles.Store) ?Navigation {
        if (self.busy()) return null;
        const target = self.pending_switch orelse return null;
        self.pending_switch = null;
        self.dirty = false;
        self.applyNavigation(store, target);
        return target;
    }

    pub fn cancelSwitch(self: *State) void {
        self.pending_switch = null;
    }
    pub fn requestDelete(self: *State, id: u64) void {
        if (!self.busy()) self.pending_delete = id;
    }
    pub fn cancelDelete(self: *State) void {
        self.pending_delete = null;
    }

    pub fn close(self: *State, store: *profiles.Store) void {
        self.pending_switch = null;
        self.pending_delete = null;
        self.dirty = false;
        if (store.find(self.selected_id)) |profile| self.draft.load(profile);
    }

    pub fn edit(self: *State, field: TextField, input: canvas.TextInputEvent) void {
        if (self.busy()) return;
        self.draft.applyTextEdit(field, input);
        self.dirty = true;
    }

    pub fn toggleFullAuto(self: *State) void {
        if (self.busy()) return;
        self.draft.full_auto = !self.draft.full_auto;
        self.dirty = true;
    }

    pub fn toggleDangerousBypass(self: *State) void {
        if (self.busy()) return;
        self.draft.dangerously_bypass_approvals_and_sandbox = !self.draft.dangerously_bypass_approvals_and_sandbox;
        self.dirty = true;
    }

    pub fn create(self: *State, store: *profiles.Store, agent: profiles.AgentType) ?[]const u8 {
        return if (self.requestNavigation(store, .{ .new = agent })) "New profile draft" else null;
    }

    fn createDraft(self: *State, store: *profiles.Store, agent: profiles.AgentType) ?[]const u8 {
        var name_buffer: [profiles.max_profile_name_bytes]u8 = undefined;
        const name = uniqueName(store, agent, &name_buffer) orelse return "Could not allocate a profile name";
        var id_buffer: [profiles.max_profile_id_bytes]u8 = undefined;
        const id = store.newDatabaseId(agent, &id_buffer) orelse return "Could not allocate a profile id";
        self.selected_id = 0;
        self.draft.create(agent, name, store.nextSortIndex(agent), id);
        self.dirty = true;
        return "New profile draft";
    }

    pub fn beginReload(self: *State, store: *profiles.Store, select_id: []const u8) void {
        store.beginLoad();
        self.loading = true;
        self.load_valid = true;
        self.select_after_load.len = 0;
        _ = self.select_after_load.set(select_id);
    }

    pub fn finishLoad(self: *State, store: *profiles.Store, agent: profiles.AgentType) bool {
        self.loading = false;
        store.finishLoad(self.load_valid);
        if (!self.load_valid) return false;
        self.loaded = true;
        const selected = if (self.select_after_load.len > 0) store.findByDatabaseId(self.select_after_load.slice()) else null;
        if (selected orelse store.default(agent)) |profile| self.load(store, profile.runtime_id);
        self.select_after_load.len = 0;
        return true;
    }

    // Returned strings borrow the draft and caller-owned JSON scratch. Effects
    // copy them synchronously; no backend or UI state is needed in the editor.
    pub fn prepareSave(self: *State, store: *profiles.Store, json_buffer: []u8) Preparation {
        if (!self.loaded or self.busy() or !self.dirty) return .skip;
        const name = std.mem.trim(u8, self.draft.name.text(), " ");
        if (name.len == 0) return .{ .invalid = "Profile name is required" };
        if (store.nameExists(self.draft.agent_type, name, self.draft.runtime_id)) return .{ .invalid = "A profile with this name already exists" };
        if (!self.draft.choicesValid()) return .{ .invalid = "One or more profile choices are invalid" };
        const prefs = self.draft.toPrefs();
        const json = profiles.encodePrefs(&prefs, json_buffer) orelse return .{ .invalid = "Profile settings are too large" };
        self.write = .save;
        return .{ .ready = .{ .is_new = self.draft.is_new, .id = self.draft.database_id.text(), .agent = self.draft.agent_type, .name = name, .sort_index = self.draft.sort_index, .prefs_json = json } };
    }

    pub fn prepareDelete(self: *State, store: *profiles.Store) ?[]const u8 {
        const profile = store.find(self.pending_delete orelse return null) orelse return null;
        if (store.count(profile.agent_type) <= 1 or self.busy()) return null;
        self.pending_delete = null;
        self.write = .delete;
        self.select_after_load.len = 0;
        return profile.id.slice();
    }

    pub fn finishWrite(self: *State, success: bool, database_busy: bool) WriteResult {
        const operation = self.write;
        if (operation == .none) return .{ .reload = false, .message = "" };
        self.write = .none;
        if (!success) return .{ .reload = false, .message = if (database_busy) "Profiles database is busy; try again" else "Agent profile could not be saved" };
        var result: WriteResult = .{ .reload = true, .message = if (operation == .delete) "Agent profile deleted" else "Agent profile saved" };
        if (operation == .save) _ = result.select_id.set(self.draft.database_id.text());
        self.dirty = false;
        return result;
    }
};

fn uniqueName(store: *const profiles.Store, agent: profiles.AgentType, out: []u8) ?[]const u8 {
    if (!store.nameExists(agent, "New profile", 0)) return "New profile";
    var suffix: usize = 2;
    while (suffix < 1000) : (suffix += 1) {
        const candidate = std.fmt.bufPrint(out, "New profile {d}", .{suffix}) catch return null;
        if (!store.nameExists(agent, candidate, 0)) return candidate;
    }
    return null;
}

fn addTestProfile(store: *profiles.Store, runtime_id: u64, id: []const u8, name: []const u8) !void {
    var profile: profiles.Profile = .{ .runtime_id = runtime_id, .agent_type = .claude };
    _ = profile.id.set(id);
    _ = profile.name.set(name);
    const target = if (store.loading) &store.pending_items else &store.items;
    try target.append(store.allocator, profile);
}

test "validation rejects invalid draft without entering the saving state" {
    const store = try profiles.Store.create(std.testing.allocator);
    defer store.destroy();
    try addTestProfile(store, 1, "first-id", "First");
    try addTestProfile(store, 2, "other-id", "Other");
    var state: State = .{ .loaded = true };
    state.load(store, 1);
    state.dirty = true;
    var json: [profiles.max_long_pref_bytes * 3]u8 = undefined;
    state.draft.name.clear();
    try std.testing.expect(state.prepareSave(store, &json) == .invalid);
    state.draft.name.set("Other");
    try std.testing.expect(state.prepareSave(store, &json) == .invalid);
    state.draft.name.set("Edited");
    state.draft.permission_mode.set("invalid-mode");
    try std.testing.expect(state.prepareSave(store, &json) == .invalid);
    state.draft.permission_mode.set("plan");
    try std.testing.expect(state.prepareSave(store, json[0..1]) == .invalid);
    try std.testing.expect(!state.saving() and state.dirty);
    const saved = state.prepareSave(store, &json).ready;
    try std.testing.expectEqualStrings("Edited", saved.name);
    try std.testing.expectEqualStrings("first-id", saved.id);
    try std.testing.expect(state.saving());
}

test "successful save restores selection using database identity after runtime ids change" {
    const store = try profiles.Store.create(std.testing.allocator);
    defer store.destroy();
    try addTestProfile(store, 1, "first-id", "First");
    try addTestProfile(store, 2, "other-id", "Other");
    var state: State = .{ .loaded = true };
    state.load(store, 2);
    state.dirty = true;
    var json: [profiles.max_long_pref_bytes * 3]u8 = undefined;
    _ = state.prepareSave(store, &json).ready;
    const completed = state.finishWrite(true, false);
    try std.testing.expect(completed.reload and !state.dirty and !state.saving());
    state.beginReload(store, completed.select_id.slice());
    try addTestProfile(store, 50, "first-id", "First");
    try addTestProfile(store, 51, "other-id", "Other");
    try std.testing.expect(state.finishLoad(store, .claude));
    try std.testing.expectEqual(@as(u64, 51), state.selected_id);
    try std.testing.expectEqualStrings("other-id", state.draft.database_id.text());
    try std.testing.expectEqual(@as(usize, 0), state.select_after_load.len);
}

test "deletion protects the last profile and reloads the remaining default" {
    const store = try profiles.Store.create(std.testing.allocator);
    defer store.destroy();
    try addTestProfile(store, 1, "first-id", "First");
    var state: State = .{ .loaded = true };
    state.load(store, 1);
    state.requestDelete(1);
    try std.testing.expect(state.prepareDelete(store) == null);
    try std.testing.expect(!state.saving());
    state.cancelDelete();
    try addTestProfile(store, 2, "other-id", "Other");
    state.load(store, 2);
    state.requestDelete(2);
    try std.testing.expectEqualStrings("other-id", state.prepareDelete(store).?);
    try std.testing.expect(state.pending_delete == null and state.saving());
    const completed = state.finishWrite(true, false);
    try std.testing.expect(completed.reload and completed.select_id.len == 0);
    state.beginReload(store, completed.select_id.slice());
    try addTestProfile(store, 7, "first-id", "First");
    try std.testing.expect(state.finishLoad(store, .claude));
    try std.testing.expectEqual(@as(u64, 7), state.selected_id);
}
