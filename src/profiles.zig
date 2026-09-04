//! Electron Canopy-compatible agent profile storage and CLI mapping.

const std = @import("std");
const db_page = @import("db_page.zig");
const workspaces = @import("workspaces.zig");

pub const max_profile_id_bytes: usize = 128;
pub const max_profile_name_bytes: usize = 128;
pub const max_pref_bytes: usize = 512;
pub const max_long_pref_bytes: usize = 4096;

pub const IdText = workspaces.Text(max_profile_id_bytes);
pub const NameText = workspaces.Text(max_profile_name_bytes);
pub const PrefText = workspaces.Text(max_pref_bytes);
pub const LongPrefText = workspaces.Text(max_long_pref_bytes);

pub const AgentType = enum {
    claude,
    codex,

    pub fn displayName(agent: AgentType) []const u8 {
        return switch (agent) {
            .claude => "Claude Code",
            .codex => "Codex",
        };
    }

    pub fn command(agent: AgentType) []const u8 {
        return @tagName(agent);
    }
};

pub const Prefs = struct {
    model: PrefText = .{},
    custom_env: LongPrefText = .{},
    settings_json: LongPrefText = .{},
    permission_mode: PrefText = .{},
    effort_level: PrefText = .{},
    append_system_prompt: LongPrefText = .{},
    base_url: PrefText = .{},
    provider: PrefText = .{},
    approval_mode: PrefText = .{},
    sandbox: PrefText = .{},
    full_auto: bool = false,
    dangerously_bypass_approvals_and_sandbox: bool = false,
    profile: PrefText = .{},
};

pub const Profile = struct {
    runtime_id: u64,
    id: IdText = .{},
    agent_type: AgentType,
    name: NameText = .{},
    is_default: bool = false,
    sort_index: i64 = 0,
    prefs: Prefs = .{},
    has_api_key: bool = false,
};

pub const ProfileRow = struct {
    key: u64,
    id: u64,
    name: []const u8,
    selected: bool,
    is_default: bool,
    can_delete: bool,
};

pub const migration_sql =
    \\CREATE TABLE IF NOT EXISTS tool_definitions (
    \\  id TEXT PRIMARY KEY,
    \\  name TEXT NOT NULL,
    \\  command TEXT NOT NULL,
    \\  args_json TEXT NOT NULL DEFAULT '[]',
    \\  icon TEXT NOT NULL DEFAULT 'terminal',
    \\  category TEXT NOT NULL DEFAULT 'system',
    \\  is_custom INTEGER NOT NULL DEFAULT 0
    \\);
    \\INSERT OR IGNORE INTO tool_definitions (id, name, command, args_json, icon, category, is_custom) VALUES
    \\  ('claude', 'Claude Code', 'claude', '[]', 'ClaudeAI', 'ai', 0),
    \\  ('codex', 'Codex', 'codex', '[]', 'OpenAI', 'ai', 0),
    \\  ('shell', 'Shell', 'shell', '[]', 'terminal', 'shell', 0);
    \\CREATE TABLE IF NOT EXISTS agent_profiles (
    \\  id          TEXT PRIMARY KEY,
    \\  agent_type  TEXT NOT NULL,
    \\  name        TEXT NOT NULL,
    \\  is_default  INTEGER NOT NULL DEFAULT 0,
    \\  sort_index  INTEGER NOT NULL DEFAULT 0,
    \\  prefs_json  TEXT NOT NULL DEFAULT '{}',
    \\  api_key_enc TEXT,
    \\  created_at  TEXT NOT NULL DEFAULT (datetime('now')),
    \\  updated_at  TEXT NOT NULL DEFAULT (datetime('now'))
    \\);
    \\CREATE UNIQUE INDEX IF NOT EXISTS idx_agent_profiles_type_name
    \\  ON agent_profiles(agent_type, name);
    \\CREATE INDEX IF NOT EXISTS idx_agent_profiles_type_sort
    \\  ON agent_profiles(agent_type, sort_index);
    \\INSERT INTO agent_profiles (id, agent_type, name, is_default, sort_index, prefs_json)
    \\SELECT 'native-claude-default', 'claude', 'Default', 1, 0, '{}'
    \\WHERE NOT EXISTS (SELECT 1 FROM agent_profiles WHERE agent_type = 'claude');
    \\INSERT INTO agent_profiles (id, agent_type, name, is_default, sort_index, prefs_json)
    \\SELECT 'native-codex-default', 'codex', 'Default', 1, 0, '{}'
    \\WHERE NOT EXISTS (SELECT 1 FROM agent_profiles WHERE agent_type = 'codex');
