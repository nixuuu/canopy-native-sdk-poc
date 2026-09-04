const std = @import("std");
const app = @import("main.zig");
const profiles = @import("profiles.zig");
const workspaces = @import("workspaces.zig");

const Stores = struct {
    tabs: *app.TabStore,
    projects: *workspaces.Store,
    profiles: *profiles.Store,

    fn init() !Stores {
        const tabs = try app.TabStore.create(std.testing.allocator);
        errdefer tabs.destroy();
        const projects = try workspaces.Store.create(std.testing.allocator);
        errdefer projects.destroy();
        const profile_store = try profiles.Store.create(std.testing.allocator);
        return .{ .tabs = tabs, .projects = projects, .profiles = profile_store };
    }

    fn deinit(stores: Stores) void {
        stores.tabs.destroy();
        stores.projects.destroy();
        stores.profiles.destroy();
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
    var model = app.initialModel(stores.tabs, stores.projects, stores.profiles);
    defer model.active_tab_by_workspace.deinit(std.testing.allocator);
    try std.testing.expect(!model.hasProjects());
    try std.testing.expectEqual(@as(usize, 0), model.projectCount());
}

test "attached folder appears as a selected workspace" {
    const stores = try Stores.init();
    defer stores.deinit();
    var model = app.initialModel(stores.tabs, stores.projects, stores.profiles);
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
    var model = app.initialModel(stores.tabs, stores.projects, stores.profiles);
    defer model.active_tab_by_workspace.deinit(std.testing.allocator);
    const one = stores.projects.attachPlaceholder("/tmp/one").?;
    const two = stores.projects.attachPlaceholder("/tmp/two").?;
    model.active_workspace_id = one.workspace_id;
    var tab_one = app.TerminalTab{ .id = 7, .workspace_id = one.workspace_id, .pty = 41 };
    _ = tab_one.title.set("one");
    _ = tab_one.path.set("/tmp/one");
    _ = tab_one.branch.set("main");
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
    try std.testing.expectEqualStrings("one", visible[0].title);
    try std.testing.expectEqualStrings("/tmp/one", visible[0].path);
    try std.testing.expect(visible[0].selected);
}

test "tab storage grows while rendered chrome remains bounded" {
    const stores = try Stores.init();
    defer stores.deinit();
    var model = app.initialModel(stores.tabs, stores.projects, stores.profiles);
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
    var model = app.initialModel(stores.tabs, stores.projects, stores.profiles);
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
    var model = app.initialModel(stores.tabs, stores.projects, stores.profiles);
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
    var model = app.initialModel(stores.tabs, stores.projects, stores.profiles);
    defer model.active_tab_by_workspace.deinit(std.testing.allocator);
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
    var model = app.initialModel(stores.tabs, stores.projects, stores.profiles);
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
    var model = app.initialModel(stores.tabs, stores.projects, stores.profiles);
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

test "preferences save commits one SQLite transaction into application state" {
    const stores = try Stores.init();
    defer stores.deinit();
    var model = app.initialModel(stores.tabs, stores.projects, stores.profiles);
    defer model.active_tab_by_workspace.deinit(std.testing.allocator);
    model.preferences_loaded = true;
    try std.testing.expect(model.default_worktrees_base.set("/tmp/default-worktrees"));
    var fx = app.Effects.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    app.update(&model, .open_preferences, &fx);
    app.update(&model, .toggle_preferences_reopen, &fx);
    app.update(&model, .use_dark_appearance, &fx);
    model.preferences_base_dir.set("/tmp/custom-worktrees");
    app.update(&model, .save_preferences, &fx);
    try std.testing.expect(model.preferences_saving);
    try std.testing.expectEqual(@as(usize, 1), fx.pendingDbCount());

    try fx.feedDbResult(app.preferences_write_key, .exec, .ok, "");
    while (fx.takeMsg()) |msg| app.update(&model, msg, &fx);
    try std.testing.expect(model.preferences_open);
    try std.testing.expect(!model.preferences_dirty);
    try std.testing.expect(!model.preferences_saved.reopen_last_workspace);
    try std.testing.expectEqual(@import("preferences.zig").AppearanceMode.dark, model.preferences_saved.appearance_mode);
    try std.testing.expectEqualStrings("/tmp/custom-worktrees", stores.projects.worktrees_base.slice());
    try std.testing.expectEqual(@as(u64, 1), model.worktrees_base_serial);
}

fn addProfile(stores: Stores, runtime_id: u64, agent_type: profiles.AgentType, name: []const u8) !*profiles.Profile {
    var profile = profiles.Profile{ .runtime_id = runtime_id, .agent_type = agent_type };
    try std.testing.expect(profile.id.set(if (agent_type == .claude) "profile-claude" else "profile-codex"));
    try std.testing.expect(profile.name.set(name));
    profile.is_default = std.mem.eql(u8, name, "Default");
    try stores.profiles.items.append(std.testing.allocator, profile);
    return &stores.profiles.items.items[stores.profiles.items.items.len - 1];
}

fn envValue(request: anytype, name: []const u8) ?[]const u8 {
    for (request.env) |entry| if (std.mem.eql(u8, entry.name, name)) return entry.value;
    return null;
}

test "tool discovery keeps the final absolute executable and ignores shell chatter" {
    try std.testing.expectEqualStrings(
        "/Users/test/.bun/bin/codex",
        app.resolvedToolExecutable("load config\n/opt/homebrew/bin/codex\n/Users/test/.bun/bin/codex\n") orelse "",
    );
    try std.testing.expect(app.resolvedToolExecutable("codex is a function\nrelative/codex\n") == null);
}

test "preferred shell accepts an absolute user shell and fails closed to zsh" {
    const stores = try Stores.init();
    defer stores.deinit();
    var model = app.initialModel(stores.tabs, stores.projects, stores.profiles);
    defer model.active_tab_by_workspace.deinit(std.testing.allocator);

    model.setUserShell("/opt/homebrew/bin/fish");
    try std.testing.expectEqualStrings("/opt/homebrew/bin/fish", model.userShell());
    model.setUserShell("relative/fish");
    try std.testing.expectEqualStrings("/bin/zsh", model.userShell());
}

test "Claude profiles launch worktree-owned PTYs with matching argv and environment" {
    const stores = try Stores.init();
    defer stores.deinit();
    var model = app.initialModel(stores.tabs, stores.projects, stores.profiles);
    defer model.active_tab_by_workspace.deinit(std.testing.allocator);
    const attached = stores.projects.attachPlaceholder("/tmp/canopy-profile-project").?;
    model.active_workspace_id = attached.workspace_id;
    const profile = try addProfile(stores, 1, .claude, "Default");
    try std.testing.expect(profile.prefs.model.set("opus"));
    try std.testing.expect(profile.prefs.permission_mode.set("plan"));
    try std.testing.expect(profile.prefs.base_url.set("https://proxy.example"));
    try std.testing.expect(profile.prefs.custom_env.set("{\"CANOPY_TEST_COLOR\":\"violet\",\"PATH\":\"blocked\"}"));
    model.profiles_loaded = true;
    model.tool_checks_remaining = 0;
    model.claude_available = true;
    try std.testing.expect(model.setToolExecutable(.claude, "/usr/local/bin/claude"));
    var fx = app.Effects.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    app.update(&model, .launch_claude, &fx);
    const request = fx.pendingPtyAt(0) orelse return error.MissingPty;
    try std.testing.expectEqualStrings("/bin/zsh", request.argv[0]);
    try std.testing.expectEqualStrings("/tmp/canopy-profile-project", request.argv[4]);
    try std.testing.expectEqualStrings("/usr/local/bin/claude", request.argv[5]);
    try std.testing.expectEqualStrings("--model", request.argv[6]);
    try std.testing.expectEqualStrings("opus", request.argv[7]);
    try std.testing.expectEqualStrings("/bin/zsh", envValue(request, "SHELL") orelse "");
    try std.testing.expectEqualStrings("truecolor", envValue(request, "COLORTERM") orelse "");
    try std.testing.expectEqualStrings("https://proxy.example", envValue(request, "ANTHROPIC_BASE_URL") orelse "");
    try std.testing.expectEqualStrings("violet", envValue(request, "CANOPY_TEST_COLOR") orelse "");
    try std.testing.expect(envValue(request, "PATH") == null);
    try std.testing.expectEqual(app.TerminalTool.claude, stores.tabs.items.items[0].tool);
    try std.testing.expectEqualStrings("Claude Code", stores.tabs.items.items[0].title.slice());

    app.update(&model, .launch_claude, &fx);
    try std.testing.expectEqualStrings("Claude Code #2", stores.tabs.items.items[1].title.slice());
}

test "Codex dangerous bypass takes precedence over approval sandbox and full auto" {
    const stores = try Stores.init();
    defer stores.deinit();
    var model = app.initialModel(stores.tabs, stores.projects, stores.profiles);
    defer model.active_tab_by_workspace.deinit(std.testing.allocator);
    const attached = stores.projects.attachPlaceholder("/tmp/canopy-codex-project").?;
    model.active_workspace_id = attached.workspace_id;
    const profile = try addProfile(stores, 7, .codex, "Work");
    try std.testing.expect(profile.prefs.model.set("gpt-5.6"));
    try std.testing.expect(profile.prefs.approval_mode.set("never"));
    try std.testing.expect(profile.prefs.sandbox.set("danger-full-access"));
    profile.prefs.full_auto = true;
    profile.prefs.dangerously_bypass_approvals_and_sandbox = true;
    try std.testing.expect(profile.prefs.profile.set("work"));
    try std.testing.expect(profile.prefs.base_url.set("https://openai.example"));
    model.profiles_loaded = true;
    model.tool_checks_remaining = 0;
    model.codex_available = true;
    model.setUserShell("/opt/homebrew/bin/fish");
    try std.testing.expect(model.setToolExecutable(.codex, "/Users/test/.bun/bin/codex"));
    var fx = app.Effects.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    app.update(&model, .{ .launch_profile = 7 }, &fx);
    const request = fx.pendingPtyAt(0) orelse return error.MissingPty;
    try std.testing.expectEqualStrings("/opt/homebrew/bin/fish", request.argv[0]);
    try std.testing.expectEqualStrings("/tmp/canopy-codex-project", request.argv[3]);
    try std.testing.expectEqualStrings("/Users/test/.bun/bin/codex", request.argv[4]);
    try std.testing.expectEqualStrings("--enable", request.argv[5]);
    try std.testing.expectEqualStrings("hooks", request.argv[6]);
    try std.testing.expectEqualStrings("--model", request.argv[7]);
    try std.testing.expectEqualStrings("gpt-5.6", request.argv[8]);
    try std.testing.expectEqualStrings("--dangerously-bypass-approvals-and-sandbox", request.argv[9]);
    try std.testing.expectEqualStrings("--profile", request.argv[10]);
    try std.testing.expectEqualStrings("work", request.argv[11]);
    for (request.argv) |arg| {
        try std.testing.expect(!std.mem.eql(u8, arg, "--ask-for-approval"));
        try std.testing.expect(!std.mem.eql(u8, arg, "--sandbox"));
        try std.testing.expect(!std.mem.eql(u8, arg, "--full-auto"));
    }
    try std.testing.expectEqualStrings("https://openai.example", envValue(request, "OPENAI_BASE_URL") orelse "");
    try std.testing.expectEqualStrings("/opt/homebrew/bin/fish", envValue(request, "SHELL") orelse "");
    try std.testing.expectEqualStrings("truecolor", envValue(request, "COLORTERM") orelse "");
    try std.testing.expectEqualStrings("Codex (Work)", stores.tabs.items.items[0].title.slice());
}

test "closing and reopening Codex retires the old PTY before recycling its key" {
    const stores = try Stores.init();
    defer stores.deinit();
    var model = app.initialModel(stores.tabs, stores.projects, stores.profiles);
    defer model.active_tab_by_workspace.deinit(std.testing.allocator);
    const attached = stores.projects.attachPlaceholder("/tmp/canopy-codex-lifecycle").?;
    model.active_workspace_id = attached.workspace_id;
    _ = try addProfile(stores, 9, .codex, "Default");
    model.profiles_loaded = true;
    model.tool_checks_remaining = 0;
    model.codex_available = true;
    try std.testing.expect(model.setToolExecutable(.codex, "/usr/local/bin/codex"));
    var fx = app.Effects.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    app.update(&model, .launch_codex, &fx);
    const first = fx.pendingPtyAt(0) orelse return error.MissingPty;
    const first_key = first.key;
    const first_tab_id = stores.tabs.items.items[0].id;
    try std.testing.expectEqual(@as(usize, 1), fx.pendingPtyCount());

    app.update(&model, .{ .close_tab = first_tab_id }, &fx);
    try std.testing.expect(fx.ptyKillRequested(first_key));
    try std.testing.expectEqual(app.TerminalPhase.closing, stores.tabs.items.items[0].phase);
    // Metadata and key remain owned until the exactly-one exit arrives.
    try std.testing.expectEqual(@as(usize, 1), stores.tabs.items.items.len);
    try fx.feedPtyExit(first_key, -1, 0, .cancelled, 0);
    while (fx.takeMsg()) |msg| app.update(&model, msg, &fx);
    try std.testing.expectEqual(@as(usize, 0), fx.pendingPtyCount());
    try std.testing.expectEqual(@as(usize, 0), stores.tabs.items.items.len);

    app.update(&model, .launch_codex, &fx);
    const second = fx.pendingPtyAt(0) orelse return error.MissingPty;
    try std.testing.expectEqual(first_key, second.key);
    try std.testing.expect(stores.tabs.items.items[0].id != first_tab_id);
    try std.testing.expectEqual(@as(usize, 1), fx.pendingPtyCount());
}

test "full Ghostty owns tool PTY and keeps launch alive until host teardown" {
    const stores = try Stores.init();
    defer stores.deinit();
    var model = app.initialModel(stores.tabs, stores.projects, stores.profiles);
    defer model.active_tab_by_workspace.deinit(std.testing.allocator);
    model.use_ghostty = true;
    const attached = stores.projects.attachPlaceholder("/tmp/canopy-ghostty").?;
    model.active_workspace_id = attached.workspace_id;
    _ = try addProfile(stores, 9, .codex, "Default");
    model.profiles_loaded = true;
    model.tool_checks_remaining = 0;
    model.codex_available = true;
    try std.testing.expect(model.setToolExecutable(.codex, "/usr/local/bin/codex"));
    var fx = app.Effects.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    app.update(&model, .launch_codex, &fx);
    const first = stores.tabs.items.items[0];
    try std.testing.expectEqual(@as(usize, 0), fx.pendingPtyCount());
    try std.testing.expect(std.mem.indexOf(u8, first.pending_launch.?.command, "'/usr/local/bin/codex'") != null);
    app.update(&model, .{ .close_tab = first.id }, &fx);
    try std.testing.expect(!fx.ptyKillRequested(first.pty));
    try std.testing.expectEqual(app.TerminalPhase.closing, stores.tabs.items.items[0].phase);
    app.update(&model, .{ .terminal_event = .{ .key = first.pty, .kind = .exit, .reason = .cancelled } }, &fx);
    try std.testing.expectEqual(@as(usize, 0), stores.tabs.items.items.len);
    app.update(&model, .launch_codex, &fx);
    try std.testing.expect(stores.tabs.items.items[0].id != first.id);
    try std.testing.expectEqual(first.pty, stores.tabs.items.items[0].pty);
    try std.testing.expectEqual(@as(usize, 0), fx.pendingPtyCount());
}

test "full Ghostty shell launch bypasses Native SDK PTY" {
    const stores = try Stores.init();
    defer stores.deinit();
    var model = app.initialModel(stores.tabs, stores.projects, stores.profiles);
    defer model.active_tab_by_workspace.deinit(std.testing.allocator);
    model.use_ghostty = true;
    model.active_workspace_id = stores.projects.attachPlaceholder("/tmp/canopy-ghostty-shell").?.workspace_id;
    var fx = app.Effects.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    app.update(&model, .open_active_terminal, &fx);
    try std.testing.expectEqual(@as(usize, 0), fx.pendingPtyCount());
    try std.testing.expectEqual(@as(usize, 1), stores.tabs.items.items.len);
    try std.testing.expect(stores.tabs.items.items[0].pending_launch != null);
}

test "close active tab is worktree scoped and leaves the last tab on teardown path" {
    const stores = try Stores.init();
    defer stores.deinit();
    var model = app.initialModel(stores.tabs, stores.projects, stores.profiles);
    defer model.active_tab_by_workspace.deinit(std.testing.allocator);
    model.use_ghostty = true;
    const one = stores.projects.attachPlaceholder("/tmp/menu-one").?.workspace_id;
    const two = stores.projects.attachPlaceholder("/tmp/menu-two").?.workspace_id;
    var fx = app.Effects.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    try std.testing.expect(!model.canCloseActiveTab());
    app.update(&model, .close_active_tab, &fx);
    model.active_workspace_id = one;
    app.update(&model, .open_active_terminal, &fx);
    app.update(&model, .open_active_terminal, &fx);
    model.active_workspace_id = two;
    app.update(&model, .open_active_terminal, &fx);
    model.active_workspace_id = one;
    app.update(&model, .close_active_tab, &fx);
    try std.testing.expectEqual(app.TerminalPhase.starting, stores.tabs.items.items[0].phase);
    try std.testing.expectEqual(app.TerminalPhase.closing, stores.tabs.items.items[1].phase);
    try std.testing.expectEqual(app.TerminalPhase.starting, stores.tabs.items.items[2].phase);
    try std.testing.expect(model.canCloseActiveTab());
    app.update(&model, .close_active_tab, &fx);
    try std.testing.expectEqual(app.TerminalPhase.closing, stores.tabs.items.items[0].phase);
    try std.testing.expect(!model.canCloseActiveTab());
    app.update(&model, .close_active_tab, &fx);
    try std.testing.expectEqual(@as(usize, 3), stores.tabs.items.items.len);
    try std.testing.expectEqual(@as(usize, 0), fx.pendingPtyCount());
}

test "close tab shortcut cannot close terminals behind any application modal" {
    const stores = try Stores.init();
    defer stores.deinit();
    var model = app.initialModel(stores.tabs, stores.projects, stores.profiles);
    defer model.active_tab_by_workspace.deinit(std.testing.allocator);
    model.use_ghostty = true;
    model.active_workspace_id = stores.projects.attachPlaceholder("/tmp/menu-modal").?.workspace_id;
    var fx = app.Effects.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    app.update(&model, .open_active_terminal, &fx);
    inline for (.{ "preferences_open", "create_dialog_open", "remove_dialog_open", "detach_dialog_open", "profile_switch_dialog_open", "profile_delete_dialog_open" }) |field| {
        @field(model, field) = true;
        try std.testing.expect(!model.canCloseActiveTab());
        app.update(&model, .close_active_tab, &fx);
        try std.testing.expectEqual(app.TerminalPhase.starting, stores.tabs.items.items[0].phase);
        @field(model, field) = false;
    }
    try std.testing.expect(model.canCloseActiveTab());
}

test "profile editor saves compatible prefs JSON before reloading rows" {
    const stores = try Stores.init();
    defer stores.deinit();
    var model = app.initialModel(stores.tabs, stores.projects, stores.profiles);
    defer model.active_tab_by_workspace.deinit(std.testing.allocator);
    _ = try addProfile(stores, 1, .codex, "Default");
    model.preferences_loaded = true;
    model.profiles_loaded = true;
    var fx = app.Effects.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    app.update(&model, .open_preferences, &fx);
    app.update(&model, .show_preferences_codex, &fx);
    model.profile_draft.model.set("gpt-5.6");
    model.profile_draft.sandbox.set("workspace-write");
    model.profile_draft.full_auto = true;
    model.profile_dirty = true;
    app.update(&model, .save_profile, &fx);
    try std.testing.expect(model.profiles_saving);
    try std.testing.expectEqual(@as(usize, 1), fx.pendingDbCount());

    try fx.feedDbResult(app.profile_write_key, .exec, .ok, "");
    while (fx.takeMsg()) |msg| app.update(&model, msg, &fx);
    try std.testing.expect(!model.profiles_saving);
    try std.testing.expectEqual(@as(usize, 1), fx.pendingDbCount());
}
