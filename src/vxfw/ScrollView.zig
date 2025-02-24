const std = @import("std");
const vaxis = @import("../main.zig");

const assert = std.debug.assert;

const Allocator = std.mem.Allocator;

const vxfw = @import("vxfw.zig");

const ScrollView = @This();

pub const Builder = struct {
    userdata: *const anyopaque,
    buildFn: *const fn (*const anyopaque, idx: usize, cursor: usize) ?vxfw.Widget,

    pub inline fn itemAtIdx(self: Builder, idx: usize, cursor: usize) ?vxfw.Widget {
        return self.buildFn(self.userdata, idx, cursor);
    }
};

pub const Source = union(enum) {
    slice: []const vxfw.Widget,
    builder: Builder,
};

const Scroll = struct {
    /// Index of the first fully-in-view widget.
    top: u32 = 0,
    /// Line offset within the top widget.
    vertical_offset: i17 = 0,
    /// Pending vertical scroll amount.
    pending_lines: i17 = 0,
    /// If there is more room to scroll down.
    has_more_vertical: bool = true,
    /// The column of the first in-view column.
    left: u32 = 0,
    /// If there is more room to scroll right.
    has_more_horizontal: bool = true,
    /// The cursor must be in the viewport.
    wants_cursor: bool = false,

    pub fn linesDown(self: *Scroll, n: u8) bool {
        if (!self.has_more_vertical) return false;
        self.pending_lines += n;
        return true;
    }

    pub fn linesUp(self: *Scroll, n: u8) bool {
        if (self.top == 0 and self.vertical_offset == 0) return false;
        self.pending_lines -= @intCast(n);
        return true;
    }

    pub fn colsLeft(self: *Scroll, n: u8) bool {
        if (self.left == 0) return false;
        self.left -|= n;
        return true;
    }
    pub fn colsRight(self: *Scroll, n: u8) bool {
        if (!self.has_more_horizontal) return false;
        self.left +|= n;
        return true;
    }
};

children: Source,
cursor: u32 = 0,
last_height: u8 = 0,
/// When true, the widget will draw a cursor next to the widget which has the cursor
draw_cursor: bool = false,
/// The cell that will be drawn to represent the scroll view's cursor. Replace this to customize the
/// cursor indicator. Must have a 1 column width.
cursor_indicator: vaxis.Cell = .{ .char = .{ .grapheme = "▐", .width = 1 } },
/// Lines to scroll for a mouse wheel
wheel_scroll: u8 = 3,
/// Set this if the exact item count is known.
item_count: ?u32 = null,

/// scroll position
scroll: Scroll = .{},

pub fn widget(self: *const ScrollView) vxfw.Widget {
    return .{
        .userdata = @constCast(self),
        .eventHandler = typeErasedEventHandler,
        .drawFn = typeErasedDrawFn,
    };
}

fn typeErasedEventHandler(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
    const self: *ScrollView = @ptrCast(@alignCast(ptr));
    return self.handleEvent(ctx, event);
}

fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
    const self: *ScrollView = @ptrCast(@alignCast(ptr));
    return self.draw(ctx);
}

pub fn handleEvent(self: *ScrollView, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
    switch (event) {
        .mouse => |mouse| {
            if (mouse.button == .wheel_up) {
                if (self.scroll.linesUp(self.wheel_scroll))
                    return ctx.consumeAndRedraw();
            }
            if (mouse.button == .wheel_down) {
                if (self.scroll.linesDown(self.wheel_scroll))
                    return ctx.consumeAndRedraw();
            }
            if (mouse.button == .wheel_left) {
                if (self.scroll.colsRight(self.wheel_scroll))
                    return ctx.consumeAndRedraw();
            }
            if (mouse.button == .wheel_right) {
                if (self.scroll.colsLeft(self.wheel_scroll))
                    return ctx.consumeAndRedraw();
            }
        },
        .key_press => |key| {
            if (key.matches(vaxis.Key.down, .{}) or
                key.matches('j', .{}) or
                key.matches('n', .{ .ctrl = true }))
            {
                // If we're drawing the cursor, move it to the next item.
                if (self.draw_cursor) return self.nextItem(ctx);

                // Otherwise scroll the view down.
                if (self.scroll.linesDown(1)) ctx.consumeAndRedraw();
            }
            if (key.matches(vaxis.Key.up, .{}) or
                key.matches('k', .{}) or
                key.matches('p', .{ .ctrl = true }))
            {
                // If we're drawing the cursor, move it to the previous item.
                if (self.draw_cursor) return self.prevItem(ctx);

                // Otherwise scroll the view up.
                if (self.scroll.linesUp(1)) ctx.consumeAndRedraw();
            }
            if (key.matches(vaxis.Key.right, .{}) or
                key.matches('l', .{}) or
                key.matches('f', .{ .ctrl = true }))
            {
                if (self.scroll.colsRight(1)) ctx.consumeAndRedraw();
            }
            if (key.matches(vaxis.Key.left, .{}) or
                key.matches('h', .{}) or
                key.matches('b', .{ .ctrl = true }))
            {
                if (self.scroll.colsLeft(1)) ctx.consumeAndRedraw();
            }
            if (key.matches('d', .{ .ctrl = true })) {
                const scroll_lines = @max(self.last_height / 2, 1);
                if (self.scroll.linesDown(scroll_lines))
                    ctx.consumeAndRedraw();
            }
            if (key.matches('u', .{ .ctrl = true })) {
                const scroll_lines = @max(self.last_height / 2, 1);
                if (self.scroll.linesUp(scroll_lines))
                    ctx.consumeAndRedraw();
            }
            if (key.matches(vaxis.Key.escape, .{})) {
                self.ensureScroll();
                return ctx.consumeAndRedraw();
            }
        },
        else => {},
    }
}

