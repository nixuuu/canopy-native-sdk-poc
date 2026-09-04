const std = @import("std");

test "explicit NO_COLOR policy follows Ghostty environment resets" {
    var snapshot = config.Snapshot.init(std.testing.allocator);
    defer snapshot.deinit();
    const a = snapshot.arena.allocator();
    try std.testing.expect(!snapshot.hasExplicitEnvironment("NO_COLOR"));
    try snapshot.entries.append(a, .{ .key = "env", .value = "NO_COLOR=1", .source = 0, .line = 1, .layer = .user });
    try std.testing.expect(snapshot.hasExplicitEnvironment("NO_COLOR"));
    try snapshot.entries.append(a, .{ .key = "env", .value = "OTHER=1", .source = 0, .line = 2, .layer = .user });
    try std.testing.expect(snapshot.hasExplicitEnvironment("NO_COLOR"));
    try snapshot.entries.append(a, .{ .key = "env", .value = "NO_COLOR=", .source = 0, .line = 3, .layer = .user });
    try std.testing.expect(!snapshot.hasExplicitEnvironment("NO_COLOR"));
    try snapshot.entries.append(a, .{ .key = "env", .value = "NO_COLOR=1", .source = 0, .line = 4, .layer = .user });
    try snapshot.entries.append(a, .{ .key = "env", .value = "", .source = 0, .line = 5, .layer = .user });
    try std.testing.expect(!snapshot.hasExplicitEnvironment("NO_COLOR"));
}
const config = @import("ghostty_config.zig");
const testing = std.testing;

const Fixture = struct {
    tmp: testing.TmpDir,
    root: []const u8,
    config_home: []const u8,

    fn init() !Fixture {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const len = try tmp.dir.realPath(testing.io, &path_buffer);
        const root = try testing.allocator.dupe(u8, path_buffer[0..len]);
        errdefer testing.allocator.free(root);
        const config_home = try std.fs.path.join(testing.allocator, &.{ root, ".config" });
        return .{ .tmp = tmp, .root = root, .config_home = config_home };
    }

    fn deinit(self: *Fixture) void {
        self.tmp.cleanup();
        testing.allocator.free(self.root);
        testing.allocator.free(self.config_home);
    }

    fn write(self: *Fixture, path: []const u8, bytes: []const u8) !void {
        if (std.fs.path.dirname(path)) |parent| try self.tmp.dir.createDirPath(testing.io, parent);
        try self.tmp.dir.writeFile(testing.io, .{ .sub_path = path, .data = bytes });
    }

    fn options(self: *Fixture) config.Options {
        return .{ .home = self.root, .config_home = self.config_home, .macos = true };
    }
};

test "Ghostty default locations override legacy with modern then macOS and deferred includes" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.write(".config/ghostty/config", "font-size = 10\nconfig-file = child.conf\nfont-size = 11\n");
    try fixture.write(".config/ghostty/config.ghostty", "font-size = 12\n");
    try fixture.write("Library/Application Support/com.mitchellh.ghostty/config", "font-size = 13\n");
    try fixture.write("Library/Application Support/com.mitchellh.ghostty/config.ghostty", "font-size = 14\n");
    try fixture.write(".config/ghostty/child.conf", "font-size = 15\nconfig-file = grandchild.conf\n");
    try fixture.write(".config/ghostty/grandchild.conf", "font-size = 16\n");
    var snapshot = config.Snapshot.init(testing.allocator);
    defer snapshot.deinit();
    try snapshot.load(testing.io, fixture.options());
    try testing.expectEqualStrings("16", snapshot.value("font-size", .dark).?);
    try testing.expectEqual(@as(usize, 6), snapshot.sources.items.len);
    try testing.expectEqual(@as(usize, 0), snapshot.diagnostics.items.len);
}

test "Ghostty preserves quoted values equals signs comments and repeatable resets" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.write(".config/ghostty/config", " # comment\r\nfont-family = First\nfont-family = \"\"\nfont-family = \"JetBrains Mono\"\n" ++
        "font-family = Symbols\nkeybind = ctrl+a=text:hello=world\nbackground = #123456\nunknown-future = value # literal\n");
    var snapshot = config.Snapshot.init(testing.allocator);
    defer snapshot.deinit();
    try snapshot.load(testing.io, fixture.options());
    const fonts = try snapshot.values(testing.allocator, "font-family", .dark);
    defer testing.allocator.free(fonts);
    try testing.expectEqual(@as(usize, 2), fonts.len);
    try testing.expectEqualStrings("JetBrains Mono", fonts[0].value);
    try testing.expectEqual(@as(usize, 4), fonts[0].line);
    try testing.expectEqualStrings("ctrl+a=text:hello=world", snapshot.value("keybind", .dark).?);
    try testing.expectEqualStrings("#123456", snapshot.value("background", .dark).?);
    try testing.expectEqualStrings("value # literal", snapshot.value("unknown-future", .dark).?);
}

test "Ghostty optional includes and canonical cycles are bounded and diagnosed" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.write(".config/ghostty/config", "config-file = ?missing\nconfig-file = required\nconfig-file = ./config\nfont-size = 17\n");
    var snapshot = config.Snapshot.init(testing.allocator);
    defer snapshot.deinit();
    try snapshot.load(testing.io, fixture.options());
    try testing.expectEqual(@as(usize, 2), snapshot.diagnostics.items.len);
    try testing.expectEqual(config.Issue.unreadable, snapshot.diagnostics.items[0].issue);
    try testing.expectEqual(config.Issue.duplicate_or_cycle, snapshot.diagnostics.items[1].issue);
    try testing.expectEqualStrings("17", snapshot.value("font-size", .dark).?);
}

