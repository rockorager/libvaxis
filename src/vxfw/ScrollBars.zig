const std = @import("std");
const vaxis = @import("../main.zig");
const vxfw = @import("vxfw.zig");

const Allocator = std.mem.Allocator;

const ScrollBars = @This();

/// The ScrollBars widget must contain a ScrollView widget. The scroll bars drawn will be for the
/// scroll view contained in the ScrollBars widget.
scroll_view: vxfw.ScrollView,
/// If `true` a horizontal scroll bar will be drawn. Set to `false` to hide the horizontal scroll
/// bar. Defaults to `true`.
draw_horizontal_scrollbar: bool = true,
/// If `true` a vertical scroll bar will be drawn. Set to `false` to hide the vertical scroll bar.
/// Defaults to `true`.
draw_vertical_scrollbar: bool = true,
/// The estimated height of all the content in the ScrollView. When provided this height will be
/// used to calculate the size of the scrollbar's thumb. If this is not provided the widget will
/// make a best effort estimate of the size of the thumb using the number of elements rendered at
/// any given time. This will cause inconsistent thumb sizes - and possibly inconsistent
/// positioning - if different elements in the ScrollView have different heights. For the best user
/// experience, providing this estimate is strongly recommended.
///
/// Note that this doesn't necessarily have to be an accurate estimate and the tolerance for larger
/// views is quite forgiving, especially if you overshoot the estimate.
estimated_content_height: ?u32 = null,
/// The estimated width of all the content in the ScrollView. When provided this width will be  used
/// to calculate the size of the scrollbar's thumb. If this is not provided the widget will  make a
/// best effort estimate of the size of the thumb using the width of  the elements rendered at  any
/// given time. This will cause inconsistent thumb sizes - and possibly inconsistent  positioning -
/// if different elements in the ScrollView have different widths. For the best user  experience,
/// providing this estimate is strongly recommended.
///
/// Note that this doesn't necessarily have to be
/// an accurate estimate and the tolerance for larger  views is quite forgiving, especially if you
/// overshoot the estimate.
estimated_content_width: ?u32 = null,
/// The cell drawn for the vertical scroll thumb. Replace this to customize the scroll thumb. Must
/// have a 1 column width.
vertical_scrollbar_thumb: vaxis.Cell = .{ .char = .{ .grapheme = "▐", .width = 1 } },
/// The cell drawn for the vertical scroll thumb while it's being hovered. Replace this to customize
/// the scroll thumb. Must have a 1 column width.
vertical_scrollbar_hover_thumb: vaxis.Cell = .{ .char = .{ .grapheme = "█", .width = 1 } },
/// The cell drawn for the vertical scroll thumb while it's being dragged by the mouse. Replace this
/// to customize the scroll thumb. Must have a 1 column width.
vertical_scrollbar_drag_thumb: vaxis.Cell = .{
    .char = .{ .grapheme = "█", .width = 1 },
    .style = .{ .fg = .{ .index = 4 } },
},
/// The cell drawn for the vertical scroll thumb. Replace this to customize the scroll thumb. Must
/// have a 1 column width.
horizontal_scrollbar_thumb: vaxis.Cell = .{ .char = .{ .grapheme = "▃", .width = 1 } },
/// The cell drawn for the horizontal scroll thumb while it's being hovered. Replace this to
/// customize the scroll thumb. Must have a 1 column width.
horizontal_scrollbar_hover_thumb: vaxis.Cell = .{ .char = .{ .grapheme = "█", .width = 1 } },
/// The cell drawn for the horizontal scroll thumb while it's being dragged by the mouse. Replace
/// this to customize the scroll thumb. Must have a 1 column width.
horizontal_scrollbar_drag_thumb: vaxis.Cell = .{
    .char = .{ .grapheme = "█", .width = 1 },
    .style = .{ .fg = .{ .index = 4 } },
},

/// You should not change this variable, treat it as private to the implementation. Used to track
/// the size of the widget so we can locate scroll bars for mouse interaction.
last_frame_size: vxfw.Size = .{ .width = 0, .height = 0 },
/// You should not change this variable, treat it as private to the implementation. Used to track
/// the width of the content so we map horizontal scroll thumb position to view position.
last_frame_max_content_width: u32 = 0,
/// You should not change this variable, treat it as private to the implementation. Used to track
/// the position of the mouse relative to the scroll thumb for mouse interaction.
mouse_offset_into_thumb: u8 = 0,

