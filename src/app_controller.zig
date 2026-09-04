//! Application update loop and host-effect orchestration.
const std = @import("std");
const native_sdk = @import("native_sdk");
const canvas = native_sdk.canvas;
const model_mod = @import("model.zig");
const messages = @import("messages.zig");
const preferences_mod = @import("preferences.zig");
const profile_editor = @import("profile_editor.zig");
const profiles_mod = @import("profiles.zig");
const terminal_tabs = @import("terminal_tabs.zig");
const theme = @import("theme.zig");
const tool_launch = @import("tool_launch.zig");
const tool_registry = @import("tool_registry.zig");
const workspaces = @import("workspaces.zig");
const git_workflow = @import("git_workflow.zig");
const git_cli = @import("git_cli.zig");

pub const Model = model_mod.Model;
pub const Msg = messages.Msg;
pub const Effects = native_sdk.Effects(Msg);
const GitOperation = git_workflow.Operation;
const TerminalTool = terminal_tabs.Tool;
const TerminalTab = terminal_tabs.Tab;
const sidebar_divider_width = model_mod.sidebar_divider_width;
const terminal_bootstrap = "cd -- \"$1\" && exec \"$2\" -l";

/// One zero-backlog lane for every Git workflow. A running command owns the
/// lane until its exact EffectExit arrives; callers are rejected, never queued.
/// Native SDK spawn has no execution timeout, so slow repositories are allowed
/// to finish naturally without a polling loop creating more host work.
fn spawnGit(model: *Model, fx: *Effects, operation: GitOperation) void {
    if (model.git.busy()) {
        model.status_text = "Another Git operation is still running";
        return;
    }
    const request = operation.request(model.project_store) orelse return;
    const key = model.git.begin(operation) orelse return;
    git_cli.execute(fx, key, request) catch {
        _ = model.git.finish(key);
        model.status_text = "Branch name is too long";
        return;
    };
    model.status_text = operation.progress();
}

fn detectRepository(model: *Model, fx: *Effects, project_id: u64) void {
    spawnGit(model, fx, .{ .kind = .detect_repo, .project_id = project_id });
}

fn refreshWorktrees(model: *Model, fx: *Effects, project_id: u64) void {
    const project = model.project_store.findProject(project_id) orelse return;
    if (!project.is_git) return;
    spawnGit(model, fx, .{ .kind = .list_worktrees, .project_id = project_id });
}

fn validateNewBranch(model: *Model, fx: *Effects, project_id: u64, branch: []const u8, target_path: []const u8) void {
    var operation = GitOperation{ .kind = .validate_branch, .project_id = project_id };
    if (!operation.branch.set(branch) or !operation.target_path.set(target_path)) {
        model.status_text = "Branch name or worktree path is too long";
        return;
    }
    spawnGit(model, fx, operation);
}

const store_read_key: u64 = 9_001;

fn persistProjects(model: *Model, fx: *Effects) void {
    const key = switch (model.project_io.requestWrite()) {
        .unavailable, .deferred => return,
        .start => |value| value,
    };
    var buffer: [workspaces.max_store_bytes]u8 = undefined;
    const bytes = model.project_store.serializeAttached(&buffer) orelse {
        _ = model.project_io.writeFinished(key);
        model.status_text = "Too many attached projects to persist";
        return;
    };
    fx.writeFile(.{
        .key = key,
        .path = model.project_io.path.slice(),
        .bytes = bytes,
        .on_result = Effects.fileMsg(.store_done),
    });
}

fn detectNextRestoredProject(model: *Model, fx: *Effects) void {
    if (!model.project_io.scanning() or model.git.busy()) return;
    if (model.project_io.nextAttachedProject(model.project_store)) |project_id| {
        spawnGit(model, fx, .{ .kind = .restore_check, .project_id = project_id });
        return;
    }
    model.status_text = if (model.project_store.hasProjects()) "Projects restored" else "Ready";
}

fn preflightRemoveStatus(model: *Model, fx: *Effects, workspace_id: u64) void {
    const worktree = model.project_store.findWorktree(workspace_id) orelse return;
    if (worktree.is_main or !worktree.active) return;
    spawnGit(model, fx, .{ .kind = .remove_status, .workspace_id = workspace_id });
}

fn preflightRemoveSubmodules(model: *Model, fx: *Effects, workspace_id: u64) void {
    spawnGit(model, fx, .{ .kind = .remove_submodules, .workspace_id = workspace_id });
}

fn finishRemovePreflight(model: *Model, fx: *Effects) void {
    const review = model.teardown.reviewed(model.workspace_dialogs.removal.safety);
    switch (review) {
        .initial, .changed => {
            model.workspace_dialogs.removal.review();
            model.status_text = if (review == .changed) "Worktree safety state changed; review again" else "Review worktree removal";
        },
        .remove => |removal| executeWorktreeRemoval(model, fx, removal.workspace_id, removal.force),
    }
}

