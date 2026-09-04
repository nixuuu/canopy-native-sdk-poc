//! Pure, bounded argv/environment construction for agent CLI PTYs.

const std = @import("std");
const native_sdk = @import("native_sdk");
const profiles = @import("profiles.zig");

const max_args: usize = 32;
const posix_bootstrap = "cd -- \"$1\" && shift && exec \"$@\"";
const fish_bootstrap = "cd -- $argv[1]; and exec $argv[2..-1]";

const blocked_environment = [_][]const u8{
    "PATH",                "HOME",                         "USER",                "SHELL",                 "TERM",
    "LD_PRELOAD",          "LD_LIBRARY_PATH",              "LD_AUDIT",            "DYLD_INSERT_LIBRARIES", "DYLD_LIBRARY_PATH",
    "DYLD_FRAMEWORK_PATH", "NODE_OPTIONS",                 "NODE_EXTRA_CA_CERTS", "ELECTRON_RUN_AS_NODE",  "PYTHONPATH",
    "PYTHONHOME",          "RUBYLIB",                      "PERL5LIB",            "CLASSPATH",             "JAVA_TOOL_OPTIONS",
    "_JAVA_OPTIONS",       "GIT_SSH_COMMAND",              "GIT_ASKPASS",         "SSH_AUTH_SOCK",         "EDITOR",
    "VISUAL",              "HTTP_PROXY",                   "HTTPS_PROXY",         "ALL_PROXY",             "FTP_PROXY",
    "NO_PROXY",            "SSL_CERT_FILE",                "SSL_CERT_DIR",        "REQUESTS_CA_BUNDLE",    "CURL_CA_BUNDLE",
    "GIT_SSL_CAINFO",      "NODE_TLS_REJECT_UNAUTHORIZED", "CC",                  "CXX",                   "LDFLAGS",
    "CFLAGS",              "CANOPY_HOOK_PORT",             "CANOPY_HOOK_PATH",    "CANOPY_HOOK_TOKEN",
};

