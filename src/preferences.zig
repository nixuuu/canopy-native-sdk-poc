//! Compatibility layer for Electron Canopy's `preferences(key,value)` table.

const std = @import("std");
const native_sdk = @import("native_sdk");
const workspaces = @import("workspaces.zig");

pub const key_reopen_last_workspace = "reopenLastWorkspace";
pub const key_font_size = "fontSize";
pub const key_worktrees_base_dir = "worktrees.baseDir";
pub const key_native_appearance = "native.appearance";

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

    pub fn apply(values: *Values, key: []const u8, value: []const u8) void {
        if (std.mem.eql(u8, key, key_reopen_last_workspace)) {
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
    \\WHERE key IN ('reopenLastWorkspace', 'fontSize', 'worktrees.baseDir', 'native.appearance')
    \\ORDER BY key;
;

pub fn decodePage(values: *Values, bytes: []const u8) bool {
    var at: usize = 0;
    const column_count = readInt(u32, bytes, &at) orelse return false;
    const row_count = readInt(u32, bytes, &at) orelse return false;
    if (column_count != 2) return false;
    const first_column = readBytes(bytes, &at) orelse return false;
    const second_column = readBytes(bytes, &at) orelse return false;
    if (!std.mem.eql(u8, first_column, "key") or !std.mem.eql(u8, second_column, "value")) return false;
    for (0..row_count) |_| {
        const key = readTextValue(bytes, &at) orelse return false;
        const value = readTextValue(bytes, &at) orelse return false;
        values.apply(key, value);
    }
    return at == bytes.len;
}

fn readTextValue(bytes: []const u8, at: *usize) ?[]const u8 {
    if (at.* >= bytes.len or bytes[at.*] != 3) return null;
    at.* += 1;
    return readBytes(bytes, at);
}

fn readBytes(bytes: []const u8, at: *usize) ?[]const u8 {
    const len = readInt(u32, bytes, at) orelse return null;
    if (len > bytes.len - at.*) return null;
    const start = at.*;
    at.* += len;
    return bytes[start..at.*];
}

fn readInt(comptime T: type, bytes: []const u8, at: *usize) ?T {
    const width = @sizeOf(T);
    if (at.* > bytes.len or width > bytes.len - at.*) return null;
    const value = std.mem.readInt(T, bytes[at.*..][0..width], .little);
    at.* += width;
    return value;
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
