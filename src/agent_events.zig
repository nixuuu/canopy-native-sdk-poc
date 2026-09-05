//! Bounded, agent-neutral hook protocol. Raw prompts, commands and auth never enter it.
const std = @import("std");
const Text = @import("workspaces.zig").Text;
pub const Kind = enum {
    session_start,
    session_end,
    prompt,
    before_tool,
    after_tool,
    tool_failure,
    permission,
    idle,
    failure,
    before_compact,
    after_compact,
    notification,
    subagent_start,
    subagent_stop,
    task_complete,
    teammate_idle,
    interrupt,
    status,
    unknown,
    pub fn label(self: Kind) []const u8 {
        return switch (self) {
            .session_start => "Session started",
            .session_end => "Session ended",
            .prompt => "Prompt submitted",
            .before_tool => "Tool started",
            .after_tool => "Tool finished",
            .tool_failure => "Tool failed",
            .permission => "Permission requested",
            .idle => "Turn finished",
            .failure => "Error",
            .before_compact => "Compaction started",
            .after_compact => "Compaction finished",
            .notification => "Notification",
            .subagent_start => "Subagent started",
            .subagent_stop => "Subagent finished",
            .task_complete => "Task completed",
            .teammate_idle => "Teammate idle",
            .interrupt => "Interrupted",
            .status => "Usage updated",
            .unknown => "Other event",
        };
    }
};

pub const Event = struct {
    tab: u64 = 0,
    sequence: u64 = 0,
    kind: Kind = .unknown,
    session: Text(128) = .{},
    tool: Text(64) = .{},
    detail: Text(256) = .{},
    agent_id: Text(128) = .{},
    model: Text(128) = .{},
    new_session: bool = false,
    context_percent: ?f64 = null,
    cost_usd: ?f64 = null,
};

pub fn text(out: anytype, value: []const u8) void {
    var length = @min(value.len, out.bytes.len);
    while (length > 0 and !std.unicode.utf8ValidateSlice(value[0..length])) length -= 1;
    _ = out.set(value[0..length]);
    for (out.bytes[0..out.len]) |*ch| if (ch.* < 32 or ch.* == 127) {
        ch.* = ' ';
    };
}

fn get(value: std.json.Value, key: []const u8) std.json.Value {
    return if (value == .object) value.object.get(key) orelse .null else .null;
}
fn string(value: std.json.Value) []const u8 {
    return if (value == .string) value.string else "";
}
fn number(value: std.json.Value) ?f64 {
    const n: f64 = switch (value) {
        .integer => @floatFromInt(value.integer),
        .float => value.float,
        else => return null,
    };
    return if (std.math.isFinite(n) and n >= 0) n else null;
}

pub const Hook = struct { name: []const u8, kind: Kind, claude: bool = true, codex: bool = true };
pub const hooks = [_]Hook{
    .{ .name = "SessionStart", .kind = .session_start },                  .{ .name = "SessionEnd", .kind = .session_end },
    .{ .name = "UserPromptSubmit", .kind = .prompt },                     .{ .name = "PreToolUse", .kind = .before_tool },
    .{ .name = "PostToolUse", .kind = .after_tool },                      .{ .name = "PostToolUseFailure", .kind = .tool_failure, .codex = false },
    .{ .name = "PermissionRequest", .kind = .permission },                .{ .name = "Stop", .kind = .idle },
    .{ .name = "StopFailure", .kind = .failure, .codex = false },         .{ .name = "PreCompact", .kind = .before_compact },
    .{ .name = "PostCompact", .kind = .after_compact },                   .{ .name = "Notification", .kind = .notification, .codex = false },
    .{ .name = "SubagentStart", .kind = .subagent_start },                .{ .name = "SubagentStop", .kind = .subagent_stop },
    .{ .name = "TaskCompleted", .kind = .task_complete, .codex = false }, .{ .name = "TeammateIdle", .kind = .teammate_idle, .codex = false },
    .{ .name = "Interrupt", .kind = .interrupt, .claude = false },
};

pub fn normalize(allocator: std.mem.Allocator, body: []const u8, status: bool) !Event {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();
    const raw = parsed.value;
    if (raw != .object) return error.InvalidHook;
    var event: Event = .{};
    if (status) {
        event.kind = .status;
        text(&event.model, string(get(get(raw, "model"), "display_name")));
        if (event.model.len == 0) text(&event.model, string(get(get(raw, "model"), "id")));
        event.context_percent = number(get(get(raw, "context_window"), "used_percentage"));
        if (event.context_percent) |percent| if (percent > 100) {
            event.context_percent = null;
        };
        event.cost_usd = number(get(get(raw, "cost"), "total_cost_usd"));
    } else {
        const name = string(get(raw, "hook_event_name"));
        if (name.len == 0) return error.InvalidHook;
        for (hooks) |hook| if (std.mem.eql(u8, name, hook.name)) {
            event.kind = hook.kind;
            break;
        };
        text(&event.model, string(get(raw, "model")));
        text(&event.tool, string(get(raw, "tool_name")));
        const input = get(raw, "tool_input");
        // Prefer a human description/file path; never copy raw shell commands or tool output.
        text(&event.detail, string(get(input, "description")));
        if (event.detail.len == 0) text(&event.detail, string(get(input, "file_path")));
        if (event.kind == .notification or event.kind == .failure or event.kind == .tool_failure)
            text(&event.detail, string(get(raw, if (event.kind == .notification) "message" else "error")));
        if (event.kind == .task_complete) text(&event.detail, string(get(raw, "task_subject")));
        const notification = string(get(raw, "notification_type"));
        if (event.kind == .notification and std.mem.eql(u8, notification, "permission_prompt")) event.kind = .permission;
        const source = string(get(raw, "source"));
        event.new_session = std.mem.eql(u8, source, "clear");
    }
    text(&event.session, string(get(raw, "session_id")));
    text(&event.agent_id, string(get(raw, "agent_id")));
    return event;
}

// SDK channels carry only this sanitized wire shape (well below their 4 KiB cap).
pub const Wire = struct {
    tab: u64,
    sequence: u64,
    kind: Kind,
    session: []const u8 = "",
    tool: []const u8 = "",
    detail: []const u8 = "",
    agent_id: []const u8 = "",
    model: []const u8 = "",
    new_session: bool = false,
    context_percent: ?f64 = null,
    cost_usd: ?f64 = null,
};
pub fn encode(event: *const Event, buffer: []u8) ![]const u8 {
    var writer = std.Io.Writer.fixed(buffer);
    const wire: Wire = .{ .tab = event.tab, .sequence = event.sequence, .kind = event.kind, .session = event.session.slice(), .tool = event.tool.slice(), .detail = event.detail.slice(), .agent_id = event.agent_id.slice(), .model = event.model.slice(), .new_session = event.new_session, .context_percent = event.context_percent, .cost_usd = event.cost_usd };
    try std.json.Stringify.value(wire, .{}, &writer);
    return writer.buffered();
}
pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !Event {
    const parsed = try std.json.parseFromSlice(Wire, allocator, bytes, .{});
    defer parsed.deinit();
    const wire = parsed.value;
    var event: Event = .{ .tab = wire.tab, .sequence = wire.sequence, .kind = wire.kind, .new_session = wire.new_session, .context_percent = wire.context_percent, .cost_usd = wire.cost_usd };
    text(&event.session, wire.session);
    text(&event.tool, wire.tool);
    text(&event.detail, wire.detail);
    text(&event.agent_id, wire.agent_id);
    text(&event.model, wire.model);
    return event;
}
