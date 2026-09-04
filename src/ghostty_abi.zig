//! The C header is the single source of truth for the application bridge ABI.
pub const c = @cImport({
    @cInclude("ghostty_bridge.h");
});

test "bridge event and environment layout preserve the existing ABI" {
    const testing = @import("std").testing;
    try testing.expectEqual(@as(usize, 16), @sizeOf(c.canopy_ghostty_event));
    try testing.expectEqual(@as(usize, 8), @offsetOf(c.canopy_ghostty_event, "kind"));
    try testing.expectEqual(@as(usize, 12), @offsetOf(c.canopy_ghostty_event, "code"));
    try testing.expectEqual(@sizeOf(usize) * 2, @sizeOf(c.canopy_ghostty_env));
}
