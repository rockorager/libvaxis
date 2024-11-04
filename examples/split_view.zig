const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const Model = struct {
    split: vxfw.SplitView,
    lhs: vxfw.Text,
    rhs: vxfw.Text,
    children: [1]vxfw.SubSurface = undefined,

    pub fn widget(self: *Model) vxfw.Widget {
        return .{
            .userdata = self,
            .eventHandler = Model.typeErasedEventHandler,
            .drawFn = Model.typeErasedDrawFn,
        };
    }

    fn typeErasedEventHandler(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        const self: *Model = @ptrCast(@alignCast(ptr));
        switch (event) {
            .init => {
                self.split.lhs = self.lhs.widget();
                self.split.rhs = self.rhs.widget();
            },
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
        const surf = try self.split.widget().draw(ctx);
        self.children[0] = .{
            .surface = surf,
            .origin = .{ .row = 0, .col = 0 },
        };
        return .{
            .size = ctx.max.size(),
            .widget = self.widget(),
            .buffer = &.{},
            .children = &self.children,
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
    model.* = .{
        .lhs = .{ .text = "Left hand side" },
        .rhs = .{ .text = "right hand side" },
        .split = .{ .lhs = undefined, .rhs = undefined, .width = 10 },
    };

    model.split.lhs = model.lhs.widget();
    model.split.rhs = model.rhs.widget();

    try app.run(model.widget(), .{});
}
