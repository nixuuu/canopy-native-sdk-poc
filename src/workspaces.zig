const std = @import("std");

pub const max_path_bytes: usize = 1024;
pub const max_name_bytes: usize = 160;
pub const max_branch_bytes: usize = 256;
pub const max_store_bytes: usize = 256 * 1024;
const store_header = "CANOPY_PROJECTS_V1\n";

pub fn Text(comptime capacity: usize) type {
    return struct {
        bytes: [capacity]u8 = @splat(0),
        len: usize = 0,

        pub fn set(self: *@This(), value: []const u8) bool {
            if (value.len > capacity) return false;
            @memcpy(self.bytes[0..value.len], value);
            self.len = value.len;
            return true;
        }

        pub fn slice(self: *const @This()) []const u8 {
            return self.bytes[0..self.len];
        }

        pub fn eql(self: *const @This(), value: []const u8) bool {
            return std.mem.eql(u8, self.slice(), value);
        }
    };
}

pub const PathText = Text(max_path_bytes);
pub const NameText = Text(max_name_bytes);
pub const BranchText = Text(max_branch_bytes);

pub const Worktree = struct {
    id: u64,
    active: bool = true,
    is_main: bool = false,
    path: PathText = .{},
    name: NameText = .{},
    branch: BranchText = .{},
};

pub const Project = struct {
    id: u64,
    attached: bool = true,
    is_git: bool = false,
    selected_path: PathText = .{},
    repo_root: PathText = .{},
    name: NameText = .{},
    worktrees: std.ArrayListUnmanaged(Worktree) = .empty,

    fn deinit(self: *Project, allocator: std.mem.Allocator) void {
        self.worktrees.deinit(allocator);
        self.worktrees = .empty;
    }

    pub fn key(self: *const Project) []const u8 {
        return if (self.is_git and self.repo_root.len > 0) self.repo_root.slice() else self.selected_path.slice();
    }
};

pub const RowKind = enum { project, worktree };

pub const SidebarRow = struct {
    key: u64,
    kind: RowKind,
    project_id: u64,
    workspace_id: u64 = 0,
    name: []const u8,
    detail: []const u8,
    path: []const u8,
    selected: bool = false,
    is_main: bool = false,
    can_remove: bool = false,
    is_git: bool = false,
};

pub const SnapshotEntry = struct {
    path: PathText = .{},
    name: NameText = .{},
    branch: BranchText = .{},
    is_main: bool = false,
};

