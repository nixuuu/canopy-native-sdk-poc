//! One schema for the profile JSON dialect, editor mapping and validation.
const std = @import("std");
pub const short_capacity = 512;
pub const long_capacity = 4096;
pub const Field = struct {
    name: []const u8,
    wire: []const u8,
    choices: []const []const u8 = &.{},
    json_object: bool = false,
};
pub const text = [_]Field{
    .{ .name = "model", .wire = "model" },
    .{ .name = "custom_env", .wire = "customEnv", .json_object = true },
    .{ .name = "settings_json", .wire = "settingsJson", .json_object = true },
    .{ .name = "permission_mode", .wire = "permissionMode", .choices = &.{ "plan", "auto", "acceptEdits", "bypassPermissions" } },
    .{ .name = "effort_level", .wire = "effortLevel", .choices = &.{ "low", "medium", "high", "xhigh", "max" } },
    .{ .name = "append_system_prompt", .wire = "appendSystemPrompt" },
    .{ .name = "base_url", .wire = "baseUrl" },
    .{ .name = "provider", .wire = "provider", .choices = &.{ "bedrock", "vertex", "foundry" } },
    .{ .name = "approval_mode", .wire = "approvalMode", .choices = &.{ "untrusted", "on-request", "never" } },
    .{ .name = "sandbox", .wire = "sandbox", .choices = &.{ "read-only", "workspace-write", "danger-full-access" } },
    .{ .name = "profile", .wire = "profile" },
};
pub const boolean = [_]Field{
    .{ .name = "full_auto", .wire = "fullAuto" },
    .{ .name = "dangerously_bypass_approvals_and_sandbox", .wire = "dangerouslyBypassApprovalsAndSandbox" },
};

pub fn valid(field: Field, value: []const u8) bool {
    if (value.len == 0) return true;
    if (std.mem.indexOfScalar(u8, value, 0) != null) return false;
    if (field.choices.len > 0) {
        for (field.choices) |choice| if (std.mem.eql(u8, choice, value)) return true;
        return false;
    }
    if (field.json_object) {
        const parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, value, .{}) catch return false;
        defer parsed.deinit();
        if (parsed.value != .object) return false;
        if (std.mem.eql(u8, field.name, "custom_env")) {
            var entries = parsed.value.object.iterator();
            while (entries.next()) |entry| {
                if (entry.value_ptr.* != .string or entry.key_ptr.len == 0 or std.mem.indexOfAny(u8, entry.key_ptr.*, "=\x00") != null or std.mem.indexOfScalar(u8, entry.value_ptr.string, 0) != null) return false;
            }
        }
    }
    return true;
}
