const std = @import("std");
const backend = @import("../git_libgit2.zig");
const workflow = @import("../git_workflow.zig");
const c = backend.c;
const a = std.testing.allocator;

fn ok(code: c_int) !void {
    if (code < 0) {
        const err = c.git_error_last();
        if (err != null) std.debug.print("libgit2 fixture: {s}\n", .{err.*.message});
        return error.Libgit2Fixture;
    }
}

const Fixture = struct {
    tmp: std.testing.TmpDir,
    root: [:0]u8,
    linked: [:0]u8,
    repo: *c.git_repository,

    fn init() !Fixture {
        try ok(c.git_libgit2_init());
        errdefer _ = c.git_libgit2_shutdown();
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        var buffer: [4096]u8 = undefined;
        const len = try tmp.dir.realPath(std.testing.io, &buffer);
        const root = try std.fmt.allocPrintSentinel(a, "{s}/repo with spaces", .{buffer[0..len]}, 0);
        errdefer a.free(root);
        const linked = try std.fmt.allocPrintSentinel(a, "{s}/linked 'quoted'", .{buffer[0..len]}, 0);
        errdefer a.free(linked);
        var repo: ?*c.git_repository = null;
        var options: c.git_repository_init_options = undefined;
        try ok(c.git_repository_init_options_init(&options, c.GIT_REPOSITORY_INIT_OPTIONS_VERSION));
        options.flags = c.GIT_REPOSITORY_INIT_MKPATH | c.GIT_REPOSITORY_INIT_NO_REINIT;
        options.initial_head = "main";
        try ok(c.git_repository_init_ext(&repo, root, &options));
        errdefer c.git_repository_free(repo);
        var result: Fixture = .{ .tmp = tmp, .root = root, .linked = linked, .repo = repo.? };
        _ = try result.commit("initial", null);
        return result;
    }

    fn commit(self: *Fixture, message: [:0]const u8, parent: ?*c.git_commit) !c.git_oid {
        var builder: ?*c.git_treebuilder = null;
        try ok(c.git_treebuilder_new(&builder, self.repo, null));
        defer c.git_treebuilder_free(builder);
        var blob: c.git_oid = undefined;
        try ok(c.git_blob_create_from_buffer(&blob, self.repo, "hello\n", 6));
        try ok(c.git_treebuilder_insert(null, builder, "README.md", &blob, c.GIT_FILEMODE_BLOB));
        var tree_id: c.git_oid = undefined;
        try ok(c.git_treebuilder_write(&tree_id, builder));
        var tree: ?*c.git_tree = null;
        try ok(c.git_tree_lookup(&tree, self.repo, &tree_id));
        defer c.git_tree_free(tree);
        var signature: ?*c.git_signature = null;
        try ok(c.git_signature_new(&signature, "Test", "test@example.invalid", 1700000000, 0));
        defer c.git_signature_free(signature);
        var id: c.git_oid = undefined;
        var parents = [_]?*const c.git_commit{parent};
        try ok(c.git_commit_create(&id, self.repo, "HEAD", signature, signature, null, message, tree, if (parent != null) 1 else 0, &parents));
        var object: ?*c.git_object = null;
        try ok(c.git_object_lookup(&object, self.repo, &id, c.GIT_OBJECT_COMMIT));
        defer c.git_object_free(object);
        try ok(c.git_reset(self.repo, object, c.GIT_RESET_HARD, null));
        return id;
    }

    fn deinit(self: *Fixture) void {
        c.git_repository_free(self.repo);
        a.free(self.root);
        a.free(self.linked);
        self.tmp.cleanup();
        _ = c.git_libgit2_shutdown();
    }

    fn create(self: *Fixture) !void {
        try expect(.{ .create_branch = .{ .repo = self.root, .branch = "feature/test" } }, .success, false);
        try expect(.{ .create_worktree = .{ .repo = self.root, .path = self.linked, .branch = "feature/test" } }, .success, false);
    }
};

fn expect(request: workflow.Request, outcome: workflow.Outcome, nonempty: bool) !void {
    var response = backend.execute(a, request);
    defer response.deinit(a);
    try std.testing.expectEqual(outcome, response.outcome);
    try std.testing.expectEqual(nonempty, response.output.items.len > 0);
}

