//! Canopy Native SDK proof of concept.
//!
//! Projects contain worktrees, worktrees own their terminal tabs, and every
//! process mutation leaves the view as an effect. Native SDK owns the PTY,
//! Ghostty VT state, input routing, resizing, selection, and rendering.

const std = @import("std");
const runner = @import("runner");
const native_sdk = @import("native_sdk");
const workspaces = @import("workspaces.zig");

pub const panic = std.debug.FullPanic(native_sdk.debug.capturePanic);

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;

const canvas_label = "main-canvas";
const window_width: f32 = 1180;
const window_height: f32 = 760;
const max_rendered_tab_buttons: usize = 12;
const terminal_bootstrap = "cd -- \"$1\" && exec /bin/zsh -il";

pub const TerminalPhase = enum { starting, running, closing, exited, failed };

pub const TerminalTab = struct {
    id: u64 = 0,
    workspace_id: u64 = 0,
    pty: u64 = 0,
    title: workspaces.NameText = .{},
    path: workspaces.PathText = .{},
    branch: workspaces.BranchText = .{},
    phase: TerminalPhase = .starting,
    exit_code: i32 = 0,
};

pub const TerminalTabRow = struct {
    id: u64,
    pty: u64,
    title: []const u8,
    path: []const u8,
    branch: []const u8,
    phase: TerminalPhase,
    exit_code: i32,
    selected: bool,
};

pub const PathPayload = struct {
    bytes: [workspaces.max_path_bytes]u8 = @splat(0),
    len: usize = 0,

    pub fn from(path: []const u8) ?PathPayload {
        if (path.len == 0 or path.len > workspaces.max_path_bytes) return null;
        var payload: PathPayload = .{};
        @memcpy(payload.bytes[0..path.len], path);
        payload.len = path.len;
        return payload;
    }

    pub fn slice(payload: *const PathPayload) []const u8 {
        return payload.bytes[0..payload.len];
    }
};

const GitOpKind = enum {
    none,
    restore_check,
    detect_repo,
    list_worktrees,
    validate_branch,
    check_target,
    check_branch,
    create_branch,
    create_worktree,
    remove_status,
    remove_submodules,
    remove_unmerged,
    remove_worktree,
};

const GitOperation = struct {
    kind: GitOpKind = .none,
    key: u64 = 0,
    project_id: u64 = 0,
    workspace_id: u64 = 0,
    force: bool = false,
    target_path: workspaces.PathText = .{},
    branch: workspaces.BranchText = .{},
};

pub const TabStore = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayListUnmanaged(TerminalTab) = .empty,
    free_pty_keys: std.ArrayListUnmanaged(u64) = .empty,

    pub fn create(allocator: std.mem.Allocator) !*TabStore {
        const store = try allocator.create(TabStore);
        store.* = .{ .allocator = allocator };
        return store;
    }

    pub fn destroy(store: *TabStore) void {
        const allocator = store.allocator;
        store.items.deinit(allocator);
        store.free_pty_keys.deinit(allocator);
        allocator.destroy(store);
    }

    fn allocatePtyKey(store: *TabStore, next: *u64) u64 {
        if (store.free_pty_keys.pop()) |key| return key;
        const key = next.*;
        next.* +%= 1;
        return key;
    }

    fn releasePtyKey(store: *TabStore, key: u64) void {
        store.free_pty_keys.append(store.allocator, key) catch {};
    }
};

