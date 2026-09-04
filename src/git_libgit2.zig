//! Blocking, typed local repository adapter. All C handles stay on one worker.
const std = @import("std");
const workflow = @import("git_workflow.zig");
const workspaces = @import("workspaces.zig");
pub const c = @cImport({
    @cInclude("git2.h");
    @cInclude("sys/stat.h");
    @cInclude("errno.h");
});

pub const Response = struct {
    value: workflow.Value = .ok,
    trees: std.ArrayList(workspaces.SnapshotEntry) = .empty,
    pub fn deinit(self: *Response, allocator: std.mem.Allocator) void {
        self.trees.deinit(allocator);
    }
};

fn check(code: c_int) !void {
    if (code >= 0) return;
    if (code == c.GIT_ENOTFOUND) return error.NotFound;
    if (code == c.GIT_ELOCKED) return error.LockedWorktree;
    const last = c.git_error_last();
    if (last != null and last.*.klass == c.GIT_ERROR_OS) {
        if (std.c._errno().* == c.EACCES or std.c._errno().* == c.EPERM) return error.AccessDenied;
        return error.RepositoryIO;
    }
    return error.Libgit2;
}

fn failure(err: anyerror) workflow.Failure {
    return switch (err) {
        error.NotRepository, error.BareRepository => .not_repository,
        error.NotFound => .not_found,
        error.InvalidPath, error.UnrepresentablePath, error.WrongWorktree, error.WrongWorktreePath => .invalid_input,
        error.AccessDenied => .access_denied,
        error.LockedWorktree => .locked,
        error.BranchInUse => .branch_in_use,
        error.UnsafeWorktree, error.ApprovalRequired => .unsafe_worktree,
        error.OutputTooLarge => .too_large,
        error.RepositoryIO, error.RepositoryChanged, error.Libgit2 => .io,
        else => .internal,
    };
}

fn z(allocator: std.mem.Allocator, bytes: []const u8) ![:0]const u8 {
    if (std.mem.indexOfScalar(u8, bytes, 0) != null) return error.InvalidPath;
    return allocator.dupeZ(u8, bytes);
}

fn open(allocator: std.mem.Allocator, path: []const u8) !*c.git_repository {
    var repo: ?*c.git_repository = null;
    const code = c.git_repository_open_ext(&repo, try z(allocator, path), 0, null);
    if (code == c.GIT_ENOTFOUND) return error.NotRepository;
    try check(code);
    return repo.?;
}

fn branch(allocator: std.mem.Allocator, repo: *c.git_repository, name: []const u8) !*c.git_reference {
    var ref: ?*c.git_reference = null;
    try check(c.git_branch_lookup(&ref, repo, try z(allocator, name), c.GIT_BRANCH_LOCAL));
    return ref.?;
}

fn pathText(ptr: [*c]const u8) ![]const u8 {
    if (ptr == null) return error.InvalidPath;
    const text = std.mem.span(ptr);
    if (std.mem.indexOfAny(u8, text, "\r\n") != null) return error.UnrepresentablePath;
    return if (text.len > 1) std.mem.trimEnd(u8, text, "/") else text;
}

fn primary(repo: *c.git_repository) !*c.git_repository {
    var root: ?*c.git_repository = null;
    try check(c.git_repository_open(&root, c.git_repository_commondir(repo)));
    return root.?;
}

fn describe(repo: *c.git_repository, path: []const u8, is_main: bool) !workspaces.SnapshotEntry {
    var entry: workspaces.SnapshotEntry = .{ .is_main = is_main };
    if (!entry.path.set(path) or !entry.name.set(workspaces.pathBasename(path))) return error.OutputTooLarge;
    var head: ?*c.git_reference = null;
    const code = c.git_repository_head(&head, repo);
    if (code == c.GIT_EUNBORNBRANCH) {
        try check(c.git_reference_lookup(&head, repo, "HEAD"));
        defer c.git_reference_free(head);
        const target = std.mem.span(c.git_reference_symbolic_target(head));
        if (!entry.branch.set(target["refs/heads/".len..])) return error.OutputTooLarge;
    } else {
        try check(code);
        defer c.git_reference_free(head);
        if (!entry.branch.set(if (c.git_repository_head_detached(repo) == 1) "(detached)" else std.mem.span(c.git_reference_shorthand(head)))) return error.OutputTooLarge;
    }
    return entry;
}