pub fn draw(self: *ScrollView, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
    std.debug.assert(ctx.max.width != null);
    std.debug.assert(ctx.max.height != null);
    switch (self.children) {
        .slice => |slice| {
            self.item_count = @intCast(slice.len);
            const builder: SliceBuilder = .{ .slice = slice };
            return self.drawBuilder(ctx, .{ .userdata = &builder, .buildFn = SliceBuilder.build });
        },
        .builder => |b| return self.drawBuilder(ctx, b),
    }
}

pub fn nextItem(self: *ScrollView, ctx: *vxfw.EventContext) void {
    // If we have a count, we can handle this directly
    if (self.item_count) |count| {
        if (self.cursor >= count - 1) {
            return ctx.consumeEvent();
        }
        self.cursor += 1;
    } else {
        switch (self.children) {
            .slice => |slice| {
                self.item_count = @intCast(slice.len);
                // If we are already at the end, don't do anything
                if (self.cursor == slice.len - 1) {
                    return ctx.consumeEvent();
                }
                // Advance the cursor
                self.cursor += 1;
            },
            .builder => |builder| {
                // Save our current state
                const prev = self.cursor;
                // Advance the cursor
                self.cursor += 1;
                // Check the bounds, reversing until we get the last item
                while (builder.itemAtIdx(self.cursor, self.cursor) == null) {
                    self.cursor -|= 1;
                }
                // If we didn't change state, we don't redraw
                if (self.cursor == prev) {
                    return ctx.consumeEvent();
                }
            },
        }
    }
    // Reset scroll
    self.ensureScroll();
    ctx.consumeAndRedraw();
}

pub fn prevItem(self: *ScrollView, ctx: *vxfw.EventContext) void {
    if (self.cursor == 0) {
        return ctx.consumeEvent();
    }

    if (self.item_count) |count| {
        // If for some reason our count changed, we handle it here
        self.cursor = @min(self.cursor - 1, count - 1);
    } else {
        switch (self.children) {
            .slice => |slice| {
                self.item_count = @intCast(slice.len);
                self.cursor = @min(self.cursor - 1, slice.len - 1);
            },
            .builder => |builder| {
                // Save our current state
                const prev = self.cursor;
                // Decrement the cursor
                self.cursor -= 1;
                // Check the bounds, reversing until we get the last item
                while (builder.itemAtIdx(self.cursor, self.cursor) == null) {
                    self.cursor -|= 1;
                }
                // If we didn't change state, we don't redraw
                if (self.cursor == prev) {
                    return ctx.consumeEvent();
                }
            },
        }
    }

    // Reset scroll
    self.ensureScroll();
    return ctx.consumeAndRedraw();
}

// Only call when cursor state has changed, or we want to ensure the cursored item is in view
pub fn ensureScroll(self: *ScrollView) void {
    if (self.cursor <= self.scroll.top) {
        self.scroll.top = @intCast(self.cursor);
        self.scroll.vertical_offset = 0;
    } else {
        self.scroll.wants_cursor = true;
    }
}

/// Inserts children until add_height is < 0
fn insertChildren(
    self: *ScrollView,
    ctx: vxfw.DrawContext,
    builder: Builder,
    child_list: *std.ArrayList(vxfw.SubSurface),
    add_height: i17,
) Allocator.Error!void {
    assert(self.scroll.top > 0);
    self.scroll.top -= 1;
    var upheight = add_height;
    while (self.scroll.top >= 0) : (self.scroll.top -= 1) {
        // Get the child
        const child = builder.itemAtIdx(self.scroll.top, self.cursor) orelse break;

        const child_offset: u16 = if (self.draw_cursor) 2 else 0;
        const max_size = ctx.max.size();

        // Set up constraints. We let the child be the entire height if it wants
        const child_ctx = ctx.withConstraints(
            .{ .width = max_size.width - child_offset, .height = 0 },
            .{ .width = null, .height = null },
        );

        // Draw the child
        const surf = try child.draw(child_ctx);

        // Accumulate the height. Traversing backward so do this before setting origin
        upheight -= surf.size.height;

        // Insert the child to the beginning of the list
        const col_offset: i17 = if (self.draw_cursor) 2 else 0;
        try child_list.insert(0, .{
            .origin = .{ .col = col_offset - @as(i17, @intCast(self.scroll.left)), .row = upheight },
            .surface = surf,
            .z_index = 0,
        });

        // Break if we went past the top edge, or are the top item
        if (upheight <= 0 or self.scroll.top == 0) break;
    }

    // Our new offset is the "upheight"
    self.scroll.vertical_offset = upheight;

    // Reset origins if we overshot and put the top item too low
    if (self.scroll.top == 0 and upheight > 0) {
        self.scroll.vertical_offset = 0;
        var row: i17 = 0;
        for (child_list.items) |*child| {
            child.origin.row = row;
            row += child.surface.size.height;
        }
    }
    // Our new offset is the "upheight"
    self.scroll.vertical_offset = upheight;
}