;

pub const load_sql =
    \\SELECT id, agent_type, name, is_default, sort_index, prefs_json,
    \\       CASE WHEN api_key_enc IS NULL OR api_key_enc = '' THEN 0 ELSE 1 END AS has_api_key
    \\FROM agent_profiles
    \\WHERE agent_type IN ('claude', 'codex')
    \\ORDER BY agent_type, sort_index, name;
;

pub const Store = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayListUnmanaged(Profile) = .empty,
    next_runtime_id: u64 = 1,
    next_native_id: u64 = 1,

    pub fn create(allocator: std.mem.Allocator) !*Store {
        const store = try allocator.create(Store);
        store.* = .{ .allocator = allocator };
        return store;
    }

    pub fn destroy(store: *Store) void {
        const allocator = store.allocator;
        store.items.deinit(allocator);
        allocator.destroy(store);
    }

    pub fn clear(store: *Store) void {
        store.items.clearRetainingCapacity();
        store.next_runtime_id = 1;
        store.next_native_id = 1;
    }

    pub fn count(store: *const Store, agent_type: AgentType) usize {
        var result: usize = 0;
        for (store.items.items) |profile| if (profile.agent_type == agent_type) {
            result += 1;
        };
        return result;
    }

    pub fn find(store: *Store, runtime_id: u64) ?*Profile {
        for (store.items.items) |*profile| if (profile.runtime_id == runtime_id) return profile;
        return null;
    }

    pub fn findByDatabaseId(store: *Store, id: []const u8) ?*Profile {
        for (store.items.items) |*profile| if (profile.id.eql(id)) return profile;
        return null;
    }

    pub fn first(store: *Store, agent_type: AgentType) ?*Profile {
        for (store.items.items) |*profile| if (profile.agent_type == agent_type) return profile;
        return null;
    }

    pub fn default(store: *Store, agent_type: AgentType) ?*Profile {
        for (store.items.items) |*profile| if (profile.agent_type == agent_type and profile.is_default) return profile;
        return store.first(agent_type);
    }

    pub fn nameExists(store: *const Store, agent_type: AgentType, name: []const u8, except_runtime_id: u64) bool {
        for (store.items.items) |profile| {
            if (profile.runtime_id == except_runtime_id or profile.agent_type != agent_type) continue;
            if (profile.name.eql(name)) return true;
        }
        return false;
    }

    pub fn nextSortIndex(store: *const Store, agent_type: AgentType) i64 {
        var max: i64 = -1;
        for (store.items.items) |profile| if (profile.agent_type == agent_type) {
            max = @max(max, profile.sort_index);
        };
        return max + 1;
    }

    pub fn newDatabaseId(store: *Store, agent_type: AgentType, out: []u8) ?[]const u8 {
        while (true) {
            const candidate = std.fmt.bufPrint(out, "native-{s}-{d}", .{ @tagName(agent_type), store.next_native_id }) catch return null;
            store.next_native_id +%= 1;
            if (store.findByDatabaseId(candidate) == null) return candidate;
        }
    }

    pub fn rows(store: *const Store, arena: std.mem.Allocator, agent_type: AgentType, selected_runtime_id: u64) []const ProfileRow {
        const total = store.count(agent_type);
        const out = arena.alloc(ProfileRow, total) catch return &.{};
        var index: usize = 0;
        for (store.items.items) |*profile| {
            if (profile.agent_type != agent_type) continue;
            out[index] = .{
                .key = profile.runtime_id,
                .id = profile.runtime_id,
                .name = profile.name.slice(),
                .selected = profile.runtime_id == selected_runtime_id,
                .is_default = profile.is_default,
                .can_delete = total > 1,
            };
            index += 1;
        }
        return out;
    }

    pub fn appendEncodedPage(store: *Store, bytes: []const u8) bool {
        const expected = [_][]const u8{ "id", "agent_type", "name", "is_default", "sort_index", "prefs_json", "has_api_key" };
        var page = db_page.Reader.init(bytes, &expected) orelse return false;
        var decoded: std.ArrayListUnmanaged(Profile) = .empty;
        defer decoded.deinit(store.allocator);
        var next_runtime_id = store.next_runtime_id;
        for (0..page.row_count) |_| {
            const id = page.text() orelse return false;
            const agent_name = page.text() orelse return false;
            const name = page.text() orelse return false;
            const is_default = page.integer() orelse return false;
            const sort_index = page.integer() orelse return false;
            const prefs_json = page.text() orelse return false;
            const has_api_key = page.integer() orelse return false;
            const agent_type = std.meta.stringToEnum(AgentType, agent_name) orelse continue;
            var profile = Profile{ .runtime_id = next_runtime_id, .agent_type = agent_type };
            next_runtime_id +%= 1;
            if (!profile.id.set(id) or !profile.name.set(name)) return false;
            profile.is_default = is_default == 1;
            profile.sort_index = sort_index;
            profile.has_api_key = has_api_key == 1;
            decodePrefs(&profile.prefs, prefs_json);
            decoded.append(store.allocator, profile) catch return false;
        }
        if (!page.done()) return false;
        store.items.appendSlice(store.allocator, decoded.items) catch return false;
        store.next_runtime_id = next_runtime_id;
        return true;
    }
};