pub const Spec = struct {
    argv_items: [max_args][]const u8 = undefined,
    argv_len: usize = 0,
    env_items: [native_sdk.max_effect_pty_env_entries]native_sdk.PtyEnvEntry = undefined,
    env_len: usize = 0,

    pub fn build(
        arena: std.mem.Allocator,
        shell: []const u8,
        workspace_path: []const u8,
        executable: []const u8,
        profile: *const profiles.Profile,
    ) ?Spec {
        if (shell.len == 0 or workspace_path.len == 0 or executable.len == 0) return null;
        var spec: Spec = .{};
        if (!spec.putEnv("SHELL", shell) or !spec.putEnv("COLORTERM", "truecolor")) return null;
        if (std.mem.eql(u8, std.fs.path.basename(shell), "fish")) {
            if (!spec.appendArgs(&.{ shell, "-lc", fish_bootstrap, workspace_path, executable })) return null;
        } else {
            if (!spec.appendArgs(&.{ shell, "-lc", posix_bootstrap, "canopy-tool", workspace_path, executable })) return null;
        }

        const prefs = &profile.prefs;
        switch (profile.agent_type) {
            .claude => {
                if (!spec.appendPair("--settings", prefs.settings_json.slice())) return null;
                if (!spec.appendPair("--model", prefs.model.slice())) return null;
                if (!spec.appendPair("--permission-mode", prefs.permission_mode.slice())) return null;
                if (!spec.appendPair("--effort", prefs.effort_level.slice())) return null;
                if (!spec.appendPair("--append-system-prompt", prefs.append_system_prompt.slice())) return null;
                if (!spec.putOptionalEnv("ANTHROPIC_BASE_URL", prefs.base_url.slice())) return null;
                if (prefs.provider.eql("bedrock") and !spec.putEnv("CLAUDE_CODE_USE_BEDROCK", "1")) return null;
                if (prefs.provider.eql("vertex") and !spec.putEnv("CLAUDE_CODE_USE_VERTEX", "1")) return null;
                if (prefs.provider.eql("foundry") and !spec.putEnv("CLAUDE_CODE_USE_FOUNDRY", "1")) return null;
            },
            .codex => {
                if (!spec.appendArgs(&.{ "--enable", "hooks" })) return null;
                if (!spec.appendPair("--model", prefs.model.slice())) return null;
                if (prefs.dangerously_bypass_approvals_and_sandbox) {
                    if (!spec.appendArg("--dangerously-bypass-approvals-and-sandbox")) return null;
                } else {
                    if (!spec.appendPair("--ask-for-approval", prefs.approval_mode.slice())) return null;
                    if (!spec.appendPair("--sandbox", prefs.sandbox.slice())) return null;
                    if (prefs.full_auto and !spec.appendArg("--full-auto")) return null;
                }
                if (!spec.appendPair("--profile", prefs.profile.slice())) return null;
                if (!spec.putOptionalEnv("OPENAI_BASE_URL", prefs.base_url.slice())) return null;
            },
        }
        spec.appendCustomEnv(arena, prefs.custom_env.slice());
        return spec;
    }

    pub fn argv(spec: *const Spec) []const []const u8 {
        return spec.argv_items[0..spec.argv_len];
    }

    pub fn env(spec: *const Spec) []const native_sdk.PtyEnvEntry {
        return spec.env_items[0..spec.env_len];
    }

    fn appendArg(spec: *Spec, value: []const u8) bool {
        if (spec.argv_len == spec.argv_items.len) return false;
        spec.argv_items[spec.argv_len] = value;
        spec.argv_len += 1;
        return true;
    }

    fn appendArgs(spec: *Spec, values: []const []const u8) bool {
        for (values) |value| if (!spec.appendArg(value)) return false;
        return true;
    }

    fn appendPair(spec: *Spec, flag: []const u8, value: []const u8) bool {
        return value.len == 0 or spec.appendArgs(&.{ flag, value });
    }

    fn putEnv(spec: *Spec, name: []const u8, value: []const u8) bool {
        if (name.len == 0 or spec.env_len == spec.env_items.len) return false;
        spec.env_items[spec.env_len] = .{ .name = name, .value = value };
        spec.env_len += 1;
        return true;
    }

    fn putOptionalEnv(spec: *Spec, name: []const u8, value: []const u8) bool {
        return value.len == 0 or spec.putEnv(name, value);
    }

    fn appendCustomEnv(spec: *Spec, arena: std.mem.Allocator, source: []const u8) void {
        if (source.len == 0) return;
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, source, .{}) catch return;
        const object = switch (parsed) {
            .object => |value| value,
            else => return,
        };
        var iterator = object.iterator();
        while (iterator.next()) |entry| {
            if (!environmentAllowed(entry.key_ptr.*)) continue;
            const value = switch (entry.value_ptr.*) {
                .string => |text| text,
                else => continue,
            };
            _ = spec.putEnv(entry.key_ptr.*, value);
        }
    }
};

pub fn resolvedExecutable(output: []const u8) ?[]const u8 {
    var result: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or !std.fs.path.isAbsolute(line) or std.mem.indexOfScalar(u8, line, 0) != null) continue;
        result = line;
    }
    return result;
}

fn environmentAllowed(name: []const u8) bool {
    for (blocked_environment) |blocked| if (std.ascii.eqlIgnoreCase(name, blocked)) return false;
    return true;
}

test "fish spec keeps argv boundaries and filters protected environment" {
    var profile = profiles.Profile{ .runtime_id = 1, .agent_type = .codex };
    _ = profile.prefs.model.set("gpt-5.6");
    _ = profile.prefs.custom_env.set("{\"SAFE\":\"yes\",\"PATH\":\"blocked\"}");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const spec = Spec.build(arena.allocator(), "/opt/homebrew/bin/fish", "/tmp/a project", "/Users/test/.bun/bin/codex", &profile) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("/opt/homebrew/bin/fish", spec.argv()[0]);
    try std.testing.expectEqualStrings("/tmp/a project", spec.argv()[3]);
    try std.testing.expectEqualStrings("/Users/test/.bun/bin/codex", spec.argv()[4]);
    try std.testing.expectEqualStrings("--enable", spec.argv()[5]);
    try std.testing.expectEqualStrings("SAFE", spec.env()[2].name);
    try std.testing.expectEqualStrings("yes", spec.env()[2].value);
    for (spec.env()) |entry| try std.testing.expect(!std.ascii.eqlIgnoreCase(entry.name, "PATH"));
}
