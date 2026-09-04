//! Sidebar actions: one application feature boundary.
const types = @import("app_types.zig");
const Model = types.Model;
const Msg = types.Msg;
const Effects = types.Effects;
const std = @import("std");
const native_sdk = @import("native_sdk");
const preferences_mod = @import("preferences.zig");
const sidebar_divider_width = @import("model.zig").sidebar_divider_width;

pub const sidebar_write_key = @import("effect_keys.zig").key(.sidebar, 1);

pub fn saveSidebarWidth(model: *Model, fx: *Effects) void {
    const width = model.sidebar_persistence.begin() orelse return;
    var buffer: [16]u8 = undefined;
    const value = std.fmt.bufPrint(&buffer, "{d}", .{width}) catch unreachable;
    fx.dbExec(.{
        .key = sidebar_write_key,
        .statements = &.{.{ .sql = preferences_mod.sidebar_upsert_sql, .params = &.{.{ .text = value }} }},
        .on_result = Effects.dbMsg(.sidebar_width_saved),
    });
}

pub fn flushSidebarWidth(model: *Model, binding: native_sdk.relational_store.Binding) bool {
    if (!model.sidebar_persistence.needsFlush()) return true;
    var buffer: [16]u8 = undefined;
    const width = model.sidebar_persistence.desired;
    const value = std.fmt.bufPrint(&buffer, "{d}", .{width}) catch unreachable;
    const outcome = binding.exec_fn(binding.context, &.{.{ .sql = preferences_mod.sidebar_upsert_sql, .params = &.{.{ .text = value }} }});
    if (outcome != .ok) return false;
    model.sidebar_persistence.saved = width;
    model.sidebar_persistence.dirty = false;
    model.sidebar_persistence.submitted = null;
    return true;
}

pub fn handle(model: *Model, msg: Msg, fx: *Effects) void {
    switch (msg) {
        .sidebar_resized => |fraction| {
            if (!model.sidebar.compact and !model.sidebar.collapsed and !model.sidebar.animating() and std.math.isFinite(fraction)) {
                const width = @max(210, std.math.clamp(fraction, 0, 1) * @max(1, model.canvas_width - sidebar_divider_width));
                if (model.sidebar_width != width) {
                    model.sidebar_width = width;
                    model.sidebar_persistence.edit(width);
                }
            }
        },
        .save_sidebar_width => saveSidebarWidth(model, fx),
        .sidebar_width_saved => |result| if (result.key == sidebar_write_key and result.kind == .exec) {
            model.sidebar_persistence.finish(result.outcome == .ok);
            if (result.outcome != .ok) model.status_text = "Could not save sidebar width";
        },
        .toggle_sidebar => model.sidebar.toggle(),
        .dismiss_sidebar => model.sidebar.overlay_open = false,
        else => unreachable,
    }
}