const PrefsWire = struct {
    model: ?[]const u8 = null,
    customEnv: ?[]const u8 = null,
    settingsJson: ?[]const u8 = null,
    permissionMode: ?[]const u8 = null,
    effortLevel: ?[]const u8 = null,
    appendSystemPrompt: ?[]const u8 = null,
    baseUrl: ?[]const u8 = null,
    provider: ?[]const u8 = null,
    approvalMode: ?[]const u8 = null,
    sandbox: ?[]const u8 = null,
    fullAuto: ?[]const u8 = null,
    dangerouslyBypassApprovalsAndSandbox: ?[]const u8 = null,
    profile: ?[]const u8 = null,
};

fn decodePrefs(out: *Prefs, json: []const u8) void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const parsed = std.json.parseFromSliceLeaky(PrefsWire, arena.allocator(), json, .{ .ignore_unknown_fields = true }) catch return;
    if (parsed.model) |value| _ = out.model.set(value);
    if (parsed.customEnv) |value| _ = out.custom_env.set(value);
    if (parsed.settingsJson) |value| _ = out.settings_json.set(value);
    if (parsed.permissionMode) |value| _ = out.permission_mode.set(value);
    if (parsed.effortLevel) |value| _ = out.effort_level.set(value);
    if (parsed.appendSystemPrompt) |value| _ = out.append_system_prompt.set(value);
    if (parsed.baseUrl) |value| _ = out.base_url.set(value);
    if (parsed.provider) |value| _ = out.provider.set(value);
    if (parsed.approvalMode) |value| _ = out.approval_mode.set(value);
    if (parsed.sandbox) |value| _ = out.sandbox.set(value);
    out.full_auto = if (parsed.fullAuto) |value| std.mem.eql(u8, value, "true") else false;
    out.dangerously_bypass_approvals_and_sandbox = if (parsed.dangerouslyBypassApprovalsAndSandbox) |value| std.mem.eql(u8, value, "true") else false;
    if (parsed.profile) |value| _ = out.profile.set(value);
}