fn preflightRemoveUnmerged(model: *Model, fx: *Effects, workspace_id: u64) void {
    const worktree = model.project_store.findWorktree(workspace_id) orelse return;
    const project = model.project_store.projectForWorkspace(workspace_id) orelse return;
    if (worktree.branch.eql("(unknown)")) {
        model.workspace_dialogs.removal.safety.unmerged_count = 1;
        finishRemovePreflight(model, fx);
        return;
    }
    spawnGit(model, fx, .{ .kind = .remove_unmerged, .project_id = project.id, .workspace_id = workspace_id });
}

fn executeWorktreeRemoval(model: *Model, fx: *Effects, workspace_id: u64, force: bool) void {
    const worktree = model.project_store.findWorktree(workspace_id) orelse return;
    const project = model.project_store.projectForWorkspace(workspace_id) orelse return;
    var operation = GitOperation{ .kind = .remove_worktree, .project_id = project.id, .workspace_id = workspace_id, .force = force };
    _ = operation.target_path.set(worktree.path.slice());
    spawnGit(model, fx, operation);
}

// Borrowed launch data: startTerminal copies metadata and the selected backend
// takes ownership of argv/env before the caller releases its temporary arena.
const TerminalStartSpec = struct {
    workspace: *const workspaces.Worktree,
    title: []const u8,
    tool: TerminalTool = .shell,
    profile_id: []const u8 = "",
    argv: []const []const u8,
    env: []const native_sdk.PtyEnvEntry,
};

fn startTerminal(model: *Model, fx: *Effects, spec: TerminalStartSpec) void {
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

    if (model.use_ghostty) {
        const added = &model.tab_store.items.items[model.tab_store.items.items.len - 1];
        added.pending_launch = @import("terminal_launch.zig").Pending.create(model.tab_store.allocator, spec.workspace.path.slice(), spec.argv, spec.env) catch {
            added.phase = .failed;
            model.status_text = "Could not prepare Ghostty session";
            return;
        };
        return;
    }
    fx.ptySpawn(.{
        .key = identity.pty_key,
        .argv = spec.argv,
        .cols = 100,
        .rows = 30,
        .term = "xterm-256color",
        .env = spec.env,
        .on_event = Effects.ptyMsg(.terminal_event),
    });
}

