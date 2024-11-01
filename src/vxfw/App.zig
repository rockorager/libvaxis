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
        .vx = try vaxis.init(allocator, .{ .system_clipboard_allocator = allocator }),
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

    try vx.enterAltScreen(tty.anyWriter());
    try vx.queryTerminal(tty.anyWriter(), 1 * std.time.ns_per_s);

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

    var buffered = tty.bufferedWriter();

    var mouse_handler = MouseHandler.init(widget);
    var focus_handler = FocusHandler.init(self.allocator, widget);
    focus_handler.intrusiveInit();
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

        while (loop.tryEvent()) |event| {
            defer {
                // Reset our context
                ctx.consume_event = false;
                ctx.phase = .capturing;
                ctx.cmds.clearRetainingCapacity();
            }
            switch (event) {
                .key_press => {
                    try focus_handler.handleEvent(&ctx, event);
                    try self.handleCommand(&ctx.cmds);
                },
                .focus_out => try mouse_handler.mouseExit(self, &ctx),
                .mouse => |mouse| try mouse_handler.handleMouse(self, &ctx, mouse),
                .winsize => |ws| {
                    try vx.resize(self.allocator, buffered.writer().any(), ws);
                    try buffered.flush();
                    ctx.redraw = true;
                },
                else => {
                    try focus_handler.handleEvent(&ctx, event);
                    try self.handleCommand(&ctx.cmds);
                },
            }
        }

        // Check if we should quit
        if (ctx.quit) return;

        // Check if we need a redraw
        if (!ctx.redraw) continue;
        ctx.redraw = false;
        // Assert that we have handled all commands
        assert(ctx.cmds.items.len == 0);

        _ = arena.reset(.retain_capacity);

        const draw_context: vxfw.DrawContext = .{
            .arena = arena.allocator(),
            .min = .{ .width = 0, .height = 0 },
            .max = .{
                .width = @intCast(vx.screen.width),
                .height = @intCast(vx.screen.height),
            },
        };
        const win = vx.window();
        win.clear();
        win.hideCursor();
        win.setCursorShape(.default);
        const surface = try widget.draw(draw_context);

        const focused = self.wants_focus orelse focus_handler.focused.widget;
        surface.render(win, focused);
        try vx.render(buffered.writer().any());
        try buffered.flush();

        // Store the last frame
        mouse_handler.last_frame = surface;
        try focus_handler.update(surface, self.wants_focus);
        self.wants_focus = null;
    }
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
        }
    }
}

fn checkTimers(self: *App, ctx: *vxfw.EventContext) anyerror!void {
    const now_ms = std.time.milliTimestamp();

    // timers are always sorted descending
    while (self.timers.popOrNull()) |tick| {
        if (now_ms < tick.deadline_ms)
            break;
        try tick.widget.handleEvent(ctx, .tick);
        try self.handleCommand(&ctx.cmds);
    }
}

const MouseHandler = struct {
    last_frame: vxfw.Surface,
    maybe_last_handler: ?vxfw.Widget = null,

    fn init(root: Widget) MouseHandler {
        return .{
            .last_frame = .{
                .size = .{ .width = 0, .height = 0 },
                .widget = root,
                .buffer = &.{},
                .children = &.{},
            },
            .maybe_last_handler = null,
        };
    }

    fn handleMouse(self: *MouseHandler, app: *App, ctx: *vxfw.EventContext, mouse: vaxis.Mouse) anyerror!void {
        const last_frame = self.last_frame;

        // For mouse events we store the last frame and use that for hit testing
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
        while (hits.popOrNull()) |item| {
            var m_local = mouse;
            m_local.col = item.local.col;
            m_local.row = item.local.row;
            try item.widget.handleEvent(ctx, .{ .mouse = m_local });
            try app.handleCommand(&ctx.cmds);

            // If the event wasn't consumed, we keep passing it on
            if (!ctx.consume_event) continue;

            if (self.maybe_last_handler) |last_mouse_handler| {
                if (!last_mouse_handler.eql(item.widget)) {
                    try last_mouse_handler.handleEvent(ctx, .mouse_leave);
                    try app.handleCommand(&ctx.cmds);
                }
            }
            self.maybe_last_handler = item.widget;
            return;
        }

        // If no one handled the mouse, we assume it exited
        return self.mouseExit(app, ctx);
    }

    fn mouseExit(self: *MouseHandler, app: *App, ctx: *vxfw.EventContext) anyerror!void {
        if (self.maybe_last_handler) |last_handler| {
            try last_handler.handleEvent(ctx, .mouse_leave);
            try app.handleCommand(&ctx.cmds);
            self.maybe_last_handler = null;
        }
    }
};

