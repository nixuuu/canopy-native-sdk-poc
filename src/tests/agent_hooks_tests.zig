const support = @import("support.zig");
const std = support.std;
const app = support.app;
const events = @import("../agent_events.zig");
const State = @import("../agent_state.zig").State;
const config = @import("../agent_hook_config.zig");
const Server = @import("../agent_hook_server.zig").Server;
const c = @import("../agent_hook_server.zig").c;
const a = std.testing.allocator;

fn event(kind: events.Kind, seq: u64) events.Event {
    var value: events.Event = .{ .kind = kind, .sequence = seq };
    events.text(&value.session, "parent");
    return value;
}

test "agent lifecycle tracks tools permissions compaction and stale events" {
    var state: State = .{};
    state.receive(event(.session_start, 1), true, 0);
    try std.testing.expectEqual(.idle, state.status);
    state.receive(event(.prompt, 2), true, 0);
    try std.testing.expectEqual(.thinking, state.status);
    var tool = event(.before_tool, 3);
    events.text(&tool.tool, "Bash");
    state.receive(tool, true, 0);
    try std.testing.expectEqual(.tool, state.status);
    state.receive(event(.permission, 4), false, 0);
    try std.testing.expect(state.unread and state.status == .permission);
    state.receive(event(.after_tool, 5), true, 0);
    try std.testing.expectEqual(@as(usize, 1), state.tool_count);
    try std.testing.expect(!state.unread and state.status == .thinking);
    state.receive(event(.before_compact, 6), true, 0);
    try std.testing.expectEqual(@as(usize, 1), state.compact_count);
    state.receive(event(.after_compact, 7), true, 0);
    for (8..50) |seq| state.receive(event(.idle, seq), false, 0);
    state.receive(event(.before_tool, 2), true, 0); // stale callback
    try std.testing.expectEqual(.idle, state.status);
    state.receive(event(.prompt, 50), true, 3);
    try std.testing.expectEqualStrings("Tracking gap", state.label());
}

test "child session events cannot overwrite the parent status or model" {
    var state: State = .{};
    state.receive(event(.session_start, 1), true, 0);
    state.receive(event(.prompt, 2), true, 0);
    var child = event(.idle, 3);
    events.text(&child.session, "child");
    events.text(&child.model, "child-model");
    state.receive(child, true, 0);
    try std.testing.expectEqual(.thinking, state.status);
    try std.testing.expectEqual(@as(usize, 0), state.model.len);
    var sub = event(.subagent_start, 4);
    events.text(&sub.agent_id, "worker-1");
    state.receive(sub, true, 0);
    sub.sequence = 5;
    state.receive(sub, true, 0);
    try std.testing.expectEqual(@as(usize, 1), state.subagent_count);
    sub.sequence = 6;
    sub.kind = .subagent_stop;
    state.receive(sub, true, 0);
    try std.testing.expectEqual(@as(usize, 0), state.subagent_count);
}

test "normalization bounds strings strips raw prompt data and validates status metrics" {
    const raw = "{\"hook_event_name\":\"PreToolUse\",\"session_id\":\"conversation\",\"tool_name\":\"Bash\",\"tool_input\":{\"description\":\"Run tests\",\"command\":\"secret-command\"},\"prompt\":\"private prompt\",\"CANOPY_HOOK_TOKEN\":\"secret-token\"}";
    var parsed = try events.normalize(a, raw, false);
    parsed.tab = 3;
    parsed.sequence = 1;
    var buffer: [4096]u8 = undefined;
    const wire = try events.encode(&parsed, &buffer);
    try std.testing.expect(std.mem.indexOf(u8, wire, "secret") == null);
    try std.testing.expect(std.mem.indexOf(u8, wire, "private prompt") == null);
    const decoded = try events.decode(a, wire);
    try std.testing.expectEqualStrings("Run tests", decoded.detail.slice());
    const status = try events.normalize(a, "{\"session_id\":\"conversation\",\"model\":{\"display_name\":\"Opus\"},\"context_window\":{\"used_percentage\":42},\"cost\":{\"total_cost_usd\":0.25}}", true);
    try std.testing.expectEqual(@as(?f64, 42), status.context_percent);
    try std.testing.expectEqual(@as(?f64, 0.25), status.cost_usd);
    const invalid = try events.normalize(a, "{\"context_window\":{\"used_percentage\":140},\"cost\":{\"total_cost_usd\":-2}}", true);
    try std.testing.expect(invalid.context_percent == null and invalid.cost_usd == null);
    try std.testing.expectError(error.InvalidHook, events.normalize(a, "[]", false));
}

