//! Per-invocation configuration. Never edits a repository or a user's agent config.
const std = @import("std");
const events = @import("agent_events.zig");
const Agent = @import("profiles.zig").AgentType;

// Curl consumes stdin directly. No hook output or decision can reach the agent.
// A missing/unresponsive Canopy always lets the agent continue within two seconds.
pub const hook_command = "/bin/sh -c \"$CANOPY_HOOK_COMMAND\"";
pub const status_command = "/bin/sh -c \"$CANOPY_STATUS_COMMAND\"";
pub const hook_body = command("hook");
pub const status_body = command("status");
fn command(comptime endpoint: []const u8) []const u8 {
    return "if [ -n \"$CANOPY_HOOK_PORT\" ] && [ -n \"$CANOPY_HOOK_TOKEN\" ]; then /usr/bin/curl --silent --fail --connect-timeout 1 --max-time 2 --noproxy \"*\" --proxy \"\" -X POST -H \"Content-Type: application/json\" -H \"X-Canopy-Auth: $CANOPY_HOOK_TOKEN\" --data-binary @- \"http://127.0.0.1:${CANOPY_HOOK_PORT}${CANOPY_HOOK_PATH}/" ++ endpoint ++ "\" >/dev/null 2>&1; fi; exit 0";
}

pub fn build(allocator: std.mem.Allocator, agent: Agent, overrides: []const u8) ![]const u8 {
    var config = try std.json.parseFromSliceLeaky(std.json.Value, allocator, if (overrides.len == 0) "{}" else overrides, .{});
    if (config != .object) return error.InvalidSettings;
    if (config.object.get("env")) |env| {
        if (env != .object) return error.InvalidSettings;
        for ([_][]const u8{ "CANOPY_HOOK_PORT", "CANOPY_HOOK_PATH", "CANOPY_HOOK_TOKEN", "CANOPY_HOOK_COMMAND", "CANOPY_STATUS_COMMAND" }) |key|
            if (env.object.contains(key)) return error.ProtectedEnvironment;
    }
    var hooks = config.object.get("hooks") orelse std.json.Value{ .object = .empty };
    if (hooks != .object) return error.InvalidHooks;
    for (events.hooks) |hook| {
        if (!(if (agent == .claude) hook.claude else hook.codex)) continue;
        var groups = hooks.object.get(hook.name) orelse std.json.Value{ .array = .init(allocator) };
        if (groups != .array) return error.InvalidHooks;
        var handler: std.json.Value = .{ .object = .empty };
        try handler.object.put(allocator, "type", .{ .string = "command" });
        try handler.object.put(allocator, "command", .{ .string = hook_command });
        try handler.object.put(allocator, "timeout", .{ .integer = 3 });
        var handlers: std.json.Value = .{ .array = .init(allocator) };
        try handlers.array.append(handler);
        var group: std.json.Value = .{ .object = .empty };
        try group.object.put(allocator, "hooks", handlers);
        try groups.array.append(group);
        try hooks.object.put(allocator, hook.name, groups);
    }
    try config.object.put(allocator, "hooks", hooks);
    if (agent == .claude) {
        if (!config.object.contains("statusLine")) {
            var line: std.json.Value = .{ .object = .empty };
            try line.object.put(allocator, "type", .{ .string = "command" });
            try line.object.put(allocator, "command", .{ .string = status_command });
            try config.object.put(allocator, "statusLine", line);
        }
        return std.json.Stringify.valueAlloc(allocator, config, .{});
    }
    // Codex 0.153.2 loads TOML hooks from the session-flags layer independently
    // of hooks in other layers, preserving project/user hooks and their trust.
    const buffer = try allocator.alloc(u8, 64 * 1024);
    var writer = std.Io.Writer.fixed(buffer);
    try writer.writeAll("hooks=");
    try toml(&writer, hooks);
    return writer.buffered();
}

fn toml(writer: *std.Io.Writer, value: std.json.Value) anyerror!void {
    switch (value) {
        .object => |object| {
            try writer.writeAll("{");
            var iterator = object.iterator();
            var first = true;
            while (iterator.next()) |entry| {
                if (!first) try writer.writeAll(",");
                first = false;
                try std.json.Stringify.value(entry.key_ptr.*, .{}, writer);
                try writer.writeAll("=");
                try toml(writer, entry.value_ptr.*);
            }
            try writer.writeAll("}");
        },
        .array => |array| {
            try writer.writeAll("[");
            for (array.items, 0..) |item, i| {
                if (i > 0) try writer.writeAll(",");
                try toml(writer, item);
            }
            try writer.writeAll("]");
        },
        .string, .integer, .bool, .float => try std.json.Stringify.value(value, .{}, writer),
        else => return error.UnsupportedHookValue,
    }
}