fn totalHeight(list: *const std.ArrayList(vxfw.SubSurface)) usize {
    var result: usize = 0;
    for (list.items) |child| {
        result += child.surface.size.height;
    }
    return result;
}

fn drawBuilder(self: *ScrollView, ctx: vxfw.DrawContext, builder: Builder) Allocator.Error!vxfw.Surface {
    defer self.scroll.wants_cursor = false;

    // Get the size. asserts neither constraint is null
    const max_size = ctx.max.size();
    // Set up surface.
    var surface: vxfw.Surface = .{
        .size = max_size,
        .widget = self.widget(),
        .buffer = &.{},
        .children = &.{},
    };

    // Set state
    {
        // Assume we have more. We only know we don't after drawing
        self.scroll.has_more_vertical = true;
    }

    var child_list = std.ArrayList(vxfw.SubSurface).init(ctx.arena);

    // Accumulated height tracks how much height we have drawn. It's initial state is
    // -(scroll.vertical_offset + scroll.pending_lines) lines _above_ the surface top edge.
    // Example:
    // 1. Scroll up 3 lines:
    //      pending_lines = -3
    //      offset = 0
    //      accumulated_height = -(0 + -3) = 3;
    //      Our first widget is placed at row 3, we will need to fill this in after the draw
    // 2. Scroll up 3 lines, with an offset of 4
    //      pending_lines = -3
    //      offset = 4
    //      accumulated_height = -(4 + -3) = -1;
    //      Our first widget is placed at row -1
    // 3. Scroll down 3 lines:
    //      pending_lines = 3
    //      offset = 0
    //      accumulated_height = -(0 + 3) = -3;
    //      Our first widget is placed at row -3. It's possible it consumes the entire widget. We
    //      will check for this at the end and only include visible children
    var accumulated_height: i17 = -(self.scroll.vertical_offset + self.scroll.pending_lines);

    // We handled the pending scroll by assigning accumulated_height. Reset it's state
    self.scroll.pending_lines = 0;

    // Set the initial index for our downard loop. We do this here because we might modify
    // scroll.top before we traverse downward
    var i: usize = self.scroll.top;

    // If we are on the first item, and we have an upward scroll that consumed our offset, eg
    // accumulated_height > 0, we reset state here. We can't scroll up anymore so we set
    // accumulated_height to 0.
    if (accumulated_height > 0 and self.scroll.top == 0) {
        self.scroll.vertical_offset = 0;
        accumulated_height = 0;
    }

    // If we are offset downward, insert widgets to the front of the list before traversing downard
    if (accumulated_height > 0) {
        try self.insertChildren(ctx, builder, &child_list, accumulated_height);
        const last_child = child_list.items[child_list.items.len - 1];
        accumulated_height = last_child.origin.row + last_child.surface.size.height;
    }

    const child_offset: u16 = if (self.draw_cursor) 2 else 0;

    while (builder.itemAtIdx(i, self.cursor)) |child| {
        // Defer the increment
        defer i += 1;

        // Set up constraints. We let the child be the entire height if it wants
        const child_ctx = ctx.withConstraints(
            .{ .width = max_size.width - child_offset, .height = 0 },
            .{ .width = null, .height = null },
        );

        // Draw the child
        const surf = try child.draw(child_ctx);

        // Add the child surface to our list. It's offset from parent is the accumulated height
        try child_list.append(.{
            .origin = .{ .col = child_offset - @as(i17, @intCast(self.scroll.left)), .row = accumulated_height },
            .surface = surf,
            .z_index = 0,
        });

        // Accumulate the height
        accumulated_height += surf.size.height;

        if (self.scroll.wants_cursor and i < self.cursor)
            continue // continue if we want the cursor and haven't gotten there yet
        else if (accumulated_height >= max_size.height)
            break; // Break if we drew enough
    } else {
        // This branch runs if we ran out of items. Set our state accordingly
        self.scroll.has_more_vertical = false;
    }

    // If we've looped through all the items without hitting the end we check for one more item to
    // see if we just drew the last item on the bottom of the screen. If we just drew the last item
    // we can set `scroll.has_more` to false.
    if (self.scroll.has_more_vertical and accumulated_height <= max_size.height) {
        if (builder.itemAtIdx(i, self.cursor) == null) self.scroll.has_more_vertical = false;
    }

    var total_height: usize = totalHeight(&child_list);

    // If we reached the bottom, don't have enough height to fill the screen, and have room to add
    // more, then we add more until out of items or filled the space. This can happen on a resize
    if (!self.scroll.has_more_vertical and total_height < max_size.height and self.scroll.top > 0) {
        try self.insertChildren(ctx, builder, &child_list, @intCast(max_size.height - total_height));
        // Set the new total height
        total_height = totalHeight(&child_list);
    }

    if (self.draw_cursor and self.cursor >= self.scroll.top) blk: {
        // The index of the cursored widget in our child_list
        const cursored_idx: u32 = self.cursor - self.scroll.top;
        // Nothing to draw if our cursor is below our viewport
        if (cursored_idx >= child_list.items.len) break :blk;

        const sub = try ctx.arena.alloc(vxfw.SubSurface, 1);
        const child = child_list.items[cursored_idx];
        sub[0] = .{
            .origin = .{ .col = child_offset - @as(i17, @intCast(self.scroll.left)), .row = 0 },
            .surface = child.surface,
            .z_index = 0,
        };
        const cursor_surf = try vxfw.Surface.initWithChildren(
            ctx.arena,
            self.widget(),
            .{ .width = child_offset, .height = child.surface.size.height },
            sub,
        );
        for (0..cursor_surf.size.height) |row| {
            cursor_surf.writeCell(0, @intCast(row), self.cursor_indicator);
        }
        child_list.items[cursored_idx] = .{
            .origin = .{ .col = 0, .row = child.origin.row },
            .surface = cursor_surf,
            .z_index = 0,
        };
    }

    // If we want the cursor, we check that the cursored widget is fully in view. If it is too
    // large, we position it so that it is the top item with a 0 offset
    if (self.scroll.wants_cursor) {
        const cursored_idx: u32 = self.cursor - self.scroll.top;
        const sub = child_list.items[cursored_idx];
        // The bottom row of the cursored widget
        const bottom = sub.origin.row + sub.surface.size.height;
        if (bottom > max_size.height) {
            // Adjust the origin by the difference
            // anchor bottom
            var origin: i17 = max_size.height;
            var idx: usize = cursored_idx + 1;
            while (idx > 0) : (idx -= 1) {
                var child = child_list.items[idx - 1];
                origin -= child.surface.size.height;
                child.origin.row = origin;
                child_list.items[idx - 1] = child;
            }
        } else if (sub.surface.size.height >= max_size.height) {
            // TODO: handle when the child is larger than our height.
            // We need to change the max constraint to be optional sizes so that we can support
            // unbounded drawing in scrollable areas
            self.scroll.top = self.cursor;
            self.scroll.vertical_offset = 0;
            child_list.deinit();
            try child_list.append(.{
                .origin = .{ .col = 0 - @as(i17, @intCast(self.scroll.left)), .row = 0 },
                .surface = sub.surface,
                .z_index = 0,
            });
            total_height = sub.surface.size.height;
        }
    }

    // If we reached the bottom, we need to reset origins
    if (!self.scroll.has_more_vertical and total_height < max_size.height) {
        // anchor top
        assert(self.scroll.top == 0);
        self.scroll.vertical_offset = 0;
        var origin: i17 = 0;
        for (0..child_list.items.len) |idx| {
            var child = child_list.items[idx];
            child.origin.row = origin;
            origin += child.surface.size.height;
            child_list.items[idx] = child;
        }
    } else if (!self.scroll.has_more_vertical) {
        // anchor bottom
        var origin: i17 = max_size.height;
        var idx: usize = child_list.items.len;
        while (idx > 0) : (idx -= 1) {
            var child = child_list.items[idx - 1];
            origin -= child.surface.size.height;
            child.origin.row = origin;
            child_list.items[idx - 1] = child;
        }
    }

    // Reset horizontal scroll info.
    self.scroll.has_more_horizontal = false;
    for (child_list.items) |child| {
        if (child.surface.size.width -| self.scroll.left > max_size.width) {
            self.scroll.has_more_horizontal = true;
            break;
        }
    }

    var start: usize = 0;
    var end: usize = child_list.items.len;

    for (child_list.items, 0..) |child, idx| {
        if (child.origin.row <= 0 and child.origin.row + child.surface.size.height > 0) {
            start = idx;
            self.scroll.vertical_offset = -child.origin.row;
            self.scroll.top += @intCast(idx);
        }
        if (child.origin.row > max_size.height) {
            end = idx;
            break;
        }
    }

    surface.children = child_list.items;

    // Update last known height.
    // If the bits from total_height don't fit u8 we won't get the right value from @intCast or
    // @truncate so we check manually.
    self.last_height = if (total_height > 255) 255 else @intCast(total_height);

    return surface;
}

