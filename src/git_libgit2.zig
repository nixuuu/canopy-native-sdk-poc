//! Blocking local repository adapter. Called only on the Git worker, never UI.
const std = @import("std");
const workflow = @import("git_workflow.zig");
pub const c = @cImport({
    @cInclude("git2.h");
    @cInclude("sys/stat.h");
    @cInclude("errno.h");
});

pub const Response = struct {
    outcome: workflow.Outcome = .success,
    output: std.ArrayList(u8) = .empty,

    pub fn deinit(self: *Response, allocator: std.mem.Allocator) void {
        self.output.deinit(allocator);
    }

    fn append(self: *Response, allocator: std.mem.Allocator, bytes: []const u8) !void {
        if (self.output.items.len + bytes.len > 256 * 1024) return error.OutputTooLarge;
        try self.output.appendSlice(allocator, bytes);
    }
};

fn check(code: c_int) !void {
    if (code < 0) return error.Libgit2;
}

fn z(allocator: std.mem.Allocator, bytes: []const u8) ![:0]const u8 {
    if (std.mem.indexOfScalar(u8, bytes, 0) != null) return error.InvalidPath;
    return allocator.dupeZ(u8, bytes);
}

fn open(allocator: std.mem.Allocator, path: []const u8) !*c.git_repository {
    var repo: ?*c.git_repository = null;
    try check(c.git_repository_open_ext(&repo, try z(allocator, path), 0, null));
    return repo.?;
}

fn branch(allocator: std.mem.Allocator, repo: *c.git_repository, name: []const u8) !*c.git_reference {
    var ref: ?*c.git_reference = null;
    try check(c.git_branch_lookup(&ref, repo, try z(allocator, name), c.GIT_BRANCH_LOCAL));
    return ref.?;
}

fn pathText(ptr: [*c]const u8) ![]const u8 {
    if (ptr == null) return error.MissingPath;
    const text = std.mem.span(ptr);
    if (std.mem.indexOfAny(u8, text, "\r\n") != null) return error.UnrepresentablePath;
    return std.mem.trimEnd(u8, text, "/");
}

fn primary(repo: *c.git_repository) !*c.git_repository {
    var root: ?*c.git_repository = null;
    try check(c.git_repository_open(&root, c.git_repository_commondir(repo)));
    return root.?;
}

fn describe(out: *Response, allocator: std.mem.Allocator, repo: *c.git_repository, path: []const u8) !void {
    try out.append(allocator, "worktree ");
    try out.append(allocator, path);
    try out.append(allocator, "\n");
    if (c.git_repository_is_bare(repo) != 0) {
        try out.append(allocator, "bare\n\n");
        return;
    }
    var head: ?*c.git_reference = null;
    const code = c.git_repository_head(&head, repo);
    if (code == c.GIT_EUNBORNBRANCH) {
        try check(c.git_reference_lookup(&head, repo, "HEAD"));
        defer c.git_reference_free(head);
        try out.append(allocator, "branch ");
        try out.append(allocator, std.mem.span(c.git_reference_symbolic_target(head)));
    } else {
        try check(code);
        defer c.git_reference_free(head);
        if (c.git_repository_head_detached(repo) == 1) {
            try out.append(allocator, "detached");
        } else {
            try out.append(allocator, "branch ");
            try out.append(allocator, std.mem.span(c.git_reference_name(head)));
        }
    }
    try out.append(allocator, "\n\n");
}

fn dirty(repo: *c.git_repository) !bool {
    var options: c.git_status_options = undefined;
    try check(c.git_status_options_init(&options, c.GIT_STATUS_OPTIONS_VERSION));
    options.flags = c.GIT_STATUS_OPT_INCLUDE_UNTRACKED | c.GIT_STATUS_OPT_RECURSE_UNTRACKED_DIRS;
    var list: ?*c.git_status_list = null;
    try check(c.git_status_list_new(&list, repo, &options));
    defer c.git_status_list_free(list);
    return c.git_status_list_entrycount(list) != 0;
}