fn openTerminal(model: *Model, fx: *Effects, workspace_id: u64) void {
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

fn removeTab(model: *Model, fx: *Effects, index: usize) void {
    const removed = model.terminal_state.removeAt(model.tab_store, index);
    if (!model.use_ghostty) fx.ptyForget(removed.pty_key);
}

fn closeTerminal(model: *Model, fx: *Effects, tab_id: u64) void {
    switch (model.terminal_state.close(model.tab_store, tab_id)) {
        .missing => return,
        .removed => |removed| {
            if (!model.use_ghostty) fx.ptyForget(removed.pty_key);
            model.status_text = "Terminal closed";
        },
        .waiting => |pty_key| {
            if (!model.use_ghostty) fx.ptyKill(pty_key);
            model.status_text = "Closing terminal";
        },
    }
}

fn cycleTab(model: *Model, forward: bool) void {
    _ = model.terminal_state.cycle(model.tab_store, model.active_workspace_id, forward) orelse return;
    model.status_text = "Terminal focused";
}

fn hasTabsForWorkspace(model: *const Model, workspace_id: u64) bool {
    for (model.tab_store.items.items) |tab| {
        if (tab.workspace_id == workspace_id) return true;
    }
    return false;
}

fn hasTabsForProject(model: *Model, project_id: u64) bool {
    for (model.tab_store.items.items) |tab| {
        const project = model.project_store.projectForWorkspace(tab.workspace_id) orelse continue;
        if (project.id == project_id) return true;
    }
    return false;
}

fn closeTabsForWorkspace(model: *Model, fx: *Effects, workspace_id: u64) void {
    for (model.tab_store.items.items) |*tab| {
        if (tab.workspace_id != workspace_id or tab.phase == .closing) continue;
        if (tab.phase == .exited or tab.phase == .failed) continue;
        tab.phase = .closing;
        if (!model.use_ghostty) fx.ptyKill(tab.pty);
    }
    // Already-ended tabs have no terminal event left to await.
    var index = model.tab_store.items.items.len;
    while (index > 0) {
        index -= 1;
        const tab = model.tab_store.items.items[index];
        if (tab.workspace_id == workspace_id and (tab.phase == .exited or tab.phase == .failed)) removeTab(model, fx, index);
    }
}

fn closeTabsForProject(model: *Model, fx: *Effects, project_id: u64) void {
    const project = model.project_store.findProject(project_id) orelse return;
    for (project.worktrees.items) |worktree| closeTabsForWorkspace(model, fx, worktree.id);
}

fn maybeFinishPendingTeardown(model: *Model, fx: *Effects) void {
    const target = model.teardown.waitingFor() orelse return;
    const has_tabs = switch (target) {
        .workspace => |id| hasTabsForWorkspace(model, id),
        .project => |id| hasTabsForProject(model, id),
    };
    if (has_tabs) return;
    switch (model.teardown.terminalsClosed() orelse return) {
        .recheck => |workspace_id| {
            model.workspace_dialogs.removal.safety = .{};
            preflightRemoveStatus(model, fx, workspace_id);
        },
        .detach => |project_id| {
            _ = model.project_store.detach(project_id);
            if (model.project_store.projectForWorkspace(model.active_workspace_id)) |active_project| {
                if (active_project.id == project_id) model.active_workspace_id = model.project_store.firstWorkspaceId();
            } else if (model.active_workspace_id != 0) {
                model.active_workspace_id = model.project_store.firstWorkspaceId();
            }
            persistProjects(model, fx);
            model.status_text = "Project detached";
        },
    }
}

pub const preferences_write_key: u64 = 8_001;
const preferences_upsert_sql = "INSERT OR REPLACE INTO preferences (key, value) VALUES (?1, ?2);";

fn openPreferences(model: *Model) void {
    if (model.preferences_edit.openDialog()) model.status_text = "Preferences opened";
}

fn closePreferences(model: *Model) void {
    if (model.profile_edit.saving() or !model.preferences_edit.closeDialog()) return;
    model.profile_edit.close(model.profile_store);
    model.status_text = "Preferences unchanged";
}

fn savePreferences(model: *Model, fx: *Effects) void {
    const prepared = switch (model.preferences_edit.prepareSave()) {
        .skip => return,
        .invalid => |message| {
            model.status_text = message;
            return;
        },
        .ready => |value| value,
    };
    const statements = [_]native_sdk.EffectDbStatement{
        .{ .sql = preferences_upsert_sql, .params = &.{ .{ .text = preferences_mod.key_reopen_last_workspace }, .{ .text = prepared.reopen } } },
        .{ .sql = preferences_upsert_sql, .params = &.{ .{ .text = preferences_mod.key_native_appearance }, .{ .text = prepared.appearance } } },
        .{ .sql = preferences_upsert_sql, .params = &.{ .{ .text = preferences_mod.key_worktrees_base_dir }, .{ .text = prepared.base_dir } } },
    };
    model.status_text = "Saving preferences";
    fx.dbExec(.{
        .key = preferences_write_key,
        .statements = &statements,
        .on_result = Effects.dbMsg(.preferences_db_done),
    });
}

pub const profiles_load_key: u64 = 8_002;
pub const profile_write_key: u64 = 8_003;

fn openProfileSection(model: *Model, agent_type: profiles_mod.AgentType) void {
    if (!model.profile_edit.openAgent(model.profile_store, agent_type)) return;
    model.preferences_edit.select(if (agent_type == .codex) .codex else .claude);
}

fn reloadProfiles(model: *Model, fx: *Effects, select_database_id: []const u8) void {
    model.profile_edit.beginReload(model.profile_store, select_database_id);
    fx.dbQuery(.{ .key = profiles_load_key, .sql = profiles_mod.load_sql, .on_result = Effects.dbMsg(.profiles_load_done) });
}

fn finishProfilesLoad(model: *Model) void {
    const agent = model.preferences_edit.agent() orelse .claude;
    if (!model.profile_edit.finishLoad(model.profile_store, agent)) model.status_text = "Agent profiles could not be loaded";
}

fn createProfileDraft(model: *Model) void {
    if (!model.preferencesProfileSelected()) return;
    const agent = model.preferences_edit.agent() orelse return;
    if (model.profile_edit.create(model.profile_store, agent)) |message| model.status_text = message;
}

fn saveProfile(model: *Model, fx: *Effects) void {
    var json_buffer: [profiles_mod.max_long_pref_bytes * 3]u8 = undefined;
    const save = switch (model.profile_edit.prepareSave(model.profile_store, &json_buffer)) {
        .skip => return,
        .invalid => |message| {
            model.status_text = message;
            return;
        },
        .ready => |prepared| prepared,
    };
    const statements = if (save.is_new)
        [_]native_sdk.EffectDbStatement{.{
            .sql = "INSERT INTO agent_profiles (id, agent_type, name, is_default, sort_index, prefs_json, api_key_enc) VALUES (?1, ?2, ?3, 0, ?4, ?5, NULL);",
            .params = &.{ .{ .text = save.id }, .{ .text = @tagName(save.agent) }, .{ .text = save.name }, .{ .integer = save.sort_index }, .{ .text = save.prefs_json } },
        }}
    else
        [_]native_sdk.EffectDbStatement{.{
            .sql = "UPDATE agent_profiles SET name = ?1, prefs_json = ?2, sort_index = ?3, updated_at = datetime('now') WHERE id = ?4;",
            .params = &.{ .{ .text = save.name }, .{ .text = save.prefs_json }, .{ .integer = save.sort_index }, .{ .text = save.id } },
        }};
    model.status_text = "Saving agent profile";
    fx.dbExec(.{ .key = profile_write_key, .statements = &statements, .on_result = Effects.dbMsg(.profile_db_done) });
}

fn deleteProfile(model: *Model, fx: *Effects) void {
    const id = model.profile_edit.prepareDelete(model.profile_store) orelse return;
    model.status_text = "Deleting agent profile";
    fx.dbExec(.{
        .key = profile_write_key,
        .statements = &.{.{ .sql = "DELETE FROM agent_profiles WHERE id = ?1;", .params = &.{.{ .text = id }} }},
        .on_result = Effects.dbMsg(.profile_db_done),
    });
}

fn startToolChecks(model: *Model, fx: *Effects) void {
    model.tools.beginDiscovery();
    const shell = model.userShell();
    // Absolute /usr/bin/which resolves external executables from the PATH
    // produced by the user's login shell, ignoring aliases/functions. The
    // collected path is reused verbatim for PTY launch so discovery and start
    // cannot drift to different global installations.
    fx.spawn(.{ .key = tool_registry.claude_check_key, .argv = &.{ shell, "-lc", "/usr/bin/which claude" }, .output = .collect, .on_exit = Effects.exitMsg(.tool_check_done) });
    fx.spawn(.{ .key = tool_registry.codex_check_key, .argv = &.{ shell, "-lc", "/usr/bin/which codex" }, .output = .collect, .on_exit = Effects.exitMsg(.tool_check_done) });
}

pub const resolvedToolExecutable = tool_launch.resolvedExecutable;

fn toolAvailable(model: *const Model, tool: TerminalTool) bool {
    return model.tools.available(tool);
}

fn toolTitle(model: *const Model, workspace_id: u64, tool: TerminalTool, profile: *const profiles_mod.Profile, out: []u8) ?[]const u8 {
    var base_buffer: [profiles_mod.max_profile_name_bytes + 32]u8 = undefined;
    const base = if (profile.name.eql("Default"))
        profile.agent_type.displayName()
    else
        std.fmt.bufPrint(&base_buffer, "{s} ({s})", .{ profile.agent_type.displayName(), profile.name.slice() }) catch return null;
    var same: usize = 0;
    for (model.tab_store.items.items) |tab| {
        if (tab.workspace_id == workspace_id and tab.tool == tool) {
            const title = tab.title.slice();
            const numbered = title.len > base.len + 2 and std.mem.startsWith(u8, title, base) and std.mem.eql(u8, title[base.len .. base.len + 2], " #");
            if (std.mem.eql(u8, title, base) or numbered) same += 1;
        }
    }
    if (same == 0) return std.fmt.bufPrint(out, "{s}", .{base}) catch null;
    return std.fmt.bufPrint(out, "{s} #{d}", .{ base, same + 1 }) catch null;
}

fn spawnProfileTool(model: *Model, fx: *Effects, profile: *const profiles_mod.Profile) void {
    const workspace = model.project_store.findWorktree(model.active_workspace_id) orelse return;
    if (!workspace.active) return;
    const tool: TerminalTool = switch (profile.agent_type) {
        .claude => .claude,
        .codex => .codex,
    };
    if (!toolAvailable(model, tool)) {
        model.status_text = if (tool == .claude) "Claude Code is not available in the login shell" else "Codex is not available in the login shell";
        return;
    }

    var env_arena = std.heap.ArenaAllocator.init(model.tab_store.allocator);
    defer env_arena.deinit();
    const launch = tool_launch.Spec.build(
        env_arena.allocator(),
        model.userShell(),
        workspace.path.slice(),
        model.toolExecutable(tool),
        profile,
    ) orelse return;

    var title_buffer: [workspaces.max_name_bytes]u8 = undefined;
    const title = toolTitle(model, workspace.id, tool, profile, &title_buffer) orelse profile.agent_type.displayName();
    startTerminal(model, fx, .{
        .workspace = workspace,
        .title = title,
        .tool = tool,
        .profile_id = profile.id.slice(),
        .argv = launch.argv(),
        .env = launch.env(),
    });
}

fn launchDefaultTool(model: *Model, fx: *Effects, agent_type: profiles_mod.AgentType) void {
    if (!model.profile_edit.loaded) return;
    const profile = model.profile_store.default(agent_type) orelse return;
    spawnProfileTool(model, fx, profile);
}

fn launchProfileTool(model: *Model, fx: *Effects, runtime_id: u64) void {
    if (!model.profile_edit.loaded) return;
    const profile = model.profile_store.find(runtime_id) orelse return;
    spawnProfileTool(model, fx, profile);
}

fn handlePreferencesLoadResult(model: *Model, fx: *Effects, result: native_sdk.EffectDbResult) void {
    if (result.key != preferences_load_key) return;
    switch (result.kind) {
        .page => {
            if (result.outcome == .ok) {
                model.preferences_edit.loadPage(result.bytes);
            } else {
                model.preferences_edit.load_valid = false;
            }
        },
        .done => {
            model.preferences_edit.finishLoad(result.outcome == .ok);
            finishPreferencesLoad(model, fx);
        },
        .exec => model.preferences_edit.load_valid = false,
    }
}

fn handlePreferencesWriteResult(model: *Model, result: native_sdk.EffectDbResult) void {
    if (result.key != preferences_write_key or result.kind != .exec) return;
    const completion = model.preferences_edit.finishSave(result.outcome == .ok, result.outcome == .busy);
    if (!completion.handled) return;
    if (completion.committed) {
        const base_dir = if (model.preferences_edit.saved.worktrees_base_dir.len > 0)
            model.preferences_edit.saved.worktrees_base_dir.slice()
        else
            model.default_worktrees_base.slice();
        _ = model.project_store.setWorktreesBase(base_dir);
        model.worktrees_base_serial +%= 1;
    }
    model.status_text = completion.message;
}

fn handleProfilesLoadResult(model: *Model, result: native_sdk.EffectDbResult) void {
    if (result.key != profiles_load_key) return;
    switch (result.kind) {
        .page => if (result.outcome != .ok or !model.profile_store.appendEncodedPage(result.bytes)) {
            model.profile_edit.load_valid = false;
        },
        .done => {
            if (result.outcome != .ok) model.profile_edit.load_valid = false;
            finishProfilesLoad(model);
        },
        .exec => model.profile_edit.load_valid = false,
    }
}

fn handleProfileWriteResult(model: *Model, fx: *Effects, result: native_sdk.EffectDbResult) void {
    if (result.key != profile_write_key or result.kind != .exec) return;
    const completed = model.profile_edit.finishWrite(result.outcome == .ok, result.outcome == .busy);
    if (completed.reload) reloadProfiles(model, fx, completed.select_id.slice());
    model.status_text = completed.message;
}

fn handleToolCheckResult(model: *Model, exit: native_sdk.EffectExit) void {
    const resolved = if (exit.reason == .exited and exit.code == 0) resolvedToolExecutable(exit.output) else null;
    _ = model.tools.completeDiscovery(exit.key, resolved);
}

fn editProfileDraft(model: *Model, field: profile_editor.TextField, edit: canvas.TextInputEvent) void {
    model.profile_edit.edit(field, edit);
}

fn handleStoreResult(model: *Model, fx: *Effects, result: native_sdk.EffectFileResult) void {
    if (result.op == .read) {
        model.project_io.skipRestore();
        if (result.outcome == .ok) {
            _ = model.project_store.restoreAttached(result.bytes);
            model.active_workspace_id = model.project_store.firstWorkspaceId();
            model.project_io.beginScan();
            detectNextRestoredProject(model, fx);
        } else {
            model.status_text = "Ready";
        }
    } else if (result.op == .write) {
        const finished = model.project_io.writeFinished(result.key);
        if (finished == .ignored) return;
        if (result.outcome != .ok) model.status_text = "Attached projects could not be persisted";
        if (finished == .restart) persistProjects(model, fx);
    }
}

fn handleTerminalEvent(model: *Model, fx: *Effects, event: native_sdk.EffectPtyEvent) void {
    switch (event.kind) {
        .output => switch (model.terminal_state.output(model.tab_store, event.key)) {
            .running => model.status_text = "Shell running",
            .missing, .ignored => return,
        },
        .exit => switch (model.terminal_state.exit(model.tab_store, event.key, event.code, event.reason == .exited)) {
            .missing => return,
            .removed => |removed| {
                if (!model.use_ghostty) fx.ptyForget(removed.pty_key);
                model.status_text = "Terminal closed";
            },
            .completed => |phase| model.status_text = if (phase == .exited) "Shell exited" else "Shell failed",
        },
        .write => unreachable,
    }
    maybeFinishPendingTeardown(model, fx);
}

fn handleGitDiscovery(model: *Model, fx: *Effects, operation: GitOperation, result: git_workflow.Result) void {
    const succeeded = result.outcome == .success;
    switch (operation.kind) {
        .restore_check => if (succeeded) {
            detectRepository(model, fx, operation.project_id);
        } else {
            _ = model.project_store.detach(operation.project_id);
            model.active_workspace_id = model.project_store.firstWorkspaceId();
            persistProjects(model, fx);
            detectNextRestoredProject(model, fx);
        },
        .detect_repo => {
            if (succeeded) {
                const root = std.mem.trim(u8, result.output, " \r\n");
                if (model.project_store.findAttachedByKey(root)) |existing| {
                    if (existing.id != operation.project_id) {
                        _ = model.project_store.detach(operation.project_id);
                        model.active_workspace_id = for (existing.worktrees.items) |worktree| {
                            if (worktree.active) break worktree.id;
                        } else 0;
                        persistProjects(model, fx);
                        refreshWorktrees(model, fx, existing.id);
                        return;
                    }
                }
                if (model.project_store.markGit(operation.project_id, root)) {
                    refreshWorktrees(model, fx, operation.project_id);
                } else {
                    model.status_text = "The Git root path is invalid";
                    detectNextRestoredProject(model, fx);
                }
            } else {
                model.status_text = "Folder attached";
                detectNextRestoredProject(model, fx);
            }
        },
        else => unreachable,
    }
}

fn handleWorktreeList(model: *Model, fx: *Effects, operation: GitOperation, result: git_workflow.Result) void {
    if (result.outcome == .success) {
        _ = model.project_store.applyWorktreePorcelain(operation.project_id, result.output);
        const project = model.project_store.findProject(operation.project_id) orelse return;
        var selected: u64 = 0;
        if (model.workspace_dialogs.create.select_after_refresh.len > 0) {
            for (project.worktrees.items) |worktree| {
                if (worktree.active and worktree.path.eql(model.workspace_dialogs.create.select_after_refresh.slice())) selected = worktree.id;
            }
            model.workspace_dialogs.create.select_after_refresh.len = 0;
        }
        if (selected == 0) {
            for (project.worktrees.items) |worktree| {
                if (worktree.active) {
                    selected = worktree.id;
                    break;
                }
            }
        }
        if (selected != 0 and (model.active_workspace_id == 0 or operation.project_id == model.workspace_dialogs.create.project_id or model.project_io.scanning())) model.active_workspace_id = selected;
        model.workspace_dialogs.create.finishRefresh(operation.project_id);
        if (model.workspace_dialogs.create.failed) {
            model.workspace_dialogs.create.failed = false;
            model.status_text = "Worktree creation failed; branch retained and Git state refreshed";
        } else {
            model.status_text = "Worktrees refreshed";
        }
    } else if (model.workspace_dialogs.create.failed) {
        model.workspace_dialogs.create.failed = false;
        model.status_text = "Worktree creation failed; inspect Git state manually";
    } else {
        model.status_text = "Could not list Git worktrees";
    }
    detectNextRestoredProject(model, fx);
}

fn handleGitCreation(model: *Model, fx: *Effects, operation: GitOperation, result: git_workflow.Result) void {
    switch (operation.kind) {
        .validate_branch, .check_target, .check_branch, .create_branch => {
            switch (operation.advanceCreation(result.outcome)) {
                .next => |next| spawnGit(model, fx, next),
                .failed => |message| model.status_text = message,
            }
        },
        .create_worktree => {
            model.workspace_dialogs.create.trackCheckout(operation.target_path.slice(), result.outcome != .success);
            refreshWorktrees(model, fx, operation.project_id);
        },
        else => unreachable,
    }
}

fn handleGitRemoval(model: *Model, fx: *Effects, operation: GitOperation, result: git_workflow.Result) void {
    switch (operation.kind) {
        .remove_status => {
            model.workspace_dialogs.removal.safety.recordStatus(result.outcome, result.output);
            preflightRemoveSubmodules(model, fx, operation.workspace_id);
        },
        .remove_submodules => {
            model.workspace_dialogs.removal.safety.recordSubmodules(result.outcome, result.output);
            preflightRemoveUnmerged(model, fx, operation.workspace_id);
        },
        .remove_unmerged => {
            model.workspace_dialogs.removal.safety.recordUnmerged(result.outcome, result.output);
            finishRemovePreflight(model, fx);
        },
        .remove_worktree => if (result.outcome == .success) {
            _ = model.project_store.removeWorktree(operation.workspace_id);
            if (model.active_workspace_id == operation.workspace_id) model.active_workspace_id = model.project_store.firstWorkspaceId();
            refreshWorktrees(model, fx, operation.project_id);
        } else {
            model.status_text = "Git refused to remove the worktree";
        },
        else => unreachable,
    }
}

fn handleGitResult(model: *Model, fx: *Effects, result: git_workflow.Result) void {
    const operation = model.git.finish(result.key) orelse return;
    switch (operation.kind.group()) {
        .none => {},
        .discovery => handleGitDiscovery(model, fx, operation, result),
        .listing => handleWorktreeList(model, fx, operation, result),
        .creation => handleGitCreation(model, fx, operation, result),
        .removal => handleGitRemoval(model, fx, operation, result),
    }
}

pub fn update(model: *Model, msg: Msg, fx: *Effects) void {
    switch (msg) {
        .open_folder => if (!model.project_io.ready()) {
            model.status_text = "Restoring attached projects";
        } else if (!model.busy()) {
            model.picker_serial +%= 1;
            model.status_text = "Choose a project folder";
        },
        .folder_selected => |payload| {
            if (!model.project_io.ready() or model.busy()) return;
            const attached = model.project_store.attachPlaceholder(payload.slice()) orelse {
                model.status_text = "That folder path cannot be attached";
                return;
            };
            model.active_workspace_id = attached.workspace_id;
            persistProjects(model, fx);
            detectRepository(model, fx, attached.project_id);
        },
        .folder_dialog_cancelled => model.status_text = "Folder selection cancelled",
        .folder_dialog_failed => model.status_text = "The folder picker could not be opened",
        .select_workspace => |id| if (model.project_store.workspaceAvailable(id)) {
            model.active_workspace_id = id;
            model.sidebar.overlay_open = false;
            model.status_text = "Worktree selected";
        },
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
        .begin_create_worktree => |project_id| {
            const project = model.project_store.findProject(project_id) orelse return;
            if (!project.attached or !project.is_git or model.busy()) return;
            model.workspace_dialogs.create.begin(project_id);
        },
        .edit_create_branch => |edit| model.workspace_dialogs.create.branch.apply(edit),
        .cancel_create_worktree => model.workspace_dialogs.create.cancel(),
        .confirm_create_worktree => {
            if (model.busy()) return;
            const project = model.project_store.findProject(model.workspace_dialogs.create.project_id) orelse return;
            const branch = std.mem.trim(u8, model.workspace_dialogs.create.branch.text(), " ");
            if (branch.len == 0) return;
            var target_buffer: [workspaces.max_path_bytes]u8 = undefined;
            const target = model.project_store.makeWorktreePath(project, branch, model.git.next_key, &target_buffer) orelse {
                model.status_text = "Could not derive a safe worktree path";
                return;
            };
            const project_id = model.workspace_dialogs.create.project_id;
            model.workspace_dialogs.create.submitted();
            validateNewBranch(model, fx, project_id, branch, target);
        },
        .request_remove_worktree => |workspace_id| {
            if (model.busy()) return;
            if (!model.project_store.workspaceAvailable(workspace_id)) return;
            const worktree = model.project_store.findWorktree(workspace_id) orelse return;
            if (worktree.is_main or !worktree.active) return;
            model.workspace_dialogs.removal.begin(workspace_id);
            model.teardown = .idle;
            preflightRemoveStatus(model, fx, workspace_id);
        },
        .cancel_remove_worktree => {
            if (model.busy()) return;
            model.workspace_dialogs.removal.cancel();
            model.teardown = .idle;
        },
        .confirm_remove_worktree => {
            const workspace_id = model.workspace_dialogs.removal.workspace_id;
            if (workspace_id == 0 or model.busy()) return;
            model.workspace_dialogs.removal.submitted();
            model.teardown = .{ .closing_worktree = .{ .workspace_id = workspace_id, .approved = model.workspace_dialogs.removal.safety } };
            closeTabsForWorkspace(model, fx, workspace_id);
            maybeFinishPendingTeardown(model, fx);
        },
        .request_detach_project => |project_id| {
            if (model.busy()) return;
            const project = model.project_store.findProject(project_id) orelse return;
            if (!project.attached) return;
            model.workspace_dialogs.detach.begin(project_id);
        },
        .cancel_detach_project => model.workspace_dialogs.detach.cancel(),
        .confirm_detach_project => {
            const project_id = model.workspace_dialogs.detach.project_id;
            if (project_id == 0 or model.busy()) return;
            model.workspace_dialogs.detach.submitted();
            model.teardown = .{ .closing_project = project_id };
            closeTabsForProject(model, fx, project_id);
            maybeFinishPendingTeardown(model, fx);
        },
        .open_preferences => openPreferences(model),
        .open_claude_preferences => {
            openPreferences(model);
            openProfileSection(model, .claude);
        },
        .close_preferences => closePreferences(model),
        .show_preferences_general => model.preferences_edit.select(.general),
        .show_preferences_appearance => model.preferences_edit.select(.appearance),
        .show_preferences_worktrees => model.preferences_edit.select(.worktrees),
        .show_preferences_claude => openProfileSection(model, .claude),
        .show_preferences_codex => openProfileSection(model, .codex),
        .edit_preferences_search => |edit| model.preferences_edit.search.apply(edit),
        .toggle_preferences_reopen => model.preferences_edit.toggleReopen(),
        .use_system_appearance => model.preferences_edit.setAppearance(.system),
        .use_light_appearance => model.preferences_edit.setAppearance(.light),
        .use_dark_appearance => model.preferences_edit.setAppearance(.dark),
        .edit_preferences_base_dir => |edit| model.preferences_edit.editBaseDir(edit),
        .save_preferences => savePreferences(model, fx),
        .preferences_load_done => |result| handlePreferencesLoadResult(model, fx, result),
        .preferences_db_done => |result| handlePreferencesWriteResult(model, result),
        .worktrees_base_failed => model.status_text = "Worktree base directory could not be created",
        .profiles_load_done => |result| handleProfilesLoadResult(model, result),
        .profile_db_done => |result| handleProfileWriteResult(model, fx, result),
        .tool_check_done => |exit| handleToolCheckResult(model, exit),
        .toggle_agent_profiles => |agent| model.tools.toggle(agent),
        .launch_agent => |agent| {
            model.sidebar.overlay_open = false;
            launchDefaultTool(model, fx, agent);
        },
        .launch_profile => |id| {
            model.sidebar.overlay_open = false;
            launchProfileTool(model, fx, id);
        },
        .new_profile => createProfileDraft(model),
        .select_profile => |id| model.profile_edit.select(model.profile_store, id),
        .confirm_profile_switch => model.profile_edit.confirmSwitch(model.profile_store),
        .cancel_profile_switch => model.profile_edit.cancelSwitch(),
        .request_delete_profile => |id| model.profile_edit.requestDelete(id),
        .confirm_delete_profile => deleteProfile(model, fx),
        .cancel_delete_profile => model.profile_edit.cancelDelete(),
        .save_profile => saveProfile(model, fx),
        .edit_profile_name => |edit| editProfileDraft(model, .name, edit),
        .edit_profile_model => |edit| editProfileDraft(model, .model, edit),
        .edit_profile_permission_mode => |edit| editProfileDraft(model, .permission_mode, edit),
        .edit_profile_effort_level => |edit| editProfileDraft(model, .effort_level, edit),
        .edit_profile_provider => |edit| editProfileDraft(model, .provider, edit),
        .edit_profile_approval_mode => |edit| editProfileDraft(model, .approval_mode, edit),
        .edit_profile_sandbox => |edit| editProfileDraft(model, .sandbox, edit),
        .edit_profile_base_url => |edit| editProfileDraft(model, .base_url, edit),
        .edit_profile_append_prompt => |edit| editProfileDraft(model, .append_system_prompt, edit),
        .edit_profile_custom_env => |edit| editProfileDraft(model, .custom_env, edit),
        .edit_profile_settings_json => |edit| editProfileDraft(model, .settings_json, edit),
        .edit_profile_codex_profile => |edit| editProfileDraft(model, .profile, edit),
        .toggle_profile_full_auto => model.profile_edit.toggleFullAuto(),
        .toggle_profile_dangerous_bypass => model.profile_edit.toggleDangerousBypass(),
        .git_done => |exit| handleGitResult(model, fx, git_cli.result(exit)),
        .store_done => |result| handleStoreResult(model, fx, result),
        .terminal_event => |event| handleTerminalEvent(model, fx, event),
        .sidebar_resized => |fraction| {
            if (!model.sidebar.compact and !model.sidebar.collapsed and !model.sidebar.animating() and std.math.isFinite(fraction)) {
                const width = @max(210, std.math.clamp(fraction, 0, 1) * @max(1, model.canvas_width - sidebar_divider_width));
                if (model.sidebar_width != width) {
                    model.sidebar_width = width;
                    model.sidebar_persistence.edit(width);
                }
            }
        },
        .save_sidebar_width => saveSidebarWidth(model, fx),
        .sidebar_width_saved => |result| if (result.key == sidebar_write_key and result.kind == .exec) {
            model.sidebar_persistence.finish(result.outcome == .ok);
            if (result.outcome != .ok) model.status_text = "Could not save sidebar width";
        },
        .toggle_sidebar => model.sidebar.toggle(),
        .dismiss_sidebar => model.sidebar.overlay_open = false,
        .set_appearance => |appearance| model.appearance = appearance,
        .chrome_changed => |chrome| model.window_chrome = chrome,
    }
}

pub const preferences_load_key: u64 = 8_000;
pub const sidebar_write_key: u64 = 8_004;

fn saveSidebarWidth(model: *Model, fx: *Effects) void {
    const width = model.sidebar_persistence.begin() orelse return;
    var buffer: [16]u8 = undefined;
    const value = std.fmt.bufPrint(&buffer, "{d}", .{width}) catch unreachable;
    fx.dbExec(.{
        .key = sidebar_write_key,
        .statements = &.{.{ .sql = preferences_mod.sidebar_upsert_sql, .params = &.{.{ .text = value }} }},
        .on_result = Effects.dbMsg(.sidebar_width_saved),
    });
}

// Shutdown uses the still-live runtime binding after Effects have stopped, so
// a queued completion or final drag sample cannot lose the latest width.
pub fn flushSidebarWidth(model: *Model, binding: native_sdk.relational_store.Binding) bool {
    if (!model.sidebar_persistence.needsFlush()) return true;
    var buffer: [16]u8 = undefined;
    const width = model.sidebar_persistence.desired;
    const value = std.fmt.bufPrint(&buffer, "{d}", .{width}) catch unreachable;
    const outcome = binding.exec_fn(binding.context, &.{.{ .sql = preferences_mod.sidebar_upsert_sql, .params = &.{.{ .text = value }} }});
    if (outcome != .ok) return false;
    model.sidebar_persistence.saved = width;
    model.sidebar_persistence.dirty = false;
    model.sidebar_persistence.submitted = null;
    return true;
}

fn beginProjectRestore(model: *Model, fx: *Effects) void {
    if (!model.preferences_edit.saved.reopen_last_workspace) {
        model.project_io.skipRestore();
        model.status_text = "Ready";
    } else if (model.project_io.beginRead()) |path| {
        fx.readFile(.{
            .key = store_read_key,
            .path = path,
            .on_result = Effects.fileMsg(.store_done),
        });
    } else if (model.active_workspace_id != 0) {
        openTerminal(model, fx, model.active_workspace_id);
    }
}

fn finishPreferencesLoad(model: *Model, fx: *Effects) void {
    if (model.sidebar_persistence.restore(model.preferences_edit.saved.sidebar_width)) |width| model.sidebar_width = width;
    const base_dir = if (model.preferences_edit.saved.worktrees_base_dir.len > 0)
        model.preferences_edit.saved.worktrees_base_dir.slice()
    else
        model.default_worktrees_base.slice();
    _ = model.project_store.setWorktreesBase(base_dir);
    model.worktrees_base_serial +%= 1;
    beginProjectRestore(model, fx);
}

pub fn boot(model: *Model, fx: *Effects) void {
    model.status_text = "Loading preferences";
    fx.dbQuery(.{
        .key = preferences_load_key,
        .sql = preferences_mod.load_sql,
        .on_result = Effects.dbMsg(.preferences_load_done),
    });
    reloadProfiles(model, fx, "");
    startToolChecks(model, fx);
}

pub fn onChrome(chrome: native_sdk.WindowChrome) ?Msg {
    return .{ .chrome_changed = chrome };
}

pub fn onAppearance(appearance: native_sdk.Appearance) ?Msg {
    return .{ .set_appearance = appearance };
}

pub fn canopyTokens(model: *const Model) canvas.DesignTokens {
    const selected = if (model.preferences_edit.open) &model.preferences_edit.draft else &model.preferences_edit.saved;
    var tokens = theme.tokens(selected.effectiveAppearance(model.appearance));
    theme.applyGripHighlight(&tokens, model.sidebar.grip.value);
    return tokens;
}
