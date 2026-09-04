//! Owns the one Git worker and its memory; domain state never crosses threads.
const std = @import("std");
const sdk = @import("native_sdk");
const workflow = @import("git_workflow.zig");
const backend = @import("git_libgit2.zig");

const Job = struct {
    arena: std.heap.ArenaAllocator,
    request: workflow.Request,
    key: u64,
    channel: sdk.ChannelHandle,
    response: backend.Response = .{},
    ready: std.atomic.Value(bool) = .init(false),

    fn run(job: *Job) void {
        job.response = backend.execute(std.heap.page_allocator, job.request);
        job.ready.store(true, .release);
        // A dedicated, empty channel receives exactly one bounded notification.
        // The host joins before freeing the response or starting the next job.
        _ = job.channel.post("");
    }

    fn destroy(job: *Job) void {
        job.response.deinit(std.heap.page_allocator);
        job.arena.deinit();
        std.heap.page_allocator.destroy(job);
    }
};

fn copy(comptime T: type, allocator: std.mem.Allocator, value: T) !T {
    if (T == []const u8) return allocator.dupe(u8, value);
    switch (@typeInfo(T)) {
        .@"struct" => |info| {
            var result: T = undefined;
            inline for (info.fields) |field| @field(result, field.name) = try copy(field.type, allocator, @field(value, field.name));
            return result;
        },
        .@"union" => {
            switch (value) {
                inline else => |payload, tag| return @unionInit(T, @tagName(tag), try copy(@TypeOf(payload), allocator, payload)),
            }
        },
        else => return value,
    }
}

pub const Host = struct {
    job: ?*Job = null,
    thread: ?std.Thread = null,
    channel_key: ?u64 = null,

    pub fn start(host: *Host, fx: anytype, key: u64, request: workflow.Request) !void {
        if (host.job != null) return error.GitBusy;
        const job = try std.heap.page_allocator.create(Job);
        job.* = .{ .arena = std.heap.ArenaAllocator.init(std.heap.page_allocator), .request = undefined, .key = key, .channel = undefined };
        errdefer job.destroy();
        job.request = try copy(workflow.Request, job.arena.allocator(), request);
        if (host.channel_key) |old| fx.closeChannel(old);
        host.channel_key = null;
        const Effects = @TypeOf(fx.*);
        job.channel = fx.openChannel(.{ .key = key, .on_event = Effects.channelMsg(.git_wakeup), .max_pending = 1 });
        if (!job.channel.live()) return error.GitChannelUnavailable;
        host.channel_key = key;
        errdefer {
            fx.closeChannel(key);
            host.channel_key = null;
        }
        host.thread = try std.Thread.spawn(.{}, Job.run, .{job});
        host.job = job;
    }

    pub fn completed(host: *Host) ?workflow.Result {
        if (host.thread == null) return null;
        const job = host.job orelse return null;
        if (!job.ready.load(.acquire)) return null;
        host.thread.?.join();
        host.thread = null;
        return .{ .key = job.key, .outcome = job.response.outcome, .output = job.response.output.items };
    }

    pub fn release(host: *Host) void {
        std.debug.assert(host.thread == null);
        if (host.job) |job| job.destroy();
        host.job = null;
    }

    pub fn deinit(host: *Host) void {
        // Mutations cannot be cancelled halfway through checkout/prune. Wait for
        // the owned operation before tearing down the effects channel or stores.
        if (host.thread) |thread| thread.join();
        host.thread = null;
        host.release();
    }
};
