//! Compatibility layer for Electron Canopy's `preferences(key,value)` table.

const std = @import("std");
const db_page = @import("db_page.zig");
const native_sdk = @import("native_sdk");
const workspaces = @import("workspaces.zig");

pub const key_reopen_last_workspace = "reopenLastWorkspace";
pub const key_font_size = "fontSize";
pub const key_worktrees_base_dir = "worktrees.baseDir";
pub const key_native_appearance = "native.appearance";
pub const key_sidebar_width = "sidebar.width";
pub const sidebar_upsert_sql = "INSERT OR REPLACE INTO preferences (key, value) VALUES ('sidebar.width', ?1);";

pub const AppearanceMode = enum { system, light, dark };

pub const ensure_schema_sql =
    \\CREATE TABLE IF NOT EXISTS preferences (
    \\  key TEXT PRIMARY KEY,
    \\  value TEXT NOT NULL
    \\);
;

pub const Values = struct {
    reopen_last_workspace: bool = true,
    font_size: u8 = 13,
    appearance_mode: AppearanceMode = .system,
    worktrees_base_dir: workspaces.PathText = .{},
    sidebar_width: ?f32 = null,

    pub fn apply(values: *Values, key: []const u8, value: []const u8) void {
        if (std.mem.eql(u8, key, key_sidebar_width)) {
            const parsed = std.fmt.parseFloat(f32, value) catch return;
            if (std.math.isFinite(parsed) and parsed >= 1 and parsed <= 100_000) values.sidebar_width = parsed;
        } else if (std.mem.eql(u8, key, key_reopen_last_workspace)) {
            values.reopen_last_workspace = !std.mem.eql(u8, value, "false");
        } else if (std.mem.eql(u8, key, key_font_size)) {
            const parsed = std.fmt.parseInt(u8, value, 10) catch return;
            if (parsed >= 8 and parsed <= 24) values.font_size = parsed;
        } else if (std.mem.eql(u8, key, key_worktrees_base_dir)) {
            if (value.len == 0) {
                values.worktrees_base_dir.len = 0;
            } else if (std.fs.path.isAbsolute(value)) {
                _ = values.worktrees_base_dir.set(value);
            }
        } else if (std.mem.eql(u8, key, key_native_appearance)) {
            values.appearance_mode = std.meta.stringToEnum(AppearanceMode, value) orelse .system;
        }
    }

    pub fn effectiveAppearance(values: *const Values, system: native_sdk.Appearance) native_sdk.Appearance {
        var effective = system;
        effective.color_scheme = switch (values.appearance_mode) {
            .system => system.color_scheme,
            .light => .light,
            .dark => .dark,
        };
        return effective;
    }
};

pub const load_sql =
    \\SELECT key, value
    \\FROM preferences
    \\WHERE key IN ('reopenLastWorkspace', 'fontSize', 'worktrees.baseDir', 'native.appearance', 'sidebar.width')
    \\ORDER BY key;
;

pub fn decodePage(values: *Values, bytes: []const u8) bool {
    var page = db_page.Reader.init(bytes, &.{ "key", "value" }) orelse return false;
    var decoded = values.*;
    for (0..page.row_count) |_| {
        const key = page.text() orelse return false;
        const value = page.text() orelse return false;
        decoded.apply(key, value);
    }
    if (!page.done()) return false;
    values.* = decoded;
    return true;
}

test "Electron-compatible preferences decode and clamp values" {
    var values: Values = .{};
    values.apply(key_reopen_last_workspace, "false");
    values.apply(key_font_size, "18");
    values.apply(key_native_appearance, "dark");
    values.apply(key_worktrees_base_dir, "/tmp/canopy-worktrees");
    try std.testing.expect(!values.reopen_last_workspace);
    try std.testing.expectEqual(@as(u8, 18), values.font_size);
    try std.testing.expectEqual(AppearanceMode.dark, values.appearance_mode);
    try std.testing.expectEqualStrings("/tmp/canopy-worktrees", values.worktrees_base_dir.slice());
    values.apply(key_font_size, "99");
    try std.testing.expectEqual(@as(u8, 18), values.font_size);
}

test "sidebar width accepts Electron numeric text and rejects corrupt values" {
    var values: Values = .{};
    try std.testing.expectEqual(@as(?f32, null), values.sidebar_width);
    values.apply(key_sidebar_width, "375");
    try std.testing.expectEqual(@as(?f32, 375), values.sidebar_width);
    for ([_][]const u8{ "", "bad", "NaN", "inf", "-1", "0", "9999999999" }) |invalid| {
        values.apply(key_sidebar_width, invalid);
        try std.testing.expectEqual(@as(?f32, 375), values.sidebar_width);
    }
}

test "malformed preference page leaves the previous values unchanged" {
    const malformed =
        "\x02\x00\x00\x00\x01\x00\x00\x00" ++
        "\x03\x00\x00\x00key\x05\x00\x00\x00value" ++
        "\x03\x13\x00\x00\x00reopenLastWorkspace" ++
        "\x03\x05\x00\x00\x00false\xff";
    var values: Values = .{};
    try std.testing.expect(!decodePage(&values, malformed));
    try std.testing.expect(values.reopen_last_workspace);
}