pub const Model = struct {
    project_store: *workspaces.Store = undefined,
    active_workspace_id: u64 = 0,
    active_tab_by_workspace: std.AutoHashMapUnmanaged(u64, u64) = .empty,
    tab_store: *TabStore = undefined,
    next_tab_id: u64 = 1,
    next_pty_key: u64 = 1,
    sidebar_fraction: f32 = 0.255,
    chrome_leading: f32 = 76,
    status_text: []const u8 = "Ready",
    picker_serial: u64 = 0,
    next_git_key: u64 = 10_000,
    git_op: GitOperation = .{},
    create_dialog_open: bool = false,
    create_project_id: u64 = 0,
    create_branch: canvas.TextBuffer(workspaces.max_branch_bytes) = .{},
    remove_dialog_open: bool = false,
    remove_workspace_id: u64 = 0,
    remove_dirty: bool = false,
    remove_has_submodules: bool = false,
    remove_unmerged_count: usize = 0,
    remove_rechecking: bool = false,
    approved_remove_dirty: bool = false,
    approved_remove_has_submodules: bool = false,
    approved_remove_unmerged_count: usize = 0,
    detach_dialog_open: bool = false,
    detach_project_id: u64 = 0,
    pending_remove_workspace_id: u64 = 0,
    pending_remove_force: bool = false,
    pending_remove_recheck: bool = false,
    pending_detach_project_id: u64 = 0,
    select_after_refresh: workspaces.PathText = .{},
    create_failed: bool = false,
    store_path: workspaces.PathText = .{},
    restore_ready: bool = true,
    restore_scan_active: bool = false,
    restore_scan_index: usize = 0,
    next_store_key: u64 = 9_100,
    persist_write_active: bool = false,
    persist_dirty: bool = false,

    pub const view_unbound = .{
        "active_tab_by_workspace",
        "active_workspace_id",
        "project_store",
        "tab_store",
        "next_tab_id",
        "next_pty_key",
        "picker_serial",
        "next_git_key",
        "git_op",
        "create_project_id",
        "create_branch",
        "remove_workspace_id",
        "remove_dirty",
        "remove_has_submodules",
        "remove_unmerged_count",
        "remove_rechecking",
        "approved_remove_dirty",
        "approved_remove_has_submodules",
        "approved_remove_unmerged_count",
        "detach_project_id",
        "pending_remove_workspace_id",
        "pending_remove_force",
        "pending_remove_recheck",
        "pending_detach_project_id",
        "select_after_refresh",
        "create_failed",
        "store_path",
        "restore_ready",
        "restore_scan_active",
        "restore_scan_index",
        "next_store_key",
        "persist_write_active",
        "persist_dirty",
        "busy",
    };

    pub fn sidebarRows(model: *const Model, arena: std.mem.Allocator) []const workspaces.SidebarRow {
        return model.project_store.sidebarRows(arena, model.active_workspace_id);
    }

    pub fn tabs(model: *const Model, arena: std.mem.Allocator) []const TerminalTabRow {
        const stored = model.tab_store.items.items;
        var workspace_count: usize = 0;
        var active_ordinal: usize = 0;
        const active = model.activeTabId(model.active_workspace_id);
        for (stored) |tab| {
            if (tab.workspace_id != model.active_workspace_id) continue;
            if (tab.id == active) active_ordinal = workspace_count;
            workspace_count += 1;
        }
        const visible_count = @min(workspace_count, max_rendered_tab_buttons);
        const half = max_rendered_tab_buttons / 2;
        const preferred_start = active_ordinal -| half;
        const start = @min(preferred_start, workspace_count -| visible_count);
        const out = arena.alloc(TerminalTabRow, visible_count) catch return &.{};
        var ordinal: usize = 0;
        var count: usize = 0;
        for (stored) |tab| {
            if (tab.workspace_id != model.active_workspace_id) continue;
            defer ordinal += 1;
            if (ordinal < start or ordinal >= start + visible_count) continue;
            out[count] = .{
                .id = tab.id,
                .pty = tab.pty,
                .title = tab.title.slice(),
                .path = tab.path.slice(),
                .branch = tab.branch.slice(),
                .phase = tab.phase,
                .exit_code = tab.exit_code,
                .selected = tab.id == active,
            };
            count += 1;
        }
        return out[0..count];
    }

    pub fn activeWorkspaceTerminalCount(model: *const Model) usize {
        var count: usize = 0;
        for (model.tab_store.items.items) |tab| {
            if (tab.workspace_id == model.active_workspace_id) count += 1;
        }
        return count;
    }

    pub fn hasTabs(model: *const Model) bool {
        for (model.tab_store.items.items) |tab| {
            if (tab.workspace_id == model.active_workspace_id) return true;
        }
        return false;
    }

    pub fn activeWorkspaceName(model: *const Model) []const u8 {
        const workspace = model.project_store.findWorktree(model.active_workspace_id) orelse return "No project";
        return workspace.name.slice();
    }

    pub fn activeWorkspacePath(model: *const Model) []const u8 {
        const workspace = model.project_store.findWorktree(model.active_workspace_id) orelse return "";
        return workspace.path.slice();
    }

    pub fn activeWorkspaceBranch(model: *const Model) []const u8 {
        const workspace = model.project_store.findWorktree(model.active_workspace_id) orelse return "";
        return workspace.branch.slice();
    }

    pub fn hasProjects(model: *const Model) bool {
        return model.project_store.hasProjects();
    }

    pub fn projectCount(model: *const Model) usize {
        return model.project_store.attachedCount();
    }

    pub fn gitBusy(model: *const Model) bool {
        return model.busy();
    }

    pub fn attachDisabled(model: *const Model) bool {
        return !model.restore_ready or model.busy();
    }

    pub fn busy(model: *const Model) bool {
        return model.git_op.kind != .none;
    }

    pub fn createBranchText(model: *const Model) []const u8 {
        return model.create_branch.text();
    }

    pub fn createDisabled(model: *const Model) bool {
        return model.create_branch.text().len == 0 or model.busy();
    }

    pub fn createProjectName(model: *const Model) []const u8 {
        const project = model.project_store.findProject(model.create_project_id) orelse return "repository";
        return project.name.slice();
    }

    pub fn removeWorktreeName(model: *const Model) []const u8 {
        const worktree = model.project_store.findWorktree(model.remove_workspace_id) orelse return "worktree";
        return worktree.name.slice();
    }

    pub fn removeWorktreePath(model: *const Model) []const u8 {
        const worktree = model.project_store.findWorktree(model.remove_workspace_id) orelse return "";
        return worktree.path.slice();
    }

    pub fn removeHasWarnings(model: *const Model) bool {
        return model.remove_dirty or model.remove_has_submodules or model.remove_unmerged_count > 0;
    }

    pub fn removeDirty(model: *const Model) bool {
        return model.remove_dirty;
    }

    pub fn removeHasSubmodules(model: *const Model) bool {
        return model.remove_has_submodules;
    }

    pub fn removeUnmergedCount(model: *const Model) usize {
        return model.remove_unmerged_count;
    }

    pub fn detachProjectName(model: *const Model) []const u8 {
        const project = model.project_store.findProject(model.detach_project_id) orelse return "project";
        return project.name.slice();
    }

    fn activeTabId(model: *const Model, workspace_id: u64) u64 {
        return model.active_tab_by_workspace.get(workspace_id) orelse 0;
    }

    fn setActiveTab(model: *Model, workspace_id: u64, tab_id: u64) void {
        model.active_tab_by_workspace.put(model.tab_store.allocator, workspace_id, tab_id) catch {};
    }

    fn setStorePath(model: *Model, path: []const u8) void {
        if (model.store_path.set(path) and path.len > 0) model.restore_ready = false;
    }
};

