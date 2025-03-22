const std = @import("std");
const vaxis = @import("../main.zig");
const vxfw = @import("vxfw.zig");

const assert = std.debug.assert;

const Allocator = std.mem.Allocator;

const EventLoop = vaxis.Loop(vxfw.Event);
const Widget = vxfw.Widget;

const App = @This();

allocator: Allocator,
tty: vaxis.Tty,
vx: vaxis.Vaxis,
timers: std.ArrayList(vxfw.Tick),
wants_focus: ?vxfw.Widget,

/// Runtime options
pub const Options = struct {
    /// Frames per second
    framerate: u8 = 60,
};

/// Create an application. We require stable pointers to do the set up, so this will create an App
/// object on the heap. Call destroy when the app is complete to reset terminal state and release
/// resources
pub fn init(allocator: Allocator) !App {
    return .{
        .allocator = allocator,
        .tty = try vaxis.Tty.init(),
        .vx = try vaxis.init(allocator, .{
            .system_clipboard_allocator = allocator,
            .kitty_keyboard_flags = .{
                .report_events = true,
            },
        }),
        .timers = std.ArrayList(vxfw.Tick).init(allocator),
        .wants_focus = null,
    };
}

pub fn deinit(self: *App) void {
    self.timers.deinit();
    self.vx.deinit(self.allocator, self.tty.anyWriter());
    self.tty.deinit();
}

