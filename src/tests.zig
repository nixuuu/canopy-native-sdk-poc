const std = @import("std");
const app = @import("main.zig");
const workspaces = @import("workspaces.zig");

const Stores = struct {
    tabs: *app.TabStore,
    projects: *workspaces.Store,

    fn init() !Stores {
        const tabs = try app.TabStore.create(std.testing.allocator);
        errdefer tabs.destroy();
        const projects = try workspaces.Store.create(std.testing.allocator);
        return .{ .tabs = tabs, .projects = projects };
    }

    fn deinit(stores: Stores) void {
        stores.tabs.destroy();
        stores.projects.destroy();
    }
};

fn finishSpawn(fx: *app.Effects, model: *app.Model, code: i32, output_lines: []const []const u8) !void {
    const request = fx.pendingSpawnAt(0) orelse return error.MissingSpawn;
    for (output_lines) |line| try fx.feedLine(request.key, line);
    try fx.feedExit(request.key, code);
    while (fx.takeMsg()) |msg| app.update(model, msg, fx);
}

test "empty store exposes the attach-project state" {
    const stores = try Stores.init();
    defer stores.deinit();
    var model = app.initialModel(stores.tabs, stores.projects);
    defer model.active_tab_by_workspace.deinit(std.testing.allocator);
    try std.testing.expect(!model.hasProjects());
    try std.testing.expectEqual(@as(usize, 0), model.projectCount());
}

test "attached folder appears as a selected workspace" {
    const stores = try Stores.init();
    defer stores.deinit();
    var model = app.initialModel(stores.tabs, stores.projects);
    defer model.active_tab_by_workspace.deinit(std.testing.allocator);
    const attached = stores.projects.attachPlaceholder("/tmp/canopy-test-project").?;
    model.active_workspace_id = attached.workspace_id;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const rows = model.sidebarRows(arena_state.allocator());
    try std.testing.expectEqual(@as(usize, 2), rows.len);
    try std.testing.expectEqual(workspaces.RowKind.project, rows[0].kind);
    try std.testing.expectEqualStrings("canopy-test-project", rows[1].name);
    try std.testing.expect(rows[1].selected);
}

test "tabs are projected per active worktree" {
    const stores = try Stores.init();
    defer stores.deinit();
    var model = app.initialModel(stores.tabs, stores.projects);
    defer model.active_tab_by_workspace.deinit(std.testing.allocator);
    const one = stores.projects.attachPlaceholder("/tmp/one").?;
    const two = stores.projects.attachPlaceholder("/tmp/two").?;
    model.active_workspace_id = one.workspace_id;
    var tab_one = app.TerminalTab{ .id = 7, .workspace_id = one.workspace_id, .pty = 41 };
    _ = tab_one.title.set("one");
    var tab_two = app.TerminalTab{ .id = 8, .workspace_id = two.workspace_id, .pty = 42 };
    _ = tab_two.title.set("two");
    try stores.tabs.items.append(stores.tabs.allocator, tab_one);
    try stores.tabs.items.append(stores.tabs.allocator, tab_two);
    try model.active_tab_by_workspace.put(std.testing.allocator, one.workspace_id, 7);

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const visible = model.tabs(arena_state.allocator());
    try std.testing.expectEqual(@as(usize, 1), visible.len);
    try std.testing.expectEqual(@as(u64, 7), visible[0].id);
    try std.testing.expect(visible[0].selected);
}