test "hook configuration appends observer hooks preserves user handlers and never writes files" {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const allocator = arena.allocator();
    const json = try config.build(allocator, .claude, "{\"hooks\":{\"Stop\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"echo own-hook\"}]}]},\"statusLine\":{\"type\":\"command\",\"command\":\"echo own-status\"},\"other\":true}");
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, allocator, json, .{});
    try std.testing.expectEqual(@as(usize, 2), parsed.object.get("hooks").?.object.get("Stop").?.array.items.len);
    try std.testing.expectEqualStrings("echo own-status", parsed.object.get("statusLine").?.object.get("command").?.string);
    try std.testing.expect(parsed.object.get("other").?.bool);
    const toml = try config.build(allocator, .codex, "{}");
    try std.testing.expect(std.mem.startsWith(u8, toml, "hooks={"));
    try std.testing.expect(std.mem.indexOf(u8, toml, "\"SessionStart\"=") != null);
    try std.testing.expect(std.mem.indexOf(u8, toml, ".codex/hooks.json") == null);
    try std.testing.expect(std.mem.indexOf(u8, toml, "\"timeout\"=3") != null);
    try std.testing.expectError(error.InvalidHooks, config.build(allocator, .codex, "{\"hooks\":[]}"));
    try std.testing.expectError(error.ProtectedEnvironment, config.build(allocator, .claude, "{\"env\":{\"CANOPY_HOOK_TOKEN\":\"override\"}}"));
}

fn connect(port: u16) !c_int {
    const fd = c.socket(c.AF_INET, c.SOCK_STREAM, 0);
    if (fd < 0) return error.Socket;
    errdefer _ = c.close(fd);
    var address: c.struct_sockaddr_in = std.mem.zeroes(c.struct_sockaddr_in);
    address.sin_len = @sizeOf(c.struct_sockaddr_in);
    address.sin_family = c.AF_INET;
    address.sin_port = c.htons(port);
    address.sin_addr.s_addr = c.htonl(0x7f000001);
    if (c.connect(fd, @ptrCast(&address), @sizeOf(c.struct_sockaddr_in)) != 0) return error.Connect;
    var timeout: c.struct_timeval = .{ .tv_sec = 3, .tv_usec = 0 };
    _ = c.setsockopt(fd, c.SOL_SOCKET, c.SO_RCVTIMEO, &timeout, @sizeOf(c.struct_timeval));
    return fd;
}
fn post(port: u16, tab: u64, token: []const u8, body: []const u8) !u16 {
    const fd = try connect(port);
    defer _ = c.close(fd);
    const request = try std.fmt.allocPrint(a, "POST /session/{d}/hook HTTP/1.1\r\nHost: localhost\r\nX-Canopy-Auth: {s}\r\nContent-Length: {d}\r\n\r\n{s}", .{ tab, token, body.len, body });
    defer a.free(request);
    var sent: usize = 0;
    while (sent < request.len) {
        const n = c.send(fd, request.ptr + sent, request.len - sent, 0);
        if (n <= 0) return error.Send;
        sent += @intCast(n);
    }
    var buffer: [256]u8 = undefined;
    const n = c.recv(fd, &buffer, buffer.len, 0);
    if (n < 12) return error.Response;
    return std.fmt.parseInt(u16, buffer[9..12], 10);
}

