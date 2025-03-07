const std = @import("std");
const vaxis = @import("../main.zig");

const grapheme = vaxis.grapheme;
const testing = std.testing;

const assert = std.debug.assert;

const Allocator = std.mem.Allocator;

pub const App = @import("App.zig");

// Widgets
pub const Border = @import("Border.zig");
pub const Button = @import("Button.zig");
pub const Center = @import("Center.zig");
pub const FlexColumn = @import("FlexColumn.zig");
pub const FlexRow = @import("FlexRow.zig");
pub const ListView = @import("ListView.zig");
pub const Padding = @import("Padding.zig");
pub const RichText = @import("RichText.zig");
pub const ScrollView = @import("ScrollView.zig");
pub const ScrollBars = @import("ScrollBars.zig");
pub const SizedBox = @import("SizedBox.zig");
pub const SplitView = @import("SplitView.zig");
pub const Spinner = @import("Spinner.zig");
pub const Text = @import("Text.zig");
pub const TextField = @import("TextField.zig");

pub const CommandList = std.ArrayList(Command);

pub const UserEvent = struct {
    name: []const u8,
    data: ?*const anyopaque = null,
};

pub const Event = union(enum) {
    key_press: vaxis.Key,
    key_release: vaxis.Key,
    mouse: vaxis.Mouse,
    focus_in, // window has gained focus
    focus_out, // window has lost focus
    paste_start, // bracketed paste start
    paste_end, // bracketed paste end
    paste: []const u8, // osc 52 paste, caller must free
    color_report: vaxis.Color.Report, // osc 4, 10, 11, 12 response
    color_scheme: vaxis.Color.Scheme, // light / dark OS theme changes
    winsize: vaxis.Winsize, // the window size has changed. This event is always sent when the loop is started
    app: UserEvent, // A custom event from the app
    tick, // An event from a Tick command
    init, // sent when the application starts
    mouse_leave, // The mouse has left the widget
    mouse_enter, // The mouse has enterred the widget
};

pub const Tick = struct {
    deadline_ms: i64,
    widget: Widget,

    pub fn lessThan(_: void, lhs: Tick, rhs: Tick) bool {
        return lhs.deadline_ms > rhs.deadline_ms;
    }

    pub fn in(ms: u32, widget: Widget) Command {
        const now = std.time.milliTimestamp();
        return .{ .tick = .{
            .deadline_ms = now + ms,
            .widget = widget,
        } };
    }
};

pub const Command = union(enum) {
    /// Callback the event with a tick event at the specified deadlline
    tick: Tick,
    /// Change the mouse shape. This also has an implicit redraw
    set_mouse_shape: vaxis.Mouse.Shape,
    /// Request that this widget receives focus
    request_focus: Widget,

    /// Try to copy the provided text to the host clipboard. Uses OSC 52. Silently fails if terminal
    /// doesn't support OSC 52
    copy_to_clipboard: []const u8,

    /// Set the title of the terminal
    set_title: []const u8,

    /// Queue a refresh of the entire screen. Implicitly sets redraw
    queue_refresh,

    /// Send a system notification
    notify: struct {
        title: ?[]const u8,
        body: []const u8,
    },

    query_color: vaxis.Cell.Color.Kind,
};

pub const EventContext = struct {
    phase: Phase = .at_target,
    cmds: CommandList,

    /// The event was handled, do not pass it on
    consume_event: bool = false,
    /// Tells the event loop to redraw the UI
    redraw: bool = true,
    /// Quit the application
    quit: bool = false,

    pub const Phase = enum {
        capturing,
        at_target,
        bubbling,
    };

    pub fn addCmd(self: *EventContext, cmd: Command) Allocator.Error!void {
        try self.cmds.append(cmd);
    }

    pub fn tick(self: *EventContext, ms: u32, widget: Widget) Allocator.Error!void {
        try self.addCmd(Tick.in(ms, widget));
    }

    pub fn consumeAndRedraw(self: *EventContext) void {
        self.consume_event = true;
        self.redraw = true;
    }

    pub fn consumeEvent(self: *EventContext) void {
        self.consume_event = true;
    }

    pub fn setMouseShape(self: *EventContext, shape: vaxis.Mouse.Shape) Allocator.Error!void {
        try self.addCmd(.{ .set_mouse_shape = shape });
        self.redraw = true;
    }

    pub fn requestFocus(self: *EventContext, widget: Widget) Allocator.Error!void {
        try self.addCmd(.{ .request_focus = widget });
    }

    pub fn copyToClipboard(self: *EventContext, content: []const u8) Allocator.Error!void {
        try self.addCmd(.{ .copy_to_clipboard = content });
    }

    pub fn setTitle(self: *EventContext, title: []const u8) Allocator.Error!void {
        try self.addCmd(.{ .set_title = title });
    }

    pub fn queueRefresh(self: *EventContext) Allocator.Error!void {
        try self.addCmd(.queue_refresh);
        self.redraw = true;
    }

    /// Send a system notification. This function dupes title and body using it's own allocator.
    /// They will be freed once the notification has been sent
    pub fn sendNotification(
        self: *EventContext,
        maybe_title: ?[]const u8,
        body: []const u8,
    ) Allocator.Error!void {
        const alloc = self.cmds.allocator;
        if (maybe_title) |title| {
            return self.addCmd(.{ .notify = .{
                .title = try alloc.dupe(u8, title),
                .body = try alloc.dupe(u8, body),
            } });
        }
        return self.addCmd(.{ .notify = .{
            .title = null,
            .body = try alloc.dupe(u8, body),
        } });
    }

    pub fn queryColor(self: *EventContext, kind: vaxis.Cell.Color.Kind) Allocator.Error!void {
        try self.addCmd(.{ .query_color = kind });
    }
};