test "tab storage grows while rendered chrome remains bounded" {
    const stores = try Stores.init();
    defer stores.deinit();
    var model = app.initialModel(stores.tabs, stores.projects);
    defer model.active_tab_by_workspace.deinit(std.testing.allocator);
    const attached = stores.projects.attachPlaceholder("/tmp/many-tabs").?;
    model.active_workspace_id = attached.workspace_id;
    for (0..64) |index| {
        try stores.tabs.items.append(stores.tabs.allocator, .{
            .id = @intCast(index + 1),
            .workspace_id = attached.workspace_id,
            .pty = @intCast(index + 1),
            .phase = .running,
        });
    }
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    try std.testing.expectEqual(@as(usize, 64), stores.tabs.items.items.len);
    try std.testing.expectEqual(@as(usize, 12), model.tabs(arena_state.allocator()).len);
}

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
    var model = app.initialModel(stores.tabs, stores.projects);
    defer model.active_tab_by_workspace.deinit(std.testing.allocator);
    var fx = app.Effects.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    app.update(&model, .{ .begin_create_worktree = attached.project_id }, &fx);
    model.create_branch.set("feature/safe-flow");
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
    var model = app.initialModel(stores.tabs, stores.projects);
    defer model.active_tab_by_workspace.deinit(std.testing.allocator);
    var fx = app.Effects.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    const first = app.PathPayload.from("/tmp/slow-repository").?;
    app.update(&model, .{ .folder_selected = first }, &fx);
    try std.testing.expect(model.gitBusy());
    try std.testing.expectEqual(@as(usize, 1), fx.pendingSpawnCount());
    const running_key = fx.pendingSpawnAt(0).?.key;

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
    try finishSpawn(&fx, &model, 0, &.{
        "worktree /tmp/slow-repository",
        "HEAD 1111111",
        "branch refs/heads/main",
        "",
    });
    try std.testing.expect(!model.gitBusy());
    try std.testing.expectEqual(@as(usize, 0), fx.pendingSpawnCount());
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
    var model = app.initialModel(stores.tabs, stores.projects);
    defer model.active_tab_by_workspace.deinit(std.testing.allocator);
    var fx = app.Effects.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    app.update(&model, .{ .open_terminal = linked }, &fx);
    try std.testing.expectEqual(@as(usize, 1), stores.tabs.items.items.len);
    app.update(&model, .{ .request_remove_worktree = linked }, &fx);
    try finishSpawn(&fx, &model, 0, &.{" M README.md"});
    try finishSpawn(&fx, &model, 1, &.{});
    try finishSpawn(&fx, &model, 0, &.{});
    try std.testing.expect(model.remove_dialog_open);
    try std.testing.expect(model.removeHasWarnings());

    app.update(&model, .confirm_remove_worktree, &fx);
    const pty_key = fx.pendingPtyAt(0).?.key;
    try std.testing.expect(fx.ptyKillRequested(pty_key));
    try fx.feedPtyExit(pty_key, -1, 0, .cancelled, 0);
    while (fx.takeMsg()) |msg| app.update(&model, msg, &fx);
    try std.testing.expectEqual(@as(usize, 0), stores.tabs.items.items.len);
    try std.testing.expectEqualStrings("status", fx.pendingSpawnAt(0).?.argv[3]);
    try finishSpawn(&fx, &model, 0, &.{" M README.md"});
    try finishSpawn(&fx, &model, 1, &.{});
    try finishSpawn(&fx, &model, 0, &.{});
    const remove = fx.pendingSpawnAt(0).?;
    try std.testing.expectEqualStrings("remove", remove.argv[4]);
    try std.testing.expectEqualStrings("--force", remove.argv[5]);
    try finishSpawn(&fx, &model, 0, &.{});
    try finishSpawn(&fx, &model, 0, &.{
        "worktree /tmp/removal-repo",
        "HEAD 1111111",
        "branch refs/heads/main",
        "",
    });
    try std.testing.expect(!stores.projects.findWorktree(linked).?.active);
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
    var model = app.initialModel(stores.tabs, stores.projects);
    defer model.active_tab_by_workspace.deinit(std.testing.allocator);
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
    try std.testing.expect(model.remove_dialog_open);
    try std.testing.expectEqualStrings("Worktree safety state changed; review again", model.status_text);

    app.update(&model, .confirm_remove_worktree, &fx);
    try finishSpawn(&fx, &model, 0, &.{" M changed.txt"});
    try finishSpawn(&fx, &model, 1, &.{});
    try finishSpawn(&fx, &model, 0, &.{});
    const remove = fx.pendingSpawnAt(0).?;
    try std.testing.expectEqualStrings("remove", remove.argv[4]);
    try std.testing.expectEqualStrings("--force", remove.argv[5]);
}

test "project persistence coalesces writes and picker waits for restore" {
    const stores = try Stores.init();
    defer stores.deinit();
    const one = stores.projects.attachPlaceholder("/tmp/persist-one").?;
    const two = stores.projects.attachPlaceholder("/tmp/persist-two").?;
    var model = app.initialModel(stores.tabs, stores.projects);
    defer model.active_tab_by_workspace.deinit(std.testing.allocator);
    try std.testing.expect(model.store_path.set("/tmp/canopy-projects.store"));
    model.restore_ready = false;
    var fx = app.Effects.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    app.update(&model, .open_folder, &fx);
    try std.testing.expectEqual(@as(u64, 0), model.picker_serial);
    model.restore_ready = true;

    app.update(&model, .{ .request_detach_project = one.project_id }, &fx);
    app.update(&model, .confirm_detach_project, &fx);
    try std.testing.expectEqual(@as(usize, 1), fx.pendingFileCount());
    try std.testing.expect(std.mem.indexOf(u8, fx.pendingFileAt(0).?.bytes, "/tmp/persist-two") != null);
    app.update(&model, .{ .request_detach_project = two.project_id }, &fx);
    app.update(&model, .confirm_detach_project, &fx);
    try std.testing.expectEqual(@as(usize, 1), fx.pendingFileCount());
    try std.testing.expect(model.persist_dirty);

    const first_key = fx.pendingFileAt(0).?.key;
    try fx.feedFileResult(first_key, .ok, "");
    while (fx.takeMsg()) |msg| app.update(&model, msg, &fx);
    try std.testing.expectEqual(@as(usize, 1), fx.pendingFileCount());
    try std.testing.expectEqualStrings("CANOPY_PROJECTS_V1\n", fx.pendingFileAt(0).?.bytes);
}