const TestMsg = union(enum) { hook: support.sdk.EffectChannelEvent };
test "HTTP server authenticates each route rejects stale sessions and serves past slow clients" {
    var fx = support.sdk.Effects(TestMsg).init(a);
    defer fx.deinit();
    fx.executor = .fake;
    const channel = fx.openChannel(.{ .key = 1, .on_event = @TypeOf(fx).channelMsg(.hook) });
    const server = try Server.create(channel);
    defer server.destroy();
    const one = try server.register(1);
    const two = try server.register(2);
    try std.testing.expect(!std.mem.eql(u8, &one, &two));
    const stalled = try connect(server.port);
    defer _ = c.close(stalled);
    _ = c.send(stalled, "POST /", 6, 0);
    const body = "{\"hook_event_name\":\"PreToolUse\",\"session_id\":\"agent-id\",\"tool_name\":\"Bash\"}";
    try std.testing.expectEqual(@as(u16, 403), try post(server.port, 2, &one, body));
    try std.testing.expectEqual(@as(u16, 403), try post(server.port, 1, "invalid", body));
    try std.testing.expectEqual(@as(u16, 200), try post(server.port, 2, &two, body));
    const message = fx.takeMsg() orelse return error.MissingEvent;
    const received = try events.decode(a, message.hook.bytes);
    try std.testing.expectEqual(@as(u64, 2), received.tab);
    try std.testing.expectEqualStrings("agent-id", received.session.slice());
    try std.testing.expectEqual(@as(u16, 400), try post(server.port, 1, &one, "[]"));
    server.unregister(1);
    try std.testing.expectEqual(@as(u16, 404), try post(server.port, 1, &one, body));
}

test "HTTP framing rejects duplicated auth conflicting lengths and chunked bodies" {
    const parse = @import("../agent_hook_server.zig").parseHeaders;
    try std.testing.expectError(error.DuplicateAuth, parse("POST /session/1/hook HTTP/1.1\r\nContent-Length: 2\r\nX-Canopy-Auth: a\r\nX-Canopy-Auth: b"));
    try std.testing.expectError(error.BadLength, parse("POST / HTTP/1.1\r\nContent-Length: 2\r\nContent-Length: 3"));
    try std.testing.expectError(error.UnsupportedEncoding, parse("POST / HTTP/1.1\r\nTransfer-Encoding: chunked"));
    try std.testing.expectError(error.BadMethod, parse("GET / HTTP/1.1"));
}

test "host prepares separate authenticated launches in one worktree and cleans registrations" {
    const stores = try support.Stores.init();
    defer stores.deinit();
    var ui: @import("git_service_tests.zig").Ui = .{ .model = app.initialModel(stores.tabs, stores.projects, stores.profiles), .effects = app.Effects.init(a) };
    defer ui.effects.deinit();
    defer ui.model.terminal_state.deinit(a);
    ui.effects.executor = .fake;
    ui.model.use_agent_hooks = true;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, ".codex");
    const original_hooks = "{\"hooks\":{},\"description\":\"user configuration\"}\n";
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".codex/hooks.json", .data = original_hooks });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".gitignore", .data = "node_modules/\n" });
    var path_buffer: [1024]u8 = undefined;
    const path_len = try tmp.dir.realPath(std.testing.io, &path_buffer);
    ui.model.active_workspace_id = stores.projects.attachPlaceholder(path_buffer[0..path_len]).?.workspace_id;
    _ = try support.addProfile(stores, 1, .codex, "Default");
    ui.model.profile_edit.loaded = true;
    _ = ui.model.tools.setExecutable(.codex, "/fake/codex");
    var host: @import("../agent_hook_host.zig").Host = .{};
    defer host.deinit();
    try ui.dispatch({}, 1, .{ .launch_agent = .codex });
    try ui.dispatch({}, 1, .{ .launch_agent = .codex });
    try std.testing.expectEqual(@as(usize, 0), ui.effects.pendingPtyCount());
    try host.reconcile({}, &ui);
    try std.testing.expectEqual(@as(usize, 2), ui.effects.pendingPtyCount());
    const first = ui.effects.pendingPtyAt(0).?;
    const second = ui.effects.pendingPtyAt(1).?;
    const one = support.envValue(first, "CANOPY_HOOK_TOKEN").?;
    const two = support.envValue(second, "CANOPY_HOOK_TOKEN").?;
    try std.testing.expect(!std.mem.eql(u8, one, two));
    const first_id = stores.tabs.items.items[0].id;
    const second_id = stores.tabs.items.items[1].id;
    try std.testing.expectEqual(@as(u16, 200), try post(host.server.?.port, first_id, one, "{\"hook_event_name\":\"PermissionRequest\",\"session_id\":\"one\"}"));
    while (ui.effects.takeMsg()) |msg| try ui.dispatch({}, 1, msg);
    try std.testing.expectEqual(.permission, stores.tabs.items.items[0].agent.status);
    try std.testing.expectEqual(.starting, stores.tabs.items.items[1].agent.status);
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const rows = ui.model.sidebarRows(arena.allocator());
    try std.testing.expectEqualStrings("Needs permission", rows[1].agent_status);
    try ui.dispatch({}, 1, .{ .close_tab = first_id });
    try host.reconcile({}, &ui);
    try std.testing.expect(!host.server.?.registered(first_id));
    try std.testing.expect(host.server.?.registered(second_id));
    const after_hooks = try tmp.dir.readFileAlloc(std.testing.io, ".codex/hooks.json", a, .limited(4096));
    defer a.free(after_hooks);
    const after_ignore = try tmp.dir.readFileAlloc(std.testing.io, ".gitignore", a, .limited(4096));
    defer a.free(after_ignore);
    try std.testing.expectEqualStrings(original_hooks, after_hooks);
    try std.testing.expectEqualStrings("node_modules/\n", after_ignore);
}