/// You should not change this variable, treat it as private to the implementation. Used to track
/// the position of the scroll thumb for mouse interaction.
vertical_thumb_top_row: u32 = 0,
/// You should not change this variable, treat it as private to the implementation. Used to track
/// the position of the scroll thumb for mouse interaction.
vertical_thumb_bottom_row: u32 = 0,
/// You should not change this variable, treat it as private to the implementation. Used to track
/// whether the scroll thumb is hovered or not so we can set the right hover style for the thumb.
is_hovering_vertical_thumb: bool = false,
/// You should not change this variable, treat it as private to the implementation. Used to track
/// whether the thumb is currently being dragged, which is important to allowing the mouse to leave
/// the scroll thumb while it's being dragged.
is_dragging_vertical_thumb: bool = false,

/// You should not change this variable, treat it as private to the implementation. Used to track
/// the position of the scroll thumb for mouse interaction.
horizontal_thumb_start_col: u32 = 0,
/// You should not change this variable, treat it as private to the implementation. Used to track
/// the position of the scroll thumb for mouse interaction.
horizontal_thumb_end_col: u32 = 0,
/// You should not change this variable, treat it as private to the implementation. Used to track
/// whether the scroll thumb is hovered or not so we can set the right hover style for the thumb.
is_hovering_horizontal_thumb: bool = false,
/// You should not change this variable, treat it as private to the implementation. Used to track
/// whether the thumb is currently being dragged, which is important to allowing the mouse to leave
/// the scroll thumb while it's being dragged.
is_dragging_horizontal_thumb: bool = false,

pub fn widget(self: *const ScrollBars) vxfw.Widget {
    return .{
        .userdata = @constCast(self),
        .eventHandler = typeErasedEventHandler,
        .captureHandler = typeErasedCaptureHandler,
        .drawFn = typeErasedDrawFn,
    };
}

fn typeErasedEventHandler(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
    const self: *ScrollBars = @ptrCast(@alignCast(ptr));
    return self.handleEvent(ctx, event);
}
fn typeErasedCaptureHandler(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
    const self: *ScrollBars = @ptrCast(@alignCast(ptr));
    return self.handleCapture(ctx, event);
}

fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
    const self: *ScrollBars = @ptrCast(@alignCast(ptr));
    return self.draw(ctx);
}

