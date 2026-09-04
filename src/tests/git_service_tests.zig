const support = @import("support.zig");
const std = support.std;
const app = support.app;
const workflow = @import("../git_workflow.zig");
const Service = @import("../git_service.zig").Service;

pub const Ui = struct {
    model: app.Model,
    effects: app.Effects,
    pub fn dispatch(self: *@This(), _: void, _: u64, msg: app.Msg) !void {
        app.update(&self.model, msg, &self.effects);
    }
};

const Fake = struct {
    key: ?u64 = null,
    result: ?workflow.Result = null,
    requests: [32]std.meta.Tag(workflow.Request) = undefined,
    count: usize = 0,
    fail_start: bool = false,
    stopped: bool = false,
    pub fn busy(self: *const Fake) bool {
        return self.key != null;
    }
    pub fn start(self: *Fake, _: anytype, key: u64, request: workflow.Request) !void {
        if (self.fail_start) return error.ExecutorUnavailable;
        if (self.busy()) return error.Overlap;
        self.requests[self.count] = std.meta.activeTag(request);
        self.count += 1;
        self.key = key;
    }
    pub fn completed(self: *Fake) ?workflow.Result {
        return self.result;
    }
    pub fn release(self: *Fake) void {
        self.result = null;
        self.key = null;
    }
    pub fn deinit(self: *Fake) void {
        self.release();
        self.stopped = true;
    }
    fn finish(self: *Fake, ui: *Ui, value: workflow.Value) !void {
        self.result = .{ .key = self.key.?, .value = value };
        try ui.dispatch({}, 1, .{ .git_wakeup = .{ .key = self.key.? } });
    }
};

pub fn settle(service: anytype, ui: *Ui) !void {
    for (0..3000) |_| {
        while (ui.effects.takeMsg()) |msg| try ui.dispatch({}, 1, msg);
        try service.drain({}, ui);
        try service.submit({}, ui);
        if (!ui.model.git.busy()) return;
        try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
    }
    return error.GitServiceTimedOut;
}

test "Git service drives full admission notification result and next-step lifecycle" {
    const stores = try support.Stores.init();
    defer stores.deinit();
    var ui: Ui = .{ .model = app.initialModel(stores.tabs, stores.projects, stores.profiles), .effects = app.Effects.init(std.testing.allocator) };
    defer ui.model.terminal_state.deinit(std.testing.allocator);
    defer ui.effects.deinit();
    ui.effects.executor = .fake;
    var service: Service(Fake) = .{};
    defer service.deinit();
    try ui.dispatch({}, 1, .{ .folder_selected = app.PathPayload.from("/tmp/service").? });
    try service.submit({}, &ui);
    try std.testing.expectEqual(.repository_root, service.executor.requests[0]);
    try ui.dispatch({}, 1, .{ .folder_selected = app.PathPayload.from("/tmp/rejected").? });
    try ui.dispatch({}, 1, .{ .git_wakeup = .{ .key = service.executor.key.? + 1 } });
    try service.drain({}, &ui);
    try service.submit({}, &ui);
    try std.testing.expectEqual(@as(usize, 1), service.executor.count);
    var root: support.workspaces.PathText = .{};
    _ = root.set("/tmp/service");
    try service.executor.finish(&ui, .{ .root = root });
    try service.drain({}, &ui);
    try service.submit({}, &ui);
    try std.testing.expectEqual(.list_worktrees, service.executor.requests[1]);
    var entries = try @import("worktree_fixture.zig").decode(std.testing.allocator, "worktree /tmp/service\nbranch refs/heads/main\n\n");
    defer entries.deinit(std.testing.allocator);
    try service.executor.finish(&ui, .{ .worktrees = entries.items });
    try service.drain({}, &ui);
    try service.submit({}, &ui);
    try std.testing.expect(!ui.model.git.busy());
    try std.testing.expectEqual(@as(usize, 1), stores.projects.attachedCount());
    try std.testing.expectEqual(@as(usize, 0), ui.effects.pendingSpawnCount());
    service.deinit();
    try std.testing.expect(service.executor.stopped);
}

test "executor startup failure releases admission and preserves attached folder" {
    const stores = try support.Stores.init();
    defer stores.deinit();
    var ui: Ui = .{ .model = app.initialModel(stores.tabs, stores.projects, stores.profiles), .effects = app.Effects.init(std.testing.allocator) };
    defer ui.effects.deinit();
    defer ui.model.terminal_state.deinit(std.testing.allocator);
    ui.effects.executor = .fake;
    var service: Service(Fake) = .{};
    defer service.deinit();
    service.executor.fail_start = true;
    try ui.dispatch({}, 1, .{ .folder_selected = app.PathPayload.from("/tmp/start-failure").? });
    try service.submit({}, &ui);
    try std.testing.expect(!ui.model.git.busy());
    try std.testing.expectEqual(@as(usize, 1), stores.projects.attachedCount());
}
