const support = @import("support.zig");
const std = support.std;
const app = support.app;
const profiles = support.profiles;
const Stores = support.Stores;
const addProfile = support.addProfile;
const envValue = support.envValue;

test "shell and tool allocation failure leave no tab or pending process" {
    for ([_]bool{ false, true }) |ghostty| {
        for ([_]bool{ false, true }) |tool| {
            var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
            const stores = try Stores.initWithTabAllocator(failing.allocator());
            defer stores.deinit();
            var model = app.initialModel(stores.tabs, stores.projects, stores.profiles);
            defer model.terminal_state.deinit(failing.allocator());
            model.use_ghostty = ghostty;
            model.active_workspace_id = stores.projects.attachPlaceholder("/tmp/start-failure").?.workspace_id;
            _ = try addProfile(stores, 1, .codex, "Default");
            model.profile_edit.loaded = true;
            _ = model.tools.setExecutable(.codex, "/usr/local/bin/codex");
            try std.testing.expect(model.setToolExecutable(.codex, "/usr/local/bin/codex"));
            try stores.tabs.free_pty_keys.ensureTotalCapacity(failing.allocator(), 1);
            failing.fail_index = failing.alloc_index;
            failing.resize_fail_index = failing.resize_index;
            var fx = app.Effects.init(std.testing.allocator);
            defer fx.deinit();
            fx.executor = .fake;
            app.update(&model, if (tool) .{ .launch_agent = .codex } else .open_active_terminal, &fx);
            try std.testing.expectEqual(@as(usize, 0), stores.tabs.items.items.len);
            try std.testing.expectEqual(@as(usize, 0), fx.pendingPtyCount());
            try std.testing.expectEqual(@import("../effect_keys.zig").first(.pty), stores.tabs.free_pty_keys.items[0]);
            try std.testing.expectEqual(@as(u64, 0), model.terminal_state.active(model.active_workspace_id));
        }
    }
}

test "failed Ghostty handoff stays closable and retries with a fresh tab identity" {
    for ([_]bool{ false, true }) |tool| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        const stores = try Stores.initWithTabAllocator(failing.allocator());
        defer stores.deinit();
        var model = app.initialModel(stores.tabs, stores.projects, stores.profiles);
        defer model.terminal_state.deinit(failing.allocator());
        model.use_ghostty = true;
        model.active_workspace_id = stores.projects.attachPlaceholder("/tmp/handoff-failure").?.workspace_id;
        _ = try addProfile(stores, 1, .codex, "Default");
        model.profile_edit.loaded = true;
        _ = model.tools.setExecutable(.codex, "/usr/local/bin/codex");
        try std.testing.expect(model.setToolExecutable(.codex, "/usr/local/bin/codex"));
        try stores.tabs.items.ensureTotalCapacity(failing.allocator(), 1);
        try stores.tabs.free_pty_keys.ensureTotalCapacity(failing.allocator(), 1);
        try model.terminal_state.active_by_workspace.ensureTotalCapacity(failing.allocator(), 1);
        failing.fail_index = failing.alloc_index;
        failing.resize_fail_index = failing.resize_index;
        var fx = app.Effects.init(std.testing.allocator);
        defer fx.deinit();
        fx.executor = .fake;
        app.update(&model, if (tool) .{ .launch_agent = .codex } else .open_active_terminal, &fx);
        const failed = stores.tabs.items.items[0];
        try std.testing.expectEqual(app.TerminalPhase.failed, failed.phase);
        try std.testing.expect(failed.pending_launch == null);
        try std.testing.expectEqual(@as(usize, 0), fx.pendingPtyCount());
        app.update(&model, .{ .close_tab = failed.id }, &fx);
        try std.testing.expectEqual(@as(usize, 0), stores.tabs.items.items.len);
        failing.fail_index = std.math.maxInt(usize);
        failing.resize_fail_index = std.math.maxInt(usize);
        app.update(&model, if (tool) .{ .launch_agent = .codex } else .open_active_terminal, &fx);
        const retried = stores.tabs.items.items[0];
        try std.testing.expect(retried.id != failed.id);
        try std.testing.expectEqual(failed.pty, retried.pty);
        try std.testing.expect(retried.pending_launch != null);
    }
}

