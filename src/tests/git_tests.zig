const support = @import("support.zig");
const std = support.std;
const app = support.app;
const profiles = support.profiles;
const workspaces = support.workspaces;
const Stores = support.Stores;
const finishSpawn = support.finishSpawn;
const envValue = support.envValue;

test "new worktree flow preflights target and branch before checkout" {
    const stores = try Stores.init();
    defer stores.deinit();
    try std.testing.expect(stores.projects.setWorktreesBase("/tmp/canopy-worktrees"));
    const attached = stores.projects.attachPlaceholder("/tmp/canopy-repo").?;
    try std.testing.expect(stores.projects.markGit(attached.project_id, "/tmp/canopy-repo"));
    try std.testing.expect(stores.projects.applyWorktreePorcelain(attached.project_id,
        \\worktree /tmp/canopy-repo
        \\HEAD 1111111
        \\branch refs/heads/main
        \\
    ));
    var model = app.initialModel(stores.tabs, stores.projects, stores.profiles);
    defer model.terminal_state.deinit(std.testing.allocator);
    var fx = app.Effects.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    app.update(&model, .{ .begin_create_worktree = attached.project_id }, &fx);
    model.workspace_dialogs.create.branch.set("feature/safe-flow");
    app.update(&model, .confirm_create_worktree, &fx);
    try std.testing.expectEqualStrings("check-ref-format", fx.pendingSpawnAt(0).?.argv[1]);

    try finishSpawn(&fx, &model, 0, &.{});
    try std.testing.expectEqualStrings("/bin/test", fx.pendingSpawnAt(0).?.argv[0]);
    try finishSpawn(&fx, &model, 0, &.{});
    try std.testing.expectEqualStrings("show-ref", fx.pendingSpawnAt(0).?.argv[3]);
    try finishSpawn(&fx, &model, 1, &.{});
    try std.testing.expectEqualStrings("branch", fx.pendingSpawnAt(0).?.argv[3]);
    try finishSpawn(&fx, &model, 0, &.{});
    const add = fx.pendingSpawnAt(0).?;
    try std.testing.expectEqualStrings("worktree", add.argv[3]);
    try std.testing.expectEqualStrings("add", add.argv[4]);
    try std.testing.expectEqualStrings("feature/safe-flow", add.argv[6]);
    var target_copy: workspaces.PathText = .{};
    try std.testing.expect(target_copy.set(add.argv[5]));
    try finishSpawn(&fx, &model, 0, &.{});
    try std.testing.expectEqualStrings("list", fx.pendingSpawnAt(0).?.argv[4]);
    var worktree_line_buffer: [workspaces.max_path_bytes + 16]u8 = undefined;
    const worktree_line = try std.fmt.bufPrint(&worktree_line_buffer, "worktree {s}", .{target_copy.slice()});
    try finishSpawn(&fx, &model, 0, &.{
        "worktree /tmp/canopy-repo",
        "HEAD 1111111",
        "branch refs/heads/main",
        "",
        worktree_line,
        "HEAD 2222222",
        "branch refs/heads/feature/safe-flow",
        "",
    });
    try std.testing.expectEqualStrings(target_copy.slice(), model.activeWorkspacePath());
}

