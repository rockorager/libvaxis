const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const Text = vxfw.Text;
const ListView = vxfw.ListView;
const Widget = vxfw.Widget;

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

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const alloc = init.gpa;

    var buffer: [1024]u8 = undefined;
    var app: vxfw.App = try .init(io, alloc, init.environ_map, &buffer);
    defer app.deinit();

    const model = try alloc.create(Model);
    defer alloc.destroy(model);

    const n = 80;
    var texts: std.ArrayList(Widget) = try .initCapacity(alloc, n);
    var allocs: std.ArrayList(*Text) = try .initCapacity(alloc, n);
    defer {
        for (allocs.items) |tw| {
            alloc.free(tw.text);
            alloc.destroy(tw);
        }
        allocs.deinit(alloc);
        texts.deinit(alloc);
    }

    for (0..n) |i| {
        const t = std.fmt.allocPrint(alloc, "List Item {d} of {d}", .{ i, n }) catch "placeholder";
        const tw = try alloc.create(Text);
        tw.* = .{ .text = t };
        _ = try allocs.append(alloc, tw);
        _ = try texts.append(alloc, tw.widget());
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
