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
                if (key.matches('c', .{ .ctrl = true }) or (key.codepoint == 'q')) {
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
        const BorderStyles = vxfw.Border.BorderStyles;
        const Style = BorderStyles.BorderCharacters;

        const borderStyles = &[_]struct { []const u8, Style }{
            .{ "bold", BorderStyles.bold },
            .{ "classic", BorderStyles.classic },
            .{ "double", BorderStyles.double },
            .{ "doubleSingle", BorderStyles.doubleSingle },
            .{ "round", BorderStyles.round },
            .{ "single", BorderStyles.single },
            .{ "singleDouble", BorderStyles.singleDouble },
        };

        var borders = std.ArrayList(vxfw.SubSurface).init(ctx.arena);
        defer borders.deinit();
        const children = try ctx.arena.alloc(vxfw.SubSurface, borderStyles.len);
        var row: i17 = -3;

        for (borderStyles, 0..) |style, i| {
            const text = vxfw.Text{ .text = style[0] };

            const padding = vxfw.Padding{
                .child = text.widget(),
                .padding = .{ .left = 1, .right = 1 },
            };

            const border = vxfw.Border{ .child = padding.widget(), .borderStyle = style[1] };
            row += 3;

            const border_child: vxfw.SubSurface = .{
                .origin = .{ .row = row, .col = 0 },
                .surface = try border.draw(ctx.withConstraints(
                    .{ .width = 30, .height = ctx.min.height },
                    .{ .width = 30, .height = 3 },
                )),
            };

            try borders.append(border_child);
            children[i] = border_child;
        }

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