pub fn run(self: *App, widget: vxfw.Widget, opts: Options) anyerror!void {
    const tty = &self.tty;
    const vx = &self.vx;

    var loop: EventLoop = .{ .tty = tty, .vaxis = vx };
    try loop.start();
    defer loop.stop();

    // Send the init event
    loop.postEvent(.init);
    // Also always initialize the app with a focus event
    loop.postEvent(.focus_in);

    try vx.enterAltScreen(tty.anyWriter());
    try vx.queryTerminal(tty.anyWriter(), 1 * std.time.ns_per_s);
    try vx.setBracketedPaste(tty.anyWriter(), true);
    try vx.subscribeToColorSchemeUpdates(tty.anyWriter());

    {
        // This part deserves a comment. loop.init installs a signal handler for the tty. We wait to
        // init the loop until we know if we need this handler. We don't need it if the terminal
        // supports in-band-resize
        if (!vx.state.in_band_resize) try loop.init();
    }

    // NOTE: We don't use pixel mouse anywhere
    vx.caps.sgr_pixels = false;
    try vx.setMouseMode(tty.anyWriter(), true);

    // Give DrawContext the unicode data
    vxfw.DrawContext.init(&vx.unicode, vx.screen.width_method);

    const framerate: u64 = if (opts.framerate > 0) opts.framerate else 60;
    // Calculate tick rate
    const tick_ms: u64 = @divFloor(std.time.ms_per_s, framerate);

    // Set up arena and context
    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();

    var mouse_handler = MouseHandler.init(widget);
    defer mouse_handler.deinit(self.allocator);
    var focus_handler = FocusHandler.init(self.allocator, widget);
    try focus_handler.path_to_focused.append(widget);
    defer focus_handler.deinit();

    // Timestamp of our next frame
    var next_frame_ms: u64 = @intCast(std.time.milliTimestamp());

    // Create our event context
    var ctx: vxfw.EventContext = .{
        .phase = .capturing,
        .cmds = vxfw.CommandList.init(self.allocator),
        .consume_event = false,
        .redraw = false,
        .quit = false,
    };
    defer ctx.cmds.deinit();

    while (true) {
        const now_ms: u64 = @intCast(std.time.milliTimestamp());
        if (now_ms >= next_frame_ms) {
            // Deadline exceeded. Schedule the next frame
            next_frame_ms = now_ms + tick_ms;
        } else {
            // Sleep until the deadline
            std.time.sleep((next_frame_ms - now_ms) * std.time.ns_per_ms);
            next_frame_ms += tick_ms;
        }

        try self.checkTimers(&ctx);

        {
            loop.queue.lock();
            defer loop.queue.unlock();
            while (loop.queue.drain()) |event| {
                defer {
                    // Reset our context
                    ctx.consume_event = false;
                    ctx.phase = .capturing;
                }
                switch (event) {
                    .key_press => {
                        try focus_handler.handleEvent(&ctx, event);
                        try self.handleCommand(&ctx.cmds);
                    },
                    .focus_out => {
                        try mouse_handler.mouseExit(self, &ctx);
                        try focus_handler.handleEvent(&ctx, .focus_out);
                        try self.handleCommand(&ctx.cmds);
                    },
                    .focus_in => {
                        try focus_handler.handleEvent(&ctx, .focus_in);
                        try self.handleCommand(&ctx.cmds);
                    },
                    .mouse => |mouse| try mouse_handler.handleMouse(self, &ctx, mouse),
                    .winsize => |ws| {
                        try vx.resize(self.allocator, tty.anyWriter(), ws);
                        ctx.redraw = true;
                    },
                    else => {
                        try focus_handler.handleEvent(&ctx, event);
                        try self.handleCommand(&ctx.cmds);
                    },
                }
            }
        }

        // If we have a focus change, handle that event before we layout
        if (self.wants_focus) |wants_focus| {
            try focus_handler.focusWidget(&ctx, wants_focus);
            try self.handleCommand(&ctx.cmds);
            self.wants_focus = null;
        }

        // Check if we should quit
        if (ctx.quit) return;

        // Check if we need a redraw
        if (!ctx.redraw) continue;
        ctx.redraw = false;
        // Clear the arena.
        _ = arena.reset(.free_all);
        // Assert that we have handled all commands
        assert(ctx.cmds.items.len == 0);

        const surface: vxfw.Surface = blk: {
            // Draw the root widget
            const surface = try self.doLayout(widget, &arena);

            // Check if any hover or mouse effects changed
            try mouse_handler.updateMouse(self, surface, &ctx);
            // Our focus may have changed. Handle that here
            if (self.wants_focus) |wants_focus| {
                try focus_handler.focusWidget(&ctx, wants_focus);
                try self.handleCommand(&ctx.cmds);
                self.wants_focus = null;
            }

            assert(ctx.cmds.items.len == 0);
            if (!ctx.redraw) break :blk surface;
            // If updating the mouse required a redraw, we do the layout again
            break :blk try self.doLayout(widget, &arena);
        };

        // Store the last frame
        mouse_handler.last_frame = surface;
        // Update the focus handler list
        try focus_handler.update(surface);
        try self.render(surface, focus_handler.focused_widget);
    }
}

fn doLayout(
    self: *App,
    widget: vxfw.Widget,
    arena: *std.heap.ArenaAllocator,
) !vxfw.Surface {
    const vx = &self.vx;

    const draw_context: vxfw.DrawContext = .{
        .arena = arena.allocator(),
        .min = .{ .width = 0, .height = 0 },
        .max = .{
            .width = @intCast(vx.screen.width),
            .height = @intCast(vx.screen.height),
        },
        .cell_size = .{
            .width = vx.screen.width_pix / vx.screen.width,
            .height = vx.screen.height_pix / vx.screen.height,
        },
    };
    return widget.draw(draw_context);
}

fn render(
    self: *App,
    surface: vxfw.Surface,
    focused_widget: vxfw.Widget,
) !void {
    const vx = &self.vx;
    const tty = &self.tty;

    const win = vx.window();
    win.clear();
    win.hideCursor();
    win.setCursorShape(.default);

    const root_win = win.child(.{
        .width = surface.size.width,
        .height = surface.size.height,
    });
    surface.render(root_win, focused_widget);

    var buffered = tty.bufferedWriter();
    try vx.render(buffered.writer().any());
    try buffered.flush();
}

fn addTick(self: *App, tick: vxfw.Tick) Allocator.Error!void {
    try self.timers.append(tick);
    std.sort.insertion(vxfw.Tick, self.timers.items, {}, vxfw.Tick.lessThan);
}

