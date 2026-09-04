//! Disjoint SDK effect identities. UI/entity IDs never share this namespace.
const std = @import("std");
pub const Domain = enum(u5) { git = 1, projects, pty, preferences, profiles, sidebar, tools };
const mask: u64 = (1 << 48) - 1;

pub fn key(domain: Domain, serial: u48) u64 {
    return (@as(u64, @intFromEnum(domain)) << 48) | serial;
}

pub fn first(domain: Domain) u64 {
    return key(domain, 1);
}

pub fn advance(value: *u64) u64 {
    std.debug.assert(value.* & mask != mask);
    const result = value.*;
    value.* += 1;
    return result;
}

test "effect families remain disjoint beyond former overlapping ranges" {
    var all = std.AutoHashMap(u64, void).init(std.testing.allocator);
    defer all.deinit();
    for (std.enums.values(Domain)) |domain| {
        var next = first(domain);
        for (0..12000) |_| {
            const result = try all.getOrPut(advance(&next));
            try std.testing.expect(!result.found_existing);
        }
        try std.testing.expect(next < 1 << 53); // exact in SDK JSON journals too
    }
}
