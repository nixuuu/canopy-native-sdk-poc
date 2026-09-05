//! Agent actions: one application feature boundary.
const types = @import("app_types.zig");
const Model = types.Model;
const Msg = types.Msg;
const Effects = types.Effects;
const std = @import("std");
const native_sdk = @import("native_sdk");
const profiles_mod = @import("profiles.zig");
const tool_launch = @import("tool_launch.zig");
const tool_registry = @import("tool_registry.zig");
const workspaces = @import("workspaces.zig");
const terminal_actions = @import("terminal_actions.zig");
const terminal_tabs = @import("terminal_tabs.zig");
const TerminalTool = terminal_tabs.Tool;

pub const resolvedToolExecutable = tool_launch.resolvedExecutable;

pub fn startToolChecks(model: *Model, fx: *Effects) void {
    model.tools.beginDiscovery();
    const shell = model.userShell();
    // Absolute /usr/bin/which resolves external executables from the PATH
    // produced by the user's login shell, ignoring aliases/functions. The
    // collected path is reused verbatim for PTY launch so discovery and start
    // cannot drift to different global installations.
    fx.spawn(.{ .key = tool_registry.claude_check_key, .argv = &.{ shell, "-lc", "/usr/bin/which claude" }, .output = .collect, .on_exit = Effects.exitMsg(.tool_check_done) });
    fx.spawn(.{ .key = tool_registry.codex_check_key, .argv = &.{ shell, "-lc", "/usr/bin/which codex" }, .output = .collect, .on_exit = Effects.exitMsg(.tool_check_done) });
}

pub fn toolAvailable(model: *const Model, tool: TerminalTool) bool {
    return model.tools.available(tool);
}

pub fn toolTitle(model: *const Model, workspace_id: u64, tool: TerminalTool, profile: *const profiles_mod.Profile, out: []u8) ?[]const u8 {
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

pub fn spawnProfileTool(model: *Model, fx: *Effects, profile: *const profiles_mod.Profile) void {
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
    const launch = tool_launch.Spec.buildTracked(
        env_arena.allocator(),
        model.userShell(),
        workspace.path.slice(),
        model.toolExecutable(tool),
        profile,
        model.use_agent_hooks,
    ) orelse {
        model.status_text = "Agent launch settings are invalid or exceed host limits";
        return;
    };

    var title_buffer: [workspaces.max_name_bytes]u8 = undefined;
    const title = toolTitle(model, workspace.id, tool, profile, &title_buffer) orelse profile.agent_type.displayName();
    terminal_actions.startTerminal(model, fx, .{
        .workspace = workspace,
        .title = title,
        .tool = tool,
        .profile_id = profile.id.slice(),
        .argv = launch.argv(),
        .env = launch.env(),
    });
}

pub fn launchDefaultTool(model: *Model, fx: *Effects, agent_type: profiles_mod.AgentType) void {
    if (!model.profile_edit.loaded) return;
    const profile = model.profile_store.default(agent_type) orelse return;
    spawnProfileTool(model, fx, profile);
}

pub fn launchProfileTool(model: *Model, fx: *Effects, runtime_id: u64) void {
    if (!model.profile_edit.loaded) return;
    const profile = model.profile_store.find(runtime_id) orelse return;
    spawnProfileTool(model, fx, profile);
}

pub fn handleToolCheckResult(model: *Model, exit: native_sdk.EffectExit) void {
    const resolved = if (exit.reason == .exited and exit.code == 0) resolvedToolExecutable(exit.output) else null;
    _ = model.tools.completeDiscovery(exit.key, resolved);
}

pub fn viewed(model: *const Model, tab: *const terminal_tabs.Tab) bool {
    return model.active_workspace_id == tab.workspace_id and model.activeTabId(tab.workspace_id) == tab.id and !model.terminalActionsBlocked();
}

pub fn acknowledge(model: *Model) void {
    for (model.tab_store.items.items) |*tab| if (viewed(model, tab)) {
        tab.agent.unread = false;
    };
}

fn hookEvent(model: *Model, event: native_sdk.EffectChannelEvent) void {
    // The SDK reports loss for the shared channel, without the lost tab IDs.
    // Conservatively mark every live registration, even if this packet is stale.
    if (event.dropped_pending > 0) trackingGap(model, event.dropped_pending);
    if (event.kind != .data) return;
    const parsed = @import("agent_events.zig").decode(std.heap.page_allocator, event.bytes) catch return;
    for (model.tab_store.items.items) |*tab| {
        if (tab.id != parsed.tab or tab.tool == .shell or !tab.agent.registered or tab.phase == .closing or tab.phase == .failed or tab.phase == .exited) continue;
        tab.agent.receive(parsed, viewed(model, tab), 0);
        return;
    }
}

fn trackingGap(model: *Model, count: u32) void {
    for (model.tab_store.items.items) |*tab| if (tab.agent.registered and
        tab.phase != .closing and tab.phase != .failed and tab.phase != .exited)
    {
        tab.agent.lost_events +|= count;
    };
}

pub fn handle(model: *Model, msg: Msg, fx: *Effects) void {
    switch (msg) {
        .agent_hook_event => |event| hookEvent(model, event),
        .agent_tracking_failed => {
            trackingGap(model, 1);
            model.status_text = "Agent tracking unavailable; restart affected agent tabs";
        },
        .agent_setup_failed => |id| {
            for (model.tab_store.items.items) |tab| if (tab.id == id) {
                terminal_actions.handleTerminalEvent(model, fx, .{ .key = tab.pty, .kind = .exit, .reason = .spawn_failed });
                break;
            };
            model.status_text = "Agent hook setup failed; see application diagnostics";
        },
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
        else => unreachable,
    }
}
