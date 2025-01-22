const std = @import("std");
const vaxis = @import("../main.zig");

const Allocator = std.mem.Allocator;

const vxfw = @import("vxfw.zig");

const SizedBox = @This();

child: vxfw.Widget,
size: vxfw.Size,

pub fn widget(self: *const SizedBox) vxfw.Widget {
    return .{
        .userdata = @constCast(self),
        .drawFn = typeErasedDrawFn,
    };
}

fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
    const self: *const SizedBox = @ptrCast(@alignCast(ptr));
    const max: vxfw.MaxSize = .{
        .width = if (ctx.max.width) |max_w| @min(max_w, self.size.width) else self.size.width,
        .height = if (ctx.max.height) |max_h| @min(max_h, self.size.height) else self.size.height,
    };
    const min: vxfw.Size = .{
        .width = @max(ctx.min.width, max.width.?),
        .height = @max(ctx.min.height, max.height.?),
    };
    return self.child.draw(ctx.withConstraints(min, max));
}

test SizedBox {
    // Create a test widget that saves the constraints it was given
    const TestWidget = struct {
        min: vxfw.Size,
        max: vxfw.MaxSize,

        pub fn widget(self: *@This()) vxfw.Widget {
            return .{
                .userdata = self,
                .drawFn = @This().typeErasedDrawFn,
            };
        }

        fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.min = ctx.min;
            self.max = ctx.max;
            return .{
                .size = ctx.min,
                .widget = self.widget(),
                .buffer = &.{},
                .children = &.{},
            };
        }
    };

    // Boiler plate draw context
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ucd = try vaxis.Unicode.init(arena.allocator());
    vxfw.DrawContext.init(&ucd, .unicode);

    var draw_ctx: vxfw.DrawContext = .{
        .arena = arena.allocator(),
        .min = .{},
        .max = .{ .width = 16, .height = 16 },
        .cell_size = .{ .width = 10, .height = 20 },
    };

    var test_widget: TestWidget = .{ .min = .{}, .max = .{} };

    // SizedBox tries to draw the child widget at the specified size. It will shrink to fit within
    // constraints
    const sized_box: SizedBox = .{
        .child = test_widget.widget(),
        .size = .{ .width = 10, .height = 10 },
    };

    const box_widget = sized_box.widget();
    _ = try box_widget.draw(draw_ctx);

    // The sized box is smaller than the constraints, so we should be the desired size
    try std.testing.expectEqual(sized_box.size, test_widget.min);
    try std.testing.expectEqual(sized_box.size, test_widget.max.size());

    draw_ctx.max.height = 8;
    _ = try box_widget.draw(draw_ctx);
    // The sized box is smaller than the constraints, so we should be that size
    try std.testing.expectEqual(@as(vxfw.Size, .{ .width = 10, .height = 8 }), test_widget.min);
    try std.testing.expectEqual(@as(vxfw.Size, .{ .width = 10, .height = 8 }), test_widget.max.size());

    draw_ctx.max.width = 8;
    _ = try box_widget.draw(draw_ctx);
    // The sized box is smaller than the constraints, so we should be that size
    try std.testing.expectEqual(@as(vxfw.Size, .{ .width = 8, .height = 8 }), test_widget.min);
    try std.testing.expectEqual(@as(vxfw.Size, .{ .width = 8, .height = 8 }), test_widget.max.size());
}

test "refAllDecls" {
    std.testing.refAllDecls(@This());
}
