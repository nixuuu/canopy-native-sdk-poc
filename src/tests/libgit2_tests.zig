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
        try succeeds(.{ .create_branch = .{ .repo = self.root, .branch = "feature/test" } });
        try succeeds(.{ .create_worktree = .{ .repo = self.root, .path = self.linked, .branch = "feature/test" } });
    }
};

fn succeeds(request: workflow.Request) !void {
    var response = backend.execute(a, request);
    defer response.deinit(a);
    try std.testing.expect(response.value != .failure);
}

fn safety(f: *Fixture) !workflow.RemovalSafety {
    var response = backend.execute(a, .{ .inspect = .{ .repo = f.root, .path = f.linked } });
    defer response.deinit(a);
    if (response.value != .safety) return error.ExpectedSafety;
    return response.value.safety;
}

fn remove(f: *Fixture, approved: workflow.RemovalSafety, force: bool) backend.Response {
    return backend.execute(a, .{ .remove_worktree = .{ .repo = f.root, .path = f.linked, .force = force, .approved = approved } });
}

fn publish(f: *Fixture) !void {
    var head: ?*c.git_reference = null;
    try ok(c.git_repository_head(&head, f.repo));
    defer c.git_reference_free(head);
    var remote: ?*c.git_reference = null;
    try ok(c.git_reference_create(&remote, f.repo, "refs/remotes/origin/main", c.git_reference_target(head), 1, null));
    defer c.git_reference_free(remote);
}

fn detachAndCommit(f: *Fixture) !void {
    var linked: ?*c.git_repository = null;
    try ok(c.git_repository_open(&linked, f.linked));
    defer c.git_repository_free(linked);
    var head: ?*c.git_reference = null;
    try ok(c.git_repository_head(&head, linked));
    defer c.git_reference_free(head);
    var parent: ?*c.git_commit = null;
    try ok(c.git_commit_lookup(&parent, linked, c.git_reference_target(head)));
    defer c.git_commit_free(parent);
    try ok(c.git_repository_set_head_detached(linked, c.git_reference_target(head)));
    const original = f.repo;
    f.repo = linked.?;
    defer f.repo = original;
    _ = try f.commit("detached local work", parent);
}

test "libgit2 discovers primary roots and returns typed worktrees including empty linked list" {
    var f = try Fixture.init();
    defer f.deinit();
    var initial = backend.execute(a, .{ .list_worktrees = f.root });
    defer initial.deinit(a);
    try std.testing.expectEqual(@as(usize, 1), initial.value.worktrees.len);
    try f.create();
    var root = backend.execute(a, .{ .repository_root = f.linked });
    defer root.deinit(a);
    try std.testing.expectEqualStrings(f.root, root.value.root.slice());
    var list = backend.execute(a, .{ .list_worktrees = f.linked });
    defer list.deinit(a);
    try std.testing.expectEqual(@as(usize, 2), list.value.worktrees.len);
    try std.testing.expect(list.value.worktrees[0].is_main);
    try std.testing.expectEqualStrings("feature/test", list.value.worktrees[1].branch.slice());
    try publish(&f);
    const approved = try safety(&f);
    try std.testing.expect(!approved.hasWarnings());
    var result = remove(&f, approved, false);
    defer result.deinit(a);
    try std.testing.expect(result.value == .ok);
    var exists = backend.execute(a, .{ .branch_exists = .{ .repo = f.root, .branch = "feature/test" } });
    defer exists.deinit(a);
    try std.testing.expect(exists.value.exists);
}

test "live HEAD inspection detects detached commits and rejects stale approval" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.create();
    try publish(&f);
    const approved = try safety(&f);
    try detachAndCommit(&f);
    const changed = try safety(&f);
    try std.testing.expect(changed.detached and changed.unmerged_count == 1);
    try std.testing.expect(!approved.matches(changed));
    var refusal = remove(&f, approved, false);
    defer refusal.deinit(a);
    try std.testing.expect(refusal.value == .changed);
    var no_force = remove(&f, changed, false);
    defer no_force.deinit(a);
    try std.testing.expect(no_force.value == .failure);
    var confirmed = remove(&f, changed, true);
    defer confirmed.deinit(a);
    try std.testing.expect(confirmed.value == .ok);
}

test "removal protects dirty locked foreign and primary trees" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.create();
    try publish(&f);
    try f.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "linked 'quoted'/untracked.txt", .data = "keep me" });
    const approved = try safety(&f);
    try std.testing.expect(approved.dirty);
    var dirty = remove(&f, approved, false);
    defer dirty.deinit(a);
    try std.testing.expect(dirty.value == .failure);
    var tree: ?*c.git_worktree = null;
    try ok(c.git_worktree_lookup(&tree, f.repo, "linked 'quoted'"));
    defer c.git_worktree_free(tree);
    try ok(c.git_worktree_lock(tree, "keep"));
    var locked = remove(&f, approved, true);
    defer locked.deinit(a);
    try std.testing.expectEqual(workflow.Failure.locked, locked.value.failure);
    try ok(c.git_worktree_unlock(tree));
    var other = try Fixture.init();
    defer other.deinit();
    var foreign = backend.execute(a, .{ .remove_worktree = .{ .repo = other.root, .path = f.linked, .force = true, .approved = approved } });
    defer foreign.deinit(a);
    try std.testing.expect(foreign.value == .failure);
    var main = backend.execute(a, .{ .remove_worktree = .{ .repo = f.root, .path = f.root, .force = true, .approved = approved } });
    defer main.deinit(a);
    try std.testing.expect(main.value == .failure);
    var missing_approval = backend.execute(a, .{ .remove_worktree = .{ .repo = f.root, .path = f.linked, .force = true } });
    defer missing_approval.deinit(a);
    try std.testing.expect(missing_approval.value == .failure);
}