fn registered(repo: *c.git_repository, path: []const u8) !*c.git_worktree {
    var names: c.git_strarray = .{};
    try check(c.git_worktree_list(&names, repo));
    defer c.git_strarray_dispose(&names);
    for (0..names.count) |index| {
        var tree: ?*c.git_worktree = null;
        try check(c.git_worktree_lookup(&tree, repo, names.strings[index]));
        errdefer c.git_worktree_free(tree);
        if (std.mem.eql(u8, std.mem.trimEnd(u8, path, "/"), try pathText(c.git_worktree_path(tree)))) return tree.?;
        c.git_worktree_free(tree);
    }
    return error.WrongWorktree;
}

fn openTree(temp: std.mem.Allocator, repo: *c.git_repository, tree: *c.git_worktree) !*c.git_repository {
    var linked: ?*c.git_repository = null;
    if (c.git_repository_open_from_worktree(&linked, tree) >= 0) return linked.?;
    const metadata = try std.fmt.allocPrintSentinel(temp, "{s}worktrees/{s}", .{ c.git_repository_commondir(repo), c.git_worktree_name(tree) }, 0);
    try check(c.git_repository_open(&linked, metadata));
    return linked.?;
}

fn status(temp: std.mem.Allocator, repo: *c.git_repository, safety: *workflow.RemovalSafety) !void {
    var options: c.git_status_options = undefined;
    try check(c.git_status_options_init(&options, c.GIT_STATUS_OPTIONS_VERSION));
    options.flags = c.GIT_STATUS_OPT_INCLUDE_UNTRACKED | c.GIT_STATUS_OPT_RECURSE_UNTRACKED_DIRS;
    var list: ?*c.git_status_list = null;
    try check(c.git_status_list_new(&list, repo, &options));
    defer c.git_status_list_free(list);
    const count = c.git_status_list_entrycount(list);
    safety.dirty = count > 0;
    var hash = std.hash.Wyhash.init(0);
    for (0..count) |index| {
        const entry = c.git_status_byindex(list, index).*;
        hash.update(std.mem.asBytes(&entry.status));
        for ([_][*c]c.git_diff_delta{ entry.head_to_index, entry.index_to_workdir }) |delta| {
            if (delta == null) continue;
            const object_id = delta.*.new_file.id;
            hash.update(&object_id.id);
            const path = std.mem.span(delta.*.new_file.path);
            hash.update(path);
            const full = try std.fmt.allocPrintSentinel(temp, "{s}{s}", .{ c.git_repository_workdir(repo), path }, 0);
            var st: c.struct_stat = undefined;
            if (c.lstat(full, &st) == 0) {
                hash.update(std.mem.asBytes(&st.st_size));
                hash.update(std.mem.asBytes(&st.st_mtimespec.tv_sec));
                hash.update(std.mem.asBytes(&st.st_mtimespec.tv_nsec));
            } else if (std.c._errno().* != c.ENOENT) return error.RepositoryIO;
        }
    }
    safety.status_hash = if (count > 0) hash.final() else 0;
}

fn hasSubmodules(temp: std.mem.Allocator, repo: *c.git_repository) !bool {
    const dir = c.git_repository_workdir(repo);
    if (dir == null) return error.BareRepository;
    const path = try std.fmt.allocPrintSentinel(temp, "{s}.gitmodules", .{dir}, 0);
    var config: ?*c.git_config = null;
    const code = c.git_config_open_ondisk(&config, path);
    if (code == c.GIT_ENOTFOUND) return false;
    try check(code);
    defer c.git_config_free(config);
    var iterator: ?*c.git_config_iterator = null;
    try check(c.git_config_iterator_glob_new(&iterator, config, "^submodule\\..*\\.path$"));
    defer c.git_config_iterator_free(iterator);
    var entry: ?*c.git_config_entry = null;
    const next = c.git_config_next(&entry, iterator);
    if (next == c.GIT_ITEROVER) return false;
    try check(next);
    return true;
}