pub fn handleCapture(self: *ScrollBars, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
    switch (event) {
        .mouse => |mouse| {
            if (self.is_dragging_vertical_thumb) {
                // Stop dragging the thumb when the mouse is released.
                if (mouse.type == .release and
                    mouse.button == .left and
                    self.is_dragging_vertical_thumb)
                {
                    // If we just let the scroll thumb go after dragging we need to make sure we
                    // redraw so the right style is immediately applied to the thumb.
                    if (self.is_dragging_vertical_thumb) {
                        self.is_dragging_vertical_thumb = false;
                        ctx.redraw = true;
                    }

                    const is_mouse_over_vertical_thumb =
                        mouse.col == self.last_frame_size.width -| 1 and
                        mouse.row >= self.vertical_thumb_top_row and
                        mouse.row < self.vertical_thumb_bottom_row;

                    // If we're not hovering the scroll bar after letting it go, we should trigger a
                    // redraw so it goes back to its narrow, non-active, state immediately.
                    if (!is_mouse_over_vertical_thumb) {
                        self.is_hovering_vertical_thumb = false;
                        ctx.redraw = true;
                    }

                    // No need to redraw yet, but we must consume the event so ending the drag
                    // action doesn't trigger some other event handler.
                    return ctx.consumeEvent();
                }

                // Process dragging the vertical thumb.
                if (mouse.type == .drag) {
                    // Make sure we consume the event if we're currently dragging the mouse so other
                    // events aren't sent in the mean time.
                    ctx.consumeEvent();

                    // New scroll thumb position.
                    const new_thumb_top = mouse.row -| self.mouse_offset_into_thumb;

                    // If the new thumb position is at the top we know we've scrolled to the top of
                    // the scroll view.
                    if (new_thumb_top == 0) {
                        self.scroll_view.scroll.top = 0;
                        return ctx.consumeAndRedraw();
                    }

                    const new_thumb_top_f: f32 = @floatFromInt(new_thumb_top);
                    const widget_height_f: f32 = @floatFromInt(self.last_frame_size.height);
                    const total_num_children_f: f32 = count: {
                        if (self.scroll_view.item_count) |c| break :count @floatFromInt(c);

                        switch (self.scroll_view.children) {
                            .slice => |slice| break :count @floatFromInt(slice.len),
                            .builder => |builder| {
                                var counter: usize = 0;
                                while (builder.itemAtIdx(counter, self.scroll_view.cursor)) |_|
                                    counter += 1;

                                break :count @floatFromInt(counter);
                            },
                        }
                    };

                    const new_top_child_idx_f =
                        new_thumb_top_f *
                        total_num_children_f / widget_height_f;
                    self.scroll_view.scroll.top = @intFromFloat(new_top_child_idx_f);

                    return ctx.consumeAndRedraw();
                }
            }

            if (self.is_dragging_horizontal_thumb) {
                // Stop dragging the thumb when the mouse is released.
                if (mouse.type == .release and
                    mouse.button == .left and
                    self.is_dragging_horizontal_thumb)
                {
                    // If we just let the scroll thumb go after dragging we need to make sure we
                    // redraw so the right style is immediately applied to the thumb.
                    if (self.is_dragging_horizontal_thumb) {
                        self.is_dragging_horizontal_thumb = false;
                        ctx.redraw = true;
                    }

                    const is_mouse_over_horizontal_thumb =
                        mouse.row == self.last_frame_size.height -| 1 and
                        mouse.col >= self.horizontal_thumb_start_col and
                        mouse.col < self.horizontal_thumb_end_col;

                    // If we're not hovering the scroll bar after letting it go, we should trigger a
                    // redraw so it goes back to its narrow, non-active, state immediately.
                    if (!is_mouse_over_horizontal_thumb) {
                        self.is_hovering_horizontal_thumb = false;
                        ctx.redraw = true;
                    }

                    // No need to redraw yet, but we must consume the event so ending the drag
                    // action doesn't trigger some other event handler.
                    return ctx.consumeEvent();
                }

                // Process dragging the horizontal thumb.
                if (mouse.type == .drag) {
                    // Make sure we consume the event if we're currently dragging the mouse so other
                    // events aren't sent in the mean time.
                    ctx.consumeEvent();

                    // New scroll thumb position.
                    const new_thumb_col_start = mouse.col -| self.mouse_offset_into_thumb;

                    // If the new thumb position is at the horizontal beginning of the current view
                    // we know we've scrolled to the  beginning of the scroll view.
                    if (new_thumb_col_start == 0) {
                        self.scroll_view.scroll.left = 0;
                        return ctx.consumeAndRedraw();
                    }

                    const new_thumb_col_start_f: f32 = @floatFromInt(new_thumb_col_start);
                    const widget_width_f: f32 = @floatFromInt(self.last_frame_size.width);

                    const max_content_width_f: f32 =
                        @floatFromInt(self.last_frame_max_content_width);

                    const new_view_col_start_f =
                        new_thumb_col_start_f * max_content_width_f / widget_width_f;
                    const new_view_col_start: u32 = @intFromFloat(@ceil(new_view_col_start_f));

                    self.scroll_view.scroll.left =
                        @min(new_view_col_start, self.last_frame_max_content_width);

                    return ctx.consumeAndRedraw();
                }
            }
        },
        else => {},
    }
}