fn handleCommand(self: *App, cmds: *vxfw.CommandList) Allocator.Error!void {
    defer cmds.clearRetainingCapacity();
    for (cmds.items) |cmd| {
        switch (cmd) {
            .tick => |tick| try self.addTick(tick),
            .set_mouse_shape => |shape| self.vx.setMouseShape(shape),
            .request_focus => |widget| self.wants_focus = widget,
            .copy_to_clipboard => |content| {
                self.vx.copyToSystemClipboard(self.tty.anyWriter(), content, self.allocator) catch |err| {
                    switch (err) {
                        error.OutOfMemory => return Allocator.Error.OutOfMemory,
                        else => std.log.err("copy error: {}", .{err}),
                    }
                };
            },
            .set_title => |title| {
                self.vx.setTitle(self.tty.anyWriter(), title) catch |err| {
                    std.log.err("set_title error: {}", .{err});
                };
            },
            .queue_refresh => self.vx.queueRefresh(),
            .notify => |notification| {
                self.vx.notify(self.tty.anyWriter(), notification.title, notification.body) catch |err| {
                    std.log.err("notify error: {}", .{err});
                };
                const alloc = cmds.allocator;
                if (notification.title) |title| {
                    alloc.free(title);
                }
                alloc.free(notification.body);
            },
            .query_color => |kind| {
                self.vx.queryColor(self.tty.anyWriter(), kind) catch |err| {
                    std.log.err("queryColor error: {}", .{err});
                };
            },
        }
    }
}

fn checkTimers(self: *App, ctx: *vxfw.EventContext) anyerror!void {
    const now_ms = std.time.milliTimestamp();

    // timers are always sorted descending
    while (self.timers.pop()) |tick| {
        if (now_ms < tick.deadline_ms) {
            // re-add the timer
            try self.timers.append(tick);
            break;
        }
        try tick.widget.handleEvent(ctx, .tick);
    }
    try self.handleCommand(&ctx.cmds);
}