pub const Store = struct {
    allocator: std.mem.Allocator,
    projects: std.ArrayListUnmanaged(Project) = .empty,
    next_project_id: u64 = 1,
    next_workspace_id: u64 = 1,
    persist_serial: u64 = 0,
    worktrees_base: PathText = .{},

    pub fn create(allocator: std.mem.Allocator) !*Store {
        const store = try allocator.create(Store);
        store.* = .{ .allocator = allocator };
        return store;
    }

    pub fn destroy(store: *Store) void {
        const allocator = store.allocator;
        for (store.projects.items) |*project| project.deinit(allocator);
        store.projects.deinit(allocator);
        allocator.destroy(store);
    }

    pub fn setWorktreesBase(store: *Store, path: []const u8) bool {
        return store.worktrees_base.set(path);
    }

    pub fn attachedCount(store: *const Store) usize {
        var count: usize = 0;
        for (store.projects.items) |project| if (project.attached) {
            count += 1;
        };
        return count;
    }

    pub fn hasProjects(store: *const Store) bool {
        return store.attachedCount() > 0;
    }

    pub fn findProject(store: *Store, id: u64) ?*Project {
        for (store.projects.items) |*project| {
            if (project.id == id) return project;
        }
        return null;
    }

    pub fn findAttachedByKey(store: *Store, path: []const u8) ?*Project {
        for (store.projects.items) |*project| {
            if (project.attached and std.mem.eql(u8, project.key(), path)) return project;
        }
        return null;
    }

    pub fn findAttachedBySelectedPath(store: *Store, path: []const u8) ?*Project {
        for (store.projects.items) |*project| {
            if (project.attached and project.selected_path.eql(path)) return project;
        }
        return null;
    }

    pub fn findWorktree(store: *Store, id: u64) ?*Worktree {
        for (store.projects.items) |*project| {
            for (project.worktrees.items) |*worktree| {
                if (worktree.id == id) return worktree;
            }
        }
        return null;
    }

    pub fn projectForWorkspace(store: *Store, workspace_id: u64) ?*Project {
        for (store.projects.items) |*project| {
            for (project.worktrees.items) |worktree| {
                if (worktree.id == workspace_id) return project;
            }
        }
        return null;
    }

    pub fn workspaceAvailable(store: *Store, workspace_id: u64) bool {
        for (store.projects.items) |*project| {
            if (!project.attached) continue;
            for (project.worktrees.items) |worktree| {
                if (worktree.id == workspace_id) return worktree.active;
            }
        }
        return false;
    }

    pub fn attachPlaceholder(store: *Store, path: []const u8) ?struct { project_id: u64, workspace_id: u64 } {
        if (!std.fs.path.isAbsolute(path) or path.len == 0 or path.len > max_path_bytes) return null;
        for (store.projects.items) |*existing| {
            if (!existing.selected_path.eql(path)) continue;
            if (!existing.attached) {
                existing.attached = true;
                store.persist_serial +%= 1;
            }
            const workspace_id = for (existing.worktrees.items) |worktree| {
                if (worktree.active) break worktree.id;
            } else 0;
            return .{ .project_id = existing.id, .workspace_id = workspace_id };
        }

        var project = Project{ .id = store.next_project_id };
        store.next_project_id +%= 1;
        if (!project.selected_path.set(path)) return null;
        _ = project.name.set(pathBasename(path));

        var workspace = Worktree{ .id = store.next_workspace_id, .is_main = true };
        store.next_workspace_id +%= 1;
        _ = workspace.path.set(path);
        _ = workspace.name.set(pathBasename(path));
        _ = workspace.branch.set("folder");
        project.worktrees.append(store.allocator, workspace) catch return null;
        store.projects.append(store.allocator, project) catch {
            project.deinit(store.allocator);
            return null;
        };
        store.persist_serial +%= 1;
        return .{ .project_id = project.id, .workspace_id = workspace.id };
    }

    pub fn markGit(store: *Store, project_id: u64, repo_root: []const u8) bool {
        const project = store.findProject(project_id) orelse return false;
        if (!std.fs.path.isAbsolute(repo_root) or repo_root.len > max_path_bytes) return false;
        project.is_git = true;
        if (!project.repo_root.set(repo_root)) return false;
        _ = project.name.set(pathBasename(repo_root));
        store.persist_serial +%= 1;
        return true;
    }

    pub fn applySnapshot(store: *Store, project_id: u64, entries: []const SnapshotEntry) !void {
        const project = store.findProject(project_id) orelse return error.MissingProject;
        if (entries.len == 0 or !entries[0].is_main) return error.InvalidSnapshot;
        var incoming = std.StringHashMap(void).init(store.allocator);
        defer incoming.deinit();
        var existing = std.StringHashMap(usize).init(store.allocator);
        defer existing.deinit();
        for (project.worktrees.items, 0..) |*tree, index| try existing.put(tree.path.slice(), index);
        var additions: usize = 0;
        for (entries, 0..) |*entry, index| {
            if (!std.fs.path.isAbsolute(entry.path.slice()) or entry.name.len == 0 or (index > 0 and entry.is_main)) return error.InvalidSnapshot;
            if ((try incoming.getOrPut(entry.path.slice())).found_existing) return error.DuplicateWorktree;
            if (!existing.contains(entry.path.slice())) additions += 1;
        }
        // Reserve before changing membership; reallocation invalidates path keys.
        try project.worktrees.ensureUnusedCapacity(store.allocator, additions);
        existing.clearRetainingCapacity();
        for (project.worktrees.items, 0..) |*tree, index| try existing.put(tree.path.slice(), index);
        for (project.worktrees.items) |*tree| tree.active = false;
        for (entries) |entry| {
            if (existing.get(entry.path.slice())) |index| {
                const tree = &project.worktrees.items[index];
                tree.active = true;
                tree.is_main = entry.is_main;
                tree.name = entry.name;
                tree.branch = entry.branch;
            } else {
                project.worktrees.appendAssumeCapacity(.{ .id = store.next_workspace_id, .path = entry.path, .name = entry.name, .branch = entry.branch, .is_main = entry.is_main });
                store.next_workspace_id += 1;
            }
        }
    }

    /// Retire inactive metadata only after all terminal owners have gone.
    pub fn collectUnused(store: *Store, terminals: anytype) void {
        var p = store.projects.items.len;
        while (p > 0) {
            p -= 1;
            const project = &store.projects.items[p];
            var owned = false;
            var w = project.worktrees.items.len;
            while (w > 0) {
                w -= 1;
                const tree = &project.worktrees.items[w];
                if (terminals.hasWorkspace(tree.id)) {
                    owned = true;
                    continue;
                }
                if (!tree.active) _ = project.worktrees.orderedRemove(w);
            }
            if (!project.attached and !owned) {
                var removed = store.projects.orderedRemove(p);
                removed.deinit(store.allocator);
            }
        }
    }

    pub fn detach(store: *Store, project_id: u64) bool {
        const project = store.findProject(project_id) orelse return false;
        if (!project.attached) return false;
        project.attached = false;
        store.persist_serial +%= 1;
        return true;
    }

    pub fn serializeAttached(store: *const Store, out: []u8) ?[]const u8 {
        if (out.len < store_header.len) return null;
        @memcpy(out[0..store_header.len], store_header);
        var used = store_header.len;
        for (store.projects.items) |*project| {
            if (!project.attached) continue;
            const path = project.selected_path.slice();
            const prefix = std.fmt.bufPrint(out[used..], "{d}:", .{path.len}) catch return null;
            used += prefix.len;
            if (out.len - used < path.len + 1) return null;
            @memcpy(out[used .. used + path.len], path);
            used += path.len;
            out[used] = '\n';
            used += 1;
        }
        return out[0..used];
    }

    pub fn restoreAttached(store: *Store, bytes: []const u8) usize {
        if (!std.mem.startsWith(u8, bytes, store_header)) return 0;
        var cursor = store_header.len;
        var restored: usize = 0;
        while (cursor < bytes.len) {
            const colon_offset = std.mem.indexOfScalar(u8, bytes[cursor..], ':') orelse break;
            const colon = cursor + colon_offset;
            const path_len = std.fmt.parseInt(usize, bytes[cursor..colon], 10) catch break;
            const path_start = colon + 1;
            if (path_len == 0 or path_len > max_path_bytes or path_start > bytes.len or path_len > bytes.len - path_start) break;
            const path_end = path_start + path_len;
            if (path_end >= bytes.len or bytes[path_end] != '\n') break;
            if (store.attachPlaceholder(bytes[path_start..path_end]) != null) restored += 1;
            cursor = path_end + 1;
        }
        return restored;
    }

    pub fn removeWorktree(store: *Store, workspace_id: u64) bool {
        const worktree = store.findWorktree(workspace_id) orelse return false;
        if (worktree.is_main or !worktree.active) return false;
        worktree.active = false;
        return true;
    }

    pub fn sidebarRows(store: *const Store, arena: std.mem.Allocator, active_workspace_id: u64) []const SidebarRow {
        var count: usize = 0;
        for (store.projects.items) |project| {
            if (!project.attached) continue;
            count += 1;
            for (project.worktrees.items) |worktree| if (worktree.active) {
                count += 1;
            };
        }
        const rows = arena.alloc(SidebarRow, count) catch return &.{};
        var index: usize = 0;
        for (store.projects.items) |*project| {
            if (!project.attached) continue;
            rows[index] = .{
                .key = project.id << 1,
                .kind = .project,
                .project_id = project.id,
                .name = project.name.slice(),
                .detail = if (project.is_git) "Git repository" else "Folder",
                .path = project.key(),
                .is_git = project.is_git,
            };
            index += 1;
            for (project.worktrees.items) |*worktree| {
                if (!worktree.active) continue;
                rows[index] = .{
                    .key = (worktree.id << 1) | 1,
                    .kind = .worktree,
                    .project_id = project.id,
                    .workspace_id = worktree.id,
                    .name = worktree.name.slice(),
                    .detail = worktree.branch.slice(),
                    .path = worktree.path.slice(),
                    .selected = worktree.id == active_workspace_id,
                    .is_main = worktree.is_main,
                    .can_remove = project.is_git and !worktree.is_main,
                    .is_git = project.is_git,
                };
                index += 1;
            }
        }
        return rows[0..index];
    }

    pub fn firstWorkspaceId(store: *const Store) u64 {
        for (store.projects.items) |project| {
            if (!project.attached) continue;
            for (project.worktrees.items) |worktree| {
                if (worktree.active) return worktree.id;
            }
        }
        return 0;
    }

    pub fn makeWorktreePath(store: *const Store, project: *const Project, branch: []const u8, serial: u64, out: []u8) ?[]const u8 {
        if (store.worktrees_base.len == 0) return null;
        var slug_storage: [max_name_bytes]u8 = undefined;
        var slug_len: usize = 0;
        for (branch) |ch| {
            if (slug_len == slug_storage.len) break;
            const normalized: u8 = if (std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_') ch else '-';
            if (normalized == '-' and slug_len > 0 and slug_storage[slug_len - 1] == '-') continue;
            slug_storage[slug_len] = normalized;
            slug_len += 1;
        }
        if (slug_len == 0) return null;
        return std.fmt.bufPrint(out, "{s}/{s}-{s}-{d}", .{ store.worktrees_base.slice(), project.name.slice(), slug_storage[0..slug_len], serial }) catch null;
    }
};

pub fn pathBasename(path: []const u8) []const u8 {
    const trimmed = std.mem.trimEnd(u8, path, "/\\");
    if (trimmed.len == 0) return path;
    return std.fs.path.basename(trimmed);
}

test "worktree porcelain creates main and linked worktrees" {
    const store = try Store.create(std.testing.allocator);
    defer store.destroy();
    const attached = store.attachPlaceholder("/tmp/repo").?;
    try std.testing.expect(store.markGit(attached.project_id, "/tmp/repo"));
    try std.testing.expect(@import("tests/worktree_fixture.zig").apply(store, attached.project_id,
        \\worktree /tmp/repo
        \\HEAD 1111111
        \\branch refs/heads/main
        \\
        \\worktree /tmp/repo-feature
        \\HEAD 2222222
        \\branch refs/heads/feature/test
        \\
    ));
    const project = store.findProject(attached.project_id).?;
    try std.testing.expectEqual(@as(usize, 2), project.worktrees.items.len);
    try std.testing.expect(project.worktrees.items[0].is_main);
    try std.testing.expectEqualStrings("feature/test", project.worktrees.items[1].branch.slice());
}

test "invalid worktree porcelain leaves the previous snapshot unchanged" {
    const store = try Store.create(std.testing.allocator);
    defer store.destroy();
    const attached = store.attachPlaceholder("/tmp/repo").?;
    try std.testing.expect(store.markGit(attached.project_id, "/tmp/repo"));
    try std.testing.expect(@import("tests/worktree_fixture.zig").apply(store, attached.project_id,
        \\worktree /tmp/repo
        \\HEAD 1111111
        \\branch refs/heads/main
        \\
    ));
    const project = store.findProject(attached.project_id).?;
    const next_workspace_id = store.next_workspace_id;

    try std.testing.expect(!@import("tests/worktree_fixture.zig").apply(store, attached.project_id,
        \\worktree relative/path
        \\branch refs/heads/broken
        \\
    ));
    try std.testing.expectEqual(@as(usize, 1), project.worktrees.items.len);
    try std.testing.expect(project.worktrees.items[0].active);
    try std.testing.expectEqualStrings("main", project.worktrees.items[0].branch.slice());
    try std.testing.expectEqual(next_workspace_id, store.next_workspace_id);
}

test "attached project persistence round-trips arbitrary path bytes" {
    const source = try Store.create(std.testing.allocator);
    defer source.destroy();
    _ = source.attachPlaceholder("/tmp/project with spaces").?;
    _ = source.attachPlaceholder("/tmp/project\nwith-newline").?;
    var buffer: [max_store_bytes]u8 = undefined;
    const encoded = source.serializeAttached(&buffer).?;

    const restored = try Store.create(std.testing.allocator);
    defer restored.destroy();
    try std.testing.expectEqual(@as(usize, 2), restored.restoreAttached(encoded));
    try std.testing.expect(restored.findAttachedBySelectedPath("/tmp/project with spaces") != null);
    try std.testing.expect(restored.findAttachedBySelectedPath("/tmp/project\nwith-newline") != null);
}