pub fn handleEvent(self: *ScrollBars, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
    switch (event) {
        .mouse => |mouse| {
            // 1. Process vertical scroll thumb hover.

            const is_mouse_over_vertical_thumb =
                mouse.col == self.last_frame_size.width -| 1 and
                mouse.row >= self.vertical_thumb_top_row and
                mouse.row < self.vertical_thumb_bottom_row;

            // Make sure we only update the state and redraw when it's necessary.
            if (!self.is_hovering_vertical_thumb and is_mouse_over_vertical_thumb) {
                self.is_hovering_vertical_thumb = true;
                ctx.redraw = true;
            } else if (self.is_hovering_vertical_thumb and !is_mouse_over_vertical_thumb) {
                self.is_hovering_vertical_thumb = false;
                ctx.redraw = true;
            }

            const did_start_dragging_vertical_thumb = is_mouse_over_vertical_thumb and
                mouse.type == .press and mouse.button == .left;

            if (did_start_dragging_vertical_thumb) {
                self.is_dragging_vertical_thumb = true;
                self.mouse_offset_into_thumb = @intCast(mouse.row -| self.vertical_thumb_top_row);

                // No need to redraw yet, but we must consume the event.
                return ctx.consumeEvent();
            }

            // 2. Process horizontal scroll thumb hover.

            const is_mouse_over_horizontal_thumb =
                mouse.row == self.last_frame_size.height -| 1 and
                mouse.col >= self.horizontal_thumb_start_col and
                mouse.col < self.horizontal_thumb_end_col;

            // Make sure we only update the state and redraw when it's necessary.
            if (!self.is_hovering_horizontal_thumb and is_mouse_over_horizontal_thumb) {
                self.is_hovering_horizontal_thumb = true;
                ctx.redraw = true;
            } else if (self.is_hovering_horizontal_thumb and !is_mouse_over_horizontal_thumb) {
                self.is_hovering_horizontal_thumb = false;
                ctx.redraw = true;
            }

            const did_start_dragging_horizontal_thumb = is_mouse_over_horizontal_thumb and
                mouse.type == .press and mouse.button == .left;

            if (did_start_dragging_horizontal_thumb) {
                self.is_dragging_horizontal_thumb = true;
                self.mouse_offset_into_thumb = @intCast(
                    mouse.col -| self.horizontal_thumb_start_col,
                );

                // No need to redraw yet, but we must consume the event.
                return ctx.consumeEvent();
            }
        },
        .mouse_leave => self.is_dragging_vertical_thumb = false,
        else => {},
    }
}