fn inspect(temp: std.mem.Allocator, repo: *c.git_repository, path: []const u8) !workflow.RemovalSafety {
    const tree = try registered(repo, path);
    defer c.git_worktree_free(tree);
    const linked = try openTree(temp, repo, tree);
    defer c.git_repository_free(linked);
    if (c.git_repository_is_worktree(linked) != 1 or
        !std.mem.eql(u8, std.mem.span(c.git_repository_commondir(repo)), std.mem.span(c.git_repository_commondir(linked)))) return error.WrongWorktree;
    var safety: workflow.RemovalSafety = .{};
    var st: c.struct_stat = undefined;
    if (c.lstat(try z(temp, path), &st) != 0) {
        if (std.c._errno().* != c.ENOENT) return error.RepositoryIO;
        safety.missing = true;
    } else if (st.st_mode & c.S_IFMT != c.S_IFDIR) return error.WrongWorktreePath;
    var head: ?*c.git_reference = null;
    try check(c.git_repository_head(&head, linked));
    defer c.git_reference_free(head);
    const oid = c.git_reference_target(head);
    @memcpy(&safety.head, oid.*.id[0..20]);
    safety.detached = c.git_repository_head_detached(linked) == 1;
    if (!safety.branch.set(if (safety.detached) "" else std.mem.span(c.git_reference_shorthand(head)))) return error.OutputTooLarge;
    if (!safety.missing) {
        try status(temp, linked, &safety);
        safety.has_submodules = try hasSubmodules(temp, linked);
    }
    var walk: ?*c.git_revwalk = null;
    try check(c.git_revwalk_new(&walk, linked));
    defer c.git_revwalk_free(walk);
    try check(c.git_revwalk_push(walk, oid));
    try check(c.git_revwalk_hide_glob(walk, if (safety.detached) "refs/*" else "refs/remotes/*"));
    var next: c.git_oid = undefined;
    while (true) {
        const code = c.git_revwalk_next(&next, walk);
        if (code == c.GIT_ITEROVER) break;
        try check(code);
        safety.unmerged_count += 1;
    }
    // A concurrent checkout invalidates the snapshot rather than mixing HEADs.
    var current: c.git_oid = undefined;
    try check(c.git_reference_name_to_id(&current, linked, "HEAD"));
    if (c.git_oid_equal(oid, &current) != 1) return error.RepositoryChanged;
    return safety;
}

pub fn execute(allocator: std.mem.Allocator, request: workflow.Request) Response {
    var response: Response = .{};
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    if (c.git_libgit2_init() < 0) return .{ .value = .{ .failure = .internal } };
    defer _ = c.git_libgit2_shutdown();
    run(allocator, arena.allocator(), request, &response) catch |err| {
        response.value = .{ .failure = failure(err) };
    };
    return response;
}

