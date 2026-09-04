//! Bounded reader for Native SDK relational-store page payloads.

const std = @import("std");

pub const Reader = struct {
    bytes: []const u8,
    at: usize = 0,
    row_count: usize = 0,

    pub fn init(bytes: []const u8, expected_columns: []const []const u8) ?Reader {
        var reader = Reader{ .bytes = bytes };
        const column_count = reader.readInt(u32) orelse return null;
        const row_count = reader.readInt(u32) orelse return null;
        if (column_count != expected_columns.len or row_count > bytes.len) return null;
        for (expected_columns) |expected| {
            const actual = reader.readBytes() orelse return null;
            if (!std.mem.eql(u8, actual, expected)) return null;
        }
        reader.row_count = row_count;
        return reader;
    }

    pub fn text(reader: *Reader) ?[]const u8 {
        if (!reader.takeTag(3)) return null;
        return reader.readBytes();
    }

    pub fn integer(reader: *Reader) ?i64 {
        if (!reader.takeTag(1)) return null;
        return reader.readInt(i64);
    }

    pub fn done(reader: *const Reader) bool {
        return reader.at == reader.bytes.len;
    }

    fn takeTag(reader: *Reader, expected: u8) bool {
        if (reader.at >= reader.bytes.len or reader.bytes[reader.at] != expected) return false;
        reader.at += 1;
        return true;
    }

    fn readBytes(reader: *Reader) ?[]const u8 {
        const len = reader.readInt(u32) orelse return null;
        if (len > reader.bytes.len - reader.at) return null;
        const start = reader.at;
        reader.at += len;
        return reader.bytes[start..reader.at];
    }

    fn readInt(reader: *Reader, comptime T: type) ?T {
        const width = @sizeOf(T);
        if (reader.at > reader.bytes.len or width > reader.bytes.len - reader.at) return null;
        const value = std.mem.readInt(T, reader.bytes[reader.at..][0..width], .little);
        reader.at += width;
        return value;
    }
};

test "reader validates headers and typed values" {
    const page =
        "\x02\x00\x00\x00" ++ // columns
        "\x01\x00\x00\x00" ++ // rows
        "\x03\x00\x00\x00key" ++
        "\x05\x00\x00\x00value" ++
        "\x03\x05\x00\x00\x00theme" ++
        "\x03\x07\x00\x00\x00Dracula";
    var reader = Reader.init(page, &.{ "key", "value" }) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), reader.row_count);
    try std.testing.expectEqualStrings("theme", reader.text() orelse "");
    try std.testing.expectEqualStrings("Dracula", reader.text() orelse "");
    try std.testing.expect(reader.done());
    try std.testing.expect(Reader.init(page, &.{ "value", "key" }) == null);
}