test "cancelling a tracked launch before registration cannot strand teardown" {
    const stores = try support.Stores.init();
    defer stores.deinit();
    var ui: @import("git_service_tests.zig").Ui = .{ .model = app.initialModel(stores.tabs, stores.projects, stores.profiles), .effects = app.Effects.init(a) };
    defer ui.effects.deinit();
    defer ui.model.terminal_state.deinit(a);
    ui.effects.executor = .fake;
    ui.model.use_agent_hooks = true;
    ui.model.active_workspace_id = stores.projects.attachPlaceholder("/tmp/early-cancel").?.workspace_id;
    _ = try support.addProfile(stores, 1, .claude, "Default");
    ui.model.profile_edit.loaded = true;
    _ = ui.model.tools.setExecutable(.claude, "/fake/claude");
    try ui.dispatch({}, 1, .{ .launch_agent = .claude });
    try ui.dispatch({}, 1, .{ .close_tab = stores.tabs.items.items[0].id });
    var host: @import("../agent_hook_host.zig").Host = .{};
    defer host.deinit();
    try host.reconcile({}, &ui);
    try std.testing.expectEqual(@as(usize, 0), stores.tabs.items.items.len);
    try std.testing.expectEqual(@as(usize, 0), ui.effects.pendingPtyCount());
    try std.testing.expect(host.server == null);
}

test "child startup cannot rebind the parent while an explicit clear starts a new conversation" {
    var state: State = .{};
    state.receive(event(.session_start, 1), true, 0);
    state.receive(event(.prompt, 2), true, 0);
    var child = try events.normalize(a, "{\"hook_event_name\":\"SessionStart\",\"session_id\":\"child\",\"source\":\"startup\"}", false);
    child.sequence = 3;
    state.receive(child, true, 0);
    try std.testing.expectEqualStrings("parent", state.session.slice());
    try std.testing.expectEqual(.thinking, state.status);
    var clear = try events.normalize(a, "{\"hook_event_name\":\"SessionStart\",\"session_id\":\"new-conversation\",\"source\":\"clear\"}", false);
    clear.sequence = 4;
    state.receive(clear, true, 0);
    try std.testing.expectEqualStrings("new-conversation", state.session.slice());
    try std.testing.expectEqual(.idle, state.status);
}

test "receiver backpressure returns 503 and reports a tracking gap" {
    var fx = support.sdk.Effects(TestMsg).init(a);
    defer fx.deinit();
    fx.executor = .fake;
    const channel = fx.openChannel(.{ .key = 1, .on_event = @TypeOf(fx).channelMsg(.hook), .max_pending = 1 });
    const server = try Server.create(channel);
    defer server.destroy();
    const token = try server.register(1);
    const body = "{\"hook_event_name\":\"Stop\",\"session_id\":\"one\"}";
    try std.testing.expectEqual(@as(u16, 200), try post(server.port, 1, &token, body));
    try std.testing.expectEqual(@as(u16, 503), try post(server.port, 1, &token, body));
    const message = fx.takeMsg() orelse return error.MissingEvent;
    try std.testing.expect(message.hook.dropped_pending > 0);
    var state: State = .{};
    state.receive(try events.decode(a, message.hook.bytes), true, message.hook.dropped_pending);
    try std.testing.expectEqualStrings("Tracking gap", state.label());
}

