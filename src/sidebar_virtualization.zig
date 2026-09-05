//! Adapt the declarative worktree rows to the SDK's runtime-scrolled window.
//! The SDK owns scrolling and remounts rows; the model still owns all data.
const std = @import("std");
const sdk = @import("native_sdk");

pub fn window(comptime Msg: type, ui: *sdk.canvas.Ui(Msg), node: sdk.canvas.Ui(Msg).Node) sdk.canvas.Ui(Msg).Node {
    if (node.global_key) |key| {
        if (node.widget.kind == .scroll_view and key == .str and
            (std.mem.eql(u8, key.str, "dock-worktrees") or std.mem.eql(u8, key.str, "overlay-worktrees")))
        {
            const options: sdk.canvas.Ui(Msg).VirtualListOptions = .{
                .id = key.str,
                .item_count = node.nodes.len,
                .item_extent = 28,
                .grow = 1,
                .padding = 4,
                .overscan = 2,
                .viewport_fallback = 760,
                .semantics = node.widget.semantics,
                .style = node.widget.style,
                .style_tokens = node.style_tokens,
            };
            const range = ui.virtualWindow(options);
            const start = @min(range.start_index, node.nodes.len);
            const end = @min(range.end_index, node.nodes.len);
            var result = ui.virtualList(options, range, node.nodes[start..end]);
            result.source = node.source;
            return result;
        }
    }
    var result = node;
    var children: ?[]@TypeOf(node) = null;
    for (node.nodes, 0..) |child, index| {
        const next = window(Msg, ui, child);
        if (next.nodes.ptr == child.nodes.ptr and next.nodes.len == child.nodes.len and next.widget.layout.virtual_item_count == child.widget.layout.virtual_item_count) continue;
        if (children == null) children = ui.arena.dupe(@TypeOf(node), node.nodes) catch return node;
        children.?[index] = next;
    }
    if (children) |nodes| result.nodes = nodes;
    return result;
}
