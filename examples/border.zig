const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

/// Our main application state
const Model = struct {
    /// Helper function to return a vxfw.Widget struct
    pub fn widget(self: *Model) vxfw.Widget {
        return .{
            .userdata = self,
            .eventHandler = Model.typeErasedEventHandler,
            .drawFn = Model.typeErasedDrawFn,
        };
    }

    fn typeErasedEventHandler(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        _ = ptr;

        switch (event) {
            .key_press => |key| {
                if (key.matches('c', .{ .ctrl = true })) {
                    ctx.quit = true;
                    return;
                }
            },
            else => {},
        }
    }

    fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *Model = @ptrCast(@alignCast(ptr));
        const max_size = ctx.max.size();

        const text = vxfw.Text{ .text = "Content" };
        const border = vxfw.Border{ .child = text.widget() };

        const border_child: vxfw.SubSurface = .{
            .origin = .{ .row = 0, .col = 0 },
            .surface = try border.draw(ctx.withConstraints(
                ctx.min,
                .{ .width = 16, .height = 5 },
            )),
        };

        const children = try ctx.arena.alloc(vxfw.SubSurface, 1);
        children[0] = border_child;

        return .{
            .size = max_size,
            .widget = self.widget(),
            .buffer = &.{},
            .children = children,
        };
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();

    var app = try vxfw.App.init(allocator);
    defer app.deinit();

    const model = try allocator.create(Model);
    defer allocator.destroy(model);

    model.* = .{};
    try app.run(model.widget(), .{});
}
