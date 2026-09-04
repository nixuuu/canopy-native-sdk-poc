//! Read-only Ghostty configuration snapshot. No options are executed or applied
//! to Native SDK. Unknown directives remain ordered for a future Ghostty host.
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

pub const Scheme = enum { light, dark };
pub const Layer = enum { user, light_theme, dark_theme };
pub const Entry = struct { key: []const u8, value: []const u8, source: usize, line: usize, layer: Layer };
pub const Source = struct { path: []const u8, bytes: []const u8, layer: Layer };
pub const Issue = enum { invalid_path, unreadable, not_regular, too_large, invalid_line, duplicate_or_cycle, limit_reached, invalid_theme, forbidden_theme_directive };
pub const Diagnostic = struct { issue: Issue, path: []const u8, line: usize = 0 };
pub const Options = struct {
    home: []const u8,
    config_home: []const u8,
    macos: bool = builtin.os.tag == .macos,
    resource_dirs: []const []const u8 = &.{},
};

const max_file_bytes = 256 * 1024;
const max_total_bytes = 2 * 1024 * 1024;
const max_files = 64;
const max_entries = 16_384;
const max_line_bytes = 16 * 1024;
const Include = struct { path: []const u8, optional: bool };

pub const Snapshot = struct {
    arena: std.heap.ArenaAllocator,
    entries: std.ArrayListUnmanaged(Entry) = .empty,
    sources: std.ArrayListUnmanaged(Source) = .empty,
    diagnostics: std.ArrayListUnmanaged(Diagnostic) = .empty,
    includes: std.ArrayListUnmanaged(Include) = .empty,
    total_bytes: usize = 0,
    attempts: usize = 0,

    pub fn init(allocator: Allocator) Snapshot {
        return .{ .arena = std.heap.ArenaAllocator.init(allocator) };
    }

    pub fn deinit(self: *Snapshot) void {
        self.arena.deinit();
        self.* = undefined;
    }

    /// Whether the user explicitly set an environment override after resets.
    /// Used to distinguish terminal policy from inherited launcher metadata.
    pub fn hasExplicitEnvironment(self: *const Snapshot, name: []const u8) bool {
        var present = false;
        for (self.entries.items) |entry| {
            if (entry.layer != .user or !std.mem.eql(u8, entry.key, "env")) continue;
            const setting = std.mem.trim(u8, entry.value, " \t");
            if (setting.len == 0) {
                present = false;
                continue;
            }
            const eq = std.mem.indexOfScalar(u8, setting, '=') orelse continue;
            if (std.mem.eql(u8, std.mem.trim(u8, setting[0..eq], " \t"), name)) present = setting[eq + 1 ..].len > 0;
        }
        return present;
    }

    /// A snapshot is loaded once. Reload builds a replacement snapshot so a
    /// failed reload can never partially mutate configuration already in use.
    pub fn load(self: *Snapshot, io: std.Io, options: Options) !void {
        std.debug.assert(self.attempts == 0);
        if (!std.fs.path.isAbsolute(options.home) or !std.fs.path.isAbsolute(options.config_home)) {
            try self.issue(.invalid_path, "configuration roots", 0);
            return;
        }
        const alloc = self.arena.allocator();
        const xdg = try std.fs.path.join(alloc, &.{ options.config_home, "ghostty" });
        try self.loadDirectory(io, options, xdg);
        if (options.macos) {
            const mac = try std.fs.path.join(alloc, &.{ options.home, "Library/Application Support/com.mitchellh.ghostty" });
            try self.loadDirectory(io, options, mac);
        }
        // Match Ghostty's deferred FIFO: defaults first, then config-file
        // entries (nested includes append to this same ordered work list).
        while (self.includes.items.len > 0) {
            const include = self.includes.orderedRemove(0);
            _ = try self.loadFile(io, options, include.path, include.optional, .user);
        }
        if (self.value("theme", .dark)) |theme| {
            if (theme.len != 0) {
                try self.loadTheme(io, options, theme, .light);
                try self.loadTheme(io, options, theme, .dark);
            }
        }
    }

    pub fn loadEnvironment(self: *Snapshot, io: std.Io, env: *const std.process.Environ.Map) !void {
        const alloc = self.arena.allocator();
        const home = env.get("HOME") orelse {
            try self.issue(.invalid_path, "HOME", 0);
            return;
        };
        const xdg = if (env.get("XDG_CONFIG_HOME")) |path|
            (if (path.len > 0) path else try std.fs.path.join(alloc, &.{ home, ".config" }))
        else
            try std.fs.path.join(alloc, &.{ home, ".config" });
        const resources: []const []const u8 = if (env.get("GHOSTTY_RESOURCES_DIR")) |path|
            &[_][]const u8{path}
        else if (builtin.os.tag == .macos)
            &[_][]const u8{
                try std.fs.path.join(alloc, &.{ home, "Applications/Ghostty.app/Contents/Resources/ghostty" }),
                "/Applications/Ghostty.app/Contents/Resources/ghostty",
            }
        else
            &[_][]const u8{ "/usr/local/share/ghostty", "/usr/share/ghostty" };
        try self.load(io, .{ .home = home, .config_home = xdg, .resource_dirs = resources });
    }

    /// Scalar lookup only. Empty is an explicit reset, not an absent value.
    /// Repeatable fields must use values(), not last-value-wins semantics.
    pub fn value(self: *const Snapshot, key: []const u8, scheme: Scheme) ?[]const u8 {
        const layers = [_]Layer{ .user, themeLayer(scheme) };
        for (layers) |layer| {
            var index = self.entries.items.len;
            while (index > 0) {
                index -= 1;
                const entry = self.entries.items[index];
                if (entry.layer == layer and std.mem.eql(u8, key, entry.key)) return entry.value;
            }
        }
        return null;
    }

    /// Ordered values for repeatable fields; an empty directive resets the
    /// list. Returned metadata retains provenance. Caller owns the slice.
    pub fn values(self: *const Snapshot, allocator: Allocator, key: []const u8, scheme: Scheme) ![]Entry {
        var out: std.ArrayList(Entry) = .empty;
        errdefer out.deinit(allocator);
        for ([_]Layer{ themeLayer(scheme), .user }) |layer| {
            for (self.entries.items) |entry| {
                if (entry.layer != layer or !std.mem.eql(u8, entry.key, key)) continue;
                if (entry.value.len == 0) out.clearRetainingCapacity() else try out.append(allocator, entry);
            }
        }
        return out.toOwnedSlice(allocator);
    }

    /// Intentionally allowlisted: arbitrary config values may hold API tokens,
    /// command arguments or environment secrets and must never enter logs/UI.
    pub fn writeSummary(self: *const Snapshot, allocator: Allocator, writer: *std.Io.Writer) !void {
        try writer.print("Ghostty configuration: {d} sources, {d} directives, {d} diagnostics\nRenderer: Native SDK (configuration read only; not applied)\n", .{ self.sources.items.len, self.entries.items.len, self.diagnostics.items.len });
        for (self.sources.items) |source| try writer.print("source [{s}]: {s}\n", .{ @tagName(source.layer), source.path });
        const fonts = try self.values(allocator, "font-family", .dark);
        defer allocator.free(fonts);
        for (fonts) |font| try writer.print("font-family: {s}\n", .{font.value});
        for ([_][]const u8{ "font-size", "theme", "background", "foreground", "cursor-color" }) |key| {
            if (self.value(key, .dark)) |val| try writer.print("{s}: {s}\n", .{ key, val });
        }
        for (self.diagnostics.items) |diagnostic| try writer.print("diagnostic [{s}] {s}:{d}\n", .{ @tagName(diagnostic.issue), diagnostic.path, diagnostic.line });
    }

    fn loadDirectory(self: *Snapshot, io: std.Io, options: Options, path: []const u8) !void {
        // Order is pinned to Ghostty Config.loadDefaultFiles, not an assumed
        // preference for the legacy basename over config.ghostty.
        for ([_][]const u8{ "config", "config.ghostty" }) |name| {
            _ = try self.loadFile(io, options, try std.fs.path.join(self.arena.allocator(), &.{ path, name }), true, .user);
        }
    }

    fn loadFile(self: *Snapshot, io: std.Io, options: Options, path: []const u8, optional: bool, layer: Layer) anyerror!bool {
        if (self.attempts >= max_files) {
            try self.issue(.limit_reached, path, 0);
            return false;
        }
        self.attempts += 1;
        const alloc = self.arena.allocator();
        const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch |err| {
            if (!(optional and err == error.FileNotFound)) try self.issue(.unreadable, path, 0);
            return false;
        };
        if (stat.kind != .file) {
            try self.issue(.not_regular, path, 0);
            return false;
        }
        if (stat.size > max_file_bytes or stat.size > max_total_bytes -| self.total_bytes) {
            try self.issue(.too_large, path, 0);
            return false;
        }
        const canonical = std.Io.Dir.cwd().realPathFileAlloc(io, path, alloc) catch {
            try self.issue(.unreadable, path, 0);
            return false;
        };
        for (self.sources.items) |source| {
            if (source.layer == layer and std.mem.eql(u8, source.path, canonical)) {
                try self.issue(.duplicate_or_cycle, path, 0);
                return false;
            }
        }
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, canonical, alloc, .limited(@min(max_file_bytes, max_total_bytes -| self.total_bytes))) catch {
            try self.issue(.unreadable, canonical, 0);
            return false;
        };
        self.total_bytes += bytes.len;
        const source_id = self.sources.items.len;
        try self.sources.append(alloc, .{ .path = canonical, .bytes = bytes, .layer = layer });
        var lines = std.mem.splitScalar(u8, bytes, '\n');
        var number: usize = 0;
        while (lines.next()) |raw| {
            number += 1;
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;
            if (line.len > max_line_bytes or std.mem.indexOfScalar(u8, line, 0) != null) {
                try self.issue(.invalid_line, canonical, number);
                continue;
            }
            const equal = std.mem.indexOfScalar(u8, line, '=') orelse {
                try self.issue(.invalid_line, canonical, number);
                continue;
            };
            const key = std.mem.trim(u8, line[0..equal], " \t");
            if (key.len == 0 or std.mem.indexOfAny(u8, key, " \t\r") != null) {
                try self.issue(.invalid_line, canonical, number);
                continue;
            }
            const raw_value = std.mem.trim(u8, line[equal + 1 ..], " \t");
            const quoted = raw_value.len >= 2 and raw_value[0] == '"' and raw_value[raw_value.len - 1] == '"';
            const val = if (quoted) raw_value[1 .. raw_value.len - 1] else raw_value;
            const include = std.mem.eql(u8, key, "config-file");
            if (layer != .user and (include or std.mem.eql(u8, key, "theme"))) {
                try self.issue(.forbidden_theme_directive, canonical, number);
                continue;
            }
            if (self.entries.items.len >= max_entries) {
                try self.issue(.limit_reached, canonical, number);
                break;
            }
            try self.entries.append(alloc, .{ .key = key, .value = val, .source = source_id, .line = number, .layer = layer });
            if (include) {
                if (val.len == 0) {
                    self.includes.clearRetainingCapacity();
                    continue;
                }
                if (self.includes.items.len >= max_files) {
                    try self.issue(.limit_reached, canonical, number);
                    continue;
                }
                const is_optional = !quoted and val[0] == '?';
                const name = if (is_optional) val[1..] else val;
                const resolved = try self.resolvePath(options.home, std.fs.path.dirname(path).?, name);
                try self.includes.append(alloc, .{ .path = resolved, .optional = is_optional });
            }
        }
        return true;
    }

    fn resolvePath(self: *Snapshot, home: []const u8, parent: []const u8, path: []const u8) ![]const u8 {
        const alloc = self.arena.allocator();
        if (std.mem.startsWith(u8, path, "~/")) return std.fs.path.resolve(alloc, &.{ home, path[2..] });
        return std.fs.path.resolve(alloc, &.{ parent, path });
    }

    fn loadTheme(self: *Snapshot, io: std.Io, options: Options, declaration: []const u8, scheme: Scheme) !void {
        var name = declaration;
        if (std.mem.startsWith(u8, declaration, "light:") or std.mem.startsWith(u8, declaration, "dark:")) {
            var parts = std.mem.splitScalar(u8, declaration, ',');
            name = "";
            while (parts.next()) |raw| {
                const part = std.mem.trim(u8, raw, " \t");
                const prefix = if (scheme == .light) "light:" else "dark:";
                if (std.mem.startsWith(u8, part, prefix)) name = std.mem.trim(u8, part[prefix.len..], " \t");
            }
            if (name.len == 0) return self.issue(.invalid_theme, "theme", 0);
        }
        const alloc = self.arena.allocator();
        if (std.fs.path.isAbsolute(name)) {
            _ = try self.loadFile(io, options, name, false, themeLayer(scheme));
            return;
        }
        if (!std.mem.eql(u8, name, std.fs.path.basename(name))) return self.issue(.invalid_theme, "theme", 0);
        const local = try std.fs.path.join(alloc, &.{ options.config_home, "ghostty/themes", name });
        if (try self.loadFile(io, options, local, true, themeLayer(scheme))) return;
        for (options.resource_dirs) |resources| {
            if (!std.fs.path.isAbsolute(resources)) continue;
            const path = try std.fs.path.join(alloc, &.{ resources, "themes", name });
            if (try self.loadFile(io, options, path, true, themeLayer(scheme))) return;
        }
        try self.issue(.invalid_theme, "theme", 0);
    }

    fn issue(self: *Snapshot, kind: Issue, path: []const u8, line: usize) !void {
        if (self.diagnostics.items.len >= 128) return;
        const alloc = self.arena.allocator();
        try self.diagnostics.append(alloc, .{ .issue = kind, .path = try alloc.dupe(u8, path), .line = line });
    }
};

fn themeLayer(scheme: Scheme) Layer {
    return if (scheme == .light) .light_theme else .dark_theme;
}