pub fn encodePrefs(prefs: *const Prefs, out: []u8) ?[]const u8 {
    const value = .{
        .model = prefs.model.slice(),
        .customEnv = prefs.custom_env.slice(),
        .settingsJson = prefs.settings_json.slice(),
        .permissionMode = prefs.permission_mode.slice(),
        .effortLevel = prefs.effort_level.slice(),
        .appendSystemPrompt = prefs.append_system_prompt.slice(),
        .baseUrl = prefs.base_url.slice(),
        .provider = prefs.provider.slice(),
        .approvalMode = prefs.approval_mode.slice(),
        .sandbox = prefs.sandbox.slice(),
        .fullAuto = if (prefs.full_auto) "true" else "",
        .dangerouslyBypassApprovalsAndSandbox = if (prefs.dangerously_bypass_approvals_and_sandbox) "true" else "",
        .profile = prefs.profile.slice(),
    };
    var writer = std.Io.Writer.fixed(out);
    std.json.Stringify.value(value, .{}, &writer) catch return null;
    return writer.buffered();
}

test "profile preferences preserve Electron's string JSON encoding" {
    var prefs: Prefs = .{};
    try std.testing.expect(prefs.model.set("gpt-5.6"));
    try std.testing.expect(prefs.approval_mode.set("on-request"));
    prefs.full_auto = true;
    var buffer: [max_long_pref_bytes * 3]u8 = undefined;
    const json = encodePrefs(&prefs, &buffer) orelse return error.TestUnexpectedResult;
    var decoded: Prefs = .{};
    decodePrefs(&decoded, json);
    try std.testing.expectEqualStrings("gpt-5.6", decoded.model.slice());
    try std.testing.expectEqualStrings("on-request", decoded.approval_mode.slice());
    try std.testing.expect(decoded.full_auto);
}

test "profile row names reference stable store entries" {
    const store = try Store.create(std.testing.allocator);
    defer store.destroy();
    var first = Profile{ .runtime_id = 1, .agent_type = .claude };
    var second = Profile{ .runtime_id = 2, .agent_type = .claude };
    try std.testing.expect(first.name.set("Default"));
    try std.testing.expect(second.name.set("Work"));
    try store.items.append(std.testing.allocator, first);
    try store.items.append(std.testing.allocator, second);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const projected = store.rows(arena.allocator(), .claude, 2);
    try std.testing.expectEqualStrings("Default", projected[0].name);
    try std.testing.expectEqualStrings("Work", projected[1].name);
    try std.testing.expect(projected[1].selected);
}

test "malformed profile page appends nothing" {
    const malformed =
        "\x07\x00\x00\x00\x01\x00\x00\x00" ++
        "\x02\x00\x00\x00id" ++
        "\x0a\x00\x00\x00agent_type" ++
        "\x04\x00\x00\x00name" ++
        "\x0a\x00\x00\x00is_default" ++
        "\x0a\x00\x00\x00sort_index" ++
        "\x0a\x00\x00\x00prefs_json" ++
        "\x0b\x00\x00\x00has_api_key" ++
        "\x03\x01\x00\x00\x00p" ++
        "\x03\x05\x00\x00\x00codex" ++
        "\x03\x07\x00\x00\x00Default" ++
        "\x01\x01\x00\x00\x00\x00\x00\x00\x00" ++
        "\x01\x00\x00\x00\x00\x00\x00\x00\x00" ++
        "\x03\x02\x00\x00\x00{}" ++
        "\x01\x00\x00\x00\x00\x00\x00\x00\x00\xff";
    const store = try Store.create(std.testing.allocator);
    defer store.destroy();
    try std.testing.expect(!store.appendEncodedPage(malformed));
    try std.testing.expectEqual(@as(usize, 0), store.items.items.len);
    try std.testing.expectEqual(@as(u64, 1), store.next_runtime_id);
}