const MouseHandler = struct {
    last_frame: vxfw.Surface,
    last_hit_list: []vxfw.HitResult,
    mouse: ?vaxis.Mouse,

    fn init(root: Widget) MouseHandler {
        return .{
            .last_frame = .{
                .size = .{ .width = 0, .height = 0 },
                .widget = root,
                .buffer = &.{},
                .children = &.{},
            },
            .last_hit_list = &.{},
            .mouse = null,
        };
    }

    fn deinit(self: MouseHandler, gpa: Allocator) void {
        gpa.free(self.last_hit_list);
    }

    fn updateMouse(
        self: *MouseHandler,
        app: *App,
        surface: vxfw.Surface,
        ctx: *vxfw.EventContext,
    ) anyerror!void {
        const mouse = self.mouse orelse return;
        // For mouse events we store the last frame and use that for hit testing
        const last_frame = surface;

        var hits = std.ArrayList(vxfw.HitResult).init(app.allocator);
        defer hits.deinit();
        const sub: vxfw.SubSurface = .{
            .origin = .{ .row = 0, .col = 0 },
            .surface = last_frame,
            .z_index = 0,
        };
        const mouse_point: vxfw.Point = .{
            .row = @intCast(mouse.row),
            .col = @intCast(mouse.col),
        };
        if (sub.containsPoint(mouse_point)) {
            try last_frame.hitTest(&hits, mouse_point);
        }

        // We store the hit list from the last mouse event to determine mouse_enter and mouse_leave
        // events. If list a is the previous hit list, and list b is the current hit list:
        // - Widgets in a but not in b get a mouse_leave event
        // - Widgets in b but not in a get a mouse_enter event
        // - Widgets in both receive nothing
        const a = self.last_hit_list;
        const b = hits.items;

        // Find widgets in a but not b
        for (a) |a_item| {
            const a_widget = a_item.widget;
            for (b) |b_item| {
                const b_widget = b_item.widget;
                if (a_widget.eql(b_widget)) break;
            } else {
                // a_item is not in b
                try a_widget.handleEvent(ctx, .mouse_leave);
                try app.handleCommand(&ctx.cmds);
            }
        }

        // Widgets in b but not in a
        for (b) |b_item| {
            const b_widget = b_item.widget;
            for (a) |a_item| {
                const a_widget = a_item.widget;
                if (b_widget.eql(a_widget)) break;
            } else {
                // b_item is not in a.
                try b_widget.handleEvent(ctx, .mouse_enter);
                try app.handleCommand(&ctx.cmds);
            }
        }

        // Store a copy of this hit list for next frame
        app.allocator.free(self.last_hit_list);
        self.last_hit_list = try app.allocator.dupe(vxfw.HitResult, hits.items);
    }

    fn handleMouse(self: *MouseHandler, app: *App, ctx: *vxfw.EventContext, mouse: vaxis.Mouse) anyerror!void {
        // For mouse events we store the last frame and use that for hit testing
        const last_frame = self.last_frame;
        self.mouse = mouse;

        var hits = std.ArrayList(vxfw.HitResult).init(app.allocator);
        defer hits.deinit();
        const sub: vxfw.SubSurface = .{
            .origin = .{ .row = 0, .col = 0 },
            .surface = last_frame,
            .z_index = 0,
        };
        const mouse_point: vxfw.Point = .{
            .row = @intCast(mouse.row),
            .col = @intCast(mouse.col),
        };
        if (sub.containsPoint(mouse_point)) {
            try last_frame.hitTest(&hits, mouse_point);
        }

        // Handle mouse_enter and mouse_leave events
        {
            // We store the hit list from the last mouse event to determine mouse_enter and mouse_leave
            // events. If list a is the previous hit list, and list b is the current hit list:
            // - Widgets in a but not in b get a mouse_leave event
            // - Widgets in b but not in a get a mouse_enter event
            // - Widgets in both receive nothing
            const a = self.last_hit_list;
            const b = hits.items;

            // Find widgets in a but not b
            for (a) |a_item| {
                const a_widget = a_item.widget;
                for (b) |b_item| {
                    const b_widget = b_item.widget;
                    if (a_widget.eql(b_widget)) break;
                } else {
                    // a_item is not in b
                    try a_widget.handleEvent(ctx, .mouse_leave);
                    try app.handleCommand(&ctx.cmds);
                }
            }

            // Widgets in b but not in a
            for (b) |b_item| {
                const b_widget = b_item.widget;
                for (a) |a_item| {
                    const a_widget = a_item.widget;
                    if (b_widget.eql(a_widget)) break;
                } else {
                    // b_item is not in a.
                    try b_widget.handleEvent(ctx, .mouse_enter);
                    try app.handleCommand(&ctx.cmds);
                }
            }

            // Store a copy of this hit list for next frame
            app.allocator.free(self.last_hit_list);
            self.last_hit_list = try app.allocator.dupe(vxfw.HitResult, hits.items);
        }

        const target = hits.pop() orelse return;

        // capturing phase
        ctx.phase = .capturing;
        for (hits.items) |item| {
            var m_local = mouse;
            m_local.col = item.local.col;
            m_local.row = item.local.row;
            try item.widget.captureEvent(ctx, .{ .mouse = m_local });
            try app.handleCommand(&ctx.cmds);

            if (ctx.consume_event) return;
        }

        // target phase
        ctx.phase = .at_target;
        {
            var m_local = mouse;
            m_local.col = target.local.col;
            m_local.row = target.local.row;
            try target.widget.handleEvent(ctx, .{ .mouse = m_local });
            try app.handleCommand(&ctx.cmds);

            if (ctx.consume_event) return;
        }

        // Bubbling phase
        ctx.phase = .bubbling;
        while (hits.pop()) |item| {
            var m_local = mouse;
            m_local.col = item.local.col;
            m_local.row = item.local.row;
            try item.widget.handleEvent(ctx, .{ .mouse = m_local });
            try app.handleCommand(&ctx.cmds);

            if (ctx.consume_event) return;
        }
    }

    /// sends .mouse_leave to all of the widgets from the last_hit_list
    fn mouseExit(self: *MouseHandler, app: *App, ctx: *vxfw.EventContext) anyerror!void {
        for (self.last_hit_list) |item| {
            try item.widget.handleEvent(ctx, .mouse_leave);
            try app.handleCommand(&ctx.cmds);
        }
    }
};