/// Maintains a tree of focusable nodes. Delivers events to the currently focused node, walking up
/// the tree until the event is handled
const FocusHandler = struct {
    arena: std.heap.ArenaAllocator,

    root: Node,
    focused: *Node,
    path_to_focused: std.ArrayList(Widget),
    maybe_wants_focus: ?vxfw.Widget = null,

    const Node = struct {
        widget: Widget,
        parent: ?*Node,
        children: []*Node,

        fn nextSibling(self: Node) ?*Node {
            const parent = self.parent orelse return null;
            const idx = for (0..parent.children.len) |i| {
                const node = parent.children[i];
                if (self.widget.eql(node.widget))
                    break i;
            } else unreachable;

            // Return null if last child
            if (idx == parent.children.len - 1)
                return null
            else
                return parent.children[idx + 1];
        }

        fn prevSibling(self: Node) ?*Node {
            const parent = self.parent orelse return null;
            const idx = for (0..parent.children.len) |i| {
                const node = parent.children[i];
                if (self.widget.eql(node.widget))
                    break i;
            } else unreachable;

            // Return null if first child
            if (idx == 0)
                return null
            else
                return parent.children[idx - 1];
        }

        fn lastChild(self: Node) ?*Node {
            if (self.children.len > 0)
                return self.children[self.children.len - 1]
            else
                return null;
        }

        fn firstChild(self: Node) ?*Node {
            if (self.children.len > 0)
                return self.children[0]
            else
                return null;
        }

        /// returns the next logical node in the tree
        fn nextNode(self: *Node) *Node {
            // If we have a sibling, we return it's first descendant line
            if (self.nextSibling()) |sibling| {
                var node = sibling;
                while (node.firstChild()) |child| {
                    node = child;
                }
                return node;
            }

            // If we don't have a sibling, we return our parent
            if (self.parent) |parent| return parent;

            // If we don't have a parent, we are the root and we return or first descendant
            var node = self;
            while (node.firstChild()) |child| {
                node = child;
            }
            return node;
        }

        fn prevNode(self: *Node) *Node {
            // If we have children, we return the last child descendant
            if (self.children.len > 0) {
                var node = self;
                while (node.lastChild()) |child| {
                    node = child;
                }
                return node;
            }

            // If we have siblings, we return the last descendant line of the sibling
            if (self.prevSibling()) |sibling| {
                var node = sibling;
                while (node.lastChild()) |child| {
                    node = child;
                }
                return node;
            }

            // If we don't have a sibling, we return our parent
            if (self.parent) |parent| return parent;

            // If we don't have a parent, we are the root and we return our last descendant
            var node = self;
            while (node.lastChild()) |child| {
                node = child;
            }
            return node;
        }
    };

    fn init(allocator: Allocator, root: Widget) FocusHandler {
        const node: Node = .{
            .widget = root,
            .parent = null,
            .children = &.{},
        };
        return .{
            .root = node,
            .focused = undefined,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .maybe_wants_focus = null,
            .path_to_focused = std.ArrayList(Widget).init(allocator),
        };
    }

    fn intrusiveInit(self: *FocusHandler) void {
        self.focused = &self.root;
    }

    fn deinit(self: *FocusHandler) void {
        self.path_to_focused.deinit();
        self.arena.deinit();
    }

    /// Update the focus list
    fn update(self: *FocusHandler, root: vxfw.Surface, maybe_wants_focus: ?vxfw.Widget) Allocator.Error!void {
        _ = self.arena.reset(.retain_capacity);
        self.maybe_wants_focus = maybe_wants_focus;

        var list = std.ArrayList(*Node).init(self.arena.allocator());
        for (root.children) |child| {
            try self.findFocusableChildren(&self.root, &list, child.surface);
        }
        self.path_to_focused.clearAndFree();
        _ = try childHasFocus(root, &self.path_to_focused, self.focused.widget);
        try self.path_to_focused.append(root.widget);
        // reverse path_to_focused so that it is root first
        std.mem.reverse(Widget, self.path_to_focused.items);
        self.root = .{
            .widget = root.widget,
            .children = list.items,
            .parent = null,
        };
    }

    /// Returns true if a child of surface is the focused widget
    fn childHasFocus(
        surface: vxfw.Surface,
        list: *std.ArrayList(Widget),
        focused: Widget,
    ) Allocator.Error!bool {
        // Check if we are the focused widget
        if (focused.eql(surface.widget)) {
            try list.append(surface.widget);
            return true;
        }
        for (surface.children) |child| {
            // Add child to list if it is the focused widget or one of it's own children is
            if (try childHasFocus(child.surface, list, focused)) {
                try list.append(surface.widget);
                return true;
            }
        }
        return false;
    }

    /// Walks the surface tree, adding all focusable nodes to list
    fn findFocusableChildren(
        self: *FocusHandler,
        parent: *Node,
        list: *std.ArrayList(*Node),
        surface: vxfw.Surface,
    ) Allocator.Error!void {
        if (surface.focusable) {
            // We are a focusable child of parent. Create a new node, and find our own focusable
            // children
            const node = try self.arena.allocator().create(Node);
            var child_list = std.ArrayList(*Node).init(self.arena.allocator());
            for (surface.children) |child| {
                try self.findFocusableChildren(node, &child_list, child.surface);
            }
            node.* = .{
                .widget = surface.widget,
                .parent = parent,
                .children = child_list.items,
            };
            if (self.maybe_wants_focus) |wants_focus| {
                if (wants_focus.eql(surface.widget)) {
                    self.focused = node;
                    self.maybe_wants_focus = null;
                }
            }
            try list.append(node);
        } else {
            for (surface.children) |child| {
                try self.findFocusableChildren(parent, list, child.surface);
            }
        }
    }

    fn focusNode(self: *FocusHandler, ctx: *vxfw.EventContext, node: *Node) anyerror!void {
        if (self.focused.widget.eql(node.widget)) return;

        try self.focused.widget.handleEvent(ctx, .focus_out);
        self.focused = node;
        try self.focused.widget.handleEvent(ctx, .focus_in);
    }

    /// Focuses the next focusable widget
    fn focusNext(self: *FocusHandler, ctx: *vxfw.EventContext) anyerror!void {
        return self.focusNode(ctx, self.focused.nextNode());
    }

    /// Focuses the previous focusable widget
    fn focusPrev(self: *FocusHandler, ctx: *vxfw.EventContext) anyerror!void {
        return self.focusNode(ctx, self.focused.prevNode());
    }

    fn handleEvent(self: *FocusHandler, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        const path = self.path_to_focused.items;
        if (path.len == 0) return;

        const target_idx = path.len - 1;

        // Capturing phase
        ctx.phase = .capturing;
        for (path[0..target_idx]) |widget| {
            try widget.handleEvent(ctx, event);
            if (ctx.consume_event) return;
        }

        // Target phase
        ctx.phase = .at_target;
        const target = path[target_idx];
        try target.handleEvent(ctx, event);
        if (ctx.consume_event) return;

        // Bubbling phase
        ctx.phase = .bubbling;
        var iter = std.mem.reverseIterator(path[0..target_idx]);
        while (iter.next()) |widget| {
            try widget.handleEvent(ctx, event);
            if (ctx.consume_event) return;
        }
    }
};
