//! Loopback-only HTTP receiver. One poll thread; bounded clients, bodies and deadlines.
const std = @import("std");
const sdk = @import("native_sdk");
const events = @import("agent_events.zig");
pub const c = @cImport({
    @cInclude("sys/socket.h");
    @cInclude("netinet/in.h");
    @cInclude("arpa/inet.h");
    @cInclude("poll.h");
    @cInclude("fcntl.h");
    @cInclude("unistd.h");
    @cInclude("pthread.h");
    @cInclude("stdlib.h");
    @cInclude("time.h");
    @cInclude("errno.h");
});
const allocator = std.heap.page_allocator;
pub const max_body = 1024 * 1024;
const max_headers = 8192;
const max_clients = 8;
pub const Token = [64]u8;
const Client = struct { fd: c_int = -1, bytes: []u8 = &.{}, used: usize = 0, deadline: i64 = 0 };

pub const Server = struct {
    fd: c_int,
    wake: [2]c_int,
    port: u16,
    channel: sdk.ChannelHandle,
    thread: ?std.Thread = null,
    stopping: std.atomic.Value(bool) = .init(false),
    failed: std.atomic.Value(bool) = .init(false),
    mutex: c.pthread_mutex_t = undefined,
    sessions: std.AutoHashMapUnmanaged(u64, Token) = .empty,
    sequence: u64 = 0,
    last_membership: ?u64 = null,

    pub fn create(channel: sdk.ChannelHandle) !*Server {
        const self = try allocator.create(Server);
        errdefer allocator.destroy(self);
        const fd = c.socket(c.AF_INET, c.SOCK_STREAM, 0);
        if (fd < 0) return error.SocketFailed;
        errdefer _ = c.close(fd);
        try nonblocking(fd);
        var address: c.struct_sockaddr_in = std.mem.zeroes(c.struct_sockaddr_in);
        address.sin_len = @sizeOf(c.struct_sockaddr_in);
        address.sin_family = c.AF_INET;
        address.sin_addr.s_addr = c.htonl(0x7f000001);
        if (c.bind(fd, @ptrCast(&address), @sizeOf(c.struct_sockaddr_in)) != 0 or c.listen(fd, 16) != 0) return error.BindFailed;
        var length: c.socklen_t = @sizeOf(c.struct_sockaddr_in);
        if (c.getsockname(fd, @ptrCast(&address), &length) != 0) return error.BindFailed;
        var wake: [2]c_int = undefined;
        if (c.pipe(&wake) != 0) return error.PipeFailed;
        errdefer {
            _ = c.close(wake[0]);
            _ = c.close(wake[1]);
        }
        try nonblocking(wake[0]);
        try nonblocking(wake[1]);
        self.* = .{ .fd = fd, .wake = wake, .port = c.ntohs(address.sin_port), .channel = channel };
        if (c.pthread_mutex_init(&self.mutex, null) != 0) return error.MutexFailed;
        errdefer _ = c.pthread_mutex_destroy(&self.mutex);
        self.thread = try std.Thread.spawn(.{}, run, .{self});
        return self;
    }

    pub fn destroy(self: *Server) void {
        self.stopping.store(true, .release);
        _ = c.write(self.wake[1], "x", 1);
        self.thread.?.join();
        _ = c.close(self.fd);
        _ = c.close(self.wake[0]);
        _ = c.close(self.wake[1]);
        self.sessions.deinit(allocator);
        _ = c.pthread_mutex_destroy(&self.mutex);
        allocator.destroy(self);
    }
    pub fn register(self: *Server, tab: u64) !Token {
        var random: [32]u8 = undefined;
        c.arc4random_buf(&random, random.len);
        const token = std.fmt.bytesToHex(random, .lower);
        _ = c.pthread_mutex_lock(&self.mutex);
        defer _ = c.pthread_mutex_unlock(&self.mutex);
        if (self.sessions.contains(tab)) return error.DuplicateSession;
        try self.sessions.put(allocator, tab, token);
        return token;
    }
    pub fn unregister(self: *Server, tab: u64) void {
        _ = c.pthread_mutex_lock(&self.mutex);
        defer _ = c.pthread_mutex_unlock(&self.mutex);
        _ = self.sessions.remove(tab);
    }
    pub fn registered(self: *Server, tab: u64) bool {
        _ = c.pthread_mutex_lock(&self.mutex);
        defer _ = c.pthread_mutex_unlock(&self.mutex);
        return self.sessions.contains(tab);
    }
    // UI-thread membership reconciliation, independent of event volume.
    pub fn prune(self: *Server, tabs: anytype) void {
        var hash = std.hash.Wyhash.init(0);
        for (tabs) |*tab| if (tab.tool != .shell and tab.phase != .closing and tab.phase != .failed and tab.phase != .exited) {
            hash.update(std.mem.asBytes(&tab.id));
        };
        const signature = hash.final();
        if (self.last_membership == signature) return;
        var alive = std.AutoHashMap(u64, void).init(allocator);
        defer alive.deinit();
        for (tabs) |*tab| if (tab.tool != .shell and tab.phase != .closing and tab.phase != .failed and tab.phase != .exited) {
            alive.put(tab.id, {}) catch return;
        };
        var retired: std.ArrayList(u64) = .empty;
        defer retired.deinit(allocator);
        _ = c.pthread_mutex_lock(&self.mutex);
        defer _ = c.pthread_mutex_unlock(&self.mutex);
        var keys = self.sessions.keyIterator();
        while (keys.next()) |key| if (!alive.contains(key.*)) {
            retired.append(allocator, key.*) catch return;
        };
        for (retired.items) |key| _ = self.sessions.remove(key);
        self.last_membership = signature;
    }

    fn route(self: *Server, path: []const u8, auth: []const u8, body: []const u8) u16 {
        if (!std.mem.startsWith(u8, path, "/session/")) return 404;
        const rest = path[9..];
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return 404;
        const tab = std.fmt.parseInt(u64, rest[0..slash], 10) catch return 404;
        const endpoint = rest[slash + 1 ..];
        if (!std.mem.eql(u8, endpoint, "hook") and !std.mem.eql(u8, endpoint, "status")) return 404;
        _ = c.pthread_mutex_lock(&self.mutex);
        const expected = self.sessions.get(tab);
        _ = c.pthread_mutex_unlock(&self.mutex);
        const token = expected orelse return 404;
        if (auth.len != token.len or !std.crypto.timing_safe.eql(Token, auth[0..64].*, token)) return 403;
        var event = events.normalize(allocator, body, std.mem.eql(u8, endpoint, "status")) catch return 400;
        self.sequence += 1;
        event.tab = tab;
        event.sequence = self.sequence;
        var buffer: [sdk.max_effect_channel_bytes]u8 = undefined;
        const packet = events.encode(&event, &buffer) catch return 413;
        return if (self.channel.post(packet) == .accepted) 200 else 503;
    }

    fn run(self: *Server) void {
        var clients: [max_clients]Client = @splat(.{});
        defer for (&clients) |*client| closeClient(client);
        while (!self.stopping.load(.acquire)) {
            var polls: [max_clients + 2]c.struct_pollfd = undefined;
            polls[0] = .{ .fd = self.fd, .events = c.POLLIN, .revents = 0 };
            polls[1] = .{ .fd = self.wake[0], .events = c.POLLIN, .revents = 0 };
            for (clients, 0..) |client, i| polls[i + 2] = .{ .fd = client.fd, .events = c.POLLIN, .revents = 0 };
            if (c.poll(&polls, polls.len, 100) < 0) {
                if (std.c._errno().* == c.EINTR) continue;
                self.failed.store(true, .release);
                _ = self.channel.post("{}"); // wakes host to expose receiver failure
                return;
            }
            if (self.stopping.load(.acquire)) return;
            const now = milliseconds();
            for (&clients, 0..) |*client, i| {
                if (client.fd < 0) continue;
                if (now >= client.deadline) {
                    respond(client.fd, 408);
                    closeClient(client);
                    continue;
                }
                if (polls[i + 2].revents == 0) continue;
                const count = c.recv(client.fd, client.bytes.ptr + client.used, client.bytes.len - client.used, 0);
                if (count <= 0) {
                    if (count < 0 and (std.c._errno().* == c.EAGAIN or std.c._errno().* == c.EINTR)) continue;
                    closeClient(client);
                    continue;
                }
                client.used += @intCast(count);
                const bytes = client.bytes[0..client.used];
                const end = std.mem.indexOf(u8, bytes, "\r\n\r\n") orelse {
                    if (bytes.len >= max_headers) {
                        respond(client.fd, 431);
                        closeClient(client);
                    }
                    continue;
                };
                if (end > max_headers) {
                    respond(client.fd, 431);
                    closeClient(client);
                    continue;
                }
                const headers = parseHeaders(bytes[0..end]) catch {
                    respond(client.fd, 400);
                    closeClient(client);
                    continue;
                };
                if (headers.length > max_body) {
                    respond(client.fd, 413);
                    closeClient(client);
                    continue;
                }
                if (bytes.len < end + 4 + headers.length) continue;
                const code = self.route(headers.path, headers.auth, bytes[end + 4 ..][0..headers.length]);
                respond(client.fd, code);
                closeClient(client);
            }
            if (polls[0].revents & c.POLLIN != 0) {
                // One accept per iteration: existing connections always get serviced.
                const fd = c.accept(self.fd, null, null);
                if (fd < 0) continue;
                nonblocking(fd) catch {
                    _ = c.close(fd);
                    continue;
                };
                var no_signal: c_int = 1;
                _ = c.setsockopt(fd, c.SOL_SOCKET, c.SO_NOSIGPIPE, &no_signal, @sizeOf(c_int));
                const free = for (&clients) |*client| {
                    if (client.fd < 0) break client;
                } else null;
                if (free) |client| {
                    const bytes = allocator.alloc(u8, max_body + max_headers + 4) catch {
                        respond(fd, 503);
                        _ = c.close(fd);
                        continue;
                    };
                    client.* = .{ .fd = fd, .bytes = bytes, .deadline = now + 2000 };
                } else {
                    respond(fd, 503);
                    _ = c.close(fd);
                }
            }
        }
    }
};