fn run(allocator: std.mem.Allocator, temp: std.mem.Allocator, request: workflow.Request, out: *Response) !void {
    switch (request) {
        .directory_exists, .target_available => |path| {
            var st: c.struct_stat = undefined;
            const code = if (request == .directory_exists) c.stat(try z(temp, path), &st) else c.lstat(try z(temp, path), &st);
            if (code != 0) {
                if (std.c._errno().* != c.ENOENT and std.c._errno().* != c.ENOTDIR) return error.AccessDenied;
                out.value = .{ .exists = request == .target_available };
            } else out.value = .{ .exists = request == .directory_exists and st.st_mode & c.S_IFMT == c.S_IFDIR };
        },
        .validate_branch => |name| {
            var valid: c_int = 0;
            try check(c.git_branch_name_is_valid(&valid, try z(temp, name)));
            out.value = .{ .exists = valid == 1 };
        },
        .repository_root => |path| {
            const repo = try open(temp, path);
            defer c.git_repository_free(repo);
            const root = try primary(repo);
            defer c.git_repository_free(root);
            if (c.git_repository_is_bare(root) != 0) return error.BareRepository;
            var result: workspaces.PathText = .{};
            if (!result.set(try pathText(c.git_repository_workdir(root)))) return error.OutputTooLarge;
            out.value = .{ .root = result };
        },
        .list_worktrees => |path| {
            const repo = try open(temp, path);
            defer c.git_repository_free(repo);
            const root = try primary(repo);
            defer c.git_repository_free(root);
            try out.trees.append(allocator, try describe(root, try pathText(c.git_repository_workdir(root)), true));
            var names: c.git_strarray = .{};
            try check(c.git_worktree_list(&names, root));
            defer c.git_strarray_dispose(&names);
            if (names.count > 4096) return error.OutputTooLarge;
            for (0..names.count) |index| {
                var tree: ?*c.git_worktree = null;
                try check(c.git_worktree_lookup(&tree, root, names.strings[index]));
                defer c.git_worktree_free(tree);
                const linked = try openTree(temp, root, tree.?);
                defer c.git_repository_free(linked);
                try out.trees.append(allocator, try describe(linked, try pathText(c.git_worktree_path(tree)), false));
            }
            out.value = .{ .worktrees = out.trees.items };
        },
        .branch_exists => |args| {
            const repo = try open(temp, args.repo);
            defer c.git_repository_free(repo);
            var ref: ?*c.git_reference = null;
            const code = c.git_branch_lookup(&ref, repo, try z(temp, args.branch), c.GIT_BRANCH_LOCAL);
            defer c.git_reference_free(ref);
            if (code == c.GIT_ENOTFOUND) {
                out.value = .{ .exists = false };
                return;
            }
            try check(code);
            out.value = .{ .exists = true };
        },
        .create_branch => |args| {
            const repo = try open(temp, args.repo);
            defer c.git_repository_free(repo);
            var head: ?*c.git_object = null;
            try check(c.git_revparse_single(&head, repo, "HEAD^{commit}"));
            defer c.git_object_free(head);
            var ref: ?*c.git_reference = null;
            try check(c.git_branch_create(&ref, repo, try z(temp, args.branch), @ptrCast(head), 0));
            defer c.git_reference_free(ref);
        },
        .create_worktree => |args| {
            const repo = try open(temp, args.repo);
            defer c.git_repository_free(repo);
            const ref = try branch(temp, repo, args.branch);
            defer c.git_reference_free(ref);
            if (c.git_branch_is_checked_out(ref) != 0) return error.BranchInUse;
            var options: c.git_worktree_add_options = undefined;
            try check(c.git_worktree_add_options_init(&options, c.GIT_WORKTREE_ADD_OPTIONS_VERSION));
            options.ref = ref;
            var tree: ?*c.git_worktree = null;
            try check(c.git_worktree_add(&tree, repo, try z(temp, std.fs.path.basename(args.path)), try z(temp, args.path), &options));
            defer c.git_worktree_free(tree);
        },
        .inspect => |args| {
            const repo = try open(temp, args.repo);
            defer c.git_repository_free(repo);
            out.value = .{ .safety = try inspect(temp, repo, args.path) };
        },
        .remove_worktree => |args| {
            const approved = args.approved orelse return error.ApprovalRequired;
            const repo = try open(temp, args.repo);
            defer c.git_repository_free(repo);
            const current = try inspect(temp, repo, args.path);
            if (!current.matches(approved)) {
                out.value = .{ .changed = current };
                return;
            }
            if (!args.force and current.hasWarnings()) return error.UnsafeWorktree;
            const tree = try registered(repo, args.path);
            defer c.git_worktree_free(tree);
            if (!current.missing) try check(c.git_worktree_validate(tree));
            if (c.git_worktree_is_locked(null, tree) != 0) return error.LockedWorktree;
            var options: c.git_worktree_prune_options = undefined;
            try check(c.git_worktree_prune_options_init(&options, c.GIT_WORKTREE_PRUNE_OPTIONS_VERSION));
            options.flags = @intCast(c.GIT_WORKTREE_PRUNE_VALID | (if (current.missing) @as(c_int, 0) else c.GIT_WORKTREE_PRUNE_WORKING_TREE));
            try check(c.git_worktree_prune(tree, &options));
        },
    }
}