test "Ghostty reads both theme schemes beneath explicit user overrides" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.write(".config/ghostty/config", "theme = light:Day,dark:Night\nforeground = #abcdef\n");
    try fixture.write(".config/ghostty/themes/Day", "background = #ffffff\nforeground = #111111\n");
    try fixture.write(".config/ghostty/themes/Night", "background = #000000\nforeground = #eeeeee\nconfig-file = forbidden\n");
    var snapshot = config.Snapshot.init(testing.allocator);
    defer snapshot.deinit();
    try snapshot.load(testing.io, fixture.options());
    try testing.expectEqualStrings("#ffffff", snapshot.value("background", .light).?);
    try testing.expectEqualStrings("#000000", snapshot.value("background", .dark).?);
    try testing.expectEqualStrings("#abcdef", snapshot.value("foreground", .dark).?);
    try testing.expectEqualStrings("#abcdef", snapshot.value("foreground", .light).?);
    try testing.expectEqual(@as(usize, 1), snapshot.diagnostics.items.len);
    try testing.expectEqual(config.Issue.forbidden_theme_directive, snapshot.diagnostics.items[0].issue);
}

test "Ghostty missing default config is valid and invalid lines do not discard valid options" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var empty = config.Snapshot.init(testing.allocator);
    defer empty.deinit();
    try empty.load(testing.io, fixture.options());
    try testing.expectEqual(@as(usize, 0), empty.sources.items.len);
    try testing.expectEqual(@as(usize, 0), empty.diagnostics.items.len);
    try fixture.write(".config/ghostty/config", "broken\n= value\nfont-size = 18\n");
    var snapshot = config.Snapshot.init(testing.allocator);
    defer snapshot.deinit();
    try snapshot.load(testing.io, fixture.options());
    try testing.expectEqual(@as(usize, 2), snapshot.diagnostics.items.len);
    try testing.expectEqualStrings("18", snapshot.value("font-size", .dark).?);
}

test "Ghostty does not read directories or oversized files" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.write(".config/ghostty/config", "config-file = dir\nconfig-file = huge\n");
    try fixture.tmp.dir.createDirPath(testing.io, ".config/ghostty/dir");
    const bytes = try testing.allocator.alloc(u8, 256 * 1024 + 1);
    defer testing.allocator.free(bytes);
    @memset(bytes, 'x');
    try fixture.write(".config/ghostty/huge", bytes);
    var snapshot = config.Snapshot.init(testing.allocator);
    defer snapshot.deinit();
    try snapshot.load(testing.io, fixture.options());
    try testing.expectEqual(@as(usize, 2), snapshot.diagnostics.items.len);
    try testing.expectEqual(config.Issue.not_regular, snapshot.diagnostics.items[0].issue);
    try testing.expectEqual(config.Issue.too_large, snapshot.diagnostics.items[1].issue);
}

test "Ghostty nested includes are FIFO and a quoted question mark is a filename" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.write(".config/ghostty/config", "config-file = a\nconfig-file = b\nconfig-file = \"?literal\"\n");
    try fixture.write(".config/ghostty/a", "config-file = ~/nested\nfont-size = 11\n");
    try fixture.write(".config/ghostty/b", "font-size = 12\n");
    try fixture.write(".config/ghostty/?literal", "font-size = 13\n");
    try fixture.write("nested", "font-size = 14\n");
    var snapshot = config.Snapshot.init(testing.allocator);
    defer snapshot.deinit();
    try snapshot.load(testing.io, fixture.options());
    try testing.expectEqualStrings("14", snapshot.value("font-size", .dark).?);
    try testing.expectEqual(@as(usize, 5), snapshot.sources.items.len);
    try testing.expectEqual(@as(usize, 0), snapshot.diagnostics.items.len);
}

test "Ghostty resource themes resolve after user themes and diagnostics do not expose secrets" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.write(".config/ghostty/config", "theme = Shared\nenv = API_KEY=SECRET_MARKER\ncommand = secret-command\n");
    try fixture.write("resources/themes/Shared", "background = #445566\n");
    const resources = try std.fs.path.join(testing.allocator, &.{ fixture.root, "resources" });
    defer testing.allocator.free(resources);
    var options = fixture.options();
    options.resource_dirs = &.{resources};
    var snapshot = config.Snapshot.init(testing.allocator);
    defer snapshot.deinit();
    try snapshot.load(testing.io, options);
    try testing.expectEqualStrings("#445566", snapshot.value("background", .dark).?);
    var text: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&text);
    try snapshot.writeSummary(testing.allocator, &writer);
    try testing.expect(std.mem.indexOf(u8, writer.buffered(), "SECRET_MARKER") == null);
    try testing.expect(std.mem.indexOf(u8, writer.buffered(), "secret-command") == null);

    try fixture.write(".config/ghostty/themes/Shared", "background = #112233\n");
    var preferred = config.Snapshot.init(testing.allocator);
    defer preferred.deinit();
    try preferred.load(testing.io, options);
    try testing.expectEqualStrings("#112233", preferred.value("background", .dark).?);
}

test "Ghostty config-file reset replaces pending includes" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.write(".config/ghostty/config", "config-file = must-not-load\nconfig-file =\nconfig-file = child\n");
    try fixture.write(".config/ghostty/child", "config-file = discarded\nconfig-file =\nconfig-file = next\n");
    try fixture.write(".config/ghostty/next", "font-size = 19\n");
    var snapshot = config.Snapshot.init(testing.allocator);
    defer snapshot.deinit();
    try snapshot.load(testing.io, fixture.options());
    try testing.expectEqualStrings("19", snapshot.value("font-size", .dark).?);
    try testing.expectEqual(@as(usize, 0), snapshot.diagnostics.items.len);
}
