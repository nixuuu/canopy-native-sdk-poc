//! Pure agent lifecycle, independent of PTY output.
const std = @import("std");
const events = @import("agent_events.zig");
const Text = @import("workspaces.zig").Text;
pub const Status = enum {
    starting,
    idle,
    thinking,
    tool,
    permission,
    compacting,
    failed,
    ended,
    pub fn label(self: Status) []const u8 {
        return switch (self) {
            .starting => "Waiting for hooks",
            .idle => "Idle",
            .thinking => "Thinking",
            .tool => "Using tool",
            .permission => "Needs permission",
            .compacting => "Compacting",
            .failed => "Error",
            .ended => "Ended",
        };
    }
    pub fn priority(self: Status) u8 {
        return switch (self) {
            .permission => 6,
            .failed => 5,
            .thinking, .tool, .compacting => 4,
            .idle => 3,
            .starting => 2,
            .ended => 1,
        };
    }
};
pub const State = struct {
    registered: bool = false,
    connected: bool = false,
    status: Status = .starting,
    session: Text(128) = .{},
    model: Text(128) = .{},
    tool: Text(64) = .{},
    detail: Text(256) = .{},
    last_sequence: u64 = 0,
    tool_count: usize = 0,
    compact_count: usize = 0,
    tasks_completed: usize = 0,
    unread: bool = false,
    lost_events: u64 = 0,
    context_percent: ?f64 = null,
    cost_usd: ?f64 = null,
    subagents: [16]Text(128) = @splat(.{}),
    subagent_count: usize = 0,

    pub fn receive(self: *State, event: events.Event, viewed: bool, lost: u32) void {
        if (event.sequence <= self.last_sequence) return;
        if (self.status == .ended and !(event.kind == .session_start and event.new_session)) return;
        self.last_sequence = event.sequence;
        self.lost_events +|= lost;
        // A child inherits the hook transport, but its Stop must not idle its parent.
        if (event.session.len > 0) {
            if (self.session.len == 0 and event.agent_id.len == 0 and event.kind != .subagent_start and event.kind != .subagent_stop) self.session = event.session;
            if (!self.session.eql(event.session.slice()) and self.session.len > 0) {
                if (event.kind == .session_start and event.new_session and event.agent_id.len == 0) {
                    self.session = event.session;
                    self.tool_count = 0;
                    self.compact_count = 0;
                    self.tasks_completed = 0;
                    self.subagent_count = 0;
                    self.context_percent = null;
                    self.cost_usd = null;
                    self.lost_events = 0;
                } else return;
            }
        }
        self.connected = true;
        if (event.model.len > 0) self.model = event.model;
        if (event.context_percent) |value| if (std.math.isFinite(value) and value >= 0 and value <= 100) {
            self.context_percent = value;
        };
        if (event.cost_usd) |value| if (std.math.isFinite(value) and value >= 0) {
            self.cost_usd = value;
        };
        switch (event.kind) {
            .session_start => {
                self.status = .idle;
                self.tool.len = 0;
                self.detail.len = 0;
            },
            .prompt, .after_compact => {
                self.status = .thinking;
                self.tool.len = 0;
            },
            .before_tool => {
                self.status = .tool;
                self.tool = event.tool;
                self.detail = event.detail;
            },
            .after_tool, .tool_failure => {
                self.tool_count +|= 1;
                self.status = .thinking;
                self.tool.len = 0;
                self.detail = event.detail;
            },
            .permission => {
                self.status = .permission;
                self.tool = event.tool;
                self.detail = event.detail;
            },
            .idle, .interrupt => {
                self.status = .idle;
                self.tool.len = 0;
            },
            .failure => {
                self.status = .failed;
                self.detail = event.detail;
            },
            .before_compact => {
                self.status = .compacting;
                self.compact_count +|= 1;
            },
            .session_end => self.status = .ended,
            .subagent_start => {
                if (event.agent_id.len > 0) {
                    for (self.subagents[0..self.subagent_count]) |id| if (id.eql(event.agent_id.slice())) return;
                    if (self.subagent_count < self.subagents.len) {
                        self.subagents[self.subagent_count] = event.agent_id;
                        self.subagent_count += 1;
                    }
                }
            },
            .subagent_stop => {
                for (self.subagents[0..self.subagent_count], 0..) |id, i| if (id.eql(event.agent_id.slice())) {
                    self.subagent_count -= 1;
                    self.subagents[i] = self.subagents[self.subagent_count];
                    break;
                };
            },
            .task_complete => self.tasks_completed +|= 1,
            .notification => self.detail = event.detail,
            .teammate_idle, .status, .unknown => {},
        }
        if (!viewed and (event.kind == .idle or event.kind == .failure or event.kind == .permission or event.kind == .session_end or event.kind == .notification)) self.unread = true;
        if (viewed) self.unread = false;
    }

    pub fn processEnded(self: *State, clean: bool) void {
        self.status = if (clean) .ended else .failed;
        self.subagent_count = 0;
    }
    pub fn label(self: *const State) []const u8 {
        return if (self.lost_events > 0 and self.status != .ended and self.status != .failed) "Tracking gap" else self.status.label();
    }
    pub fn summary(self: *const State, allocator: std.mem.Allocator) []const u8 {
        return std.fmt.allocPrint(allocator, "{s}{s}{s} · {d} tools · {d} compactions · {d} subagents", .{
            self.model.slice(),
            if (self.model.len > 0 and self.tool.len > 0) " · " else "",
            self.tool.slice(),
            self.tool_count,
            self.compact_count,
            self.subagent_count,
        }) catch "Agent details unavailable";
    }
};