test "Git lane keeps exactly one command in flight and never queues user work" {
    const stores = try Stores.init();
    defer stores.deinit();
    var model = app.initialModel(stores.tabs, stores.projects, stores.profiles);
    defer model.terminal_state.deinit(std.testing.allocator);
    var fx = app.Effects.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    const first = app.PathPayload.from("/tmp/slow-repository").?;
    app.update(&model, .{ .folder_selected = first }, &fx);
    try std.testing.expect(model.gitBusy());
    try std.testing.expectEqual(@as(usize, 1), fx.pendingSpawnCount());
    const running_key = fx.pendingSpawnAt(0).?.key;

    app.update(&model, .{ .git_done = .{ .key = running_key + 99, .code = 0 } }, &fx);
    try std.testing.expect(model.gitBusy());
    try std.testing.expectEqual(running_key, fx.pendingSpawnAt(0).?.key);

    const second = app.PathPayload.from("/tmp/must-not-be-queued").?;
    app.update(&model, .{ .folder_selected = second }, &fx);
    app.update(&model, .open_folder, &fx);
    try std.testing.expectEqual(@as(usize, 1), stores.projects.attachedCount());
    try std.testing.expectEqual(@as(usize, 1), fx.pendingSpawnCount());
    try std.testing.expectEqual(running_key, fx.pendingSpawnAt(0).?.key);
    try std.testing.expectEqual(@as(u64, 0), model.picker_serial);

    try finishSpawn(&fx, &model, 0, &.{"/tmp/slow-repository"});
    try std.testing.expect(model.gitBusy());
    try std.testing.expectEqual(@as(usize, 1), fx.pendingSpawnCount());
    try std.testing.expectEqualStrings("list", fx.pendingSpawnAt(0).?.argv[4]);
    const refresh_key = fx.pendingSpawnAt(0).?.key;
    app.update(&model, .{ .git_done = .{ .key = running_key, .code = 0 } }, &fx);
    try std.testing.expectEqual(refresh_key, fx.pendingSpawnAt(0).?.key);
    try std.testing.expect(model.gitBusy());
    try finishSpawn(&fx, &model, 0, &.{
        "worktree /tmp/slow-repository",
        "HEAD 1111111",
        "branch refs/heads/main",
        "",
    });
    try std.testing.expect(!model.gitBusy());
    try std.testing.expectEqual(@as(usize, 0), fx.pendingSpawnCount());
}

test "repository discovery reuses an attached Git root instead of keeping a duplicate" {
    const stores = try Stores.init();
    defer stores.deinit();
    const existing = stores.projects.attachPlaceholder("/tmp/repository").?;
    try std.testing.expect(stores.projects.markGit(existing.project_id, "/tmp/repository"));
    try std.testing.expect(stores.projects.applyWorktreePorcelain(existing.project_id,
        \\worktree /tmp/repository
        \\HEAD 1111111
        \\branch refs/heads/main
        \\
    ));
    var model = app.initialModel(stores.tabs, stores.projects, stores.profiles);
    defer model.terminal_state.deinit(std.testing.allocator);
    model.active_workspace_id = existing.workspace_id;
    var fx = app.Effects.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    app.update(&model, .{ .folder_selected = app.PathPayload.from("/tmp/repository/child").? }, &fx);
    try std.testing.expectEqual(@as(usize, 2), stores.projects.attachedCount());
    try std.testing.expectEqualStrings("rev-parse", fx.pendingSpawnAt(0).?.argv[3]);
    try finishSpawn(&fx, &model, 0, &.{"/tmp/repository"});
    try std.testing.expectEqual(@as(usize, 1), stores.projects.attachedCount());
    try std.testing.expectEqual(existing.workspace_id, model.active_workspace_id);
    try std.testing.expectEqualStrings("list", fx.pendingSpawnAt(0).?.argv[4]);
    try finishSpawn(&fx, &model, 0, &.{ "worktree /tmp/repository", "HEAD 1111111", "branch refs/heads/main", "" });
    try std.testing.expect(!model.gitBusy());
    try std.testing.expectEqual(@as(usize, 0), fx.pendingSpawnCount());
}

