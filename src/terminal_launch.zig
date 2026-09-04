//! Owned handoff to the full Ghostty host. Never expose command/env to UI data.
const std = @import("std");
const sdk = @import("native_sdk");
pub const Env = extern struct { name: [*:0]const u8, value: [*:0]const u8 };
pub const Pending = struct {
    arena: std.heap.ArenaAllocator,
    command: [:0]const u8,
    original_command: [:0]const u8,
    cwd: [:0]const u8,
    env: []Env,

    pub fn create(allocator: std.mem.Allocator, cwd: []const u8, argv: []const []const u8, env: []const sdk.PtyEnvEntry) !*Pending {
        const self = try allocator.create(Pending);
        errdefer allocator.destroy(self);
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const a = arena.allocator();
        var command: std.ArrayList(u8) = .empty;
        // On macOS Ghostty wraps this as `exec -l <command>` itself.
        // An additional `exec` prefix would become the executable name.
        for (argv, 0..) |arg, index| {
            if (std.mem.indexOfScalar(u8, arg, 0) != null) return error.InvalidArgument;
            if (index != 0) try command.append(a, ' ');
            try command.append(a, '\'');
            for (arg) |ch| {
                if (ch == '\'') try command.appendSlice(a, "'\\''") else try command.append(a, ch);
            }
            try command.append(a, '\'');
        }
        const entries = try a.alloc(Env, env.len);
        for (env, entries) |entry, *out| out.* = .{ .name = try a.dupeZ(u8, entry.name), .value = try a.dupeZ(u8, entry.value) };
        const original_command = try a.dupeZ(u8, command.items);
        const explicit_no_color = for (env) |entry| {
            if (std.mem.eql(u8, entry.name, "NO_COLOR")) break true;
        } else false;
        // Build tools (including Codex) export NO_COLOR for their own output.
        // Remove it in the PTY child only, without touching the multi-threaded
        // host's environment. An explicit profile setting still wins.
        const command_z = if (explicit_no_color) original_command else try std.fmt.allocPrintSentinel(a, "'/usr/bin/env' '-u' 'NO_COLOR' {s}", .{original_command}, 0);
        const cwd_z = try a.dupeZ(u8, cwd);
        self.* = .{ .arena = arena, .command = command_z, .original_command = original_command, .cwd = cwd_z, .env = entries };
        return self;
    }

    pub fn destroy(self: *Pending) void {
        const allocator = self.arena.child_allocator;
        self.arena.deinit();
        allocator.destroy(self);
    }
};

test "Ghostty handoff owns quoted argv and environment" {
    const pending = try Pending.create(std.testing.allocator, "/tmp/a b", &.{ "/bin/sh", "a'b", "$(touch nope)", "" }, &.{.{ .name = "TEST", .value = "some value" }});
    defer pending.destroy();
    try std.testing.expectEqualStrings("'/usr/bin/env' '-u' 'NO_COLOR' '/bin/sh' 'a'\\''b' '$(touch nope)' ''", pending.command);
    try std.testing.expectEqualStrings("/tmp/a b", pending.cwd);
    try std.testing.expectEqualStrings("some value", std.mem.span(pending.env[0].value));
}

test "explicit profile NO_COLOR is preserved" {
    const pending = try Pending.create(std.testing.allocator, "/tmp", &.{"/bin/sh"}, &.{.{ .name = "NO_COLOR", .value = "1" }});
    defer pending.destroy();
    try std.testing.expectEqualStrings("'/bin/sh'", pending.command);
}
