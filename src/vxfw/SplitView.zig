const std = @import("std");
const vaxis = @import("../main.zig");

const Allocator = std.mem.Allocator;

const vxfw = @import("vxfw.zig");

const SplitView = @This();

lhs: vxfw.Widget,
rhs: vxfw.Widget,
constrain: enum { lhs, rhs } = .lhs,
style: vaxis.Style = .{},
/// min width for the constrained side
min_width: u16 = 0,
/// max width for the constrained side
max_width: ?u16 = null,
/// Target width to draw at
width: u16,

/// Statically allocated children
children: [2]vxfw.SubSurface = undefined,

// State
pressed: bool = false,
mouse_set: bool = false,

pub fn widget(self: *const SplitView) vxfw.Widget {
    return .{
        .userdata = @constCast(self),
        .eventHandler = typeErasedEventHandler,
        .drawFn = typeErasedDrawFn,
    };
}

fn typeErasedEventHandler(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
    const self: *SplitView = @ptrCast(@alignCast(ptr));
    switch (event) {
        .mouse_leave => {
            self.pressed = false;
            return;
        },
        .mouse => {},
        else => return,
    }
    const mouse = event.mouse;

    const separator_col: u16 = switch (self.constrain) {
        .lhs => self.width + 1,
        .rhs => self.width -| 1,
    };

    // If we are on the separator, we always set the mouse shape
    if (mouse.col == separator_col) {
        try ctx.setMouseShape(.@"ew-resize");
        self.mouse_set = true;
        // Set pressed state if we are a left click
        if (mouse.type == .press and mouse.button == .left) {
            self.pressed = true;
        }
    } else if (self.mouse_set) {
        // If we have set the mouse state and *aren't* over the separator, default the mouse state
        try ctx.setMouseShape(.default);
        self.mouse_set = false;
    }

    // On release, we reset state
    if (mouse.type == .release) {
        self.pressed = false;
        self.mouse_set = false;
        try ctx.setMouseShape(.default);
    }

    // If pressed, we always keep the mouse shape and we update the width
    if (self.pressed) {
        try ctx.setMouseShape(.@"ew-resize");
        self.width = @max(self.min_width, mouse.col -| 1);
        if (self.max_width) |max| {
            self.width = @min(self.width, max);
        }
        ctx.consume_event = true;
    }
}

fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
    const self: *SplitView = @ptrCast(@alignCast(ptr));
    // Fills entire space
    const max = ctx.max.size();
    // Constrain width to the max
    self.width = @min(self.width, max.width);

    // The constrained side is equal to the width
    const constrained_min: vxfw.Size = .{ .width = self.width, .height = max.height };
    const constrained_max: vxfw.MaxSize = .{ .width = self.width, .height = max.height };

    const unconstrained_min: vxfw.Size = .{ .width = max.width - self.width - 2, .height = max.height };
    const unconstrained_max: vxfw.MaxSize = .{ .width = max.width - self.width - 2, .height = max.height };

    switch (self.constrain) {
        .lhs => {
            const lhs_ctx = ctx.withConstraints(constrained_min, constrained_max);
            const lhs_surface = try self.lhs.draw(lhs_ctx);

            self.children[0] = .{
                .surface = lhs_surface,
                .origin = .{ .row = 0, .col = 0 },
            };
            const rhs_ctx = ctx.withConstraints(unconstrained_min, unconstrained_max);
            const rhs_surface = try self.rhs.draw(rhs_ctx);
            self.children[1] = .{
                .surface = rhs_surface,
                .origin = .{ .row = 0, .col = self.width + 2 },
            };
        },
        .rhs => {
            const lhs_ctx = ctx.withConstraints(unconstrained_min, unconstrained_max);
            const lhs_surface = try self.lhs.draw(lhs_ctx);
            self.children[0] = .{
                .surface = lhs_surface,
                .origin = .{ .row = 0, .col = 0 },
            };
            const rhs_ctx = ctx.withConstraints(constrained_min, constrained_max);
            const rhs_surface = try self.rhs.draw(rhs_ctx);
            self.children[1] = .{
                .surface = rhs_surface,
                .origin = .{ .row = 0, .col = self.width + 2 },
            };
        },
    }

    var surface = try vxfw.Surface.initWithChildren(ctx.arena, self.widget(), max, &self.children);
    surface.handles_mouse = true;
    for (0..max.height) |row| {
        surface.writeCell(self.width + 1, @intCast(row), .{
            .char = .{ .grapheme = "│", .width = 1 },
            .style = self.style,
        });
    }
    return surface;
}

test SplitView {
    // Boiler plate draw context
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ucd = try vaxis.Unicode.init(arena.allocator());
    vxfw.DrawContext.init(&ucd, .unicode);

    const draw_ctx: vxfw.DrawContext = .{
        .arena = arena.allocator(),
        .min = .{},
        .max = .{ .width = 16, .height = 16 },
    };

    // Create LHS and RHS widgets
    const lhs: vxfw.Text = .{ .text = "Left hand side" };
    const rhs: vxfw.Text = .{ .text = "Right hand side" };

    var split_view: SplitView = .{
        .lhs = lhs.widget(),
        .rhs = rhs.widget(),
        .width = 8,
    };

    const split_widget = split_view.widget();
    {
        const surface = try split_widget.draw(draw_ctx);
        // SplitView expands to fill the space
        try std.testing.expectEqual(@as(vxfw.Size, .{ .width = 16, .height = 16 }), surface.size);
        // It has two children
        try std.testing.expectEqual(2, surface.children.len);
        // The left child should have a width = SplitView.width
        try std.testing.expectEqual(split_view.width, surface.children[0].surface.size.width);
    }

    // Send the widget a mouse press on the separator
    var mouse: vaxis.Mouse = .{
        // The separator is width + 1
        .col = split_view.width + 1,
        .row = 0,
        .type = .press,
        .button = .left,
        .mods = .{},
    };

    var ctx: vxfw.EventContext = .{
        .cmds = std.ArrayList(vxfw.Command).init(arena.allocator()),
    };
    try split_widget.handleEvent(&ctx, .{ .mouse = mouse });
    // We should get a command to change the mouse shape
    try std.testing.expect(ctx.cmds.items[0] == .set_mouse_shape);
    try std.testing.expect(ctx.redraw);
    try std.testing.expect(split_view.pressed);

    // If we move the mouse, we should update the width
    mouse.col = 2;
    mouse.type = .drag;
    try split_widget.handleEvent(&ctx, .{ .mouse = mouse });
    try std.testing.expect(ctx.redraw);
    try std.testing.expect(split_view.pressed);
    try std.testing.expectEqual(mouse.col - 1, split_view.width);
}

test "refAllDecls" {
    std.testing.refAllDecls(@This());
}
