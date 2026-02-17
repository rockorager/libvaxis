const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const Text = vxfw.Text;
const ListView = vxfw.ListView;
const Widget = vxfw.Widget;

pub const std_options: std.Options = .{
    .log_scope_levels = &[_]std.log.ScopeLevel{
        .{ .scope = .vaxis, .level = .err },
    },
};

const Model = struct {
    list_view: ListView,

    pub fn widget(self: *Model) Widget {
        return .{
            .userdata = self,
            .eventHandler = Model.typeErasedEventHandler,
            .drawFn = Model.typeErasedDrawFn,
        };
    }

    pub fn typeErasedEventHandler(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        const self: *Model = @ptrCast(@alignCast(ptr));
        try ctx.requestFocus(self.list_view.widget());
        switch (event) {
            .key_press => |key| {
                if (key.matches('q', .{}) or key.matchExact('c', .{ .ctrl = true })) {
                    ctx.quit = true;
                    return;
                }
            },
            else => {},
        }
    }

    fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *Model = @ptrCast(@alignCast(ptr));
        const max = ctx.max.size();

        const list_view: vxfw.SubSurface = .{
            .origin = .{ .row = 1, .col = 1 },
            .surface = try self.list_view.draw(ctx),
        };

        const children = try ctx.arena.alloc(vxfw.SubSurface, 1);
        children[0] = list_view;

        return .{
            .size = max,
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

    const n = 80;
    var texts = try std.ArrayList(Widget).initCapacity(allocator, n);

    var allocs = try std.ArrayList(*Text).initCapacity(allocator, n);
    defer {
        for (allocs.items) |tw| {
            allocator.free(tw.text);
            allocator.destroy(tw);
        }
        allocs.deinit(allocator);
        texts.deinit(allocator);
    }

    for (0..n) |i| {
        const t = std.fmt.allocPrint(allocator, "List Item {d}", .{i}) catch "placeholder";
        const tw = try allocator.create(Text);
        tw.* = .{ .text = t };
        _ = try allocs.append(allocator, tw);
        _ = try texts.append(allocator, tw.widget());
    }

    model.* = .{
        .list_view = .{
            .wheel_scroll = 3,
            .scroll = .{
                .wants_cursor = true,
            },
            .children = .{ .slice = texts.items },
        },
    };

    try app.run(model.widget(), .{});
}