pub fn draw(self: *ScrollBars, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
    var children = std.ArrayList(vxfw.SubSurface).init(ctx.arena);

    // 1. If we're not drawing the scrollbars we can just draw the ScrollView directly.

    if (!self.draw_vertical_scrollbar and !self.draw_horizontal_scrollbar) {
        try children.append(.{
            .origin = .{ .row = 0, .col = 0 },
            .surface = try self.scroll_view.draw(ctx),
        });

        return .{
            .size = ctx.max.size(),
            .widget = self.widget(),
            .buffer = &.{},
            .children = children.items,
        };
    }

    // 2. Otherwise we can draw the scrollbars.

    const max = ctx.max.size();
    self.last_frame_size = max;

    // 3. Draw the scroll view itself.

    const scroll_view_surface = try self.scroll_view.draw(ctx.withConstraints(
        ctx.min,
        .{
            // We make sure to make room for the scrollbars if required.
            .width = max.width -| @intFromBool(self.draw_vertical_scrollbar),
            .height = max.height -| @intFromBool(self.draw_horizontal_scrollbar),
        },
    ));

    try children.append(.{
        .origin = .{ .row = 0, .col = 0 },
        .surface = scroll_view_surface,
    });

    // 4. Draw the vertical scroll bar.

    if (self.draw_vertical_scrollbar) vertical: {
        // If we can't scroll, then there's no need to draw the scroll bar.
        if (self.scroll_view.scroll.top == 0 and !self.scroll_view.scroll.has_more_vertical)
            break :vertical;

        // To draw the vertical scrollbar we need to know how big the scroll bar thumb should be.
        // If we've been provided with an estimated height we use that to figure out how big the
        // thumb should be, otherwise we estimate the size based on how many of the children were
        // actually drawn in the ScrollView.

        const widget_height_f: f32 = @floatFromInt(scroll_view_surface.size.height);
        const total_num_children_f: f32 = count: {
            if (self.scroll_view.item_count) |c| break :count @floatFromInt(c);

            switch (self.scroll_view.children) {
                .slice => |slice| break :count @floatFromInt(slice.len),
                .builder => |builder| {
                    var counter: usize = 0;
                    while (builder.itemAtIdx(counter, self.scroll_view.cursor)) |_|
                        counter += 1;

                    break :count @floatFromInt(counter);
                },
            }
        };

        const thumb_height: u16 = height: {
            // If we know the height, we can use the height of the current view to determine the
            // size of the thumb.
            if (self.estimated_content_height) |h| {
                const content_height_f: f32 = @floatFromInt(h);

                const thumb_height_f = widget_height_f * widget_height_f / content_height_f;
                break :height @intFromFloat(@max(thumb_height_f, 1));
            }

            // Otherwise we estimate the size of the thumb based on the number of child elements
            // drawn in the scroll view, and the number of total child elements.

            const num_children_rendered_f: f32 = @floatFromInt(scroll_view_surface.children.len);

            const thumb_height_f = widget_height_f * num_children_rendered_f / total_num_children_f;
            break :height @intFromFloat(@max(thumb_height_f, 1));
        };

        // We also need to know the position of the thumb in the scroll bar. To find that we use the
        // index of the top-most child widget rendered in the ScrollView.

        const thumb_top: u32 = if (self.scroll_view.scroll.top == 0)
            0
        else if (self.scroll_view.scroll.has_more_vertical) pos: {
            const top_child_idx_f: f32 = @floatFromInt(self.scroll_view.scroll.top);
            const thumb_top_f = widget_height_f * top_child_idx_f / total_num_children_f;

            break :pos @intFromFloat(thumb_top_f);
        } else max.height -| thumb_height;

        // Once we know the thumb height and its position we can draw the scroll bar.

        const scroll_bar = try vxfw.Surface.init(
            ctx.arena,
            self.widget(),
            .{
                .width = 1,
                // We make sure to make room for the horizontal scroll bar if it's being drawn.
                .height = max.height -| @intFromBool(self.draw_horizontal_scrollbar),
            },
        );

        const thumb_end_row = thumb_top + thumb_height;
        for (thumb_top..thumb_end_row) |row| {
            scroll_bar.writeCell(
                0,
                @intCast(row),
                if (self.is_dragging_vertical_thumb)
                    self.vertical_scrollbar_drag_thumb
                else if (self.is_hovering_vertical_thumb)
                    self.vertical_scrollbar_hover_thumb
                else
                    self.vertical_scrollbar_thumb,
            );
        }

        self.vertical_thumb_top_row = thumb_top;
        self.vertical_thumb_bottom_row = thumb_end_row;

        try children.append(.{
            .origin = .{ .row = 0, .col = max.width -| 1 },
            .surface = scroll_bar,
        });
    }

    // 5. Draw the horizontal scroll bar.

    const is_horizontally_scrolled = self.scroll_view.scroll.left > 0;
    const has_more_horizontal_content = self.scroll_view.scroll.has_more_horizontal;

    const should_draw_scrollbar = is_horizontally_scrolled or has_more_horizontal_content;

    if (self.draw_horizontal_scrollbar and should_draw_scrollbar) {
        const scroll_bar = try vxfw.Surface.init(
            ctx.arena,
            self.widget(),
            .{ .width = max.width, .height = 1 },
        );

        const widget_width_f: f32 = @floatFromInt(max.width);

        const max_content_width: u32 = width: {
            if (self.estimated_content_width) |w| break :width w;

            var max_content_width: u32 = 0;
            for (scroll_view_surface.children) |child| {
                max_content_width = @max(max_content_width, child.surface.size.width);
            }
            break :width max_content_width;
        };
        const max_content_width_f: f32 =
            if (self.scroll_view.scroll.left + max.width > max_content_width)
                // If we've managed to overscroll horizontally for whatever reason - for example if the
                // content changes - we make sure the scroll thumb doesn't disappear by increasing the
                // max content width to match the current overscrolled position.
                @floatFromInt(self.scroll_view.scroll.left + max.width)
            else
                @floatFromInt(max_content_width);

        self.last_frame_max_content_width = max_content_width;

        const thumb_width_f: f32 = widget_width_f * widget_width_f / max_content_width_f;
        const thumb_width: u32 = @intFromFloat(@max(thumb_width_f, 1));

        const view_start_col_f: f32 = @floatFromInt(self.scroll_view.scroll.left);
        const thumb_start_f = view_start_col_f * widget_width_f / max_content_width_f;

        const thumb_start: u32 = @intFromFloat(thumb_start_f);
        const thumb_end = thumb_start + thumb_width;
        for (thumb_start..thumb_end) |col| {
            scroll_bar.writeCell(
                @intCast(col),
                0,
                if (self.is_dragging_horizontal_thumb)
                    self.horizontal_scrollbar_drag_thumb
                else if (self.is_hovering_horizontal_thumb)
                    self.horizontal_scrollbar_hover_thumb
                else
                    self.horizontal_scrollbar_thumb,
            );
        }
        self.horizontal_thumb_start_col = thumb_start;
        self.horizontal_thumb_end_col = thumb_end;
        try children.append(.{
            .origin = .{ .row = max.height -| 1, .col = 0 },
            .surface = scroll_bar,
        });
    }

    return .{
        .size = ctx.max.size(),
        .widget = self.widget(),
        .buffer = &.{},
        .children = children.items,
    };
}