pub const DrawContext = struct {
    // Allocator backed by an arena. Widgets do not need to free their own resources, they will be
    // freed after rendering
    arena: std.mem.Allocator,
    // Constraints
    min: Size,
    max: MaxSize,

    // Size of a single cell, in pixels
    cell_size: Size,

    // Unicode stuff
    var unicode: ?*const vaxis.Unicode = null;
    var width_method: vaxis.gwidth.Method = .unicode;

    pub fn init(ucd: *const vaxis.Unicode, method: vaxis.gwidth.Method) void {
        DrawContext.unicode = ucd;
        DrawContext.width_method = method;
    }

    pub fn stringWidth(_: DrawContext, str: []const u8) usize {
        assert(DrawContext.unicode != null); // DrawContext not initialized
        return vaxis.gwidth.gwidth(
            str,
            DrawContext.width_method,
            &DrawContext.unicode.?.width_data,
        );
    }

    pub fn graphemeIterator(_: DrawContext, str: []const u8) grapheme.Iterator {
        assert(DrawContext.unicode != null); // DrawContext not initialized
        return DrawContext.unicode.?.graphemeIterator(str);
    }

    pub fn withConstraints(self: DrawContext, min: Size, max: MaxSize) DrawContext {
        return .{
            .arena = self.arena,
            .min = min,
            .max = max,
            .cell_size = self.cell_size,
        };
    }
};

pub const Size = struct {
    width: u16 = 0,
    height: u16 = 0,
};

pub const MaxSize = struct {
    width: ?u16 = null,
    height: ?u16 = null,

    /// Returns true if the row would fall outside of this height. A null height value is infinite
    /// and always returns false
    pub fn outsideHeight(self: MaxSize, row: u16) bool {
        const max = self.height orelse return false;
        return row >= max;
    }

    /// Returns true if the col would fall outside of this width. A null width value is infinite
    /// and always returns false
    pub fn outsideWidth(self: MaxSize, col: u16) bool {
        const max = self.width orelse return false;
        return col >= max;
    }

    /// Asserts that neither height nor width are null
    pub fn size(self: MaxSize) Size {
        assert(self.width != null);
        assert(self.height != null);
        return .{
            .width = self.width.?,
            .height = self.height.?,
        };
    }

    pub fn fromSize(other: Size) MaxSize {
        return .{
            .width = other.width,
            .height = other.height,
        };
    }
};

/// The Widget interface
pub const Widget = struct {
    userdata: *anyopaque,
    captureHandler: ?*const fn (userdata: *anyopaque, ctx: *EventContext, event: Event) anyerror!void = null,
    eventHandler: ?*const fn (userdata: *anyopaque, ctx: *EventContext, event: Event) anyerror!void = null,
    drawFn: *const fn (userdata: *anyopaque, ctx: DrawContext) Allocator.Error!Surface,

    pub fn captureEvent(self: Widget, ctx: *EventContext, event: Event) anyerror!void {
        if (self.captureHandler) |handle| {
            return handle(self.userdata, ctx, event);
        }
    }

    pub fn handleEvent(self: Widget, ctx: *EventContext, event: Event) anyerror!void {
        if (self.eventHandler) |handle| {
            return handle(self.userdata, ctx, event);
        }
    }

    pub fn draw(self: Widget, ctx: DrawContext) Allocator.Error!Surface {
        return self.drawFn(self.userdata, ctx);
    }

    /// Returns true if the Widgets point to the same widget instance. To be considered the same,
    /// the userdata and drawFn fields must point to the same values in both widgets
    pub fn eql(self: Widget, other: Widget) bool {
        return @intFromPtr(self.userdata) == @intFromPtr(other.userdata) and
            @intFromPtr(self.drawFn) == @intFromPtr(other.drawFn);
    }
};