test "changed dirty files require review even when the dirty flag remains true" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.create();
    try f.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "linked 'quoted'/untracked.txt", .data = "old" });
    const approved = try safety(&f);
    try f.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "linked 'quoted'/untracked.txt", .data = "new content" });
    var result = remove(&f, approved, true);
    defer result.deinit(a);
    try std.testing.expect(result.value == .changed);
}

test "missing registered worktrees remain visible and require current force approval" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.create();
    try f.tmp.dir.deleteTree(std.testing.io, "linked 'quoted'");
    var list = backend.execute(a, .{ .list_worktrees = f.root });
    defer list.deinit(a);
    try std.testing.expectEqual(@as(usize, 2), list.value.worktrees.len);
    const approved = try safety(&f);
    try std.testing.expect(approved.missing);
    var result = remove(&f, approved, true);
    defer result.deinit(a);
    try std.testing.expect(result.value == .ok);
}

test "branch validation and malformed submodule configuration fail explicitly" {
    for ([_][]const u8{ "", "-option", "HEAD", "a..b", "bad name", "trailing/", "@{-1}" }) |name| {
        var result = backend.execute(a, .{ .validate_branch = name });
        defer result.deinit(a);
        try std.testing.expect(!result.value.exists);
    }
    var f = try Fixture.init();
    defer f.deinit();
    try f.create();
    try f.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "linked 'quoted'/.gitmodules", .data = "[invalid" });
    var result = backend.execute(a, .{ .inspect = .{ .repo = f.root, .path = f.linked } });
    defer result.deinit(a);
    try std.testing.expect(result.value == .failure);
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
    try std.testing.expect(result.value.exists);
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

test "real Git service completes create and remove workflows without a macOS event loop" {
    const support = @import("support.zig");
    const service_tests = @import("git_service_tests.zig");
    var f = try Fixture.init();
    defer f.deinit();
    const stores = try support.Stores.init();
    defer stores.deinit();
    try std.testing.expect(stores.projects.setWorktreesBase(std.fs.path.dirname(f.root).?));
    var ui: service_tests.Ui = .{ .model = support.app.initialModel(stores.tabs, stores.projects, stores.profiles), .effects = support.app.Effects.init(a) };
    defer ui.effects.deinit();
    defer ui.model.terminal_state.deinit(a);
    ui.effects.executor = .fake;
    var service: @import("../git_service.zig").Service(@import("../git_host.zig").Host) = .{};
    defer service.deinit();
    try ui.dispatch({}, 1, .{ .folder_selected = support.app.PathPayload.from(f.root).? });
    try service_tests.settle(&service, &ui);
    const project = stores.projects.projects.items[0].id;
    try ui.dispatch({}, 1, .{ .begin_create_worktree = project });
    ui.model.workspace_dialogs.create.branch.set("feature/service");
    try ui.dispatch({}, 1, .confirm_create_worktree);
    try service_tests.settle(&service, &ui);
    const workspace = ui.model.active_workspace_id;
    try std.testing.expect(!stores.projects.findWorktree(workspace).?.is_main);
    try ui.dispatch({}, 1, .{ .request_remove_worktree = workspace });
    try service_tests.settle(&service, &ui);
    try std.testing.expect(ui.model.workspace_dialogs.removal.open);
    try std.testing.expect(ui.model.workspace_dialogs.removal.safety.unmerged_count > 0);
    try ui.dispatch({}, 1, .confirm_remove_worktree);
    try service_tests.settle(&service, &ui);
    try std.testing.expect(stores.projects.findWorktree(workspace) == null);
    try std.testing.expectEqual(@as(usize, 0), ui.effects.pendingSpawnCount());
}

test "changed gitlink cannot redirect removal into another repository" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.create();
    const approved = try safety(&f);
    var other = try Fixture.init();
    defer other.deinit();
    const redirect = try std.fmt.allocPrint(a, "gitdir: {s}/.git\n", .{other.root});
    defer a.free(redirect);
    try f.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "linked 'quoted'/.git", .data = redirect });
    var result = remove(&f, approved, true);
    defer result.deinit(a);
    try std.testing.expectEqual(workflow.Failure.invalid_input, result.value.failure);
}

test "inspection supports the complete allowed branch-name length" {
    var f = try Fixture.init();
    defer f.deinit();
    var name: [@import("../workspaces.zig").max_branch_bytes]u8 = @splat('x');
    name[128] = '/'; // Keep each filesystem component below NAME_MAX.
    try succeeds(.{ .create_branch = .{ .repo = f.root, .branch = &name } });
    try succeeds(.{ .create_worktree = .{ .repo = f.root, .path = f.linked, .branch = &name } });
    const inspected = try safety(&f);
    try std.testing.expectEqualStrings(&name, inspected.branch.slice());
}