pub const Msg = union(enum) {
    open_folder,
    folder_selected: PathPayload,
    folder_dialog_cancelled,
    folder_dialog_failed,
    select_workspace: u64,
    open_terminal: u64,
    open_active_terminal,
    activate_tab: u64,
    previous_tab,
    next_tab,
    close_tab: u64,
    begin_create_worktree: u64,
    edit_create_branch: canvas.TextInputEvent,
    cancel_create_worktree,
    confirm_create_worktree,
    request_remove_worktree: u64,
    cancel_remove_worktree,
    confirm_remove_worktree,
    request_detach_project: u64,
    cancel_detach_project,
    confirm_detach_project,
    git_done: native_sdk.EffectExit,
    store_done: native_sdk.EffectFileResult,
    terminal_event: native_sdk.EffectPtyEvent,
    sidebar_resized: f32,
    chrome_changed: native_sdk.WindowChrome,

    pub const view_unbound = .{
        "folder_selected",
        "folder_dialog_cancelled",
        "folder_dialog_failed",
        "git_done",
        "store_done",
        "terminal_event",
        "chrome_changed",
    };
};

const CanopyApp = native_sdk.UiApp(Model, Msg);
pub const Effects = native_sdk.Effects(Msg);

fn nextGitKey(model: *Model) u64 {
    const key = model.next_git_key;
    model.next_git_key +%= 1;
    if (model.next_git_key == 0) model.next_git_key = 10_000;
    return key;
}

/// One zero-backlog lane for every Git workflow. A running command owns the
/// lane until its exact EffectExit arrives; callers are rejected, never queued.
/// Native SDK spawn has no execution timeout, so slow repositories are allowed
/// to finish naturally without a polling loop creating more host work.
fn spawnGit(model: *Model, fx: *Effects, operation: GitOperation, argv: []const []const u8) void {
    if (model.git_op.kind != .none) {
        model.status_text = "Another Git operation is still running";
        return;
    }
    model.git_op = operation;
    model.git_op.key = nextGitKey(model);
    fx.spawn(.{
        .key = model.git_op.key,
        .argv = argv,
        .output = .collect,
        .on_exit = Effects.exitMsg(.git_done),
    });
}

fn detectRepository(model: *Model, fx: *Effects, project_id: u64) void {
    const project = model.project_store.findProject(project_id) orelse return;
    spawnGit(model, fx, .{ .kind = .detect_repo, .project_id = project_id }, &.{
        "/usr/bin/git",
        "-C",
        project.selected_path.slice(),
        "rev-parse",
        "--show-toplevel",
    });
    model.status_text = "Inspecting folder";
}

fn refreshWorktrees(model: *Model, fx: *Effects, project_id: u64) void {
    const project = model.project_store.findProject(project_id) orelse return;
    if (!project.is_git) return;
    spawnGit(model, fx, .{ .kind = .list_worktrees, .project_id = project_id }, &.{
        "/usr/bin/git",
        "-C",
        project.repo_root.slice(),
        "worktree",
        "list",
        "--porcelain",
    });
    model.status_text = "Refreshing worktrees";
}

fn validateNewBranch(model: *Model, fx: *Effects, project_id: u64, branch: []const u8, target_path: []const u8) void {
    var operation = GitOperation{ .kind = .validate_branch, .project_id = project_id };
    if (!operation.branch.set(branch) or !operation.target_path.set(target_path)) {
        model.status_text = "Branch name or worktree path is too long";
        return;
    }
    spawnGit(model, fx, operation, &.{ "/usr/bin/git", "check-ref-format", "--branch", operation.branch.slice() });
    model.status_text = "Validating branch";
}

fn checkWorktreeTarget(model: *Model, fx: *Effects, operation: GitOperation) void {
    var next = operation;
    next.kind = .check_target;
    spawnGit(model, fx, next, &.{ "/bin/test", "!", "-e", next.target_path.slice() });
    model.status_text = "Checking worktree target";
}

fn checkBranchAvailable(model: *Model, fx: *Effects, operation: GitOperation) void {
    const project = model.project_store.findProject(operation.project_id) orelse return;
    var next = operation;
    next.kind = .check_branch;
    var ref_buffer: [workspaces.max_branch_bytes + "refs/heads/".len]u8 = undefined;
    const branch_ref = std.fmt.bufPrint(&ref_buffer, "refs/heads/{s}", .{next.branch.slice()}) catch {
        model.status_text = "Branch name is too long";
        return;
    };
    spawnGit(model, fx, next, &.{ "/usr/bin/git", "-C", project.repo_root.slice(), "show-ref", "--verify", "--quiet", branch_ref });
    model.status_text = "Checking branch availability";
}

fn createBranch(model: *Model, fx: *Effects, operation: GitOperation) void {
    const project = model.project_store.findProject(operation.project_id) orelse return;
    var next = operation;
    next.kind = .create_branch;
    spawnGit(model, fx, next, &.{ "/usr/bin/git", "-C", project.repo_root.slice(), "branch", next.branch.slice(), "HEAD" });
    model.status_text = "Creating branch";
}

fn createWorktree(model: *Model, fx: *Effects, operation: GitOperation) void {
    const project = model.project_store.findProject(operation.project_id) orelse return;
    var next = operation;
    next.kind = .create_worktree;
    spawnGit(model, fx, next, &.{
        "/usr/bin/git",
        "-C",
        project.repo_root.slice(),
        "worktree",
        "add",
        next.target_path.slice(),
        next.branch.slice(),
    });
    model.status_text = "Creating worktree";
}

const store_read_key: u64 = 9_001;

fn persistProjects(model: *Model, fx: *Effects) void {
    if (model.store_path.len == 0) return;
    if (model.persist_write_active) {
        model.persist_dirty = true;
        return;
    }
    var buffer: [workspaces.max_store_bytes]u8 = undefined;
    const bytes = model.project_store.serializeAttached(&buffer) orelse {
        model.status_text = "Too many attached projects to persist";
        return;
    };
    const key = model.next_store_key;
    model.next_store_key +%= 1;
    if (model.next_store_key < 9_100) model.next_store_key = 9_100;
    model.persist_write_active = true;
    fx.writeFile(.{
        .key = key,
        .path = model.store_path.slice(),
        .bytes = bytes,
        .on_result = Effects.fileMsg(.store_done),
    });
}