test "tabs are projected per active worktree" {
    const stores = try Stores.init();
    defer stores.deinit();
    var model = app.initialModel(stores.tabs, stores.projects, stores.profiles);
    defer model.terminal_state.deinit(std.testing.allocator);
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
    model.terminal_state.select(stores.tabs, one.workspace_id, 7);

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
    defer model.terminal_state.deinit(std.testing.allocator);
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
    defer model.terminal_state.deinit(std.testing.allocator);

    model.setUserShell("/opt/homebrew/bin/fish");
    try std.testing.expectEqualStrings("/opt/homebrew/bin/fish", model.userShell());
    model.setUserShell("relative/fish");
    try std.testing.expectEqualStrings("/bin/zsh", model.userShell());
}

test "Claude profiles launch worktree-owned PTYs with matching argv and environment" {
    const stores = try Stores.init();
    defer stores.deinit();
    var model = app.initialModel(stores.tabs, stores.projects, stores.profiles);
    defer model.terminal_state.deinit(std.testing.allocator);
    const attached = stores.projects.attachPlaceholder("/tmp/canopy-profile-project").?;
    model.active_workspace_id = attached.workspace_id;
    const profile = try addProfile(stores, 1, .claude, "Default");
    try std.testing.expect(profile.prefs.model.set("opus"));
    try std.testing.expect(profile.prefs.permission_mode.set("plan"));
    try std.testing.expect(profile.prefs.base_url.set("https://proxy.example"));
    try std.testing.expect(profile.prefs.custom_env.set("{\"CANOPY_TEST_COLOR\":\"violet\",\"PATH\":\"blocked\"}"));
    model.profile_edit.loaded = true;
    model.tools.pending_checks = 0;
    _ = model.tools.setExecutable(.claude, "/usr/local/bin/claude");
    try std.testing.expect(model.setToolExecutable(.claude, "/usr/local/bin/claude"));
    var fx = app.Effects.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    app.update(&model, .{ .launch_agent = .claude }, &fx);
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

    app.update(&model, .{ .launch_agent = .claude }, &fx);
    try std.testing.expectEqualStrings("Claude Code #2", stores.tabs.items.items[1].title.slice());
}

test "Codex dangerous bypass takes precedence over approval sandbox and full auto" {
    const stores = try Stores.init();
    defer stores.deinit();
    var model = app.initialModel(stores.tabs, stores.projects, stores.profiles);
    defer model.terminal_state.deinit(std.testing.allocator);
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
    model.profile_edit.loaded = true;
    model.tools.pending_checks = 0;
    _ = model.tools.setExecutable(.codex, "/usr/local/bin/codex");
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
    defer model.terminal_state.deinit(std.testing.allocator);
    const attached = stores.projects.attachPlaceholder("/tmp/canopy-codex-lifecycle").?;
    model.active_workspace_id = attached.workspace_id;
    _ = try addProfile(stores, 9, .codex, "Default");
    model.profile_edit.loaded = true;
    model.tools.pending_checks = 0;
    _ = model.tools.setExecutable(.codex, "/usr/local/bin/codex");
    try std.testing.expect(model.setToolExecutable(.codex, "/usr/local/bin/codex"));
    var fx = app.Effects.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    app.update(&model, .{ .launch_agent = .codex }, &fx);
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

    app.update(&model, .{ .launch_agent = .codex }, &fx);
    const second = fx.pendingPtyAt(0) orelse return error.MissingPty;
    try std.testing.expectEqual(first_key, second.key);
    try std.testing.expect(stores.tabs.items.items[0].id != first_tab_id);
    try std.testing.expectEqual(@as(usize, 1), fx.pendingPtyCount());
}