test "failed worktree checkout refreshes state without deleting the created branch" {
    const stores = try Stores.init();
    defer stores.deinit();
    var model = app.initialModel(stores.tabs, stores.projects, stores.profiles);
    defer model.terminal_state.deinit(std.testing.allocator);
    const attached = stores.projects.attachPlaceholder("/tmp/checkout-failure").?;
    try std.testing.expect(stores.projects.setWorktreesBase("/tmp/canopy-worktrees"));
    try std.testing.expect(stores.projects.markGit(attached.project_id, "/tmp/checkout-failure"));
    var fx = app.Effects.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    app.update(&model, .{ .begin_create_worktree = attached.project_id }, &fx);
    model.workspace_dialogs.create.branch.set("feature/retained");
    app.update(&model, .confirm_create_worktree, &fx);
    try finishSpawn(&fx, &model, 0, &.{}); // valid name
    try finishSpawn(&fx, &model, 0, &.{}); // absent target
    try finishSpawn(&fx, &model, 1, &.{}); // absent branch
    try finishSpawn(&fx, &model, 0, &.{}); // branch created
    try std.testing.expectEqualStrings("add", fx.pendingSpawnAt(0).?.argv[4]);
    try finishSpawn(&fx, &model, 128, &.{});
    try std.testing.expectEqual(@as(usize, 1), fx.pendingSpawnCount());
    try std.testing.expectEqualStrings("list", fx.pendingSpawnAt(0).?.argv[4]);
    try finishSpawn(&fx, &model, 0, &.{ "worktree /tmp/checkout-failure", "HEAD 1111111", "branch refs/heads/main", "" });
    try std.testing.expectEqual(@as(usize, 0), fx.pendingSpawnCount());
    try std.testing.expect(!model.gitBusy());
    try std.testing.expectEqualStrings("Worktree creation failed; branch retained and Git state refreshed", model.status_text);
}

test "worktree removal waits for PTY exit and requires force for dirty state" {
    const stores = try Stores.init();
    defer stores.deinit();
    const attached = stores.projects.attachPlaceholder("/tmp/removal-repo").?;
    try std.testing.expect(stores.projects.markGit(attached.project_id, "/tmp/removal-repo"));
    try std.testing.expect(stores.projects.applyWorktreePorcelain(attached.project_id,
        \\worktree /tmp/removal-repo
        \\HEAD 1111111
        \\branch refs/heads/main
        \\
        \\worktree /tmp/removal-repo-feature
        \\HEAD 2222222
        \\branch refs/heads/feature/remove-me
        \\
    ));
    const project = stores.projects.findProject(attached.project_id).?;
    const linked = project.worktrees.items[1].id;
    var model = app.initialModel(stores.tabs, stores.projects, stores.profiles);
    defer model.terminal_state.deinit(std.testing.allocator);
    var fx = app.Effects.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    app.update(&model, .{ .open_terminal = linked }, &fx);
    try std.testing.expectEqual(@as(usize, 1), stores.tabs.items.items.len);
    const shell_request = fx.pendingPtyAt(0) orelse return error.MissingPty;
    try std.testing.expectEqualStrings("/bin/sh", shell_request.argv[0]);
    try std.testing.expectEqualStrings("/tmp/removal-repo-feature", shell_request.argv[4]);
    try std.testing.expectEqualStrings("/bin/zsh", shell_request.argv[5]);
    try std.testing.expectEqualStrings("/bin/zsh", envValue(shell_request, "SHELL") orelse "");
    try std.testing.expectEqualStrings("truecolor", envValue(shell_request, "COLORTERM") orelse "");
    app.update(&model, .{ .request_remove_worktree = linked }, &fx);
    try finishSpawn(&fx, &model, 0, &.{" M README.md"});
    try finishSpawn(&fx, &model, 1, &.{});
    try finishSpawn(&fx, &model, 0, &.{});
    try std.testing.expect(model.workspace_dialogs.removal.open);
    try std.testing.expect(model.removeHasWarnings());

    app.update(&model, .confirm_remove_worktree, &fx);
    const pty_key = fx.pendingPtyAt(0).?.key;
    try std.testing.expect(fx.ptyKillRequested(pty_key));
    try std.testing.expect(model.busy());
    // A slow terminal exit owns the workflow; clicks must not replace it,
    // enqueue another command, or introduce another session in its target.
    app.update(&model, .{ .request_detach_project = attached.project_id }, &fx);
    app.update(&model, .confirm_detach_project, &fx);
    app.update(&model, .cancel_remove_worktree, &fx);
    app.update(&model, .confirm_remove_worktree, &fx);
    app.update(&model, .{ .open_terminal = linked }, &fx);
    try std.testing.expectEqual(linked, model.teardown.closing_worktree.workspace_id);
    try std.testing.expectEqual(@as(usize, 1), stores.tabs.items.items.len);
    try std.testing.expectEqual(@as(usize, 0), fx.pendingSpawnCount());
    try fx.feedPtyExit(pty_key, -1, 0, .cancelled, 0);
    while (fx.takeMsg()) |msg| app.update(&model, msg, &fx);
    try std.testing.expectEqual(@as(usize, 0), stores.tabs.items.items.len);
    try std.testing.expectEqualStrings("status", fx.pendingSpawnAt(0).?.argv[3]);
    app.update(&model, .{ .open_terminal = linked }, &fx);
    try std.testing.expectEqual(@as(usize, 0), stores.tabs.items.items.len);
    try finishSpawn(&fx, &model, 0, &.{" M README.md"});
    try finishSpawn(&fx, &model, 1, &.{});
    try finishSpawn(&fx, &model, 0, &.{});
    const remove = fx.pendingSpawnAt(0).?;
    try std.testing.expectEqualStrings("remove", remove.argv[4]);
    try std.testing.expectEqualStrings("--force", remove.argv[5]);
    app.update(&model, .{ .open_terminal = linked }, &fx);
    try std.testing.expectEqual(@as(usize, 0), stores.tabs.items.items.len);
    try finishSpawn(&fx, &model, 0, &.{});
    try finishSpawn(&fx, &model, 0, &.{
        "worktree /tmp/removal-repo",
        "HEAD 1111111",
        "branch refs/heads/main",
        "",
    });
    try std.testing.expect(!stores.projects.findWorktree(linked).?.active);
    try std.testing.expect(!model.busy());
}