const SliceBuilder = struct {
    slice: []const vxfw.Widget,

    fn build(ptr: *const anyopaque, idx: usize, _: usize) ?vxfw.Widget {
        const self: *const SliceBuilder = @ptrCast(@alignCast(ptr));
        if (idx >= self.slice.len) return null;
        return self.slice[idx];
    }
};

test ScrollView {
    // Create child widgets
    const Text = @import("Text.zig");
    const abc: Text = .{ .text = "abc\n  def\n  ghi" };
    const def: Text = .{ .text = "def" };
    const ghi: Text = .{ .text = "ghi" };
    const jklmno: Text = .{ .text = "jkl\n mno" };
    //
    // 0 |abc|
    // 1 |  d|ef
    // 2 |  g|hi
    // 3 |def|
    // 4  ghi
    // 5  jkl
    // 6    mno

    // Create the scroll view
    const scroll_view: ScrollView = .{
        .wheel_scroll = 1, // Set wheel scroll to one
        .children = .{ .slice = &.{
            abc.widget(),
            def.widget(),
            ghi.widget(),
            jklmno.widget(),
        } },
    };

    // Boiler plate draw context
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ucd = try vaxis.Unicode.init(arena.allocator());
    vxfw.DrawContext.init(&ucd, .unicode);

    const scroll_widget = scroll_view.widget();
    const draw_ctx: vxfw.DrawContext = .{
        .arena = arena.allocator(),
        .min = .{},
        .max = .{ .width = 3, .height = 4 },
        .cell_size = .{ .width = 10, .height = 20 },
    };

    var surface = try scroll_widget.draw(draw_ctx);
    // ScrollView expands to max height and max width
    try std.testing.expectEqual(4, surface.size.height);
    try std.testing.expectEqual(3, surface.size.width);
    // We have 2 children, because only visible children appear as a surface
    try std.testing.expectEqual(2, surface.children.len);

    // ScrollView starts at the top and left.
    try std.testing.expectEqual(0, scroll_view.scroll.top);
    try std.testing.expectEqual(0, scroll_view.scroll.left);

    // With the widgets provided the scroll view should have both more content to scroll vertically
    // and horizontally.
    try std.testing.expectEqual(true, scroll_view.scroll.has_more_vertical);
    try std.testing.expectEqual(true, scroll_view.scroll.has_more_horizontal);

    var mouse_event: vaxis.Mouse = .{
        .col = 0,
        .row = 0,
        .button = .wheel_up,
        .mods = .{},
        .type = .press,
    };
    // Event handlers need a context
    var ctx: vxfw.EventContext = .{
        .cmds = std.ArrayList(vxfw.Command).init(std.testing.allocator),
    };
    defer ctx.cmds.deinit();

    try scroll_widget.handleEvent(&ctx, .{ .mouse = mouse_event });
    // Wheel up doesn't adjust the scroll
    try std.testing.expectEqual(0, scroll_view.scroll.top);
    try std.testing.expectEqual(0, scroll_view.scroll.vertical_offset);

    // Wheel right doesn't adjust the horizontal scroll
    mouse_event.button = .wheel_right;
    try scroll_widget.handleEvent(&ctx, .{ .mouse = mouse_event });
    try std.testing.expectEqual(0, scroll_view.scroll.left);

    // Scroll right with 'h' doesn't adjust the horizontal scroll
    try scroll_widget.handleEvent(&ctx, .{ .key_press = .{ .codepoint = 'h' } });
    try std.testing.expectEqual(0, scroll_view.scroll.left);

    // Scroll right with '<c-b>' doesn't adjust the horizontal scroll
    try scroll_widget.handleEvent(
        &ctx,
        .{ .key_press = .{ .codepoint = 'c', .mods = .{ .ctrl = true } } },
    );
    try std.testing.expectEqual(0, scroll_view.scroll.left);

    // === TEST SCROLL DOWN === //

    // Send a wheel down to scroll down one line
    mouse_event.button = .wheel_down;
    try scroll_widget.handleEvent(&ctx, .{ .mouse = mouse_event });
    // We have to draw the widget for scrolls to take effect
    surface = try scroll_widget.draw(draw_ctx);
    // 0  abc
    // 1 |  d|ef
    // 2 |  g|hi
    // 3 |def|
    // 4 |ghi|
    // 5  jkl
    // 6    mno
    // We should have gone down 1 line, and not changed our top widget
    try std.testing.expectEqual(0, scroll_view.scroll.top);
    try std.testing.expectEqual(1, scroll_view.scroll.vertical_offset);
    // One more widget has scrolled into view
    try std.testing.expectEqual(3, surface.children.len);

    // Send a 'j' to scroll down one more line.
    try scroll_widget.handleEvent(&ctx, .{ .key_press = .{ .codepoint = 'j' } });
    surface = try scroll_widget.draw(draw_ctx);
    // 0  abc
    // 1    def
    // 2 |  g|hi
    // 3 |def|
    // 4 |ghi|
    // 5 |jkl|
    // 6    mno
    // We should have gone down 1 line, and not changed our top widget
    try std.testing.expectEqual(0, scroll_view.scroll.top);
    try std.testing.expectEqual(2, scroll_view.scroll.vertical_offset);
    // One more widget has scrolled into view
    try std.testing.expectEqual(4, surface.children.len);

    // Send `<c-n> to scroll down one more line
    try scroll_widget.handleEvent(
        &ctx,
        .{ .key_press = .{ .codepoint = 'n', .mods = .{ .ctrl = true } } },
    );
    surface = try scroll_widget.draw(draw_ctx);
    // 0  abc
    // 1    def
    // 2    ghi
    // 3 |def|
    // 4 |ghi|
    // 5 |jkl|
    // 6 |  m|no
    // We should have gone down 1 line, which scrolls our top widget out of view
    try std.testing.expectEqual(1, scroll_view.scroll.top);
    try std.testing.expectEqual(0, scroll_view.scroll.vertical_offset);
    // The top widget has now scrolled out of view, but is still rendered out of view because of
    // how pending scroll events are handled.
    try std.testing.expectEqual(4, surface.children.len);

    // We've scrolled to the bottom.
    try std.testing.expectEqual(false, scroll_view.scroll.has_more_vertical);

    // Scroll down one more line, this shouldn't do anything.
    try scroll_widget.handleEvent(&ctx, .{ .mouse = mouse_event });
    surface = try scroll_widget.draw(draw_ctx);
    // 0  abc
    // 1    def
    // 2    ghi
    // 3 |def|
    // 4 |ghi|
    // 5 |jkl|
    // 6 |  m|no
    try std.testing.expectEqual(1, scroll_view.scroll.top);
    try std.testing.expectEqual(0, scroll_view.scroll.vertical_offset);
    // The top widget was scrolled out of view on the last render, so we should no longer be
    // drawing it right above the current view.
    try std.testing.expectEqual(3, surface.children.len);

    // We've scrolled to the bottom.
    try std.testing.expectEqual(false, scroll_view.scroll.has_more_vertical);

    // === TEST SCROLL UP === //

    mouse_event.button = .wheel_up;

    // Send mouse up, now the top widget is in view.
    try scroll_widget.handleEvent(&ctx, .{ .mouse = mouse_event });
    surface = try scroll_widget.draw(draw_ctx);
    // 0  abc
    // 1    def
    // 2 |  g|hi
    // 3 |def|
    // 4 |ghi|
    // 5 |jkl|
    // 6    mno
    try std.testing.expectEqual(0, scroll_view.scroll.top);
    try std.testing.expectEqual(2, scroll_view.scroll.vertical_offset);
    // The top widget was scrolled out of view on the last render, so we should no longer be
    // drawing it right above the current view.
    try std.testing.expectEqual(4, surface.children.len);

    // We've scrolled away from the bottom.
    try std.testing.expectEqual(true, scroll_view.scroll.has_more_vertical);

    // Send 'k' to scroll up, now the bottom widget should be out of view.
    try scroll_widget.handleEvent(&ctx, .{ .key_press = .{ .codepoint = 'k' } });
    surface = try scroll_widget.draw(draw_ctx);
    // 0  abc
    // 1 |  d|ef
    // 2 |  g|hi
    // 3 |def|
    // 4 |ghi|
    // 5  jkl
    // 6    mno
    try std.testing.expectEqual(0, scroll_view.scroll.top);
    try std.testing.expectEqual(1, scroll_view.scroll.vertical_offset);
    // The top widget was scrolled out of view on the last render, so we should no longer be
    // drawing it right above the current view.
    try std.testing.expectEqual(3, surface.children.len);

    // Send '<c-p>' to scroll up, now we should be at the top.
    try scroll_widget.handleEvent(
        &ctx,
        .{ .key_press = .{ .codepoint = 'p', .mods = .{ .ctrl = true } } },
    );
    surface = try scroll_widget.draw(draw_ctx);
    // 0 |abc|
    // 1 |  d|ef
    // 2 |  g|hi
    // 3 |def|
    // 4  ghi
    // 5  jkl
    // 6    mno
    try std.testing.expectEqual(0, scroll_view.scroll.top);
    try std.testing.expectEqual(0, scroll_view.scroll.vertical_offset);
    // The top widget was scrolled out of view on the last render, so we should no longer be
    // drawing it right above the current view.
    try std.testing.expectEqual(2, surface.children.len);

    // We should be at the top.
    try std.testing.expectEqual(0, scroll_view.scroll.top);
    // We should still have no horizontal scroll.
    try std.testing.expectEqual(0, scroll_view.scroll.left);

    // === TEST SCROLL LEFT - MOVES VIEW TO THE RIGHT === //

    mouse_event.button = .wheel_left;

    // Send `.wheel_left` to scroll the view to the right.
    try scroll_widget.handleEvent(&ctx, .{ .mouse = mouse_event });
    surface = try scroll_widget.draw(draw_ctx);
    // 0 a|bc |
    // 1  | de|f
    // 2  | gh|i
    // 3 d|ef |
    // 4  ghi
    // 5  jkl
    // 6    mno
    try std.testing.expectEqual(1, scroll_view.scroll.left);
    // The number of children should be just the top 2 widgets.
    try std.testing.expectEqual(2, surface.children.len);
    // There is still more to draw horizontally.
    try std.testing.expectEqual(true, scroll_view.scroll.has_more_horizontal);

    // Send `l` to scroll the view to the right.
    try scroll_widget.handleEvent(&ctx, .{ .key_press = .{ .codepoint = 'l' } });
    surface = try scroll_widget.draw(draw_ctx);
    // 0 ab|c  |
    // 1   |def|
    // 2   |ghi|
    // 3 de|f  |
    // 4  ghi
    // 5  jkl
    // 6    mno
    try std.testing.expectEqual(2, scroll_view.scroll.left);
    // The number of children should be just the top 2 widgets.
    try std.testing.expectEqual(2, surface.children.len);
    // There is nothing more to draw horizontally.
    try std.testing.expectEqual(false, scroll_view.scroll.has_more_horizontal);

    // Send `<c-f>` to scroll the view to the right, this should do nothing.
    try scroll_widget.handleEvent(
        &ctx,
        .{ .key_press = .{ .codepoint = 'f', .mods = .{ .ctrl = true } } },
    );
    surface = try scroll_widget.draw(draw_ctx);
    // 0 ab|c  |
    // 1   |def|
    // 2   |ghi|
    // 3 de|f  |
    // 4  ghi
    // 5  jkl
    // 6    mno
    try std.testing.expectEqual(2, scroll_view.scroll.left);
    // The number of children should be just the top 2 widgets.
    try std.testing.expectEqual(2, surface.children.len);
    // There is nothing more to draw horizontally.
    try std.testing.expectEqual(false, scroll_view.scroll.has_more_horizontal);

    // Send `.wheel_right` to scroll the view to the left.
    mouse_event.button = .wheel_right;
    try scroll_widget.handleEvent(&ctx, .{ .mouse = mouse_event });
    surface = try scroll_widget.draw(draw_ctx);
    // 0 a|bc |
    // 1  | de|f
    // 2  | gh|i
    // 3 d|ef |
    // 4  ghi
    // 5  jkl
    // 6    mno
    try std.testing.expectEqual(1, scroll_view.scroll.left);
    // The number of children should be just the top 2 widgets.
    try std.testing.expectEqual(2, surface.children.len);
    // There is still more to draw horizontally.
    try std.testing.expectEqual(true, scroll_view.scroll.has_more_horizontal);

    // Processing 2 or more events before drawing may produce overscroll, because we need to draw
    // the children to determine whether there's more horizontal scrolling available.
    try scroll_widget.handleEvent(
        &ctx,
        .{ .key_press = .{ .codepoint = 'f', .mods = .{ .ctrl = true } } },
    );
    try scroll_widget.handleEvent(&ctx, .{ .key_press = .{ .codepoint = 'l' } });
    surface = try scroll_widget.draw(draw_ctx);
    // 0 abc|   |
    // 1   d|ef |
    // 2   g|hi |
    // 3 def|   |
    // 4  ghi
    // 5  jkl
    // 6    mno
    try std.testing.expectEqual(3, scroll_view.scroll.left);
    // The number of children should be just the top 2 widgets.
    try std.testing.expectEqual(2, surface.children.len);
    // There is nothing more to draw horizontally.
    try std.testing.expectEqual(false, scroll_view.scroll.has_more_horizontal);

    // === TEST SCROLL RIGHT - MOVES VIEW TO THE LEFT === //

    // Send `.wheel_right` to scroll the view to the left.
    try scroll_widget.handleEvent(&ctx, .{ .mouse = mouse_event });
    surface = try scroll_widget.draw(draw_ctx);
    // 0 ab|c  |
    // 1   |def|
    // 2   |ghi|
    // 3 de|f  |
    // 4  ghi
    // 5  jkl
    // 6    mno
    try std.testing.expectEqual(2, scroll_view.scroll.left);
    // The number of children should be just the top 2 widgets.
    try std.testing.expectEqual(2, surface.children.len);
    // There is nothing more to draw horizontally.
    try std.testing.expectEqual(false, scroll_view.scroll.has_more_horizontal);

    // Send `h` to scroll the view to the left.
    try scroll_widget.handleEvent(&ctx, .{ .key_press = .{ .codepoint = 'h' } });
    surface = try scroll_widget.draw(draw_ctx);
    // 0 a|bc |
    // 1  | de|f
    // 2  | gh|i
    // 3 d|ef |
    // 4  ghi
    // 5  jkl
    // 6    mno
    try std.testing.expectEqual(1, scroll_view.scroll.left);
    // The number of children should be just the top 2 widgets.
    try std.testing.expectEqual(2, surface.children.len);
    // There is now more to draw horizontally.
    try std.testing.expectEqual(true, scroll_view.scroll.has_more_horizontal);

    // Send `<c-b>` to scroll the view to the left.
    try scroll_widget.handleEvent(
        &ctx,
        .{ .key_press = .{ .codepoint = 'b', .mods = .{ .ctrl = true } } },
    );
    surface = try scroll_widget.draw(draw_ctx);
    // 0 |abc|
    // 1 |  d|ef
    // 2 |  g|hi
    // 3 |def|
    // 4  ghi
    // 5  jkl
    // 6    mno
    try std.testing.expectEqual(0, scroll_view.scroll.left);
    // The number of children should be just the top 2 widgets.
    try std.testing.expectEqual(2, surface.children.len);
    // There is now more to draw horizontally.
    try std.testing.expectEqual(true, scroll_view.scroll.has_more_horizontal);

    // === TEST COMBINED HORIZONTAL AND VERTICAL SCROLL === //

    // Scroll 3 columns to the right and 2 rows down.
    mouse_event.button = .wheel_left;
    try scroll_widget.handleEvent(&ctx, .{ .mouse = mouse_event });
    try scroll_widget.handleEvent(&ctx, .{ .mouse = mouse_event });
    try scroll_widget.handleEvent(&ctx, .{ .mouse = mouse_event });
    mouse_event.button = .wheel_down;
    try scroll_widget.handleEvent(&ctx, .{ .mouse = mouse_event });
    try scroll_widget.handleEvent(&ctx, .{ .mouse = mouse_event });
    surface = try scroll_widget.draw(draw_ctx);
    // 0  abc
    // 1    def
    // 2    g|hi |
    // 3  def|   |
    // 4  ghi|   |
    // 5  jkl|   |
    // 6    mno
    try std.testing.expectEqual(3, scroll_view.scroll.left);
    try std.testing.expectEqual(0, scroll_view.scroll.top);
    try std.testing.expectEqual(2, scroll_view.scroll.vertical_offset);
    // Even though only 1 child is visible, we still draw all 4 children in the view.
    try std.testing.expectEqual(4, surface.children.len);
    // There is nothing more to draw horizontally.
    try std.testing.expectEqual(false, scroll_view.scroll.has_more_horizontal);
}