test "oversized HTTP bodies are rejected from the header before reading payload" {
    var fx = support.sdk.Effects(TestMsg).init(a);
    defer fx.deinit();
    fx.executor = .fake;
    const server = try Server.create(fx.openChannel(.{ .key = 1, .on_event = @TypeOf(fx).channelMsg(.hook) }));
    defer server.destroy();
    const fd = try connect(server.port);
    defer _ = c.close(fd);
    const headers = "POST /session/1/hook HTTP/1.1\r\nContent-Length: 1048577\r\n\r\n";
    try std.testing.expectEqual(@as(isize, headers.len), c.send(fd, headers.ptr, headers.len, 0));
    var buffer: [256]u8 = undefined;
    const count = c.recv(fd, &buffer, buffer.len, 0);
    try std.testing.expect(count >= 12);
    try std.testing.expectEqualStrings("413", buffer[9..12]);
    try std.testing.expect(fx.takeMsg() == null);
}

test "maximum normalized event fits SDK channel and closed tabs ignore delayed packets" {
    var packet: events.Event = .{ .tab = 1, .sequence = 1, .kind = .permission };
    const worst = [_]u8{'"'} ** 1024;
    events.text(&packet.session, &worst);
    events.text(&packet.tool, &worst);
    events.text(&packet.detail, &worst);
    events.text(&packet.model, &worst);
    events.text(&packet.agent_id, &worst);
    var buffer: [support.sdk.max_effect_channel_bytes]u8 = undefined;
    const bytes = try events.encode(&packet, &buffer);
    const stores = try support.Stores.init();
    defer stores.deinit();
    var model = app.initialModel(stores.tabs, stores.projects, stores.profiles);
    defer model.terminal_state.deinit(a);
    try stores.tabs.items.append(a, .{ .id = 1, .pty = 10, .tool = .codex, .phase = .exited, .agent = .{ .registered = true, .status = .ended } });
    try stores.tabs.items.append(a, .{ .id = 2, .pty = 11, .tool = .codex, .agent = .{ .registered = true } });
    var fx = app.Effects.init(a);
    defer fx.deinit();
    fx.executor = .fake;
    app.update(&model, .{ .agent_hook_event = .{ .key = 1, .bytes = bytes } }, &fx);
    try std.testing.expectEqual(.ended, stores.tabs.items.items[0].agent.status);
    try std.testing.expectEqual(.starting, stores.tabs.items.items[1].agent.status);
}