test "full Ghostty owns tool PTY and keeps launch alive until host teardown" {
    const stores = try Stores.init();
    defer stores.deinit();
    var model = app.initialModel(stores.tabs, stores.projects, stores.profiles);
    defer model.terminal_state.deinit(std.testing.allocator);
    model.use_ghostty = true;
    const attached = stores.projects.attachPlaceholder("/tmp/canopy-ghostty").?;
    model.active_workspace_id = attached.workspace_id;
    _ = try addProfile(stores, 9, .codex, "Default");
    model.profile_edit.loaded = true;
    model.tools.pending_checks = 0;
    _ = model.tools.setExecutable(.codex, "/usr/local/bin/codex");
    try std.testing.expect(model.setToolExecutable(.codex, "/usr/local/bin/codex"));
    var fx = app.Effects.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    app.update(&model, .{ .launch_agent = .codex }, &fx);
    const first = stores.tabs.items.items[0];
    try std.testing.expectEqual(@as(usize, 0), fx.pendingPtyCount());
    try std.testing.expect(std.mem.indexOf(u8, first.pending_launch.?.command, "'/usr/local/bin/codex'") != null);
    app.update(&model, .{ .close_tab = first.id }, &fx);
    try std.testing.expect(!fx.ptyKillRequested(first.pty));
    try std.testing.expectEqual(app.TerminalPhase.closing, stores.tabs.items.items[0].phase);
    app.update(&model, .{ .terminal_event = .{ .key = first.pty, .kind = .exit, .reason = .cancelled } }, &fx);
    try std.testing.expectEqual(@as(usize, 0), stores.tabs.items.items.len);
    app.update(&model, .{ .launch_agent = .codex }, &fx);
    try std.testing.expect(stores.tabs.items.items[0].id != first.id);
    try std.testing.expectEqual(first.pty, stores.tabs.items.items[0].pty);
    try std.testing.expectEqual(@as(usize, 0), fx.pendingPtyCount());
}

test "full Ghostty shell launch bypasses Native SDK PTY" {
    const stores = try Stores.init();
    defer stores.deinit();
    var model = app.initialModel(stores.tabs, stores.projects, stores.profiles);
    defer model.terminal_state.deinit(std.testing.allocator);
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
    defer model.terminal_state.deinit(std.testing.allocator);
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
    defer model.terminal_state.deinit(std.testing.allocator);
    model.use_ghostty = true;
    model.active_workspace_id = stores.projects.attachPlaceholder("/tmp/menu-modal").?.workspace_id;
    var fx = app.Effects.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    app.update(&model, .open_active_terminal, &fx);
    model.preferences_edit.open = true;
    try std.testing.expect(!model.canCloseActiveTab());
    app.update(&model, .close_active_tab, &fx);
    try std.testing.expectEqual(app.TerminalPhase.starting, stores.tabs.items.items[0].phase);
    model.preferences_edit.open = false;
    inline for (.{ "create", "removal", "detach" }) |field| {
        @field(model.workspace_dialogs, field).open = true;
        try std.testing.expect(!model.canCloseActiveTab());
        app.update(&model, .close_active_tab, &fx);
        try std.testing.expectEqual(app.TerminalPhase.starting, stores.tabs.items.items[0].phase);
        @field(model.workspace_dialogs, field).open = false;
    }
    inline for (.{ "pending_switch", "pending_delete" }) |field| {
        @field(model.profile_edit, field) = if (comptime std.mem.eql(u8, field, "pending_switch")) .{ .profile = 1 } else 1;
        try std.testing.expect(!model.canCloseActiveTab());
        app.update(&model, .close_active_tab, &fx);
        try std.testing.expectEqual(app.TerminalPhase.starting, stores.tabs.items.items[0].phase);
        @field(model.profile_edit, field) = null;
    }
    try std.testing.expect(model.canCloseActiveTab());
}