fn detectNextRestoredProject(model: *Model, fx: *Effects) void {
    if (!model.restore_scan_active or model.git_op.kind != .none) return;
    while (model.restore_scan_index < model.project_store.projects.items.len) {
        const index = model.restore_scan_index;
        model.restore_scan_index += 1;
        const project = &model.project_store.projects.items[index];
        if (!project.attached) continue;
        spawnGit(model, fx, .{ .kind = .restore_check, .project_id = project.id }, &.{ "/bin/test", "-d", project.selected_path.slice() });
        model.status_text = "Checking restored project";
        return;
    }
    model.restore_scan_active = false;
    model.status_text = if (model.project_store.hasProjects()) "Projects restored" else "Ready";
}

fn preflightRemoveStatus(model: *Model, fx: *Effects, workspace_id: u64) void {
    const worktree = model.project_store.findWorktree(workspace_id) orelse return;
    if (worktree.is_main or !worktree.active) return;
    spawnGit(model, fx, .{ .kind = .remove_status, .workspace_id = workspace_id }, &.{
        "/usr/bin/git",
        "-C",
        worktree.path.slice(),
        "status",
        "--porcelain",
    });
    model.status_text = "Checking worktree safety";
}

fn preflightRemoveSubmodules(model: *Model, fx: *Effects, workspace_id: u64) void {
    const worktree = model.project_store.findWorktree(workspace_id) orelse return;
    spawnGit(model, fx, .{ .kind = .remove_submodules, .workspace_id = workspace_id }, &.{
        "/usr/bin/git",
        "-C",
        worktree.path.slice(),
        "config",
        "--file",
        ".gitmodules",
        "--get-regexp",
        "path",
    });
    model.status_text = "Checking worktree submodules";
}

fn finishRemovePreflight(model: *Model, fx: *Effects) void {
    if (!model.remove_rechecking) {
        model.remove_dialog_open = true;
        model.status_text = "Review worktree removal";
        return;
    }
    model.remove_rechecking = false;
    const changed = model.remove_dirty != model.approved_remove_dirty or
        model.remove_has_submodules != model.approved_remove_has_submodules or
        model.remove_unmerged_count != model.approved_remove_unmerged_count;
    if (changed) {
        model.remove_dialog_open = true;
        model.status_text = "Worktree safety state changed; review again";
        return;
    }
    const workspace_id = model.pending_remove_workspace_id;
    model.pending_remove_workspace_id = 0;
    model.pending_remove_force = model.removeHasWarnings();
    executeWorktreeRemoval(model, fx, workspace_id, model.pending_remove_force);
    model.pending_remove_force = false;
}

fn preflightRemoveUnmerged(model: *Model, fx: *Effects, workspace_id: u64) void {
    const worktree = model.project_store.findWorktree(workspace_id) orelse return;
    const project = model.project_store.projectForWorkspace(workspace_id) orelse return;
    if (worktree.branch.eql("(unknown)")) {
        model.remove_unmerged_count = 1;
        finishRemovePreflight(model, fx);
        return;
    }
    if (worktree.branch.eql("(detached)")) {
        spawnGit(model, fx, .{ .kind = .remove_unmerged, .project_id = project.id, .workspace_id = workspace_id }, &.{
            "/usr/bin/git",
            "-C",
            worktree.path.slice(),
            "log",
            "HEAD",
            "--not",
            "--all",
            "--oneline",
        });
        return;
    }
    spawnGit(model, fx, .{ .kind = .remove_unmerged, .project_id = project.id, .workspace_id = workspace_id }, &.{
        "/usr/bin/git",
        "-C",
        project.repo_root.slice(),
        "log",
        worktree.branch.slice(),
        "--not",
        "--remotes",
        "--oneline",
    });
}

fn executeWorktreeRemoval(model: *Model, fx: *Effects, workspace_id: u64, force: bool) void {
    const worktree = model.project_store.findWorktree(workspace_id) orelse return;
    const project = model.project_store.projectForWorkspace(workspace_id) orelse return;
    var operation = GitOperation{ .kind = .remove_worktree, .project_id = project.id, .workspace_id = workspace_id, .force = force };
    _ = operation.target_path.set(worktree.path.slice());
    if (force) {
        spawnGit(model, fx, operation, &.{ "/usr/bin/git", "-C", project.repo_root.slice(), "worktree", "remove", "--force", operation.target_path.slice() });
    } else {
        spawnGit(model, fx, operation, &.{ "/usr/bin/git", "-C", project.repo_root.slice(), "worktree", "remove", operation.target_path.slice() });
    }
    model.status_text = "Removing worktree";
}

fn countNonEmptyLines(bytes: []const u8) usize {
    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| if (std.mem.trim(u8, line, " \r").len > 0) {
        count += 1;
    };
    return count;
}

fn openTerminal(model: *Model, fx: *Effects, workspace_id: u64) void {
    if (!model.project_store.workspaceAvailable(workspace_id)) return;
    const workspace = model.project_store.findWorktree(workspace_id) orelse return;
    if (!workspace.active) return;
    model.active_workspace_id = workspace_id;

    const tab_id = model.next_tab_id;
    const pty_key = model.tab_store.allocatePtyKey(&model.next_pty_key);
    model.next_tab_id +%= 1;

    var tab = TerminalTab{
        .id = tab_id,
        .workspace_id = workspace_id,
        .pty = pty_key,
    };
    _ = tab.title.set(workspace.name.slice());
    _ = tab.path.set(workspace.path.slice());
    _ = tab.branch.set(workspace.branch.slice());
    model.tab_store.items.append(model.tab_store.allocator, tab) catch {
        model.tab_store.releasePtyKey(pty_key);
        model.status_text = "The host could not allocate another terminal tab";
        return;
    };
    model.setActiveTab(workspace_id, tab_id);
    model.status_text = "Starting login shell";

    // The path is argv data, not interpolated shell source. $1 lets zsh do a
    // safe `cd` even when a future configured project contains whitespace.
    fx.ptySpawn(.{
        .key = pty_key,
        .argv = &.{ "/bin/zsh", "-c", terminal_bootstrap, "canopy", workspace.path.slice() },
        .cols = 100,
        .rows = 30,
        .term = "xterm-256color",
        .on_event = Effects.ptyMsg(.terminal_event),
    });
}

