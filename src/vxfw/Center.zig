const std = @import("std");
const vaxis = @import("../main.zig");

const Allocator = std.mem.Allocator;

const vxfw = @import("vxfw.zig");

const Center = @This();

child: vxfw.Widget,

pub fn widget(self: *const Center) vxfw.Widget {
    return .{
        .userdata = @constCast(self),
        .drawFn = typeErasedDrawFn,
    };
}

fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
    const self: *const Center = @ptrCast(@alignCast(ptr));
    return self.draw(ctx);
}

/// Cannot have unbounded constraints
pub fn draw(self: *const Center, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
    const child_ctx = ctx.withConstraints(.{ .width = 0, .height = 0 }, ctx.max);
    const max_size = ctx.max.size();
    const child = try self.child.draw(child_ctx);

    const x = (max_size.width - child.size.width) / 2;
    const y = (max_size.height - child.size.height) / 2;

    const children = try ctx.arena.alloc(vxfw.SubSurface, 1);
    children[0] = .{
        .origin = .{ .col = x, .row = y },
        .z_index = 0,
        .surface = child,
    };

    return .{
        .size = max_size,
        .widget = self.widget(),
        .buffer = &.{},
        .children = children,
    };
}

test Center {
    const Text = @import("Text.zig");
    // Will be height=1, width=3
    const text: Text = .{ .text = "abc" };

    const center: Center = .{ .child = text.widget() };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ucd = try vaxis.Unicode.init(arena.allocator());
    vxfw.DrawContext.init(&ucd, .unicode);

    {
        // Center expands to the max size. It must therefore have non-null max width and max height.
        // These values are asserted in draw
        const ctx: vxfw.DrawContext = .{
            .arena = arena.allocator(),
            .min = .{},
            .max = .{ .width = 10, .height = 10 },
            .cell_size = .{ .width = 10, .height = 20 },
        };

        const surface = try center.draw(ctx);
        // Center does not produce any drawable cells
        try std.testing.expectEqual(0, surface.buffer.len);
        // Center has 1 child
        try std.testing.expectEqual(1, surface.children.len);
        // Center is the max size
        try std.testing.expectEqual(surface.size, ctx.max.size());
        const child = surface.children[0];
        // The child is 1x3
        try std.testing.expectEqual(3, child.surface.size.width);
        try std.testing.expectEqual(1, child.surface.size.height);
        // A centered 1x3 in 10x10 should be at origin 3, 4. The bias is toward the top left corner
        try std.testing.expectEqual(4, child.origin.row);
        try std.testing.expectEqual(3, child.origin.col);
    }
    {
        // Center expands to the max size. It must therefore have non-null max width and max height.
        // These values are asserted in draw
        const ctx: vxfw.DrawContext = .{
            .arena = arena.allocator(),
            .min = .{},
            .max = .{ .width = 5, .height = 3 },
            .cell_size = .{ .width = 10, .height = 20 },
        };

        const surface = try center.draw(ctx);
        // Center does not produce any drawable cells
        try std.testing.expectEqual(0, surface.buffer.len);
        // Center has 1 child
        try std.testing.expectEqual(1, surface.children.len);
        // Center is the max size
        try std.testing.expectEqual(surface.size, ctx.max.size());
        const child = surface.children[0];
        // The child is 1x3
        try std.testing.expectEqual(3, child.surface.size.width);
        try std.testing.expectEqual(1, child.surface.size.height);
        // A centered 1x3 in 3x5 should be at origin 1, 1. This is a perfectly centered child
        try std.testing.expectEqual(1, child.origin.row);
        try std.testing.expectEqual(1, child.origin.col);
    }
}

test "refAllDecls" {
    std.testing.refAllDecls(@This());
}