test "footer groups hug both edges stay centered and never overlap at responsive widths" {
    const stores = try support.Stores.init();
    defer stores.deinit();
    var model = app.initialModel(stores.tabs, stores.projects, stores.profiles);
    defer model.terminal_state.deinit(a);
    model.use_ghostty = true;
    model.active_workspace_id = stores.projects.attachPlaceholder("/tmp/agent-layout").?.workspace_id;
    const workspace = stores.projects.findWorktree(model.active_workspace_id).?;
    _ = workspace.branch.set("codex/a-very-long-branch-name-that-must-not-push-the-status-or-operation-control-outside-the-window");
    _ = workspace.path.set("/Users/developer/GIT/a-very-long-project-name/worktrees/a-long-worktree-directory-to-check-that-the-right-group-truncates-cleanly");
    try stores.tabs.items.append(a, .{ .id = 1, .pty = 1, .workspace_id = model.active_workspace_id, .tool = .claude, .phase = .running });
    model.setActiveTab(model.active_workspace_id, 1);
    const agent = &stores.tabs.items.items[0].agent;
    events.text(&agent.model, "claude-a-very-long-model-name-that-needs-truncation");
    events.text(&agent.tool, "mcp__provider__a-very-long-tool-name");
    agent.tool_count = 999;
    agent.context_percent = 100;
    agent.cost_usd = 1234.5678;
    const Status = @import("../agent_state.zig").Status;
    const canvas = support.sdk.canvas;
    const footer_id = canvas.globalWidgetId(.row, .{ .str = "status-footer" });
    const left_id = canvas.globalWidgetId(.row, .{ .str = "footer-agent" });
    const right_id = canvas.globalWidgetId(.row, .{ .str = "footer-worktree" });
    for ([_]u32{ 480, 720, 860, 1100, 1180, 1400, 1800, 2560 }) |width| for ([_]Status{ .starting, .idle, .tool, .permission, .failed, .ended }) |status| {
        model.canvas_width = @floatFromInt(width);
        agent.status = status;
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        var ui = canvas.Ui(app.Msg).init(arena.allocator());
        const tree = try ui.finalize(app.CompiledCanopyView.build(&ui, &model));
        const nodes = try arena.allocator().alloc(canvas.WidgetLayoutNode, 2048);
        const layout = try canvas.layoutWidgetTree(tree.root, support.sdk.geometry.RectF.init(0, 0, @floatFromInt(width), 760), nodes);
        var left: ?support.sdk.geometry.RectF = null;
        var right: ?support.sdk.geometry.RectF = null;
        var previous_left_end: ?f32 = null;
        var previous_right_end: ?f32 = null;
        for (layout.nodes) |node| {
            if (node.widget.id == left_id) left = node.frame;
            if (node.widget.id == right_id) right = node.frame;
            if (node.widget.id == @import("../canvas_host.zig").terminal_viewport_id) try std.testing.expect(node.frame.y <= 79);
            if (node.widget.kind == .tooltip) continue;
            if (node.parent_index) |parent_index| {
                const parent_id = layout.nodes[parent_index].widget.id;
                if (parent_id == left_id) {
                    if (previous_left_end) |end| try std.testing.expectApproxEqAbs(end + 8, node.frame.x, 0.01);
                    previous_left_end = node.frame.x + node.frame.width;
                }
                if (parent_id == right_id) {
                    if (previous_right_end) |end| try std.testing.expectApproxEqAbs(end + 12, node.frame.x, 0.01);
                    previous_right_end = node.frame.x + node.frame.width;
                }
            }
            var parent = node.parent_index;
            while (parent) |index| : (parent = layout.nodes[index].parent_index) {
                if (layout.nodes[index].widget.id != footer_id) continue;
                try std.testing.expect(std.math.isFinite(node.frame.x) and std.math.isFinite(node.frame.width));
                try std.testing.expect(node.frame.x >= 0 and node.frame.x + node.frame.width <= @as(f32, @floatFromInt(width)) + 0.01);
                // Text, icons, separators and controls share one optical center.
                if (node.frame.height > 0) try std.testing.expectApproxEqAbs(@as(f32, 744), node.frame.y + node.frame.height / 2, 0.5);
                break;
            }
        }
        try std.testing.expect(left != null and right != null);
        try std.testing.expectApproxEqAbs(@as(f32, 12), left.?.x, 0.01);
        try std.testing.expectApproxEqAbs(@as(f32, @floatFromInt(width)) - 12, right.?.x + right.?.width, 0.01);
        try std.testing.expect(left.?.x + left.?.width + 24 <= right.?.x + 0.01);
    };
}

test "shared channel loss marks all live sessions even when the delivered packet is stale" {
    const stores = try support.Stores.init();
    defer stores.deinit();
    var model = app.initialModel(stores.tabs, stores.projects, stores.profiles);
    defer model.terminal_state.deinit(a);
    for (1..4) |id| try stores.tabs.items.append(a, .{ .id = id, .pty = id, .tool = .codex, .phase = if (id == 3) .exited else .running, .agent = .{ .registered = true } });
    var fx = app.Effects.init(a);
    defer fx.deinit();
    fx.executor = .fake;
    app.update(&model, .{ .agent_hook_event = .{ .key = 1, .bytes = "{}", .dropped_pending = 2 } }, &fx);
    try std.testing.expectEqual(@as(u64, 2), stores.tabs.items.items[0].agent.lost_events);
    try std.testing.expectEqual(@as(u64, 2), stores.tabs.items.items[1].agent.lost_events);
    try std.testing.expectEqual(@as(u64, 0), stores.tabs.items.items[2].agent.lost_events);
}
