const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const BorderLabel = vxfw.Border.BorderLabel;
const Graphemes = vxfw.Border.Graphemes;

const BorderData = struct {
    []const u8,
    Graphemes.Record,
    []const BorderLabel,
    vaxis.Style,
};

const Position = struct { i17, i17 };

/// Our main application state
const Model = struct {
    const Self = @This();

    /// Creates a `vxfw.Widget`.
    pub fn widget(self: *Self) vxfw.Widget {
        return .{
            .userdata = self,
            .eventHandler = Self.typeErasedEventHandler,
            .drawFn = Self.typeErasedDrawFn,
        };
    }

    /// Used by `vxfw` to handle events for the `Modal`.
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

    /// Used by `vxfw` to draw a `vxfw.Surface`.
    fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *Model = @ptrCast(@alignCast(ptr));
        const max_size = ctx.max.size();
        const empty_lebels = &[_]vxfw.Border.BorderLabel{};

        const graphemes = &[_]BorderData{
            .{ "Bold", Graphemes.bold, empty_lebels, .{} },
            .{ "Classic", Graphemes.classic, empty_lebels, .{} },
            .{ "Double", Graphemes.double, empty_lebels, .{} },
            .{ "Double Single", Graphemes.double_single, empty_lebels, .{} },
            .{ "Round", Graphemes.round, empty_lebels, .{} },
            .{ "Single", Graphemes.single, empty_lebels, .{} },
            .{ "Single Double", Graphemes.single_double, empty_lebels, .{} },
        };

        const titled = &[_]BorderData{
            .{
                "Dim title",
                Graphemes.round,
                &[_]BorderLabel{.{ .text = "Top Left", .alignment = .top_left }},
                .{ .dim = true },
            },
            .{
                " ",
                Graphemes.round,
                &[_]BorderLabel{.{ .text = "Top Center", .alignment = .top_center }},
                .{},
            },
            .{
                "Bold title",
                Graphemes.round,
                &[_]BorderLabel{.{ .text = "Top Right", .alignment = .top_right }},
                .{ .bold = true },
            },
            .{
                " ",
                Graphemes.round,
                &[_]BorderLabel{.{ .text = "Bottom Left", .alignment = .bottom_left }},
                .{},
            },
            .{
                "Italic title",
                Graphemes.round,
                &[_]BorderLabel{.{ .text = "Bottom Center", .alignment = .bottom_center }},
                .{ .italic = true },
            },
            .{
                " ",
                Graphemes.round,
                &[_]BorderLabel{.{ .text = "Bottom Right", .alignment = .bottom_right }},
                .{},
            },
            .{
                "With color",
                Graphemes.round,
                &[_]BorderLabel{
                    .{ .text = "Top Left", .alignment = .top_left },
                    .{ .text = "Bottom Right", .alignment = .bottom_right },
                },
                .{ .fg = .{ .index = 220 } },
            },
        };

        const children = try ctx.arena.alloc(vxfw.SubSurface, graphemes.len + titled.len);
        var row: i17 = 1;

        for (graphemes, 0..) |data, i| {
            children[i] = try Self.createBorder(ctx, data, .{ row, 2 });
            row += 3;
        }

        row = 1;

        for (titled, 0..) |data, i| {
            children[i + graphemes.len] = try Self.createBorder(ctx, data, .{ row, 33 });
            row += 3;
        }

        return .{
            .size = max_size,
            .widget = self.widget(),
            .buffer = &.{},
            .children = children,
        };
    }

    /// Creates a `vxfw.SubSurface` for a `vxfw.Border` that contains text and
    /// optionally a title and styles.
    fn createBorder(ctx: vxfw.DrawContext, data: BorderData, position: Position) !vxfw.SubSurface {
        const text = vxfw.Text{ .text = data[0] };

        const padding = vxfw.Padding{
            .child = text.widget(),
            .padding = .{ .left = 1, .right = 1 },
        };

        const border = vxfw.Border{
            .child = padding.widget(),
            .graphemes = data[1],
            .labels = data[2],
            .style = data[3],
        };

        return .{
            .origin = .{ .row = position[0], .col = position[1] },
            .surface = try border.draw(ctx.withConstraints(
                .{ .width = 30, .height = ctx.min.height },
                .{ .width = 30, .height = 3 },
            )),
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
