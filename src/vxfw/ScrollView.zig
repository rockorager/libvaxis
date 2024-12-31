const std = @import("std");
const vaxis = @import("../main.zig");

const assert = std.debug.assert;

const Allocator = std.mem.Allocator;

const vxfw = @import("vxfw.zig");

const ScrollView = @This();

pub const Builder = struct {
    userdata: *const anyopaque,
    buildFn: *const fn (*const anyopaque, idx: usize, cursor: usize) ?vxfw.Widget,

    inline fn itemAtIdx(self: Builder, idx: usize, cursor: usize) ?vxfw.Widget {
        return self.buildFn(self.userdata, idx, cursor);
    }
};

pub const Source = union(enum) {
    slice: []const vxfw.Widget,
    builder: Builder,
};

const Scroll = struct {
    /// Index of the first fully-in-view widget
    top: u32 = 0,
    /// Line offset within the top widget.
    offset: i17 = 0,
    /// Pending scroll amount
    pending_lines: i17 = 0,
    /// If there is more room to scroll down
    has_more: bool = true,
    /// The cursor must be in the viewport
    wants_cursor: bool = false,

    pub fn linesDown(self: *Scroll, n: u8) bool {
        if (!self.has_more) return false;
        self.pending_lines += n;
        return true;
    }

    pub fn linesUp(self: *Scroll, n: u8) bool {
        if (self.top == 0 and self.offset == 0) return false;
        self.pending_lines -= @intCast(n);
        return true;
    }
};

const cursor_indicator: vaxis.Cell = .{ .char = .{ .grapheme = "▐", .width = 1 } };