// @reykjalin found an issue on mac with ghostty where the scroll up and scroll down were uneven.
// Ghostty has high precision scrolling and sends a lot of wheel events for each tick
test "ScrollView: uneven scroll" {
    // Create child widgets
    const Text = @import("Text.zig");
    const zero: Text = .{ .text = "0" };
    const one: Text = .{ .text = "1" };
    const two: Text = .{ .text = "2" };
    const three: Text = .{ .text = "3" };
    const four: Text = .{ .text = "4" };
    const five: Text = .{ .text = "5" };
    const six: Text = .{ .text = "6" };
    // 0 |
    // 1 |
    // 2 |
    // 3 |
    // 4
    // 5
    // 6

    // Create the list view
    const scroll_view: ScrollView = .{
        .wheel_scroll = 1, // Set wheel scroll to one
        .children = .{ .slice = &.{
            zero.widget(),
            one.widget(),
            two.widget(),
            three.widget(),
            four.widget(),
            five.widget(),
            six.widget(),
        } },
    };

    // Boiler plate draw context
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ucd = try vaxis.Unicode.init(arena.allocator());
    vxfw.DrawContext.init(&ucd, .unicode);

    const scroll_widget = scroll_view.widget();
    const draw_ctx: vxfw.DrawContext = .{
        .arena = arena.allocator(),
        .min = .{},
        .max = .{ .width = 16, .height = 4 },
        .cell_size = .{ .width = 10, .height = 20 },
    };

    var surface = try scroll_widget.draw(draw_ctx);

    var mouse_event: vaxis.Mouse = .{
        .col = 0,
        .row = 0,
        .button = .wheel_up,
        .mods = .{},
        .type = .press,
    };
    // Event handlers need a context
    var ctx: vxfw.EventContext = .{
        .cmds = std.ArrayList(vxfw.Command).init(std.testing.allocator),
    };
    defer ctx.cmds.deinit();

    // Send a wheel down x 3
    mouse_event.button = .wheel_down;
    try scroll_widget.handleEvent(&ctx, .{ .mouse = mouse_event });
    try scroll_widget.handleEvent(&ctx, .{ .mouse = mouse_event });
    try scroll_widget.handleEvent(&ctx, .{ .mouse = mouse_event });
    // We have to draw the widget for scrolls to take effect
    surface = try scroll_widget.draw(draw_ctx);
    // 0
    // 1
    // 2
    // 3 |
    // 4 |
    // 5 |
    // 6 |
    try std.testing.expectEqual(3, scroll_view.scroll.top);
    try std.testing.expectEqual(0, scroll_view.scroll.vertical_offset);
    // The first time we draw again we still draw all 7 children due to how pending scroll events
    // work.
    try std.testing.expectEqual(7, surface.children.len);

    surface = try scroll_widget.draw(draw_ctx);
    // By drawing again without any pending events there are now only the 4 visible elements
    // rendered.
    try std.testing.expectEqual(4, surface.children.len);

    // Now wheel_up two times should move us two lines up
    mouse_event.button = .wheel_up;
    try scroll_widget.handleEvent(&ctx, .{ .mouse = mouse_event });
    try scroll_widget.handleEvent(&ctx, .{ .mouse = mouse_event });
    surface = try scroll_widget.draw(draw_ctx);
    try std.testing.expectEqual(1, scroll_view.scroll.top);
    try std.testing.expectEqual(0, scroll_view.scroll.vertical_offset);
    try std.testing.expectEqual(4, surface.children.len);
}

test "refAllDecls" {
    std.testing.refAllDecls(@This());
}
