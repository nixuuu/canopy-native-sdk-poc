//! CLI transport only. No workflow, UI, project selection or teardown policy.
const std = @import("std");
const sdk = @import("native_sdk");
const workflow = @import("git_workflow.zig");
const workspaces = @import("workspaces.zig");

pub const Command = struct {
    args: [10][]const u8 = undefined,
    len: usize = 0,
    branch_ref: [workspaces.max_branch_bytes + "refs/heads/".len]u8 = undefined,

    // Build in caller-owned storage, so the formatted ref survives until spawn.
    pub fn build(self: *Command, request: workflow.Request) ![]const []const u8 {
        const argv: []const []const u8 = switch (request) {
            .directory_exists => |path| &.{ "/bin/test", "-d", path },
            .repository_root => |path| &.{ "/usr/bin/git", "-C", path, "rev-parse", "--show-toplevel" },
            .list_worktrees => |repo| &.{ "/usr/bin/git", "-C", repo, "worktree", "list", "--porcelain" },
            .validate_branch => |branch| &.{ "/usr/bin/git", "check-ref-format", "--branch", branch },
            .target_available => |path| &.{ "/bin/test", "!", "-e", path },
            .branch_exists => |args| &.{ "/usr/bin/git", "-C", args.repo, "show-ref", "--verify", "--quiet", try std.fmt.bufPrint(&self.branch_ref, "refs/heads/{s}", .{args.branch}) },
            .create_branch => |args| &.{ "/usr/bin/git", "-C", args.repo, "branch", args.branch, "HEAD" },
            .create_worktree => |args| &.{ "/usr/bin/git", "-C", args.repo, "worktree", "add", args.path, args.branch },
            .status => |path| &.{ "/usr/bin/git", "-C", path, "status", "--porcelain" },
            .submodules => |path| &.{ "/usr/bin/git", "-C", path, "config", "--file", ".gitmodules", "--get-regexp", "path" },
            .unmerged => |args| &.{ "/usr/bin/git", "-C", args.repo, "log", args.branch, "--not", if (args.detached) "--all" else "--remotes", "--oneline" },
            .remove_worktree => |args| if (args.force) &.{ "/usr/bin/git", "-C", args.repo, "worktree", "remove", "--force", args.path } else &.{ "/usr/bin/git", "-C", args.repo, "worktree", "remove", args.path },
        };
        @memcpy(self.args[0..argv.len], argv);
        self.len = argv.len;
        return self.args[0..self.len];
    }
};

pub fn execute(fx: anytype, key: u64, request: workflow.Request) !void {
    var command: Command = .{};
    const argv = try command.build(request);
    const Effects = @TypeOf(fx.*);
    fx.spawn(.{ .key = key, .argv = argv, .output = .collect, .on_exit = Effects.exitMsg(.git_done) });
}

pub fn outcome(exit: sdk.EffectExit) workflow.Outcome {
    if (exit.reason != .exited) return .failure;
    if (exit.code == 1) return .negative;
    return if (exit.code == 0 and !exit.output_truncated) .success else .failure;
}

pub fn result(exit: sdk.EffectExit) workflow.Result {
    return .{ .key = exit.key, .outcome = outcome(exit), .output = exit.output };
}

test "CLI requests preserve argument boundaries and existing Git commands" {
    const repo = "/tmp/repo with spaces";
    const path = "/tmp/worktree 'quoted'";
    const branch = "feature/test";
    const Case = struct { request: workflow.Request, argv: []const []const u8 };
    const cases = [_]Case{
        .{ .request = .{ .directory_exists = repo }, .argv = &.{ "/bin/test", "-d", repo } },
        .{ .request = .{ .repository_root = repo }, .argv = &.{ "/usr/bin/git", "-C", repo, "rev-parse", "--show-toplevel" } },
        .{ .request = .{ .list_worktrees = repo }, .argv = &.{ "/usr/bin/git", "-C", repo, "worktree", "list", "--porcelain" } },
        .{ .request = .{ .validate_branch = branch }, .argv = &.{ "/usr/bin/git", "check-ref-format", "--branch", branch } },
        .{ .request = .{ .target_available = path }, .argv = &.{ "/bin/test", "!", "-e", path } },
        .{ .request = .{ .branch_exists = .{ .repo = repo, .branch = branch } }, .argv = &.{ "/usr/bin/git", "-C", repo, "show-ref", "--verify", "--quiet", "refs/heads/feature/test" } },
        .{ .request = .{ .create_branch = .{ .repo = repo, .branch = branch } }, .argv = &.{ "/usr/bin/git", "-C", repo, "branch", branch, "HEAD" } },
        .{ .request = .{ .create_worktree = .{ .repo = repo, .path = path, .branch = branch } }, .argv = &.{ "/usr/bin/git", "-C", repo, "worktree", "add", path, branch } },
        .{ .request = .{ .status = path }, .argv = &.{ "/usr/bin/git", "-C", path, "status", "--porcelain" } },
        .{ .request = .{ .submodules = path }, .argv = &.{ "/usr/bin/git", "-C", path, "config", "--file", ".gitmodules", "--get-regexp", "path" } },
        .{ .request = .{ .unmerged = .{ .repo = repo, .branch = branch, .detached = false } }, .argv = &.{ "/usr/bin/git", "-C", repo, "log", branch, "--not", "--remotes", "--oneline" } },
        .{ .request = .{ .unmerged = .{ .repo = path, .branch = "HEAD", .detached = true } }, .argv = &.{ "/usr/bin/git", "-C", path, "log", "HEAD", "--not", "--all", "--oneline" } },
        .{ .request = .{ .remove_worktree = .{ .repo = repo, .path = path, .force = false } }, .argv = &.{ "/usr/bin/git", "-C", repo, "worktree", "remove", path } },
        .{ .request = .{ .remove_worktree = .{ .repo = repo, .path = path, .force = true } }, .argv = &.{ "/usr/bin/git", "-C", repo, "worktree", "remove", "--force", path } },
    };
    for (cases) |case| {
        var command: Command = .{};
        const actual = try command.build(case.request);
        try std.testing.expectEqual(case.argv.len, actual.len);
        for (case.argv, actual) |expected, arg| try std.testing.expectEqualStrings(expected, arg);
    }
}

test "CLI completion distinguishes negative answers from failure and truncation" {
    try std.testing.expectEqual(workflow.Outcome.success, outcome(.{ .key = 1, .code = 0 }));
    try std.testing.expectEqual(workflow.Outcome.negative, outcome(.{ .key = 1, .code = 1 }));
    try std.testing.expectEqual(workflow.Outcome.failure, outcome(.{ .key = 1, .code = 128 }));
    try std.testing.expectEqual(workflow.Outcome.failure, outcome(.{ .key = 1, .code = 0, .output_truncated = true }));
    for ([_]sdk.EffectExitReason{ .cancelled, .rejected, .spawn_failed, .signaled }) |reason| {
        try std.testing.expectEqual(workflow.Outcome.failure, outcome(.{ .key = 1, .code = 1, .reason = reason }));
    }
}