test "libgit2 discovers roots and creates lists and removes a real worktree without subprocesses" {
    var f = try Fixture.init();
    defer f.deinit();
    try expect(.{ .directory_exists = f.root }, .success, false);
    try expect(.{ .list_worktrees = f.root }, .success, true);
    try expect(.{ .directory_exists = f.linked }, .negative, false);
    try expect(.{ .target_available = f.linked }, .success, false);
    try expect(.{ .branch_exists = .{ .repo = f.root, .branch = "feature/test" } }, .negative, false);
    try f.create();
    try expect(.{ .target_available = f.linked }, .negative, false);
    try expect(.{ .branch_exists = .{ .repo = f.root, .branch = "feature/test" } }, .success, false);
    try expect(.{ .create_branch = .{ .repo = f.root, .branch = "feature/test" } }, .failure, false);
    var root = backend.execute(a, .{ .repository_root = f.linked });
    defer root.deinit(a);
    try std.testing.expectEqual(.success, root.outcome);
    try std.testing.expectEqualStrings(f.root, root.output.items);
    var list = backend.execute(a, .{ .list_worktrees = f.linked });
    defer list.deinit(a);
    try std.testing.expectEqual(.success, list.outcome);
    try std.testing.expect(std.mem.indexOf(u8, list.output.items, f.root) != null);
    try std.testing.expect(std.mem.indexOf(u8, list.output.items, f.linked) != null);
    try std.testing.expect(std.mem.indexOf(u8, list.output.items, "branch refs/heads/feature/test") != null);
    try expect(.{ .status = f.linked }, .success, false);
    try expect(.{ .submodules = f.linked }, .negative, false);
    try expect(.{ .remove_worktree = .{ .repo = f.root, .path = f.linked, .force = false } }, .success, false);
    try expect(.{ .directory_exists = f.linked }, .negative, false);
    try expect(.{ .branch_exists = .{ .repo = f.root, .branch = "feature/test" } }, .success, false);
}

test "libgit2 refuses dirty locked main and foreign worktrees even with inappropriate removal requests" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.create();
    try f.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "linked 'quoted'/untracked.txt", .data = "keep me" });
    try expect(.{ .status = f.linked }, .success, true);
    try expect(.{ .remove_worktree = .{ .repo = f.root, .path = f.linked, .force = false } }, .failure, false);
    var tree: ?*c.git_worktree = null;
    try ok(c.git_worktree_lookup(&tree, f.repo, "linked 'quoted'"));
    defer c.git_worktree_free(tree);
    try ok(c.git_worktree_lock(tree, "keep"));
    try expect(.{ .remove_worktree = .{ .repo = f.root, .path = f.linked, .force = true } }, .failure, false);
    try ok(c.git_worktree_unlock(tree));
    var other = try Fixture.init();
    defer other.deinit();
    try expect(.{ .remove_worktree = .{ .repo = other.root, .path = f.linked, .force = true } }, .failure, false);
    try expect(.{ .remove_worktree = .{ .repo = f.root, .path = f.root, .force = true } }, .failure, false);
    try expect(.{ .directory_exists = f.linked }, .success, false);
    try expect(.{ .remove_worktree = .{ .repo = f.root, .path = f.linked, .force = true } }, .success, false);
}

test "libgit2 validates branches and fails closed for invalid repository input" {
    for ([_][]const u8{ "feature/test", "unicode/żółć" }) |name| try expect(.{ .validate_branch = name }, .success, false);
    for ([_][]const u8{ "", "-option", "HEAD", "a..b", "bad name", "trailing/", "@{-1}" }) |name| try expect(.{ .validate_branch = name }, .negative, false);
    try expect(.{ .repository_root = "/missing/canopy/repository" }, .failure, false);
    try expect(.{ .repository_root = "/tmp\x00/repository" }, .failure, false);
}

