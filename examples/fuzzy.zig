const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const Model = struct {
    list: std.ArrayList(vxfw.Text),
    filtered: std.ArrayList(vxfw.RichText),
    list_view: vxfw.ListView,
    text_field: vxfw.TextField,
    result: []const u8,
    unicode_data: *const vaxis.Unicode,

    /// Used for filtered RichText Spans
    arena: std.heap.ArenaAllocator,

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
                // Initialize the filtered list
                const allocator = self.arena.allocator();
                for (self.list.items) |line| {
                    var spans = std.ArrayList(vxfw.RichText.TextSpan){};
                    const span: vxfw.RichText.TextSpan = .{ .text = line.text };
                    try spans.append(allocator, span);
                    try self.filtered.append(allocator, .{ .text = spans.items });
                }

                return ctx.requestFocus(self.text_field.widget());
            },
            .key_press => |key| {
                if (key.matches('c', .{ .ctrl = true })) {
                    ctx.quit = true;
                    return;
                }
                return self.list_view.handleEvent(ctx, event);
            },
            .focus_in => {
                return ctx.requestFocus(self.text_field.widget());
            },
            else => {},
        }
    }

    fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *Model = @ptrCast(@alignCast(ptr));
        const max = ctx.max.size();

        const list_view: vxfw.SubSurface = .{
            .origin = .{ .row = 2, .col = 0 },
            .surface = try self.list_view.draw(ctx.withConstraints(
                ctx.min,
                .{ .width = max.width, .height = max.height - 3 },
            )),
        };

        const text_field: vxfw.SubSurface = .{
            .origin = .{ .row = 0, .col = 2 },
            .surface = try self.text_field.draw(ctx.withConstraints(
                ctx.min,
                .{ .width = max.width, .height = 1 },
            )),
        };

        const prompt: vxfw.Text = .{ .text = "", .style = .{ .fg = .{ .index = 4 } } };

        const prompt_surface: vxfw.SubSurface = .{
            .origin = .{ .row = 0, .col = 0 },
            .surface = try prompt.draw(ctx.withConstraints(ctx.min, .{ .width = 2, .height = 1 })),
        };

        const children = try ctx.arena.alloc(vxfw.SubSurface, 3);
        children[0] = list_view;
        children[1] = text_field;
        children[2] = prompt_surface;

        return .{
            .size = max,
            .widget = self.widget(),
            .buffer = &.{},
            .children = children,
        };
    }

    fn widgetBuilder(ptr: *const anyopaque, idx: usize, _: usize) ?vxfw.Widget {
        const self: *const Model = @ptrCast(@alignCast(ptr));
        if (idx >= self.filtered.items.len) return null;

        return self.filtered.items[idx].widget();
    }

    fn onChange(maybe_ptr: ?*anyopaque, _: *vxfw.EventContext, str: []const u8) anyerror!void {
        const ptr = maybe_ptr orelse return;
        const self: *Model = @ptrCast(@alignCast(ptr));
        const allocator = self.arena.allocator();
        self.filtered.clearAndFree(allocator);
        _ = self.arena.reset(.free_all);

        const hasUpper = for (str) |b| {
            if (std.ascii.isUpper(b)) break true;
        } else false;

        // Loop each line
        // If our input is only lowercase, we convert the line to lowercase
        // Iterate the input graphemes, looking for them _in order_ in the line
        outer: for (self.list.items) |item| {
            const tgt = if (hasUpper)
                item.text
            else
                try toLower(allocator, item.text);

            var spans = std.ArrayList(vxfw.RichText.TextSpan){};
            var i: usize = 0;
            var iter = self.unicode_data.graphemeIterator(str);
            while (iter.next()) |g| {
                if (std.mem.indexOfPos(u8, tgt, i, g.bytes(str))) |idx| {
                    const up_to_here: vxfw.RichText.TextSpan = .{ .text = item.text[i..idx] };
                    const match: vxfw.RichText.TextSpan = .{
                        .text = item.text[idx .. idx + g.len],
                        .style = .{ .fg = .{ .index = 4 }, .reverse = true },
                    };
                    try spans.append(allocator, up_to_here);
                    try spans.append(allocator, match);
                    i = idx + g.len;
                } else continue :outer;
            }
            const up_to_here: vxfw.RichText.TextSpan = .{ .text = item.text[i..] };
            try spans.append(allocator, up_to_here);
            try self.filtered.append(allocator, .{ .text = spans.items });
        }
        self.list_view.scroll.top = 0;
        self.list_view.scroll.offset = 0;
        self.list_view.cursor = 0;
    }

    fn onSubmit(maybe_ptr: ?*anyopaque, ctx: *vxfw.EventContext, _: []const u8) anyerror!void {
        const ptr = maybe_ptr orelse return;
        const self: *Model = @ptrCast(@alignCast(ptr));
        if (self.list_view.cursor < self.filtered.items.len) {
            const selected = self.filtered.items[self.list_view.cursor];
            const allocator = self.arena.allocator();
            var result = std.ArrayList(u8){};
            for (selected.text) |span| {
                try result.appendSlice(allocator, span.text);
            }
            self.result = result.items;
        }
        ctx.quit = true;
    }
};

fn toLower(allocator: std.mem.Allocator, src: []const u8) std.mem.Allocator.Error![]const u8 {
    const lower = try allocator.alloc(u8, src.len);
    for (src, 0..) |b, i| {
        lower[i] = std.ascii.toLower(b);
    }
    return lower;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();

    var app = try vxfw.App.init(allocator);
    errdefer app.deinit();

    const model = try allocator.create(Model);
    defer allocator.destroy(model);
    model.* = .{
        .list = std.ArrayList(vxfw.Text){},
        .filtered = std.ArrayList(vxfw.RichText){},
        .list_view = .{
            .children = .{
                .builder = .{
                    .userdata = model,
                    .buildFn = Model.widgetBuilder,
                },
            },
        },
        .text_field = .{
            .buf = vxfw.TextField.Buffer.init(allocator),
            .unicode = &app.vx.unicode,
            .userdata = model,
            .onChange = Model.onChange,
            .onSubmit = Model.onSubmit,
        },
        .result = "",
        .arena = std.heap.ArenaAllocator.init(allocator),
        .unicode_data = &app.vx.unicode,
    };
    defer model.text_field.deinit();
    defer model.list.deinit(allocator);
    defer model.filtered.deinit(allocator);
    defer model.arena.deinit();

    // Run the command
    var fd = std.process.Child.init(&.{"fd"}, allocator);
    fd.stdout_behavior = .Pipe;
    fd.stderr_behavior = .Pipe;
    var stdout = std.ArrayList(u8){};
    var stderr = std.ArrayList(u8){};
    defer stdout.deinit(allocator);
    defer stderr.deinit(allocator);
    try fd.spawn();
    try fd.collectOutput(allocator, &stdout, &stderr, 10_000_000);
    _ = try fd.wait();

    var iter = std.mem.splitScalar(u8, stdout.items, '\n');
    while (iter.next()) |line| {
        if (line.len == 0) continue;
        try model.list.append(allocator, .{ .text = line });
    }

    try app.run(model.widget(), .{});
    app.deinit();

    if (model.result.len > 0) {
        _ = try std.posix.write(std.posix.STDOUT_FILENO, model.result);
        _ = try std.posix.write(std.posix.STDOUT_FILENO, "\n");
    } else {
        std.process.exit(130);
    }
}