/// Maintains a tree of focusable nodes. Delivers events to the currently focused node, walking up
/// the tree until the event is handled
const FocusHandler = struct {
    root: Widget,
    focused_widget: vxfw.Widget,
    path_to_focused: std.ArrayList(Widget),

    fn init(allocator: Allocator, root: Widget) FocusHandler {
        return .{
            .root = root,
            .focused_widget = root,
            .path_to_focused = std.ArrayList(Widget).init(allocator),
        };
    }

    fn deinit(self: *FocusHandler) void {
        self.path_to_focused.deinit();
    }

    /// Update the focus list
    fn update(self: *FocusHandler, surface: vxfw.Surface) Allocator.Error!void {
        // clear path
        self.path_to_focused.clearAndFree();

        // Find the path to the focused widget. This builds a list that has the first element as the
        // focused widget, and walks backward to the root. It's possible our focused widget is *not*
        // in this tree. If this is the case, we refocus to the root widget
        const has_focus = try self.childHasFocus(surface);

        // We assert that the focused widget *must* be in the widget tree. There is certianly a
        // logic bug in the code somewhere if this is not the case
        assert(has_focus); // Focused widget not found in Surface tree
        if (!self.root.eql(surface.widget)) {
            // If the root of surface is not the initial widget, we append the initial widget
            try self.path_to_focused.append(self.root);
        }

        // reverse path_to_focused so that it is root first
        std.mem.reverse(Widget, self.path_to_focused.items);
    }

    /// Returns true if a child of surface is the focused widget
    fn childHasFocus(
        self: *FocusHandler,
        surface: vxfw.Surface,
    ) Allocator.Error!bool {
        // Check if we are the focused widget
        if (self.focused_widget.eql(surface.widget)) {
            try self.path_to_focused.append(surface.widget);
            return true;
        }
        for (surface.children) |child| {
            // Add child to list if it is the focused widget or one of it's own children is
            if (try self.childHasFocus(child.surface)) {
                try self.path_to_focused.append(surface.widget);
                return true;
            }
        }
        return false;
    }

    fn focusWidget(self: *FocusHandler, ctx: *vxfw.EventContext, widget: vxfw.Widget) anyerror!void {
        // Focusing a widget requires it to have an event handler
        assert(widget.eventHandler != null);
        if (self.focused_widget.eql(widget)) return;

        ctx.phase = .at_target;
        try self.focused_widget.handleEvent(ctx, .focus_out);
        self.focused_widget = widget;
        try self.focused_widget.handleEvent(ctx, .focus_in);
    }

    fn handleEvent(self: *FocusHandler, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        const path = self.path_to_focused.items;
        assert(path.len > 0);

        // Capturing phase. We send capture events from the root to the target (inclusive of target)
        ctx.phase = .capturing;
        for (path) |widget| {
            try widget.captureEvent(ctx, event);
            if (ctx.consume_event) return;
        }

        // Target phase. This is only sent to the target
        ctx.phase = .at_target;
        const target = self.path_to_focused.getLast();
        try target.handleEvent(ctx, event);
        if (ctx.consume_event) return;

        // Bubbling phase. Bubbling phase moves from target (exclusive) to the root
        ctx.phase = .bubbling;
        const target_idx = path.len - 1;
        var iter = std.mem.reverseIterator(path[0..target_idx]);
        while (iter.next()) |widget| {
            try widget.handleEvent(ctx, event);
            if (ctx.consume_event) return;
        }
    }
};
