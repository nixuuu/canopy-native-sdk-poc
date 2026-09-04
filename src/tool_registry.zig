//! Installed agent discovery and sidebar state, independent of process effects.
const std = @import("std");
const profiles = @import("profiles.zig");
const tabs = @import("terminal_tabs.zig");
const workspaces = @import("workspaces.zig");

pub const claude_check_key = @import("effect_keys.zig").key(.tools, 1);
pub const codex_check_key = @import("effect_keys.zig").key(.tools, 2);

pub const Agent = struct {
    expanded: bool = false,
    executable: workspaces.PathText = .{},

    pub fn available(self: *const Agent) bool {
        return self.executable.len > 0;
    }
};

pub const State = struct {
    claude: Agent = .{},
    codex: Agent = .{},
    pending_checks: u2 = 0b11,

    pub fn beginDiscovery(self: *State) void {
        self.claude.executable.len = 0;
        self.codex.executable.len = 0;
        self.pending_checks = 0b11;
    }

    pub fn ready(self: *const State) bool {
        return self.pending_checks == 0;
    }

    pub fn noAgentsAvailable(self: *const State) bool {
        return !self.claude.available() and !self.codex.available();
    }

    pub fn agent(self: *State, kind: profiles.AgentType) *Agent {
        return switch (kind) {
            .claude => &self.claude,
            .codex => &self.codex,
        };
    }

    pub fn agentConst(self: *const State, kind: profiles.AgentType) *const Agent {
        return switch (kind) {
            .claude => &self.claude,
            .codex => &self.codex,
        };
    }

    pub fn toggle(self: *State, kind: profiles.AgentType) void {
        const selected = self.agent(kind);
        selected.expanded = !selected.expanded;
    }

    pub fn setExecutable(self: *State, kind: profiles.AgentType, path: []const u8) bool {
        const selected = self.agent(kind);
        selected.executable.len = 0;
        if (path.len == 0 or !std.fs.path.isAbsolute(path) or std.mem.indexOfScalar(u8, path, 0) != null) return false;
        return selected.executable.set(path);
    }

    pub fn executable(self: *const State, tool: tabs.Tool) []const u8 {
        return switch (tool) {
            .shell => "",
            .claude => self.claude.executable.slice(),
            .codex => self.codex.executable.slice(),
        };
    }

    pub fn available(self: *const State, tool: tabs.Tool) bool {
        return tool == .shell or self.executable(tool).len > 0;
    }

    pub fn completeDiscovery(self: *State, key: u64, path: ?[]const u8) bool {
        const completion = switch (key) {
            claude_check_key => .{ @as(u2, 0b01), profiles.AgentType.claude },
            codex_check_key => .{ @as(u2, 0b10), profiles.AgentType.codex },
            else => return false,
        };
        if (self.pending_checks & completion[0] == 0) return false;
        self.pending_checks &= ~completion[0];
        if (path) |resolved| _ = self.setExecutable(completion[1], resolved);
        return true;
    }
};

test "discovery accepts each result once and fails closed on invalid paths" {
    var state: State = .{};
    state.beginDiscovery();
    try std.testing.expect(state.completeDiscovery(claude_check_key, "/usr/local/bin/claude"));
    try std.testing.expect(!state.completeDiscovery(claude_check_key, "/different/claude"));
    try std.testing.expectEqualStrings("/usr/local/bin/claude", state.executable(.claude));
    try std.testing.expect(!state.ready());
    try std.testing.expect(state.completeDiscovery(codex_check_key, "relative/codex"));
    try std.testing.expect(state.ready());
    try std.testing.expect(!state.available(.codex));
    try std.testing.expect(state.available(.shell));
}

test "agent expansion is independent" {
    var state: State = .{};
    state.toggle(.claude);
    try std.testing.expect(state.claude.expanded and !state.codex.expanded);
    state.toggle(.codex);
    try std.testing.expect(state.claude.expanded and state.codex.expanded);
}
