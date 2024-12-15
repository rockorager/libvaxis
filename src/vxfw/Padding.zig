const std = @import("std");
const vaxis = @import("../main.zig");

const Allocator = std.mem.Allocator;

const vxfw = @import("vxfw.zig");

const Padding = @This();
const PadValues = struct {
    left: u16 = 0,
    right: u16 = 0,
    top: u16 = 0,
    bottom: u16 = 0,
};

child: vxfw.Widget,
padding: PadValues = .{},

/// Vertical padding will be divided by 2 to approximate equal padding
pub fn all(padding: u16) PadValues {
    return .{
        .left = padding,
        .right = padding,
        .top = padding / 2,
        .bottom = padding / 2,
    };
}

pub fn horizontal(padding: u16) PadValues {
    return .{
        .left = padding,
        .right = padding,
    };
}

pub fn vertical(padding: u16) PadValues {
    return .{
        .top = padding,
        .bottom = padding,
    };
}

pub fn widget(self: *const Padding) vxfw.Widget {
    return .{
        .userdata = @constCast(self),
        .drawFn = typeErasedDrawFn,
    };
}

fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
    const self: *const Padding = @ptrCast(@alignCast(ptr));
    return self.draw(ctx);
}

pub fn draw(self: *const Padding, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
    const pad = self.padding;
    if (pad.left > 0 or pad.right > 0)
        std.debug.assert(ctx.max.width != null);
    if (pad.top > 0 or pad.bottom > 0)
        std.debug.assert(ctx.max.height != null);
    const inner_min: vxfw.Size = .{
        .width = ctx.min.width -| (pad.right + pad.left),
        .height = ctx.min.height -| (pad.top + pad.bottom),
    };

    const max_width: ?u16 = if (ctx.max.width) |max|
        max -| (pad.right + pad.left)
    else
        null;
    const max_height: ?u16 = if (ctx.max.height) |max|
        max -| (pad.top + pad.bottom)
    else
        null;

    const inner_max: vxfw.MaxSize = .{
        .width = max_width,
        .height = max_height,
    };

    const child_surface = try self.child.draw(ctx.withConstraints(inner_min, inner_max));

    const children = try ctx.arena.alloc(vxfw.SubSurface, 1);
    children[0] = .{
        .surface = child_surface,
        .z_index = 0,
        .origin = .{ .row = pad.top, .col = pad.left },
    };

    const size: vxfw.Size = .{
        .width = child_surface.size.width + (pad.right + pad.left),
        .height = child_surface.size.height + (pad.top + pad.bottom),
    };

    // Create the padding surface
    return .{
        .size = size,
        .widget = self.widget(),
        .buffer = &.{},
        .children = children,
    };
}

test Padding {
    const Text = @import("Text.zig");
    // Will be height=1, width=3
    const text: Text = .{ .text = "abc" };

    const padding: Padding = .{
        .child = text.widget(),
        .padding = horizontal(1),
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ucd = try vaxis.Unicode.init(arena.allocator());
    vxfw.DrawContext.init(&ucd, .unicode);

    // Center expands to the max size. It must therefore have non-null max width and max height.
    // These values are asserted in draw
    const ctx: vxfw.DrawContext = .{
        .arena = arena.allocator(),
        .min = .{},
        .max = .{ .width = 10, .height = 10 },
        .cell_size = .{ .width = 10, .height = 20 },
    };

    const pad_widget = padding.widget();

    const surface = try pad_widget.draw(ctx);
    // Padding does not produce any drawable cells
    try std.testing.expectEqual(0, surface.buffer.len);
    // Padding has 1 child
    try std.testing.expectEqual(1, surface.children.len);
    const child = surface.children[0];
    // Padding is the child size + padding
    try std.testing.expectEqual(child.surface.size.width + 2, surface.size.width);
    try std.testing.expectEqual(0, child.origin.row);
    try std.testing.expectEqual(1, child.origin.col);
}

test "refAllDecls" {
    std.testing.refAllDecls(@This());
}