pub const FlexItem = struct {
    widget: Widget,
    /// A value of zero means the child will have it's inherent size. Any value greater than zero
    /// and the remaining space will be proportioned to each item
    flex: u8 = 1,

    pub fn init(child: Widget, flex: u8) FlexItem {
        return .{ .widget = child, .flex = flex };
    }
};

pub const Point = struct {
    row: u16,
    col: u16,
};

pub const RelativePoint = struct {
    row: i17,
    col: i17,
};

/// Result of a hit test
pub const HitResult = struct {
    local: Point,
    widget: Widget,
};

pub const CursorState = struct {
    /// Local coordinates
    row: u16,
    /// Local coordinates
    col: u16,
    shape: vaxis.Cell.CursorShape = .default,
};

pub const Surface = struct {
    /// Size of this surface
    size: Size,
    /// The widget this surface belongs to
    widget: Widget,

    /// Cursor state
    cursor: ?CursorState = null,

    /// Contents of this surface. Must be len == 0 or  len == size.width * size.height
    buffer: []vaxis.Cell,

    children: []SubSurface,

    pub fn empty(widget: Widget) Surface {
        return .{
            .size = .{},
            .widget = widget,
            .buffer = &.{},
            .children = &.{},
        };
    }

    /// Creates a slice of vaxis.Cell's equal to size.width * size.height
    pub fn createBuffer(allocator: Allocator, size: Size) Allocator.Error![]vaxis.Cell {
        const buffer = try allocator.alloc(vaxis.Cell, size.width * size.height);
        @memset(buffer, .{ .default = true });
        return buffer;
    }

    pub fn init(allocator: Allocator, widget: Widget, size: Size) Allocator.Error!Surface {
        return .{
            .size = size,
            .widget = widget,
            .buffer = try Surface.createBuffer(allocator, size),
            .children = &.{},
        };
    }

    pub fn initWithChildren(
        allocator: Allocator,
        widget: Widget,
        size: Size,
        children: []SubSurface,
    ) Allocator.Error!Surface {
        return .{
            .size = size,
            .widget = widget,
            .buffer = try Surface.createBuffer(allocator, size),
            .children = children,
        };
    }

    pub fn writeCell(self: Surface, col: u16, row: u16, cell: vaxis.Cell) void {
        if (self.size.width <= col) return;
        if (self.size.height <= row) return;
        const i = (row * self.size.width) + col;
        assert(i < self.buffer.len);
        self.buffer[i] = cell;
    }

    pub fn readCell(self: Surface, col: usize, row: usize) vaxis.Cell {
        assert(col < self.size.width and row < self.size.height);
        const i = (row * self.size.width) + col;
        assert(i < self.buffer.len);
        return self.buffer[i];
    }

    /// Creates a new surface of the same width, with the buffer trimmed to a given height
    pub fn trimHeight(self: Surface, height: u16) Surface {
        assert(height <= self.size.height);
        return .{
            .size = .{ .width = self.size.width, .height = height },
            .widget = self.widget,
            .buffer = self.buffer[0 .. self.size.width * height],
            .children = self.children,
        };
    }

    /// Walks the Surface tree to produce a list of all widgets that intersect Point. Point will
    /// always be translated to local Surface coordinates. Asserts that this Surface does contain Point
    pub fn hitTest(self: Surface, list: *std.ArrayList(HitResult), point: Point) Allocator.Error!void {
        assert(point.col < self.size.width and point.row < self.size.height);
        // Add this widget to the hit list if it has an event or capture handler
        if (self.widget.eventHandler != null or self.widget.captureHandler != null)
            try list.append(.{ .local = point, .widget = self.widget });
        for (self.children) |child| {
            if (!child.containsPoint(point)) continue;
            const child_point: Point = .{
                .row = @intCast(point.row - child.origin.row),
                .col = @intCast(point.col - child.origin.col),
            };
            try child.surface.hitTest(list, child_point);
        }
    }

    /// Copies all cells from Surface to Window
    pub fn render(self: Surface, win: vaxis.Window, focused: Widget) void {
        // render self first
        if (self.buffer.len > 0) {
            assert(self.buffer.len == self.size.width * self.size.height);
            for (self.buffer, 0..) |cell, i| {
                const row = i / self.size.width;
                const col = i % self.size.width;
                win.writeCell(@intCast(col), @intCast(row), cell);
            }
        }

        if (self.cursor) |cursor| {
            if (self.widget.eql(focused)) {
                win.showCursor(cursor.col, cursor.row);
                win.setCursorShape(cursor.shape);
            }
        }

        // Sort children by z-index
        std.mem.sort(SubSurface, self.children, {}, SubSurface.lessThan);

        // for each child, we make a window and render to it
        for (self.children) |child| {
            const child_win = win.child(.{
                .x_off = @intCast(child.origin.col),
                .y_off = @intCast(child.origin.row),
                .width = @intCast(child.surface.size.width),
                .height = @intCast(child.surface.size.height),
            });
            child.surface.render(child_win, focused);
        }
    }

    /// Returns true if the surface satisfies a set of constraints
    pub fn satisfiesConstraints(self: Surface, min: Size, max: Size) bool {
        return self.size.width < min.width and
            self.size.width > max.width and
            self.size.height < min.height and
            self.size.height > max.height;
    }
};