fn removeTab(model: *Model, index: usize) void {
    const removed = model.tab_store.items.orderedRemove(index);
    model.tab_store.releasePtyKey(removed.pty);

    if (model.activeTabId(removed.workspace_id) == removed.id) {
        var replacement: u64 = 0;
        for (model.tab_store.items.items) |tab| {
            if (tab.workspace_id != removed.workspace_id or tab.phase == .closing) continue;
            replacement = tab.id;
        }
        model.setActiveTab(removed.workspace_id, replacement);
    }
}

fn closeTerminal(model: *Model, fx: *Effects, tab_id: u64) void {
    var found: ?usize = null;
    for (model.tab_store.items.items, 0..) |tab, index| {
        if (tab.id == tab_id) {
            found = index;
            break;
        }
    }
    const index = found orelse return;
    const phase = model.tab_store.items.items[index].phase;
    if (phase == .exited or phase == .failed) {
        removeTab(model, index);
        model.status_text = "Terminal closed";
        return;
    }

    model.tab_store.items.items[index].phase = .closing;
    fx.ptyKill(model.tab_store.items.items[index].pty);
    if (model.activeTabId(model.tab_store.items.items[index].workspace_id) == tab_id) {
        var replacement: u64 = 0;
        for (model.tab_store.items.items) |tab| {
            if (tab.workspace_id != model.tab_store.items.items[index].workspace_id or tab.id == tab_id or tab.phase == .closing) continue;
            replacement = tab.id;
        }
        model.setActiveTab(model.tab_store.items.items[index].workspace_id, replacement);
    }
    model.status_text = "Closing terminal";
}

fn cycleTab(model: *Model, forward: bool) void {
    const tabs = model.tab_store.items.items;
    const count = model.activeWorkspaceTerminalCount();
    if (count < 2) return;
    const active = model.activeTabId(model.active_workspace_id);
    var ordinal: usize = 0;
    var active_ordinal: usize = 0;
    for (tabs) |tab| {
        if (tab.workspace_id != model.active_workspace_id) continue;
        if (tab.id == active) active_ordinal = ordinal;
        ordinal += 1;
    }
    const target = if (forward)
        (active_ordinal + 1) % count
    else if (active_ordinal == 0)
        count - 1
    else
        active_ordinal - 1;
    ordinal = 0;
    for (tabs) |tab| {
        if (tab.workspace_id != model.active_workspace_id) continue;
        if (ordinal == target) {
            model.setActiveTab(tab.workspace_id, tab.id);
            model.status_text = "Terminal focused";
            return;
        }
        ordinal += 1;
    }
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
        fx.ptyKill(tab.pty);
    }
    // Already-ended tabs have no terminal event left to await.
    var index = model.tab_store.items.items.len;
    while (index > 0) {
        index -= 1;
        const tab = model.tab_store.items.items[index];
        if (tab.workspace_id == workspace_id and (tab.phase == .exited or tab.phase == .failed)) removeTab(model, index);
    }
}

fn closeTabsForProject(model: *Model, fx: *Effects, project_id: u64) void {
    const project = model.project_store.findProject(project_id) orelse return;
    for (project.worktrees.items) |worktree| closeTabsForWorkspace(model, fx, worktree.id);
}

fn maybeFinishPendingTeardown(model: *Model, fx: *Effects) void {
    if (model.pending_remove_workspace_id != 0 and !hasTabsForWorkspace(model, model.pending_remove_workspace_id)) {
        const workspace_id = model.pending_remove_workspace_id;
        if (model.pending_remove_recheck) {
            model.pending_remove_recheck = false;
            model.remove_rechecking = true;
            model.remove_dirty = false;
            model.remove_has_submodules = false;
            model.remove_unmerged_count = 0;
            preflightRemoveStatus(model, fx, workspace_id);
        }
    }
    if (model.pending_detach_project_id != 0 and !hasTabsForProject(model, model.pending_detach_project_id)) {
        const project_id = model.pending_detach_project_id;
        model.pending_detach_project_id = 0;
        _ = model.project_store.detach(project_id);
        if (model.project_store.projectForWorkspace(model.active_workspace_id)) |active_project| {
            if (active_project.id == project_id) model.active_workspace_id = model.project_store.firstWorkspaceId();
        } else if (model.active_workspace_id != 0) {
            model.active_workspace_id = model.project_store.firstWorkspaceId();
        }
        persistProjects(model, fx);
        model.status_text = "Project detached";
    }
}