test "libgit2 history hides remote refs and protects detached commits and detects submodules" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.create();
    try expect(.{ .unmerged = .{ .repo = f.root, .branch = "feature/test", .detached = false } }, .success, true);
    var head: ?*c.git_reference = null;
    try ok(c.git_repository_head(&head, f.repo));
    defer c.git_reference_free(head);
    var remote: ?*c.git_reference = null;
    try ok(c.git_reference_create(&remote, f.repo, "refs/remotes/origin/main", c.git_reference_target(head), 0, null));
    defer c.git_reference_free(remote);
    try expect(.{ .unmerged = .{ .repo = f.root, .branch = "feature/test", .detached = false } }, .success, false);
    var linked: ?*c.git_repository = null;
    try ok(c.git_repository_open(&linked, f.linked));
    defer c.git_repository_free(linked);
    try ok(c.git_repository_set_head_detached(linked, c.git_reference_target(head)));
    try expect(.{ .unmerged = .{ .repo = f.linked, .branch = "HEAD", .detached = true } }, .success, false);
    var parent: ?*c.git_commit = null;
    try ok(c.git_commit_lookup(&parent, linked, c.git_reference_target(head)));
    defer c.git_commit_free(parent);
    const original = f.repo;
    f.repo = linked.?;
    _ = try f.commit("detached", parent);
    f.repo = original;
    try expect(.{ .unmerged = .{ .repo = f.linked, .branch = "HEAD", .detached = true } }, .success, true);
    try f.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "linked 'quoted'/.gitmodules", .data = "[submodule \"test\"]\n path = module\n url = ../module\n" });
    try expect(.{ .submodules = f.linked }, .success, true);
    try f.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "linked 'quoted'/.gitmodules", .data = "[invalid" });
    try expect(.{ .submodules = f.linked }, .failure, false);
}

test "Git worker owns request bytes rejects overlap and posts completion without spawning processes" {
    const app = @import("../main.zig");
    const Host = @import("../git_host.zig").Host;
    var fx = app.Effects.init(a);
    defer fx.deinit();
    fx.executor = .fake;
    var host: Host = .{};
    defer host.deinit();
    var name = [_]u8{ 'v', 'a', 'l', 'i', 'd' };
    try host.start(&fx, 10000, .{ .validate_branch = &name });
    @memset(&name, ' ');
    try std.testing.expectError(error.GitBusy, host.start(&fx, 10001, .{ .validate_branch = "next" }));
    var completion: ?workflow.Result = null;
    for (0..1000) |_| {
        completion = host.completed();
        if (completion != null) break;
        try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
    }
    const result = completion orelse return error.WorkerTimedOut;
    try std.testing.expectEqual(.success, result.outcome);
    try std.testing.expectEqual(@as(u64, 10000), result.key);
    try std.testing.expect(host.completed() == null);
    try std.testing.expectEqual(@as(usize, 0), fx.pendingSpawnCount());
    const wake = fx.takeMsg() orelse return error.MissingWorkerWake;
    try std.testing.expect(wake == .git_wakeup);
    host.release();
    try host.start(&fx, 10001, .{ .validate_branch = "next" });
    // Shutdown joins and frees a running job, including all copied strings.
    host.deinit();
    try std.testing.expect(host.job == null and host.thread == null);
}

test "libgit2 lists and force prunes a registered worktree removed outside the app" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.create();
    try f.tmp.dir.deleteTree(std.testing.io, "linked 'quoted'");
    var list = backend.execute(a, .{ .list_worktrees = f.root });
    defer list.deinit(a);
    try std.testing.expectEqual(.success, list.outcome);
    try std.testing.expect(std.mem.indexOf(u8, list.output.items, f.linked) != null);
    try expect(.{ .remove_worktree = .{ .repo = f.root, .path = f.linked, .force = false } }, .failure, false);
    try expect(.{ .remove_worktree = .{ .repo = f.root, .path = f.linked, .force = true } }, .success, false);
    var after = backend.execute(a, .{ .list_worktrees = f.root });
    defer after.deinit(a);
    try std.testing.expectEqual(.success, after.outcome);
    try std.testing.expect(std.mem.indexOf(u8, after.output.items, f.linked) == null);
}

test "Git worker does not close a channel whose occupied key rejects its start" {
    const app = @import("../main.zig");
    const Host = @import("../git_host.zig").Host;
    var fx = app.Effects.init(a);
    defer fx.deinit();
    fx.executor = .fake;
    const existing = fx.openChannel(.{ .key = 12000, .on_event = app.Effects.channelMsg(.git_wakeup) });
    var host: Host = .{};
    defer host.deinit();
    try std.testing.expectError(error.GitChannelUnavailable, host.start(&fx, 12000, .{ .validate_branch = "test" }));
    try std.testing.expect(existing.live());
    try std.testing.expect(host.job == null and host.thread == null and host.channel_key == null);
}