const Headers = struct { path: []const u8, auth: []const u8, length: usize };
pub fn parseHeaders(bytes: []const u8) !Headers {
    var lines = std.mem.splitSequence(u8, bytes, "\r\n");
    const first = lines.next() orelse return error.BadRequest;
    var words = std.mem.splitScalar(u8, first, ' ');
    if (!std.mem.eql(u8, words.next() orelse "", "POST")) return error.BadMethod;
    const path = words.next() orelse return error.BadRequest;
    if (!std.mem.eql(u8, words.next() orelse "", "HTTP/1.1") or words.next() != null) return error.BadRequest;
    var auth: ?[]const u8 = null;
    var length: ?usize = null;
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.BadHeader;
        const name = line[0..colon];
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (std.ascii.eqlIgnoreCase(name, "transfer-encoding")) return error.UnsupportedEncoding;
        if (std.ascii.eqlIgnoreCase(name, "content-length")) {
            if (length != null or value.len == 0) return error.BadLength;
            for (value) |ch| if (!std.ascii.isDigit(ch)) return error.BadLength;
            length = try std.fmt.parseInt(usize, value, 10);
        }
        if (std.ascii.eqlIgnoreCase(name, "x-canopy-auth")) {
            if (auth != null) return error.DuplicateAuth;
            auth = value;
        }
    }
    return .{ .path = path, .auth = auth orelse "", .length = length orelse return error.MissingLength };
}
fn nonblocking(fd: c_int) !void {
    if (c.fcntl(fd, c.F_SETFL, @as(c_int, c.O_NONBLOCK)) < 0 or c.fcntl(fd, c.F_SETFD, @as(c_int, c.FD_CLOEXEC)) < 0) return error.SocketFlags;
}
fn closeClient(client: *Client) void {
    if (client.fd < 0) return;
    _ = c.close(client.fd);
    allocator.free(client.bytes);
    client.* = .{};
}
fn respond(fd: c_int, code: u16) void {
    var buffer: [160]u8 = undefined;
    const bytes = std.fmt.bufPrint(&buffer, "HTTP/1.1 {d} Result\r\nContent-Type: application/json\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{{}}", .{code}) catch return;
    _ = c.send(fd, bytes.ptr, bytes.len, 0);
}
fn milliseconds() i64 {
    var time: c.struct_timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &time);
    return time.tv_sec * 1000 + @divTrunc(time.tv_nsec, 1000000);
}