test "worktree removal asks again when the fresh preflight changed" {
    const stores = try Stores.init();
    defer stores.deinit();
    const attached = stores.projects.attachPlaceholder("/tmp/recheck-repo").?;
    try std.testing.expect(stores.projects.markGit(attached.project_id, "/tmp/recheck-repo"));
    try std.testing.expect(stores.projects.applyWorktreePorcelain(attached.project_id,
        \\worktree /tmp/recheck-repo
        \\HEAD 1111111
        \\branch refs/heads/main
        \\
        \\worktree /tmp/recheck-repo-feature
        \\HEAD 2222222
        \\branch refs/heads/feature/recheck
        \\
    ));
    const linked = stores.projects.findProject(attached.project_id).?.worktrees.items[1].id;
    var model = app.initialModel(stores.tabs, stores.projects, stores.profiles);
    defer model.terminal_state.deinit(std.testing.allocator);
    var fx = app.Effects.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    app.update(&model, .{ .request_remove_worktree = linked }, &fx);
    try finishSpawn(&fx, &model, 0, &.{});
    try finishSpawn(&fx, &model, 1, &.{});
    try finishSpawn(&fx, &model, 0, &.{});
    try std.testing.expect(!model.removeHasWarnings());

    app.update(&model, .confirm_remove_worktree, &fx);
    try finishSpawn(&fx, &model, 0, &.{" M changed.txt"});
    try finishSpawn(&fx, &model, 1, &.{});
    try finishSpawn(&fx, &model, 0, &.{});
    try std.testing.expect(model.workspace_dialogs.removal.open);
    try std.testing.expectEqualStrings("Worktree safety state changed; review again", model.status_text);
    try std.testing.expect(!model.teardown.busy());
    try std.testing.expectEqual(@as(usize, 0), fx.pendingSpawnCount());

    app.update(&model, .confirm_remove_worktree, &fx);
    try finishSpawn(&fx, &model, 0, &.{" M changed.txt"});
    try finishSpawn(&fx, &model, 1, &.{});
    try finishSpawn(&fx, &model, 0, &.{});
    const remove = fx.pendingSpawnAt(0).?;
    try std.testing.expectEqualStrings("remove", remove.argv[4]);
    try std.testing.expectEqualStrings("--force", remove.argv[5]);
    try finishSpawn(&fx, &model, 128, &.{});
    try std.testing.expect(!model.busy());
    try std.testing.expect(stores.projects.findWorktree(linked).?.active);
    try std.testing.expectEqualStrings("Git refused to remove the worktree", model.status_text);
    app.update(&model, .{ .request_remove_worktree = linked }, &fx);
    try std.testing.expectEqualStrings("status", fx.pendingSpawnAt(0).?.argv[3]);
}