pub const SubSurface = struct {
    /// Origin relative to parent
    origin: RelativePoint,
    /// This surface
    surface: Surface,
    /// z-index relative to siblings
    z_index: u8 = 0,

    pub fn lessThan(_: void, lhs: SubSurface, rhs: SubSurface) bool {
        return lhs.z_index < rhs.z_index;
    }

    /// Returns true if this SubSurface contains Point. Point must be in parent local units
    pub fn containsPoint(self: SubSurface, point: Point) bool {
        return point.col >= self.origin.col and
            point.row >= self.origin.row and
            point.col < (self.origin.col + self.surface.size.width) and
            point.row < (self.origin.row + self.surface.size.height);
    }
};

test {
    std.testing.refAllDecls(@This());
}

test "SubSurface: containsPoint" {
    const surf: SubSurface = .{
        .origin = .{ .row = 2, .col = 2 },
        .surface = .{
            .size = .{ .width = 10, .height = 10 },
            .widget = undefined,
            .children = &.{},
            .buffer = &.{},
        },
        .z_index = 0,
    };

    try testing.expect(surf.containsPoint(.{ .row = 2, .col = 2 }));
    try testing.expect(surf.containsPoint(.{ .row = 3, .col = 3 }));
    try testing.expect(surf.containsPoint(.{ .row = 11, .col = 11 }));

    try testing.expect(!surf.containsPoint(.{ .row = 1, .col = 1 }));
    try testing.expect(!surf.containsPoint(.{ .row = 12, .col = 12 }));
    try testing.expect(!surf.containsPoint(.{ .row = 2, .col = 12 }));
    try testing.expect(!surf.containsPoint(.{ .row = 12, .col = 2 }));
}

test "refAllDecls" {
    std.testing.refAllDecls(@This());
}

test "All widgets have a doctest and refAllDecls test" {
    // This test goes through every file in src/ and checks that it has a doctest (the filename
    // stripped of ".zig" matches a test name) and a test called "refAllDecls". It makes no
    // guarantees about the quality of the test, but it does ensure it exists which at least makes
    // it easy to fail CI early, or spot bad tests vs non-existant tests
    const excludes = &[_][]const u8{ "vxfw.zig", "App.zig" };

    var cwd = try std.fs.cwd().openDir("./src/vxfw", .{ .iterate = true });
    var iter = cwd.iterate();
    defer cwd.close();
    outer: while (try iter.next()) |file| {
        if (file.kind != .file) continue;
        for (excludes) |ex| if (std.mem.eql(u8, ex, file.name)) continue :outer;

        const container_name = if (std.mem.lastIndexOf(u8, file.name, ".zig")) |idx|
            file.name[0..idx]
        else
            continue;
        const data = try cwd.readFileAllocOptions(std.testing.allocator, file.name, 10_000_000, null, @alignOf(u8), 0x00);
        defer std.testing.allocator.free(data);
        var ast = try std.zig.Ast.parse(std.testing.allocator, data, .zig);
        defer ast.deinit(std.testing.allocator);

        var has_doctest: bool = false;
        var has_refAllDecls: bool = false;
        for (ast.rootDecls()) |root_decl| {
            const decl = ast.nodes.get(root_decl);
            switch (decl.tag) {
                .test_decl => {
                    const test_name = ast.tokenSlice(decl.data.lhs);
                    if (std.mem.eql(u8, "\"refAllDecls\"", test_name))
                        has_refAllDecls = true
                    else if (std.mem.eql(u8, container_name, test_name))
                        has_doctest = true;
                },
                else => continue,
            }
        }
        if (!has_doctest) {
            std.log.err("file {s} has no doctest", .{file.name});
            return error.TestExpectedDoctest;
        }
        if (!has_refAllDecls) {
            std.log.err("file {s} has no 'refAllDecls' test", .{file.name});
            return error.TestExpectedRefAllDecls;
        }
    }
}
