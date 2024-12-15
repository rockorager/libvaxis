const std = @import("std");
const vaxis = @import("../main.zig");

const Allocator = std.mem.Allocator;

const vxfw = @import("vxfw.zig");

const FlexColumn = @This();

children: []const vxfw.FlexItem,

pub fn widget(self: *const FlexColumn) vxfw.Widget {
    return .{
        .userdata = @constCast(self),
        .drawFn = typeErasedDrawFn,
    };
}

fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
    const self: *const FlexColumn = @ptrCast(@alignCast(ptr));
    return self.draw(ctx);
}

pub fn draw(self: *const FlexColumn, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
    std.debug.assert(ctx.max.height != null);
    std.debug.assert(ctx.max.width != null);
    if (self.children.len == 0) return vxfw.Surface.init(ctx.arena, self.widget(), ctx.min);

    // Store the inherent size of each widget
    const size_list = try ctx.arena.alloc(u16, self.children.len);

    var layout_arena = std.heap.ArenaAllocator.init(ctx.arena);

    const layout_ctx: vxfw.DrawContext = .{
        .min = .{ .width = 0, .height = 0 },
        .max = .{ .width = ctx.max.width, .height = null },
        .arena = layout_arena.allocator(),
        .cell_size = ctx.cell_size,
    };

    // Store the inherent size of each widget
    var first_pass_height: u16 = 0;
    var total_flex: u16 = 0;
    for (self.children, 0..) |child, i| {
        const surf = try child.widget.draw(layout_ctx);
        first_pass_height += surf.size.height;
        total_flex += child.flex;
        size_list[i] = surf.size.height;
    }

    // We are done with the layout arena
    layout_arena.deinit();

    // make our children list
    var children = std.ArrayList(vxfw.SubSurface).init(ctx.arena);

    // Draw again, but with distributed heights
    var second_pass_height: u16 = 0;
    var max_width: u16 = 0;
    const remaining_space = ctx.max.height.? - first_pass_height;
    for (self.children, 1..) |child, i| {
        const inherent_height = size_list[i - 1];
        const child_height = if (child.flex == 0)
            inherent_height
        else if (i == self.children.len)
            // If we are the last one, we just get the remainder
            ctx.max.height.? - second_pass_height
        else
            inherent_height + (remaining_space * child.flex) / total_flex;

        // Create a context for the child
        const child_ctx = ctx.withConstraints(
            .{ .width = 0, .height = child_height },
            .{ .width = ctx.max.width.?, .height = child_height },
        );
        const surf = try child.widget.draw(child_ctx);

        try children.append(.{
            .origin = .{ .col = 0, .row = second_pass_height },
            .surface = surf,
            .z_index = 0,
        });
        max_width = @max(max_width, surf.size.width);
        second_pass_height += surf.size.height;
    }

    const size: vxfw.Size = .{ .width = max_width, .height = second_pass_height };
    return .{
        .size = size,
        .widget = self.widget(),
        .buffer = &.{},
        .children = children.items,
    };
}

test FlexColumn {
    // Create child widgets
    const Text = @import("Text.zig");
    // Will be height=1, width=3
    const abc: Text = .{ .text = "abc" };
    const def: Text = .{ .text = "def" };
    const ghi: Text = .{ .text = "ghi" };
    const jklmno: Text = .{ .text = "jkl\nmno" };

    // Create the flex column
    const flex_column: FlexColumn = .{
        .children = &.{
            .{ .widget = abc.widget(), .flex = 0 }, // flex=0 means we are our inherent size
            .{ .widget = def.widget(), .flex = 1 },
            .{ .widget = ghi.widget(), .flex = 1 },
            .{ .widget = jklmno.widget(), .flex = 1 },
        },
    };

    // Boiler plate draw context
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ucd = try vaxis.Unicode.init(arena.allocator());
    vxfw.DrawContext.init(&ucd, .unicode);

    const flex_widget = flex_column.widget();
    const ctx: vxfw.DrawContext = .{
        .arena = arena.allocator(),
        .min = .{},
        .max = .{ .width = 16, .height = 16 },
        .cell_size = .{ .width = 10, .height = 20 },
    };

    const surface = try flex_widget.draw(ctx);
    // FlexColumn expands to max height and widest child
    try std.testing.expectEqual(16, surface.size.height);
    try std.testing.expectEqual(3, surface.size.width);
    // We have four children
    try std.testing.expectEqual(4, surface.children.len);

    // We will track the row we are on to confirm the origins
    var row: u16 = 0;
    // First child has flex=0, it should be it's inherent height
    try std.testing.expectEqual(1, surface.children[0].surface.size.height);
    try std.testing.expectEqual(row, surface.children[0].origin.row);
    // Add the child height each time
    row += surface.children[0].surface.size.height;
    // Let's do some math
    // - We have 4 children to fit into 16 rows. 3 children will be 1 row tall, one will be 2 rows
    //   tall for a total height of 5 rows.
    // - The first child is 1 row and no flex. The rest of the height gets distributed evenly among
    //   the remaining 3 children. The remainder height is 16 - 5 = 11, so each child should get 11 /
    //   3 = 3 extra rows, and the last will receive the remainder
    try std.testing.expectEqual(1 + 3, surface.children[1].surface.size.height);
    try std.testing.expectEqual(row, surface.children[1].origin.row);
    row += surface.children[1].surface.size.height;

    try std.testing.expectEqual(1 + 3, surface.children[2].surface.size.height);
    try std.testing.expectEqual(row, surface.children[2].origin.row);
    row += surface.children[2].surface.size.height;

    try std.testing.expectEqual(2 + 3 + 2, surface.children[3].surface.size.height);
    try std.testing.expectEqual(row, surface.children[3].origin.row);
}

test "refAllDecls" {
    std.testing.refAllDecls(@This());
}