pub fn update(model: *Model, msg: Msg, fx: *Effects) void {
    switch (msg) {
        .open_folder => if (!model.restore_ready) {
            model.status_text = "Restoring attached projects";
        } else if (!model.busy()) {
            model.picker_serial +%= 1;
            model.status_text = "Choose a project folder";
        },
        .folder_selected => |payload| {
            if (!model.restore_ready or model.busy()) return;
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
            model.status_text = "Worktree selected";
        },
        .open_terminal => |id| openTerminal(model, fx, id),
        .open_active_terminal => openTerminal(model, fx, model.active_workspace_id),
        .activate_tab => |id| {
            for (model.tab_store.items.items) |tab| {
                if (tab.id != id or tab.workspace_id != model.active_workspace_id) continue;
                model.setActiveTab(tab.workspace_id, id);
                model.status_text = "Terminal focused";
                return;
            }
        },
        .previous_tab => cycleTab(model, false),
        .next_tab => cycleTab(model, true),
        .close_tab => |id| closeTerminal(model, fx, id),
        .begin_create_worktree => |project_id| {
            const project = model.project_store.findProject(project_id) orelse return;
            if (!project.attached or !project.is_git or model.busy()) return;
            model.create_project_id = project_id;
            model.create_branch.clear();
            model.create_dialog_open = true;
        },
        .edit_create_branch => |edit| model.create_branch.apply(edit),
        .cancel_create_worktree => {
            model.create_dialog_open = false;
            model.create_project_id = 0;
            model.create_branch.clear();
        },
        .confirm_create_worktree => {
            if (model.busy()) return;
            const project = model.project_store.findProject(model.create_project_id) orelse return;
            const branch = std.mem.trim(u8, model.create_branch.text(), " ");
            if (branch.len == 0) return;
            var target_buffer: [workspaces.max_path_bytes]u8 = undefined;
            const target = model.project_store.makeWorktreePath(project, branch, model.next_git_key, &target_buffer) orelse {
                model.status_text = "Could not derive a safe worktree path";
                return;
            };
            const project_id = model.create_project_id;
            model.create_dialog_open = false;
            validateNewBranch(model, fx, project_id, branch, target);
        },
        .request_remove_worktree => |workspace_id| {
            if (model.busy()) return;
            if (!model.project_store.workspaceAvailable(workspace_id)) return;
            const worktree = model.project_store.findWorktree(workspace_id) orelse return;
            if (worktree.is_main or !worktree.active) return;
            model.remove_workspace_id = workspace_id;
            model.remove_dirty = false;
            model.remove_has_submodules = false;
            model.remove_unmerged_count = 0;
            model.remove_rechecking = false;
            model.pending_remove_workspace_id = 0;
            model.pending_remove_recheck = false;
            preflightRemoveStatus(model, fx, workspace_id);
        },
        .cancel_remove_worktree => {
            model.remove_dialog_open = false;
            model.remove_workspace_id = 0;
            model.pending_remove_workspace_id = 0;
            model.pending_remove_recheck = false;
            model.remove_rechecking = false;
        },
        .confirm_remove_worktree => {
            const workspace_id = model.remove_workspace_id;
            if (workspace_id == 0 or model.busy()) return;
            model.remove_dialog_open = false;
            model.approved_remove_dirty = model.remove_dirty;
            model.approved_remove_has_submodules = model.remove_has_submodules;
            model.approved_remove_unmerged_count = model.remove_unmerged_count;
            model.pending_remove_workspace_id = workspace_id;
            model.pending_remove_recheck = true;
            closeTabsForWorkspace(model, fx, workspace_id);
            maybeFinishPendingTeardown(model, fx);
        },
        .request_detach_project => |project_id| {
            const project = model.project_store.findProject(project_id) orelse return;
            if (!project.attached) return;
            model.detach_project_id = project_id;
            model.detach_dialog_open = true;
        },
        .cancel_detach_project => {
            model.detach_dialog_open = false;
            model.detach_project_id = 0;
        },
        .confirm_detach_project => {
            const project_id = model.detach_project_id;
            if (project_id == 0 or model.busy()) return;
            model.detach_dialog_open = false;
            model.pending_detach_project_id = project_id;
            closeTabsForProject(model, fx, project_id);
            maybeFinishPendingTeardown(model, fx);
        },
        .git_done => |exit| {
            if (model.git_op.kind == .none or exit.key != model.git_op.key) return;
            const operation = model.git_op;
            model.git_op = .{};
            const succeeded = exit.reason == .exited and exit.code == 0 and !exit.output_truncated;
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
                        const root = std.mem.trim(u8, exit.output, " \r\n");
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
                .list_worktrees => {
                    if (succeeded) {
                        _ = model.project_store.applyWorktreePorcelain(operation.project_id, exit.output);
                        const project = model.project_store.findProject(operation.project_id) orelse return;
                        var selected: u64 = 0;
                        if (model.select_after_refresh.len > 0) {
                            for (project.worktrees.items) |worktree| {
                                if (worktree.active and worktree.path.eql(model.select_after_refresh.slice())) selected = worktree.id;
                            }
                            model.select_after_refresh.len = 0;
                        }
                        if (selected == 0) {
                            for (project.worktrees.items) |worktree| {
                                if (worktree.active) {
                                    selected = worktree.id;
                                    break;
                                }
                            }
                        }
                        if (selected != 0 and (model.active_workspace_id == 0 or operation.project_id == model.create_project_id or model.restore_scan_active)) model.active_workspace_id = selected;
                        if (operation.project_id == model.create_project_id) model.create_project_id = 0;
                        if (model.create_failed) {
                            model.create_failed = false;
                            model.status_text = "Worktree creation failed; branch retained and Git state refreshed";
                        } else {
                            model.status_text = "Worktrees refreshed";
                        }
                    } else {
                        if (model.create_failed) {
                            model.create_failed = false;
                            model.status_text = "Worktree creation failed; inspect Git state manually";
                        } else {
                            model.status_text = "Could not list Git worktrees";
                        }
                    }
                    detectNextRestoredProject(model, fx);
                },
                .validate_branch => if (succeeded) {
                    checkWorktreeTarget(model, fx, operation);
                } else {
                    model.status_text = "That is not a valid Git branch name";
                },
                .check_target => if (succeeded) {
                    checkBranchAvailable(model, fx, operation);
                } else {
                    model.status_text = "The generated worktree target already exists";
                },
                .check_branch => if (exit.reason == .exited and exit.code == 1) {
                    createBranch(model, fx, operation);
                } else if (succeeded) {
                    model.status_text = "That local branch already exists";
                } else {
                    model.status_text = "Git could not check branch availability";
                },
                .create_branch => if (succeeded) {
                    createWorktree(model, fx, operation);
                } else {
                    model.status_text = "Git could not create the branch (it may now exist)";
                },
                .create_worktree => if (succeeded) {
                    _ = model.select_after_refresh.set(operation.target_path.slice());
                    refreshWorktrees(model, fx, operation.project_id);
                } else {
                    model.create_failed = true;
                    _ = model.select_after_refresh.set(operation.target_path.slice());
                    refreshWorktrees(model, fx, operation.project_id);
                },
                .remove_status => {
                    model.remove_dirty = !succeeded or std.mem.trim(u8, exit.output, " \r\n").len > 0;
                    preflightRemoveSubmodules(model, fx, operation.workspace_id);
                },
                .remove_submodules => {
                    const no_submodules = exit.reason == .exited and exit.code == 1;
                    model.remove_has_submodules = if (succeeded) std.mem.trim(u8, exit.output, " \r\n").len > 0 else !no_submodules;
                    preflightRemoveUnmerged(model, fx, operation.workspace_id);
                },
                .remove_unmerged => {
                    model.remove_unmerged_count = if (succeeded) countNonEmptyLines(exit.output) else 1;
                    finishRemovePreflight(model, fx);
                },
                .remove_worktree => if (succeeded) {
                    _ = model.project_store.removeWorktree(operation.workspace_id);
                    if (model.active_workspace_id == operation.workspace_id) model.active_workspace_id = model.project_store.firstWorkspaceId();
                    refreshWorktrees(model, fx, operation.project_id);
                } else {
                    model.status_text = "Git refused to remove the worktree";
                },
                .none => {},
            }
        },
        .store_done => |result| {
            if (result.op == .read) {
                model.restore_ready = true;
                if (result.outcome == .ok) {
                    _ = model.project_store.restoreAttached(result.bytes);
                    model.active_workspace_id = model.project_store.firstWorkspaceId();
                    model.restore_scan_active = true;
                    model.restore_scan_index = 0;
                    detectNextRestoredProject(model, fx);
                } else {
                    model.status_text = "Ready";
                }
            } else if (result.op == .write) {
                model.persist_write_active = false;
                if (result.outcome != .ok) model.status_text = "Attached projects could not be persisted";
                if (model.persist_dirty) {
                    model.persist_dirty = false;
                    persistProjects(model, fx);
                }
            }
        },
        .terminal_event => |event| {
            var index: usize = 0;
            while (index < model.tab_store.items.items.len) : (index += 1) {
                if (model.tab_store.items.items[index].pty != event.key) continue;
                switch (event.kind) {
                    .output => {
                        if (model.tab_store.items.items[index].phase != .closing) {
                            model.tab_store.items.items[index].phase = .running;
                            model.status_text = "Shell running";
                        }
                    },
                    .exit => {
                        if (model.tab_store.items.items[index].phase == .closing) {
                            removeTab(model, index);
                            model.status_text = "Terminal closed";
                        } else {
                            model.tab_store.items.items[index].exit_code = event.code;
                            model.tab_store.items.items[index].phase = if (event.reason == .exited) .exited else .failed;
                            model.status_text = if (event.reason == .exited) "Shell exited" else "Shell failed";
                        }
                    },
                    .write => unreachable,
                }
                maybeFinishPendingTeardown(model, fx);
                return;
            }
        },
        .sidebar_resized => |fraction| model.sidebar_fraction = fraction,
        .chrome_changed => |chrome| model.chrome_leading = @max(76, chrome.insets.left + 64),
    }
}

