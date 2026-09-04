//! Terminal actions: one application feature boundary.
const types = @import("app_types.zig");
const Model = types.Model;
const Msg = types.Msg;
const Effects = types.Effects;
const native_sdk = @import("native_sdk");
const workspaces = @import("workspaces.zig");
const terminal_transport = @import("terminal_transport.zig");
const terminal_tabs = @import("terminal_tabs.zig");
const TerminalTool = terminal_tabs.Tool;
const TerminalTab = terminal_tabs.Tab;

const terminal_bootstrap = "cd -- \"$1\" && exec \"$2\" -l";
pub const TerminalStartSpec = struct {
    workspace: *const workspaces.Worktree,
    title: []const u8,
    tool: TerminalTool = .shell,
    profile_id: []const u8 = "",
    argv: []const []const u8,
    env: []const native_sdk.PtyEnvEntry,
};

pub fn startTerminal(model: *Model, fx: *Effects, spec: TerminalStartSpec) void {
    // New sessions must not prolong teardown of their owning worktree/project.
    if (model.teardown.target()) |target| switch (target) {
        .workspace => |id| if (id == spec.workspace.id) return,
        .project => |id| {
            const project = model.project_store.projectForWorkspace(spec.workspace.id) orelse return;
            if (project.id == id) return;
        },
    };
    if (model.git.active.kind == .remove_worktree and model.git.active.workspace_id == spec.workspace.id) return;
    const identity = model.terminal_state.allocate(model.tab_store);
    var tab = TerminalTab{
        .id = identity.tab_id,
        .workspace_id = spec.workspace.id,
        .pty = identity.pty_key,
        .tool = spec.tool,
    };
    _ = tab.title.set(spec.title);
    _ = tab.path.set(spec.workspace.path.slice());
    _ = tab.branch.set(spec.workspace.branch.slice());
    _ = tab.profile_id.set(spec.profile_id);
    model.tab_store.items.append(model.tab_store.allocator, tab) catch {
        model.terminal_state.rollback(model.tab_store, identity);
        model.status_text = if (spec.tool == .shell) "The host could not allocate another terminal tab" else "The host could not allocate another tool tab";
        return;
    };
    model.setActiveTab(spec.workspace.id, identity.tab_id);
    model.status_text = switch (spec.tool) {
        .shell => "Starting login shell",
        .claude => "Starting Claude Code",
        .codex => "Starting Codex",
    };

    const added = &model.tab_store.items.items[model.tab_store.items.items.len - 1];
    terminal_transport.start(model.use_ghostty, model.tab_store.allocator, added, spec.argv, spec.env, fx) catch {
        _ = model.terminal_state.exit(model.tab_store, added.pty, 0, false);
        model.status_text = "Could not prepare terminal session";
    };
}

pub fn openTerminal(model: *Model, fx: *Effects, workspace_id: u64) void {
    if (!model.project_store.workspaceAvailable(workspace_id)) return;
    const workspace = model.project_store.findWorktree(workspace_id) orelse return;
    if (!workspace.active) return;
    model.active_workspace_id = workspace_id;

    // cwd/shell remain argv data, not interpolated shell source. The neutral
    // wrapper changes cwd, then the login shell owns startup and environment.
    const user_shell = model.userShell();
    startTerminal(model, fx, .{
        .workspace = workspace,
        .title = workspace.name.slice(),
        .argv = &.{ "/bin/sh", "-c", terminal_bootstrap, "canopy-shell", workspace.path.slice(), user_shell },
        .env = &.{
            .{ .name = "SHELL", .value = user_shell },
            .{ .name = "COLORTERM", .value = "truecolor" },
        },
    });
}

pub fn removeTab(model: *Model, fx: *Effects, index: usize) void {
    const removed = model.terminal_state.removeAt(model.tab_store, index);
    terminal_transport.forget(model.use_ghostty, fx, removed.pty_key);
}

pub fn closeTerminal(model: *Model, fx: *Effects, tab_id: u64) void {
    switch (model.terminal_state.close(model.tab_store, tab_id)) {
        .missing => return,
        .removed => |removed| {
            terminal_transport.forget(model.use_ghostty, fx, removed.pty_key);
            model.status_text = "Terminal closed";
        },
        .waiting => |pty_key| {
            terminal_transport.close(model.use_ghostty, fx, pty_key);
            model.status_text = "Closing terminal";
        },
    }
}

pub fn cycleTab(model: *Model, forward: bool) void {
    _ = model.terminal_state.cycle(model.tab_store, model.active_workspace_id, forward) orelse return;
    model.status_text = "Terminal focused";
}

pub fn hasTabsForWorkspace(model: *const Model, workspace_id: u64) bool {
    for (model.tab_store.items.items) |tab| {
        if (tab.workspace_id == workspace_id) return true;
    }
    return false;
}

pub fn hasTabsForProject(model: *Model, project_id: u64) bool {
    for (model.tab_store.items.items) |tab| {
        const project = model.project_store.projectForWorkspace(tab.workspace_id) orelse continue;
        if (project.id == project_id) return true;
    }
    return false;
}

pub fn closeTabsForWorkspace(model: *Model, fx: *Effects, workspace_id: u64) void {
    const Sink = struct {
        model: *Model,
        fx: *Effects,
        pub fn closed(self: @This(), result: @import("terminal_controller.zig").Close) void {
            switch (result) {
                .missing => {},
                .waiting => |key| terminal_transport.close(self.model.use_ghostty, self.fx, key),
                .removed => |removed| terminal_transport.forget(self.model.use_ghostty, self.fx, removed.pty_key),
            }
        }
    };
    model.terminal_state.closeWorkspace(model.tab_store, workspace_id, Sink{ .model = model, .fx = fx });
}

pub fn closeTabsForProject(model: *Model, fx: *Effects, project_id: u64) void {
    const project = model.project_store.findProject(project_id) orelse return;
    for (project.worktrees.items) |worktree| closeTabsForWorkspace(model, fx, worktree.id);
}

pub fn handleTerminalEvent(model: *Model, fx: *Effects, event: native_sdk.EffectPtyEvent) void {
    switch (event.kind) {
        .output => switch (model.terminal_state.output(model.tab_store, event.key)) {
            .running => model.status_text = "Shell running",
            .missing, .ignored => return,
        },
        .exit => switch (model.terminal_state.exit(model.tab_store, event.key, event.code, event.reason == .exited)) {
            .missing => return,
            .removed => |removed| {
                terminal_transport.forget(model.use_ghostty, fx, removed.pty_key);
                model.status_text = "Terminal closed";
            },
            .completed => |phase| model.status_text = if (phase == .exited) "Shell exited" else "Shell failed",
        },
        .write => unreachable,
    }
}

pub fn handle(model: *Model, msg: Msg, fx: *Effects) void {
    switch (msg) {
        .open_terminal => |id| {
            model.sidebar.overlay_open = false;
            openTerminal(model, fx, id);
        },
        .open_active_terminal => openTerminal(model, fx, model.active_workspace_id),
        .activate_tab => |id| {
            if (!model.terminal_state.activate(model.tab_store, model.active_workspace_id, id)) return;
            model.status_text = "Terminal focused";
        },
        .previous_tab => cycleTab(model, false),
        .next_tab => cycleTab(model, true),
        .close_tab => |id| closeTerminal(model, fx, id),
        .close_active_tab => if (model.canCloseActiveTab()) closeTerminal(model, fx, model.activeTabId(model.active_workspace_id)),
        .terminal_event => |event| handleTerminalEvent(model, fx, event),
        else => unreachable,
    }
}
