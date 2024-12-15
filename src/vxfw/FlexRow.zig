const std = @import("std");
const vaxis = @import("../main.zig");

const vxfw = @import("vxfw.zig");

const Allocator = std.mem.Allocator;

const FlexRow = @This();

children: []const vxfw.FlexItem,

pub fn widget(self: *const FlexRow) vxfw.Widget {
    return .{
        .userdata = @constCast(self),
        .drawFn = typeErasedDrawFn,
    };
}

fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
    const self: *const FlexRow = @ptrCast(@alignCast(ptr));
    return self.draw(ctx);
}

pub fn draw(self: *const FlexRow, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
    std.debug.assert(ctx.max.height != null);
    std.debug.assert(ctx.max.width != null);
    if (self.children.len == 0) return vxfw.Surface.init(ctx.arena, self.widget(), ctx.min);

    // Store the inherent size of each widget
    const size_list = try ctx.arena.alloc(u16, self.children.len);

    var layout_arena = std.heap.ArenaAllocator.init(ctx.arena);

    const layout_ctx: vxfw.DrawContext = .{
        .min = .{ .width = 0, .height = 0 },
        .max = .{ .width = null, .height = ctx.max.height },
        .arena = layout_arena.allocator(),
        .cell_size = ctx.cell_size,
    };

    var first_pass_width: u16 = 0;
    var total_flex: u16 = 0;
    for (self.children, 0..) |child, i| {
        const surf = try child.widget.draw(layout_ctx);
        first_pass_width += surf.size.width;
        total_flex += child.flex;
        size_list[i] = surf.size.width;
    }

    // We are done with the layout arena
    layout_arena.deinit();

    // make our children list
    var children = std.ArrayList(vxfw.SubSurface).init(ctx.arena);

    // Draw again, but with distributed widths
    var second_pass_width: u16 = 0;
    var max_height: u16 = 0;
    const remaining_space = ctx.max.width.? - first_pass_width;
    for (self.children, 1..) |child, i| {
        const inherent_width = size_list[i - 1];
        const child_width = if (child.flex == 0)
            inherent_width
        else if (i == self.children.len)
            // If we are the last one, we just get the remainder
            ctx.max.width.? - second_pass_width
        else
            inherent_width + (remaining_space * child.flex) / total_flex;

        // Create a context for the child
        const child_ctx = ctx.withConstraints(
            .{ .width = child_width, .height = 0 },
            .{ .width = child_width, .height = ctx.max.height.? },
        );
        const surf = try child.widget.draw(child_ctx);

        try children.append(.{
            .origin = .{ .col = second_pass_width, .row = 0 },
            .surface = surf,
            .z_index = 0,
        });
        max_height = @max(max_height, surf.size.height);
        second_pass_width += surf.size.width;
    }
    const size: vxfw.Size = .{ .width = second_pass_width, .height = max_height };
    return .{
        .size = size,
        .widget = self.widget(),
        .buffer = &.{},
        .children = children.items,
    };
}

test FlexRow {
    // Create child widgets
    const Text = @import("Text.zig");
    // Will be height=1, width=3
    const abc: Text = .{ .text = "abc" };
    const def: Text = .{ .text = "def" };
    const ghi: Text = .{ .text = "ghi" };
    const jklmno: Text = .{ .text = "jkl\nmno" };

    // Create the flex row
    const flex_row: FlexRow = .{
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

    const flex_widget = flex_row.widget();
    const ctx: vxfw.DrawContext = .{
        .arena = arena.allocator(),
        .min = .{},
        .max = .{ .width = 16, .height = 16 },
        .cell_size = .{ .width = 10, .height = 20 },
    };

    const surface = try flex_widget.draw(ctx);
    // FlexRow expands to max width and tallest child
    try std.testing.expectEqual(16, surface.size.width);
    try std.testing.expectEqual(2, surface.size.height);
    // We have four children
    try std.testing.expectEqual(4, surface.children.len);

    // We will track the column we are on to confirm the origins
    var col: u16 = 0;
    // First child has flex=0, it should be it's inherent width
    try std.testing.expectEqual(3, surface.children[0].surface.size.width);
    try std.testing.expectEqual(col, surface.children[0].origin.col);
    // Add the child height each time
    col += surface.children[0].surface.size.width;
    // Let's do some math
    // - We have 4 children to fit into 16 cols. All children will be 3 wide for a total width of 12
    // - The first child is 3 cols and no flex. The rest of the width gets distributed evenly among
    //   the remaining 3 children. The remainder width is 16 - 12 = 4, so each child should get 4 /
    //   3 = 1 extra cols, and the last will receive the remainder
    try std.testing.expectEqual(1 + 3, surface.children[1].surface.size.width);
    try std.testing.expectEqual(col, surface.children[1].origin.col);
    col += surface.children[1].surface.size.width;

    try std.testing.expectEqual(1 + 3, surface.children[2].surface.size.width);
    try std.testing.expectEqual(col, surface.children[2].origin.col);
    col += surface.children[2].surface.size.width;

    try std.testing.expectEqual(1 + 3 + 1, surface.children[3].surface.size.width);
    try std.testing.expectEqual(col, surface.children[3].origin.col);
}

test "refAllDecls" {
    std.testing.refAllDecls(@This());
}