pub fn boot(model: *Model, fx: *Effects) void {
    if (model.store_path.len > 0) {
        fx.readFile(.{
            .key = store_read_key,
            .path = model.store_path.slice(),
            .on_result = Effects.fileMsg(.store_done),
        });
    } else if (model.active_workspace_id != 0) {
        openTerminal(model, fx, model.active_workspace_id);
    }
}

pub fn onChrome(chrome: native_sdk.WindowChrome) ?Msg {
    return .{ .chrome_changed = chrome };
}

pub const AppUi = canvas.Ui(Msg);
pub const app_markup = @embedFile("app.native");

const app_permissions = [_][]const u8{
    native_sdk.security.permission_command,
    native_sdk.security.permission_view,
};
const shell_views = [_]native_sdk.ShellView{.{
    .label = canvas_label,
    .kind = .gpu_surface,
    .fill = true,
    .role = "Canopy workspace",
    .accessibility_label = "Canopy",
    .gpu_backend = .metal,
    .gpu_pixel_format = .bgra8_unorm,
    .gpu_present_mode = .timer,
    .gpu_alpha_mode = .@"opaque",
    .gpu_color_space = .srgb,
    .gpu_vsync = true,
}};
const shell_windows = [_]native_sdk.ShellWindow{.{
    .label = "main",
    .title = "Canopy",
    .width = window_width,
    .height = window_height,
    .min_width = 860,
    .min_height = 560,
    .titlebar = .hidden_inset_tall,
    .views = &shell_views,
}};
const shell_scene: native_sdk.ShellConfig = .{ .windows = &shell_windows };

pub fn initialModel(tab_store: *TabStore, project_store: *workspaces.Store) Model {
    return .{ .tab_store = tab_store, .project_store = project_store };
}

fn appOptions(io: std.Io) CanopyApp.Options {
    return .{
        .name = "canopy-native-sdk-poc",
        .scene = shell_scene,
        .canvas_label = canvas_label,
        .update_fx = update,
        .init_fx = boot,
        .markup = .{ .source = app_markup, .watch_path = "src/app.native", .io = io },
        .on_chrome = onChrome,
    };
}