fn submodules(allocator: std.mem.Allocator, repo: *c.git_repository) !bool {
    const path = try std.fmt.allocPrintSentinel(allocator, "{s}.gitmodules", .{c.git_repository_workdir(repo)}, 0);
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

pub fn execute(allocator: std.mem.Allocator, request: workflow.Request) Response {
    var response: Response = .{};
    // All transient C strings and paths are scoped to this operation.
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const initialized = c.git_libgit2_init();
    if (initialized < 0) return .{ .outcome = .failure };
    defer _ = c.git_libgit2_shutdown();
    run(allocator, arena.allocator(), request, &response) catch {
        response.output.clearRetainingCapacity();
        response.outcome = .failure;
    };
    return response;
}

fn run(allocator: std.mem.Allocator, temp: std.mem.Allocator, request: workflow.Request, out: *Response) !void {
    switch (request) {
        .directory_exists, .target_available => |path| {
            var stat: c.struct_stat = undefined;
            const code = if (request == .directory_exists) c.stat(try z(temp, path), &stat) else c.lstat(try z(temp, path), &stat);
            if (code != 0) {
                // Permission and I/O failures must never mean an available target.
                const errno = std.c._errno().*;
                if (errno != c.ENOENT and errno != c.ENOTDIR) return error.StatFailed;
                out.outcome = if (request == .directory_exists) .negative else .success;
            } else {
                out.outcome = if (request == .directory_exists and stat.st_mode & c.S_IFMT == c.S_IFDIR) .success else .negative;
            }
        },
        .validate_branch => |name| {
            var valid: c_int = 0;
            try check(c.git_branch_name_is_valid(&valid, try z(temp, name)));
            out.outcome = if (valid == 1) .success else .negative;
        },
        .repository_root => |path| {
            const repo = try open(temp, path);
            defer c.git_repository_free(repo);
            if (c.git_repository_is_bare(repo) != 0) return error.BareRepository;
            const root = try primary(repo);
            defer c.git_repository_free(root);
            try out.append(allocator, try pathText(c.git_repository_workdir(root)));
        },
        .list_worktrees => |path| {
            const repo = try open(temp, path);
            defer c.git_repository_free(repo);
            const root = try primary(repo);
            defer c.git_repository_free(root);
            try describe(out, allocator, root, try pathText(if (c.git_repository_is_bare(root) != 0) c.git_repository_path(root) else c.git_repository_workdir(root)));
            var names: c.git_strarray = .{};
            try check(c.git_worktree_list(&names, root));
            defer c.git_strarray_dispose(&names);
            for (0..names.count) |index| {
                const name = names.strings[index];
                var tree: ?*c.git_worktree = null;
                try check(c.git_worktree_lookup(&tree, root, name));
                defer c.git_worktree_free(tree);
                var linked: ?*c.git_repository = null;
                const code = c.git_repository_open_from_worktree(&linked, tree);
                if (code < 0) {
                    // An externally removed directory still has a registered HEAD.
                    const metadata = try std.fmt.allocPrintSentinel(temp, "{s}worktrees/{s}", .{ c.git_repository_commondir(root), name }, 0);
                    try check(c.git_repository_open(&linked, metadata));
                }
                defer c.git_repository_free(linked);
                try describe(out, allocator, linked.?, try pathText(c.git_worktree_path(tree)));
            }
        },
        .branch_exists => |args| {
            const repo = try open(temp, args.repo);
            defer c.git_repository_free(repo);
            var ref: ?*c.git_reference = null;
            const code = c.git_branch_lookup(&ref, repo, try z(temp, args.branch), c.GIT_BRANCH_LOCAL);
            defer c.git_reference_free(ref);
            if (code == c.GIT_ENOTFOUND) {
                out.outcome = .negative;
                return;
            }
            try check(code);
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
        .status => |path| {
            const repo = try open(temp, path);
            defer c.git_repository_free(repo);
            if (try dirty(repo)) try out.append(allocator, "dirty\n");
        },
        .submodules => |path| {
            const repo = try open(temp, path);
            defer c.git_repository_free(repo);
            if (try submodules(temp, repo)) try out.append(allocator, "submodule\n") else out.outcome = .negative;
        },
        .unmerged => |args| {
            const repo = try open(temp, args.repo);
            defer c.git_repository_free(repo);
            var walk: ?*c.git_revwalk = null;
            try check(c.git_revwalk_new(&walk, repo));
            defer c.git_revwalk_free(walk);
            if (args.detached) {
                try check(c.git_revwalk_push_head(walk));
            } else {
                const ref = try branch(temp, repo, args.branch);
                defer c.git_reference_free(ref);
                try check(c.git_revwalk_push(walk, c.git_reference_target(ref)));
            }
            try check(c.git_revwalk_hide_glob(walk, if (args.detached) "refs/*" else "refs/remotes/*"));
            var oid: c.git_oid = undefined;
            while (true) {
                const code = c.git_revwalk_next(&oid, walk);
                if (code == c.GIT_ITEROVER) break;
                try check(code);
                // Consumers need an exact count, not commit messages or filenames.
                try out.append(allocator, "commit\n");
            }
        },
        .remove_worktree => |args| {
            const repo = try open(temp, args.repo);
            defer c.git_repository_free(repo);
            var initial_stat: c.struct_stat = undefined;
            if (c.lstat(try z(temp, args.path), &initial_stat) != 0) {
                if (std.c._errno().* != c.ENOENT or !args.force) return error.MissingWorktree;
                // Prune only the matching registration, never a directory, when
                // a worktree was already removed outside the application.
                var names: c.git_strarray = .{};
                try check(c.git_worktree_list(&names, repo));
                defer c.git_strarray_dispose(&names);
                for (0..names.count) |index| {
                    const name = names.strings[index];
                    var missing: ?*c.git_worktree = null;
                    try check(c.git_worktree_lookup(&missing, repo, name));
                    defer c.git_worktree_free(missing);
                    if (!std.mem.eql(u8, std.mem.trimEnd(u8, args.path, "/"), try pathText(c.git_worktree_path(missing)))) continue;
                    if (c.git_worktree_is_locked(null, missing) != 0) return error.LockedWorktree;
                    var prune: c.git_worktree_prune_options = undefined;
                    try check(c.git_worktree_prune_options_init(&prune, c.GIT_WORKTREE_PRUNE_OPTIONS_VERSION));
                    prune.flags = c.GIT_WORKTREE_PRUNE_VALID;
                    try check(c.git_worktree_prune(missing, &prune));
                    return;
                }
                return error.MissingWorktree;
            }
            // Opening must resolve precisely this linked worktree, never its parent.
            var target: ?*c.git_repository = null;
            try check(c.git_repository_open(&target, try z(temp, args.path)));
            defer c.git_repository_free(target);
            if (c.git_repository_is_worktree(target) != 1 or
                !std.mem.eql(u8, std.mem.span(c.git_repository_commondir(repo)), std.mem.span(c.git_repository_commondir(target)))) return error.WrongWorktree;
            var tree: ?*c.git_worktree = null;
            try check(c.git_worktree_open_from_repository(&tree, target));
            defer c.git_worktree_free(tree);
            try check(c.git_worktree_validate(tree));
            if (!std.mem.eql(u8, std.mem.trimEnd(u8, args.path, "/"), try pathText(c.git_worktree_path(tree)))) return error.WrongWorktreePath;
            var stat: c.struct_stat = undefined;
            if (c.lstat(try z(temp, args.path), &stat) != 0 or stat.st_mode & c.S_IFMT != c.S_IFDIR) return error.WrongWorktreePath;
            // A single force approval must never override an explicit worktree lock.
            if (c.git_worktree_is_locked(null, tree) != 0) return error.LockedWorktree;
            if (!args.force and (try dirty(target.?) or try submodules(temp, target.?))) return error.UnsafeWorktree;
            var options: c.git_worktree_prune_options = undefined;
            try check(c.git_worktree_prune_options_init(&options, c.GIT_WORKTREE_PRUNE_OPTIONS_VERSION));
            options.flags = c.GIT_WORKTREE_PRUNE_VALID | c.GIT_WORKTREE_PRUNE_WORKING_TREE;
            try check(c.git_worktree_prune(tree, &options));
        },
    }
}