children: Source,
cursor: u32 = 0,
/// When true, the widget will draw a cursor next to the widget which has the cursor
draw_cursor: bool = true,
/// Lines to scroll for a mouse wheel
wheel_scroll: u8 = 3,
/// Set this if the exact item count is known.
item_count: ?u32 = null,
/// When true, the widget will draw horizontal and vertical scrollbars on the right and bottom
/// sides of the contained widget.
draw_scrollbars: bool = true,

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
                    ctx.consumeAndRedraw();
            }
            if (mouse.button == .wheel_down) {
                if (self.scroll.linesDown(self.wheel_scroll))
                    ctx.consumeAndRedraw();
            }
        },
        .key_press => |key| {
            if (key.matches(vaxis.Key.down, .{})) {
                return self.nextItem(ctx);
            }
            if (key.matches(vaxis.Key.up, .{})) {
                return self.prevItem(ctx);
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
        self.scroll.offset = 0;
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
            .{ .width = max_size.width - 1 - child_offset, .height = 0 },
            .{ .width = max_size.width - 1 - child_offset, .height = null },
        );

        // Draw the child
        const surf = try child.draw(child_ctx);

        // Accumulate the height. Traversing backward so do this before setting origin
        upheight -= surf.size.height;

        // Insert the child to the beginning of the list
        try child_list.insert(0, .{
            .origin = .{ .col = if (self.draw_cursor) 2 else 0, .row = upheight },
            .surface = surf,
            .z_index = 0,
        });

        // Break if we went past the top edge, or are the top item
        if (upheight <= 0 or self.scroll.top == 0) break;
    }

    // Our new offset is the "upheight"
    self.scroll.offset = upheight;

    // Reset origins if we overshot and put the top item too low
    if (self.scroll.top == 0 and upheight > 0) {
        self.scroll.offset = 0;
        var row: i17 = 0;
        for (child_list.items) |*child| {
            child.origin.row = row;
            row += child.surface.size.height;
        }
    }
    // Our new offset is the "upheight"
    self.scroll.offset = upheight;
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
        surface.focusable = true;
        // Assume we have more. We only know we don't after drawing
        self.scroll.has_more = true;
    }

    var child_list = std.ArrayList(vxfw.SubSurface).init(ctx.arena);

    // Accumulated height tracks how much height we have drawn. It's initial state is
    // (scroll.offset + scroll.pending_lines) lines _above_ the surface top edge.
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
    var accumulated_height: i17 = -(self.scroll.offset + self.scroll.pending_lines);

    // We handled the pending scroll by assigning accumulated_height. Reset it's state
    self.scroll.pending_lines = 0;

    // Set the initial index for our downard loop. We do this here because we might modify
    // scroll.top before we traverse downward
    var i: usize = self.scroll.top;

    // If we are on the first item, and we have an upward scroll that consumed our offset, eg
    // accumulated_height > 0, we reset state here. We can't scroll up anymore so we set
    // accumulated_height to 0.
    if (accumulated_height > 0 and self.scroll.top == 0) {
        self.scroll.offset = 0;
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
            .{ .width = max_size.width - 1 - child_offset, .height = 0 },
            .{ .width = max_size.width - 1 - child_offset, .height = null },
        );

        // Draw the child
        var surf = try child.draw(child_ctx);
        // We set the child to non-focusable so that we can manage where the keyevents go
        surf.focusable = false;

        // Add the child surface to our list. It's offset from parent is the accumulated height
        try child_list.append(.{
            .origin = .{ .col = child_offset, .row = accumulated_height },
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
        self.scroll.has_more = false;
    }

    // If we've looped through all the items without hitting the end we check for one more item to
    // see if we just drew the last item on the bottom of the screen. If we just drew the last item
    // we can set `scroll.has_more` to false.
    if (self.scroll.has_more) {
        if (builder.itemAtIdx(i, self.cursor) == null) self.scroll.has_more = false;
    }

    var total_height: usize = totalHeight(&child_list);

    // If we reached the bottom, don't have enough height to fill the screen, and have room to add
    // more, then we add more until out of items or filled the space. This can happen on a resize
    if (!self.scroll.has_more and total_height < max_size.height and self.scroll.top > 0) {
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
            .origin = .{ .col = child_offset, .row = 0 },
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
            cursor_surf.writeCell(0, @intCast(row), cursor_indicator);
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
            self.scroll.offset = 0;
            child_list.deinit();
            try child_list.append(.{
                .origin = .{ .col = 0, .row = 0 },
                .surface = sub.surface,
                .z_index = 0,
            });
            total_height = sub.surface.size.height;
        }
    }

    // If we reached the bottom, we need to reset origins
    if (!self.scroll.has_more and total_height < max_size.height) {
        // anchor top
        assert(self.scroll.top == 0);
        self.scroll.offset = 0;
        var origin: i17 = 0;
        for (0..child_list.items.len) |idx| {
            var child = child_list.items[idx];
            child.origin.row = origin;
            origin += child.surface.size.height;
            child_list.items[idx] = child;
        }
    } else if (!self.scroll.has_more) {
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

    var start: usize = 0;
    var end: usize = child_list.items.len;

    for (child_list.items, 0..) |child, idx| {
        if (child.origin.row <= 0 and child.origin.row + child.surface.size.height > 0) {
            start = idx;
            self.scroll.offset = -child.origin.row;
            self.scroll.top += @intCast(idx);
        }
        if (child.origin.row > max_size.height) {
            end = idx;
            break;
        }
    }

    var children_with_scrollbar = std.ArrayList(vxfw.SubSurface).init(ctx.arena);

    const num_children_rendered: usize = @max(end - start, 1);

    const estimated_total_height = height: {
        if (self.item_count) |count|
            break :height (count * total_height) / num_children_rendered;

        var child_count: usize = 0;
        while (builder.itemAtIdx(child_count, self.cursor)) |_| {
            child_count += 1;
        }

        break :height (child_count * total_height) / num_children_rendered;
    };

    // We only show the scrollbar if the content height is larger than the widget height and
    // drawing the scrollbars is requested.
    if (self.draw_scrollbars and estimated_total_height > max_size.height) {
        // The scroll bar surface needs to span the entire widget so dragging the scroll bar can work
        // even if the mouse leaves the scrollbar itself.
        const scroll_bar = try vxfw.Surface.init(ctx.arena, self.widget(), max_size);

        const widget_height_f: f32 = @floatFromInt(max_size.height);
        const total_height_f: f32 = @floatFromInt(estimated_total_height);
        const scroll_top_f: f32 = @floatFromInt(self.scroll.top);

        const scroll_bar_height_f: f32 = widget_height_f * (widget_height_f / total_height_f);
        const scroll_bar_height: u32 = @intFromFloat(scroll_bar_height_f);

        const scroll_bar_top_f: f32 = widget_height_f * (scroll_top_f / total_height_f);
        const scroll_bar_top: u32 = if (self.scroll.has_more)
            @intFromFloat(scroll_bar_top_f)
        else if (self.scroll.top == 0)
            0
        else
            max_size.height - scroll_bar_height;

        // We need the scroll bar to be at least 1 row high so it's visible.
        const end_row = scroll_bar_top + @max(scroll_bar_height, 1);
        for (scroll_bar_top..end_row) |row| {
            scroll_bar.writeCell(max_size.width - 1, @intCast(row), cursor_indicator);
        }

        try children_with_scrollbar.append(.{
            .surface = scroll_bar,
            .origin = .{ .row = 0, .col = 0 },
        });
    }

    try children_with_scrollbar.appendSlice(child_list.items[start..end]);

    surface.children = children_with_scrollbar.items;
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
    // 0 |*abc
    // 1 |   def
    // 2 |   ghi
    // 3 | def
    // 4   ghi
    // 5   jkl
    // 6     mno

    // Create the list view
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
        .max = .{ .width = 16, .height = 4 },
    };

    var surface = try scroll_widget.draw(draw_ctx);
    // ScrollView expands to max height and max width
    try std.testing.expectEqual(4, surface.size.height);
    try std.testing.expectEqual(16, surface.size.width);
    // We have 3 children, because only visible children appear as a surface, abc, def, and
    // scroll bar.
    try std.testing.expectEqual(3, surface.children.len);

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
    try std.testing.expectEqual(0, scroll_view.scroll.offset);

    // Send a wheel down
    mouse_event.button = .wheel_down;
    try scroll_widget.handleEvent(&ctx, .{ .mouse = mouse_event });
    // We have to draw the widget for scrolls to take effect
    surface = try scroll_widget.draw(draw_ctx);
    // 0  *abc
    // 1 |   def
    // 2 |   ghi
    // 3 | def
    // 4 | ghi
    // 5   jkl
    // 6     mno
    // We should have gone down 1 line, and not changed our top widget
    try std.testing.expectEqual(0, scroll_view.scroll.top);
    try std.testing.expectEqual(1, scroll_view.scroll.offset);
    // One more widget has scrolled into view
    try std.testing.expectEqual(4, surface.children.len);

    // Scroll down two more lines
    try scroll_widget.handleEvent(&ctx, .{ .mouse = mouse_event });
    try scroll_widget.handleEvent(&ctx, .{ .mouse = mouse_event });
    surface = try scroll_widget.draw(draw_ctx);
    // 0  *abc
    // 1     def
    // 2     ghi
    // 3 | def
    // 4 | ghi
    // 5 | jkl
    // 6 |   mno
    // We should have gone down 2 lines, which scrolls our top widget out of view
    try std.testing.expectEqual(1, scroll_view.scroll.top);
    try std.testing.expectEqual(0, scroll_view.scroll.offset);
    try std.testing.expectEqual(4, surface.children.len);

    // Scroll down again. We shouldn't advance anymore since we are at the bottom
    try scroll_widget.handleEvent(&ctx, .{ .mouse = mouse_event });
    surface = try scroll_widget.draw(draw_ctx);
    try std.testing.expectEqual(1, scroll_view.scroll.top);
    try std.testing.expectEqual(0, scroll_view.scroll.offset);
    try std.testing.expectEqual(4, surface.children.len);

    // Mouse wheel events don't change the cursor position. Let's press "escape" to reset the
    // viewport and bring our cursor into view
    try scroll_widget.handleEvent(&ctx, .{ .key_press = .{ .codepoint = vaxis.Key.escape } });
    surface = try scroll_widget.draw(draw_ctx);
    try std.testing.expectEqual(0, scroll_view.scroll.top);
    try std.testing.expectEqual(0, scroll_view.scroll.offset);
    try std.testing.expectEqual(3, surface.children.len);

    // Cursor down
    try scroll_widget.handleEvent(&ctx, .{ .key_press = .{ .codepoint = vaxis.Key.down } });
    surface = try scroll_widget.draw(draw_ctx);
    // 0 | abc
    // 1 |   def
    // 2 |   ghi
    // 3 |*def
    // 4   ghi
    // 5   jkl
    // 6     mno
    // Scroll doesn't change
    try std.testing.expectEqual(0, scroll_view.scroll.top);
    try std.testing.expectEqual(0, scroll_view.scroll.offset);
    try std.testing.expectEqual(3, surface.children.len);
    try std.testing.expectEqual(1, scroll_view.cursor);

    // Cursor down
    try scroll_widget.handleEvent(&ctx, .{ .key_press = .{ .codepoint = vaxis.Key.down } });
    surface = try scroll_widget.draw(draw_ctx);
    // 0   abc
    // 1 |   def
    // 2 |   ghi
    // 3 | def
    // 4 |*ghi
    // 5   jkl
    // 6     mno
    // Scroll advances one row
    try std.testing.expectEqual(0, scroll_view.scroll.top);
    try std.testing.expectEqual(1, scroll_view.scroll.offset);
    try std.testing.expectEqual(4, surface.children.len);
    try std.testing.expectEqual(2, scroll_view.cursor);

    // Cursor down
    try scroll_widget.handleEvent(&ctx, .{ .key_press = .{ .codepoint = vaxis.Key.down } });
    surface = try scroll_widget.draw(draw_ctx);
    // 0   abc
    // 1     def
    // 2     ghi
    // 3 | def
    // 4 | ghi
    // 5 |*jkl
    // 6 |   mno
    // We are cursored onto the last item. The entire last item comes into view, effectively
    // advancing the scroll by 2
    try std.testing.expectEqual(1, scroll_view.scroll.top);
    try std.testing.expectEqual(0, scroll_view.scroll.offset);
    try std.testing.expectEqual(4, surface.children.len);
    try std.testing.expectEqual(3, scroll_view.cursor);
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
    try std.testing.expectEqual(0, scroll_view.scroll.offset);
    try std.testing.expectEqual(5, surface.children.len);

    // Now wheel_up two times should move us two lines up
    mouse_event.button = .wheel_up;
    try scroll_widget.handleEvent(&ctx, .{ .mouse = mouse_event });
    try scroll_widget.handleEvent(&ctx, .{ .mouse = mouse_event });
    surface = try scroll_widget.draw(draw_ctx);
    try std.testing.expectEqual(1, scroll_view.scroll.top);
    try std.testing.expectEqual(0, scroll_view.scroll.offset);
    try std.testing.expectEqual(5, surface.children.len);
}

test "refAllDecls" {
    std.testing.refAllDecls(@This());
}
