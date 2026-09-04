//! Testable command/result boundary. Executor owns threads; controller owns state.

pub fn Service(comptime Executor: type) type {
    return struct {
        executor: Executor = .{},
        const Self = @This();

        pub fn deinit(self: *Self) void {
            self.executor.deinit();
        }

        /// Called after incoming SDK notifications, before native reconciliation.
        pub fn drain(self: *Self, runtime: anytype, ui: anytype) !void {
            if (!ui.model.git.completion_ready) return;
            if (self.executor.completed()) |result| {
                defer self.executor.release();
                try ui.dispatch(runtime, 1, .{ .git_done = result });
            }
        }

        /// Called after ALL native callbacks; they may have admitted the next step.
        pub fn submit(self: *Self, runtime: anytype, ui: anytype) !void {
            while (!self.executor.busy() and ui.model.git.busy()) {
                const operation = &ui.model.git.active;
                const request = operation.request(ui.model.project_store) orelse {
                    try ui.dispatch(runtime, 1, .{ .git_done = .{ .key = operation.key, .value = .{ .failure = .invalid_input } } });
                    continue;
                };
                self.executor.start(&ui.effects, operation.key, request) catch {
                    try ui.dispatch(runtime, 1, .{ .git_done = .{ .key = operation.key, .value = .{ .failure = .internal } } });
                };
            }
        }
    };
}
