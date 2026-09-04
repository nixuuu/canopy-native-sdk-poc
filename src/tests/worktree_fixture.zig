//! Legacy porcelain fixtures for tests only. Production consumes typed snapshots.
const std = @import("std");
const workspaces = @import("../workspaces.zig");
fn parse(path: []const u8, branch: []const u8, is_main: bool) ?workspaces.SnapshotEntry {
    if (!std.fs.path.isAbsolute(path)) return null;
    var parsed = workspaces.SnapshotEntry{ .is_main = is_main };
    if (!parsed.path.set(path) or !parsed.name.set(workspaces.pathBasename(path)) or !parsed.branch.set(branch)) return null;
    return parsed;
}

pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !std.ArrayListUnmanaged(workspaces.SnapshotEntry) {
    var parsed: std.ArrayListUnmanaged(workspaces.SnapshotEntry) = .empty;
    errdefer parsed.deinit(allocator);

    var current_path: []const u8 = "";
    var current_branch: []const u8 = "(unknown)";
    var detached = false;
    var ordinal: usize = 0;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trimEnd(u8, raw_line, "\r");
        if (std.mem.startsWith(u8, line, "worktree ")) {
            if (current_path.len > 0) {
                const entry = parse(current_path, if (detached) "(detached)" else current_branch, ordinal == 0) orelse return error.InvalidFixture;
                try parsed.append(allocator, entry);
                ordinal += 1;
            }
            current_path = line["worktree ".len..];
            current_branch = "(unknown)";
            detached = false;
        } else if (std.mem.startsWith(u8, line, "branch refs/heads/")) {
            current_branch = line["branch refs/heads/".len..];
        } else if (std.mem.eql(u8, line, "detached")) {
            detached = true;
        } else if (line.len == 0 and current_path.len > 0) {
            const entry = parse(current_path, if (detached) "(detached)" else current_branch, ordinal == 0) orelse return error.InvalidFixture;
            try parsed.append(allocator, entry);
            ordinal += 1;
            current_path = "";
            current_branch = "(unknown)";
            detached = false;
        }
    }
    if (current_path.len > 0) {
        const entry = parse(current_path, if (detached) "(detached)" else current_branch, ordinal == 0) orelse return error.InvalidFixture;
        try parsed.append(allocator, entry);
    }

    return parsed;
}

pub fn apply(store: *workspaces.Store, project_id: u64, bytes: []const u8) bool {
    var parsed = decode(store.allocator, bytes) catch return false;
    defer parsed.deinit(store.allocator);
    store.applySnapshot(project_id, parsed.items) catch return false;
    return true;
}
