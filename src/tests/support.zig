pub const std = @import("std");
pub const app = @import("../main.zig");
pub const profiles = @import("../profiles.zig");
pub const workspaces = @import("../workspaces.zig");
pub const sdk = @import("native_sdk");

pub const Stores = struct {
    tabs: *app.TabStore,
    projects: *workspaces.Store,
    profiles: *profiles.Store,

    pub fn init() !Stores {
        return initWithTabAllocator(std.testing.allocator);
    }

    pub fn initWithTabAllocator(allocator: std.mem.Allocator) !Stores {
        const tabs = try app.TabStore.create(allocator);
        errdefer tabs.destroy();
        const projects = try workspaces.Store.create(std.testing.allocator);
        errdefer projects.destroy();
        const profile_store = try profiles.Store.create(std.testing.allocator);
        return .{ .tabs = tabs, .projects = projects, .profiles = profile_store };
    }

    pub fn deinit(stores: Stores) void {
        stores.tabs.destroy();
        stores.projects.destroy();
        stores.profiles.destroy();
    }
};

pub fn finishGit(fx: *app.Effects, model: *app.Model, outcome: @import("../git_workflow.zig").Outcome, output_lines: []const []const u8) !void {
    try std.testing.expect(model.git.busy());
    try std.testing.expectEqual(@as(usize, 0), fx.pendingSpawnCount());
    const output = try std.mem.join(std.testing.allocator, "\n", output_lines);
    defer std.testing.allocator.free(output);
    app.update(model, .{ .git_done = .{ .key = model.git.active.key, .outcome = outcome, .output = output } }, fx);
}

pub fn addProfile(stores: Stores, runtime_id: u64, agent_type: profiles.AgentType, name: []const u8) !*profiles.Profile {
    var profile = profiles.Profile{ .runtime_id = runtime_id, .agent_type = agent_type };
    try std.testing.expect(profile.id.set(if (agent_type == .claude) "profile-claude" else "profile-codex"));
    try std.testing.expect(profile.name.set(name));
    profile.is_default = std.mem.eql(u8, name, "Default");
    try stores.profiles.items.append(std.testing.allocator, profile);
    return &stores.profiles.items.items[stores.profiles.items.items.len - 1];
}

pub fn envValue(request: anytype, name: []const u8) ?[]const u8 {
    for (request.env) |entry| if (std.mem.eql(u8, entry.name, name)) return entry.value;
    return null;
}
