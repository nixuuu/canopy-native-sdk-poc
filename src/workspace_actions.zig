//! Workspace actions: one application feature boundary.
const types = @import("app_types.zig");
const Model = types.Model;
const Msg = types.Msg;
const Effects = types.Effects;
const std = @import("std");
const native_sdk = @import("native_sdk");
const workspaces = @import("workspaces.zig");
const git_workflow = @import("git_workflow.zig");
const terminal_actions = @import("terminal_actions.zig");
const GitOperation = git_workflow.Operation;

const store_read_key = @import("effect_keys.zig").key(.projects, 0);

pub fn collectUnused(model: *Model) void {
    model.project_store.collectUnused(model.tab_store);
    if (model.active_workspace_id != 0 and model.project_store.findWorktree(model.active_workspace_id) == null)
        model.active_workspace_id = model.project_store.firstWorkspaceId();
}

pub fn startGit(model: *Model, _: *Effects, operation: GitOperation) void {
    if (model.git.busy()) {
        model.status_text = "Another Git operation is still running";
        return;
    }
    _ = operation.request(model.project_store) orelse return;
    _ = model.git.begin(operation) orelse return;
    model.status_text = operation.progress();
}

pub fn detectRepository(model: *Model, fx: *Effects, project_id: u64) void {
    startGit(model, fx, .{ .kind = .detect_repo, .project_id = project_id });
}

pub fn refreshWorktrees(model: *Model, fx: *Effects, project_id: u64) void {
    const project = model.project_store.findProject(project_id) orelse return;
    if (!project.is_git) return;
    startGit(model, fx, .{ .kind = .list_worktrees, .project_id = project_id });
}

pub fn validateNewBranch(model: *Model, fx: *Effects, project_id: u64, branch: []const u8, target_path: []const u8) void {
    var operation = GitOperation{ .kind = .validate_branch, .project_id = project_id };
    if (!operation.branch.set(branch) or !operation.target_path.set(target_path)) {
        model.status_text = "Branch name or worktree path is too long";
        return;
    }
    startGit(model, fx, operation);
}