test ScrollBars {
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
    const ScrollView = @import("ScrollView.zig");
    const scroll_view: ScrollView = .{
        .wheel_scroll = 1, // Set wheel scroll to one
        .children = .{ .slice = &.{
            abc.widget(),
            def.widget(),
            ghi.widget(),
            jklmno.widget(),
        } },
    };

    // Create the scroll bars.
    var scroll_bars: ScrollBars = .{
        .scroll_view = scroll_view,
        .estimated_content_height = 7,
        .estimated_content_width = 5,
    };

    // Boiler plate draw context
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ucd = try vaxis.Unicode.init(arena.allocator());
    vxfw.DrawContext.init(&ucd, .unicode);

    const scroll_widget = scroll_bars.widget();
    const draw_ctx: vxfw.DrawContext = .{
        .arena = arena.allocator(),
        .min = .{},
        .max = .{ .width = 3, .height = 4 },
        .cell_size = .{ .width = 10, .height = 20 },
    };

    var surface = try scroll_widget.draw(draw_ctx);
    // Scroll bars should have 3 children: both scrollbars and the scroll view.
    try std.testing.expectEqual(3, surface.children.len);

    // Hide only the horizontal scroll bar.
    scroll_bars.draw_horizontal_scrollbar = false;
    surface = try scroll_widget.draw(draw_ctx);
    // Scroll bars should have 2 children: vertical scroll bar and the scroll view.
    try std.testing.expectEqual(2, surface.children.len);

    // Hide only the vertical scroll bar.
    scroll_bars.draw_horizontal_scrollbar = true;
    scroll_bars.draw_vertical_scrollbar = false;
    surface = try scroll_widget.draw(draw_ctx);
    // Scroll bars should have 2 children: vertical scroll bar and the scroll view.
    try std.testing.expectEqual(2, surface.children.len);

    // Hide both scroll bars.
    scroll_bars.draw_horizontal_scrollbar = false;
    surface = try scroll_widget.draw(draw_ctx);
    // Scroll bars should have 1 child: the scroll view.
    try std.testing.expectEqual(1, surface.children.len);

    // Re-enable scroll bars.
    scroll_bars.draw_horizontal_scrollbar = true;
    scroll_bars.draw_vertical_scrollbar = true;

    // Even though the estimated size is smaller than the draw area, we still render the scroll
    // bars if the scroll view knows we haven't rendered everything.
    scroll_bars.estimated_content_height = 2;
    scroll_bars.estimated_content_width = 1;
    surface = try scroll_widget.draw(draw_ctx);
    // Scroll bars should have 3 children: both scrollbars and the scroll view.
    try std.testing.expectEqual(3, surface.children.len);

    // The scroll view should be able to tell whether the scroll bars need to be rendered or not
    // even if estimated content sizes aren't provided.
    scroll_bars.estimated_content_height = null;
    scroll_bars.estimated_content_width = null;
    surface = try scroll_widget.draw(draw_ctx);
    // Scroll bars should have 3 children: both scrollbars and the scroll view.
    try std.testing.expectEqual(3, surface.children.len);
}

test "refAllDecls" {
    std.testing.refAllDecls(@This());
}
