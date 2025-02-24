const std = @import("std");
const vaxis = @import("../main.zig");

const vxfw = @import("vxfw.zig");

const Allocator = std.mem.Allocator;

const Center = @import("Center.zig");
const Text = @import("Text.zig");

const Button = @This();

// User supplied values
label: []const u8,
onClick: *const fn (?*anyopaque, ctx: *vxfw.EventContext) anyerror!void,
userdata: ?*anyopaque = null,

// Styles
style: struct {
    default: vaxis.Style = .{ .reverse = true },
    mouse_down: vaxis.Style = .{ .fg = .{ .index = 4 }, .reverse = true },
    hover: vaxis.Style = .{ .fg = .{ .index = 3 }, .reverse = true },
    focus: vaxis.Style = .{ .fg = .{ .index = 5 }, .reverse = true },
} = .{},

// State
mouse_down: bool = false,
has_mouse: bool = false,
focused: bool = false,

pub fn widget(self: *Button) vxfw.Widget {
    return .{
        .userdata = self,
        .eventHandler = typeErasedEventHandler,
        .drawFn = typeErasedDrawFn,
    };
}

fn typeErasedEventHandler(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
    const self: *Button = @ptrCast(@alignCast(ptr));
    return self.handleEvent(ctx, event);
}

pub fn handleEvent(self: *Button, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
    switch (event) {
        .key_press => |key| {
            if (key.matches(vaxis.Key.enter, .{}) or key.matches('j', .{ .ctrl = true })) {
                return self.doClick(ctx);
            }
        },
        .mouse => |mouse| {
            if (self.mouse_down and mouse.type == .release) {
                self.mouse_down = false;
                return self.doClick(ctx);
            }
            if (mouse.type == .press and mouse.button == .left) {
                self.mouse_down = true;
                return ctx.consumeAndRedraw();
            }
            return ctx.consumeEvent();
        },
        .mouse_enter => {
            // implicit redraw
            self.has_mouse = true;
            try ctx.setMouseShape(.pointer);
            return ctx.consumeAndRedraw();
        },
        .mouse_leave => {
            self.has_mouse = false;
            self.mouse_down = false;
            // implicit redraw
            try ctx.setMouseShape(.default);
        },
        .focus_in => {
            self.focused = true;
            ctx.redraw = true;
        },
        .focus_out => {
            self.focused = false;
            ctx.redraw = true;
        },
        else => {},
    }
}

fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
    const self: *Button = @ptrCast(@alignCast(ptr));
    return self.draw(ctx);
}

pub fn draw(self: *Button, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
    const style: vaxis.Style = if (self.mouse_down)
        self.style.mouse_down
    else if (self.has_mouse)
        self.style.hover
    else if (self.focused)
        self.style.focus
    else
        self.style.default;

    const text: Text = .{
        .style = style,
        .text = self.label,
        .text_align = .center,
    };

    const center: Center = .{ .child = text.widget() };
    const surf = try center.draw(ctx);

    const button_surf = try vxfw.Surface.initWithChildren(ctx.arena, self.widget(), surf.size, surf.children);
    @memset(button_surf.buffer, .{ .style = style });
    return button_surf;
}

fn doClick(self: *Button, ctx: *vxfw.EventContext) anyerror!void {
    try self.onClick(self.userdata, ctx);
    ctx.consume_event = true;
}

test Button {
    // Create some object which reacts to a button press
    const Foo = struct {
        count: u8,

        fn onClick(ptr: ?*anyopaque, ctx: *vxfw.EventContext) anyerror!void {
            const foo: *@This() = @ptrCast(@alignCast(ptr));
            foo.count +|= 1;
            ctx.consumeAndRedraw();
        }
    };
    var foo: Foo = .{ .count = 0 };

    var button: Button = .{
        .label = "Test Button",
        .onClick = Foo.onClick,
        .userdata = &foo,
    };

    // Event handlers need a context
    var ctx: vxfw.EventContext = .{
        .cmds = std.ArrayList(vxfw.Command).init(std.testing.allocator),
    };
    defer ctx.cmds.deinit();

    // Get the widget interface
    const b_widget = button.widget();

    // Create a synthetic mouse event
    var mouse_event: vaxis.Mouse = .{
        .col = 0,
        .row = 0,
        .mods = .{},
        .button = .left,
        .type = .press,
    };
    // Send the button a mouse press event
    try b_widget.handleEvent(&ctx, .{ .mouse = mouse_event });

    // A press alone doesn't trigger onClick
    try std.testing.expectEqual(0, foo.count);

    // Send the button a mouse release event. The onClick handler is called
    mouse_event.type = .release;
    try b_widget.handleEvent(&ctx, .{ .mouse = mouse_event });
    try std.testing.expectEqual(1, foo.count);

    // Send it another press
    mouse_event.type = .press;
    try b_widget.handleEvent(&ctx, .{ .mouse = mouse_event });

    // Now the mouse leaves
    try b_widget.handleEvent(&ctx, .mouse_leave);

    // Then it comes back. We don't know it but the button was pressed outside of our widget. We
    // receie the release event
    mouse_event.type = .release;
    try b_widget.handleEvent(&ctx, .{ .mouse = mouse_event });

    // But we didn't have the press registered, so we don't call onClick
    try std.testing.expectEqual(1, foo.count);

    // Now we receive an enter keypress. This also triggers the onClick handler
    try b_widget.handleEvent(&ctx, .{ .key_press = .{ .codepoint = vaxis.Key.enter } });
    try std.testing.expectEqual(2, foo.count);

    // Now we draw the button. Set up our context with some unicode data
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ucd = try vaxis.Unicode.init(arena.allocator());
    vxfw.DrawContext.init(&ucd, .unicode);

    const draw_ctx: vxfw.DrawContext = .{
        .arena = arena.allocator(),
        .min = .{},
        .max = .{ .width = 13, .height = 3 },
        .cell_size = .{ .width = 10, .height = 20 },
    };
    const surface = try b_widget.draw(draw_ctx);

    // The button should fill the available space.
    try std.testing.expectEqual(surface.size.width, draw_ctx.max.width.?);
    try std.testing.expectEqual(surface.size.height, draw_ctx.max.height.?);

    // It should have one child, the label
    try std.testing.expectEqual(1, surface.children.len);

    // The label should be centered
    try std.testing.expectEqual(1, surface.children[0].origin.row);
    try std.testing.expectEqual(1, surface.children[0].origin.col);
}

test "refAllDecls" {
    std.testing.refAllDecls(@This());
}