pub fn persistProjects(model: *Model, fx: *Effects) void {
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

pub fn detectNextRestoredProject(model: *Model, fx: *Effects) void {
    if (!model.project_io.scanning() or model.git.busy()) return;
    if (model.project_io.nextAttachedProject(model.project_store)) |project_id| {
        startGit(model, fx, .{ .kind = .restore_check, .project_id = project_id });
        return;
    }
    model.status_text = if (model.project_store.hasProjects()) "Projects restored" else "Ready";
}

pub fn preflightRemoveStatus(model: *Model, fx: *Effects, workspace_id: u64) void {
    const worktree = model.project_store.findWorktree(workspace_id) orelse return;
    if (worktree.is_main or !worktree.active) return;
    startGit(model, fx, .{ .kind = .remove_status, .workspace_id = workspace_id });
}

pub fn finishRemovePreflight(model: *Model, fx: *Effects) void {
    const review = model.teardown.reviewed(model.workspace_dialogs.removal.safety);
    switch (review) {
        .initial, .changed => {
            model.workspace_dialogs.removal.review();
            model.status_text = if (review == .changed) "Worktree safety state changed; review again" else "Review worktree removal";
        },
        .remove => |removal| executeWorktreeRemoval(model, fx, removal.workspace_id, removal.force),
    }
}

pub fn executeWorktreeRemoval(model: *Model, fx: *Effects, workspace_id: u64, force: bool) void {
    const worktree = model.project_store.findWorktree(workspace_id) orelse return;
    const project = model.project_store.projectForWorkspace(workspace_id) orelse return;
    var operation = GitOperation{ .kind = .remove_worktree, .project_id = project.id, .workspace_id = workspace_id, .force = force, .approved = model.workspace_dialogs.removal.safety };
    _ = operation.target_path.set(worktree.path.slice());
    startGit(model, fx, operation);
}

pub fn maybeFinishPendingTeardown(model: *Model, fx: *Effects) void {
    const target = model.teardown.waitingFor() orelse return;
    const has_tabs = switch (target) {
        .workspace => |id| terminal_actions.hasTabsForWorkspace(model, id),
        .project => |id| terminal_actions.hasTabsForProject(model, id),
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

pub fn handleStoreResult(model: *Model, fx: *Effects, result: native_sdk.EffectFileResult) void {
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

pub fn handleGitDiscovery(model: *Model, fx: *Effects, operation: GitOperation, result: git_workflow.Result) void {
    const succeeded = result.outcome() == .success;
    switch (operation.kind) {
        .restore_check => if (succeeded) {
            detectRepository(model, fx, operation.project_id);
        } else {
            if (result.value == .failure) {
                model.status_text = result.value.failure.message();
                detectNextRestoredProject(model, fx);
                return;
            }
            _ = model.project_store.detach(operation.project_id);
            model.active_workspace_id = model.project_store.firstWorkspaceId();
            persistProjects(model, fx);
            detectNextRestoredProject(model, fx);
        },
        .detect_repo => {
            if (succeeded) {
                const root = result.value.root.slice();
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
                model.status_text = if (result.value == .failure and result.value.failure != .not_repository) result.value.failure.message() else "Folder attached";
                detectNextRestoredProject(model, fx);
            }
        },
        else => unreachable,
    }
}

pub fn handleWorktreeList(model: *Model, fx: *Effects, operation: GitOperation, result: git_workflow.Result) void {
    if (result.outcome() == .success) {
        if (result.value != .worktrees) {
            model.status_text = "Invalid Git worktree response";
            return;
        }
        model.project_store.applySnapshot(operation.project_id, result.value.worktrees) catch {
            model.status_text = "Git worktree snapshot could not be applied";
            detectNextRestoredProject(model, fx);
            return;
        };
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

pub fn handleGitCreation(model: *Model, fx: *Effects, operation: GitOperation, result: git_workflow.Result) void {
    switch (operation.kind) {
        .validate_branch, .check_target, .check_branch, .create_branch => {
            switch (operation.advanceCreation(result.outcome())) {
                .next => |next| startGit(model, fx, next),
                .failed => |message| model.status_text = if (result.value == .failure) result.value.failure.message() else message,
            }
        },
        .create_worktree => {
            model.workspace_dialogs.create.trackCheckout(operation.target_path.slice(), result.outcome() != .success);
            refreshWorktrees(model, fx, operation.project_id);
        },
        else => unreachable,
    }
}

pub fn handleGitRemoval(model: *Model, fx: *Effects, operation: GitOperation, result: git_workflow.Result) void {
    switch (operation.kind) {
        .remove_status => {
            if (result.value != .safety) {
                model.teardown = .idle;
                model.workspace_dialogs.removal.cancel();
                model.status_text = if (result.value == .failure) result.value.failure.message() else "Invalid Git safety response";
                return;
            }
            model.workspace_dialogs.removal.safety = result.value.safety;
            finishRemovePreflight(model, fx);
        },
        .remove_worktree => if (result.value == .changed) {
            model.workspace_dialogs.removal.safety = result.value.changed;
            model.workspace_dialogs.removal.review();
            model.teardown = .idle;
            model.status_text = "Worktree safety state changed; review again";
        } else if (result.value == .ok) {
            _ = model.project_store.removeWorktree(operation.workspace_id);
            if (model.active_workspace_id == operation.workspace_id) model.active_workspace_id = model.project_store.firstWorkspaceId();
            refreshWorktrees(model, fx, operation.project_id);
        } else {
            model.status_text = if (result.value == .failure) result.value.failure.message() else "Invalid Git removal response";
        },
        else => unreachable,
    }
}

pub fn handleGitResult(model: *Model, fx: *Effects, incoming: git_workflow.Result) void {
    const operation = model.git.finish(incoming.key) orelse return;
    const valid = incoming.value == .failure or switch (operation.kind) {
        .none => false,
        .restore_check, .validate_branch, .check_target, .check_branch => incoming.value == .exists,
        .detect_repo => incoming.value == .root,
        .list_worktrees => incoming.value == .worktrees,
        .create_branch, .create_worktree => incoming.value == .ok,
        .remove_status => incoming.value == .safety,
        .remove_worktree => incoming.value == .ok or incoming.value == .changed,
    };
    const result: git_workflow.Result = if (valid) incoming else .{ .key = incoming.key, .value = .{ .failure = .invalid_input } };
    switch (operation.kind.group()) {
        .none => {},
        .discovery => handleGitDiscovery(model, fx, operation, result),
        .listing => handleWorktreeList(model, fx, operation, result),
        .creation => handleGitCreation(model, fx, operation, result),
        .removal => handleGitRemoval(model, fx, operation, result),
    }
}

pub fn beginProjectRestore(model: *Model, fx: *Effects) void {
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
        terminal_actions.openTerminal(model, fx, model.active_workspace_id);
    }
}

pub fn handle(model: *Model, msg: Msg, fx: *Effects) void {
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
            terminal_actions.closeTabsForWorkspace(model, fx, workspace_id);
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
            terminal_actions.closeTabsForProject(model, fx, project_id);
            maybeFinishPendingTeardown(model, fx);
        },
        .worktrees_base_failed => model.status_text = "Worktree base directory could not be created",
        .git_done => |result| handleGitResult(model, fx, result),
        .git_wakeup => |event| {
            if (event.kind == .data) model.git.notified(event.key);
        },
        .store_done => |result| handleStoreResult(model, fx, result),
        else => unreachable,
    }
}