const CanopyHost = struct {
    ui_app: *CanopyApp,
    io: std.Io,
    handled_picker_serial: u64 = 0,

    fn create(allocator: std.mem.Allocator, io: std.Io, tab_store: *TabStore, project_store: *workspaces.Store, store_path: []const u8) !*CanopyHost {
        const host = try allocator.create(CanopyHost);
        errdefer allocator.destroy(host);
        const ui_app = try CanopyApp.create(allocator, appOptions(io));
        ui_app.model = initialModel(tab_store, project_store);
        ui_app.model.setStorePath(store_path);
        host.* = .{ .ui_app = ui_app, .io = io };
        return host;
    }

    fn destroy(host: *CanopyHost, allocator: std.mem.Allocator) void {
        host.ui_app.model.active_tab_by_workspace.deinit(host.ui_app.model.tab_store.allocator);
        host.ui_app.destroy();
        allocator.destroy(host);
    }

    fn app(host: *CanopyHost) native_sdk.App {
        return .{
            .context = host,
            .name = "canopy-native-sdk-poc",
            .scene_fn = scene,
            .event_fn = event,
            .stop_fn = stop,
        };
    }

    fn scene(_: *anyopaque) anyerror!native_sdk.ShellConfig {
        return shell_scene;
    }

    fn event(context: *anyopaque, runtime: *native_sdk.Runtime, event_value: native_sdk.Event) anyerror!void {
        const host: *CanopyHost = @ptrCast(@alignCast(context));
        try host.ui_app.app().event(runtime, event_value);
        try host.presentPendingFolderDialog(runtime);
    }

    fn stop(context: *anyopaque, runtime: *native_sdk.Runtime) anyerror!void {
        const host: *CanopyHost = @ptrCast(@alignCast(context));
        try host.ui_app.app().stop(runtime);
        host.flushProjectsOnStop() catch |err| std.debug.print("canopy: final project snapshot failed ({s})\n", .{@errorName(err)});
    }

    fn flushProjectsOnStop(host: *CanopyHost) !void {
        const model = &host.ui_app.model;
        if (model.store_path.len == 0) return;
        var buffer: [workspaces.max_store_bytes]u8 = undefined;
        const bytes = model.project_store.serializeAttached(&buffer) orelse return error.ProjectStoreTooLarge;
        var atomic = try std.Io.Dir.cwd().createFileAtomic(host.io, model.store_path.slice(), .{ .make_path = true, .replace = true });
        defer atomic.deinit(host.io);
        try atomic.file.writePositionalAll(host.io, bytes, 0);
        try atomic.file.sync(host.io);
        try atomic.replace(host.io);
    }

    fn presentPendingFolderDialog(host: *CanopyHost, runtime: *native_sdk.Runtime) !void {
        const serial = host.ui_app.model.picker_serial;
        if (serial == host.handled_picker_serial) return;
        host.handled_picker_serial = serial;
        var path_buffer: [native_sdk.platform.max_dialog_paths_bytes]u8 = undefined;
        const result = runtime.showOpenDialog(.{
            .title = "Attach Project Folder",
            .allow_directories = true,
            .allow_multiple = false,
        }, &path_buffer) catch {
            try host.ui_app.dispatch(runtime, 1, .folder_dialog_failed);
            return;
        };
        if (result.count == 0) {
            try host.ui_app.dispatch(runtime, 1, .folder_dialog_cancelled);
            return;
        }
        const payload = PathPayload.from(result.paths) orelse {
            try host.ui_app.dispatch(runtime, 1, .folder_dialog_failed);
            return;
        };
        try host.ui_app.dispatch(runtime, 1, .{ .folder_selected = payload });
    }
};

pub fn main(init: std.process.Init) !void {
    const tab_store = try TabStore.create(std.heap.page_allocator);
    defer tab_store.destroy();
    const project_store = try workspaces.Store.create(std.heap.page_allocator);
    defer project_store.destroy();
    const env = native_sdk.debug.envFromMap(init.environ_map);
    const platform = native_sdk.app_dirs.currentPlatform();
    var worktree_base_buffer: [workspaces.max_path_bytes]u8 = undefined;
    if (env.home) |home| {
        if (std.fmt.bufPrint(&worktree_base_buffer, "{s}/canopy/worktrees", .{home})) |base| {
            if (project_store.setWorktreesBase(base)) {
                std.Io.Dir.cwd().createDirPath(init.io, base) catch {};
            }
        } else |_| {}
    }
    var data_dir_buffer: [workspaces.max_path_bytes]u8 = undefined;
    var store_path_buffer: [workspaces.max_path_bytes]u8 = undefined;
    var store_path: []const u8 = "";
    if (native_sdk.app_dirs.resolveOne(.{ .name = "tech.itsol.canopy.native-poc" }, platform, env, .data, &data_dir_buffer)) |data_dir| {
        std.Io.Dir.cwd().createDirPath(init.io, data_dir) catch {};
        store_path = native_sdk.app_dirs.join(platform, &store_path_buffer, &.{ data_dir, "projects.store" }) catch "";
    } else |_| {}
    const host = try CanopyHost.create(std.heap.page_allocator, init.io, tab_store, project_store, store_path);
    defer host.destroy(std.heap.page_allocator);

    try runner.runWithOptions(host.app(), .{
        .app_name = "canopy-native-sdk-poc",
        .window_title = "Canopy",
        .bundle_id = "tech.itsol.canopy.native-poc",
        .icon_path = "assets/icon.png",
        .default_frame = geometry.RectF.init(0, 0, window_width, window_height),
        .js_window_api = false,
        .security = .{
            .permissions = &app_permissions,
            .navigation = .{ .allowed_origins = &.{ "zero://inline", "zero://app" } },
        },
    }, init);
}

test {
    _ = @import("tests.zig");
}
