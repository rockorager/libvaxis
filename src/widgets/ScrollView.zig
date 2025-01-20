const std = @import("std");
const vaxis = @import("../main.zig");

pub const Scroll = struct {
    x: usize = 0,
    y: usize = 0,

    pub fn restrictTo(self: *@This(), w: usize, h: usize) void {
        self.x = @min(self.x, w);
        self.y = @min(self.y, h);
    }
};

pub const VerticalScrollbar = struct {
    character: vaxis.Cell.Character = .{ .grapheme = "▐", .width = 1 },
    fg: vaxis.Style = .{},
    bg: vaxis.Style = .{ .fg = .{ .index = 8 } },
};

scroll: Scroll = .{},
vertical_scrollbar: ?VerticalScrollbar = .{},

/// Standard input mappings.
/// It is not neccessary to use this, you can set `scroll` manually.
pub fn input(self: *@This(), key: vaxis.Key) void {
    if (key.matches(vaxis.Key.right, .{})) {
        self.scroll.x +|= 1;
    } else if (key.matches(vaxis.Key.right, .{ .shift = true })) {
        self.scroll.x +|= 32;
    } else if (key.matches(vaxis.Key.left, .{})) {
        self.scroll.x -|= 1;
    } else if (key.matches(vaxis.Key.left, .{ .shift = true })) {
        self.scroll.x -|= 32;
    } else if (key.matches(vaxis.Key.up, .{})) {
        self.scroll.y -|= 1;
    } else if (key.matches(vaxis.Key.page_up, .{})) {
        self.scroll.y -|= 32;
    } else if (key.matches(vaxis.Key.down, .{})) {
        self.scroll.y +|= 1;
    } else if (key.matches(vaxis.Key.page_down, .{})) {
        self.scroll.y +|= 32;
    } else if (key.matches(vaxis.Key.end, .{})) {
        self.scroll.y = std.math.maxInt(usize);
    } else if (key.matches(vaxis.Key.home, .{})) {
        self.scroll.y = 0;
    }
}

/// Must be called before doing any `writeCell` calls.
pub fn draw(self: *@This(), parent: vaxis.Window, content_size: struct {
    cols: usize,
    rows: usize,
}) void {
    const content_cols = if (self.vertical_scrollbar) |_| content_size.cols +| 1 else content_size.cols;
    const max_scroll_x = content_cols -| parent.width;
    const max_scroll_y = content_size.rows -| parent.height;
    self.scroll.restrictTo(max_scroll_x, max_scroll_y);
    if (self.vertical_scrollbar) |opts| {
        const vbar: vaxis.widgets.Scrollbar = .{
            .character = opts.character,
            .style = opts.fg,
            .total = content_size.rows,
            .view_size = parent.height,
            .top = self.scroll.y,
        };
        const bg = parent.child(.{
            .x_off = parent.width -| opts.character.width,
            .width = opts.character.width,
            .height = parent.height,
        });
        bg.fill(.{ .char = opts.character, .style = opts.bg });
        vbar.draw(bg);
    }
}

pub const BoundingBox = struct {
    x1: usize,
    y1: usize,
    x2: usize,
    y2: usize,

    pub inline fn below(self: @This(), row: usize) bool {
        return row < self.y1;
    }

    pub inline fn above(self: @This(), row: usize) bool {
        return row >= self.y2;
    }

    pub inline fn rowInside(self: @This(), row: usize) bool {
        return row >= self.y1 and row < self.y2;
    }

    pub inline fn colInside(self: @This(), col: usize) bool {
        return col >= self.x1 and col < self.x2;
    }

    pub inline fn inside(self: @This(), col: usize, row: usize) bool {
        return self.rowInside(row) and self.colInside(col);
    }
};

/// Boundary of the content, useful for culling to improve draw performance.
pub fn bounds(self: *@This(), parent: vaxis.Window) BoundingBox {
    const right_pad: usize = if (self.vertical_scrollbar != null) 1 else 0;
    return .{
        .x1 = self.scroll.x,
        .y1 = self.scroll.y,
        .x2 = self.scroll.x +| parent.width -| right_pad,
        .y2 = self.scroll.y +| parent.height,
    };
}

/// Use this function instead of `Window.writeCell` to draw your cells and they will magically scroll.
pub fn writeCell(self: *@This(), parent: vaxis.Window, col: usize, row: usize, cell: vaxis.Cell) void {
    const b = self.bounds(parent);
    if (!b.inside(col, row)) return;
    const win = parent.child(.{ .width = @intCast(b.x2 - b.x1), .height = @intCast(b.y2 - b.y1) });
    win.writeCell(@intCast(col -| self.scroll.x), @intCast(row -| self.scroll.y), cell);
}

/// Use this function instead of `Window.readCell` to read the correct cell in scrolling context.
pub fn readCell(self: *@This(), parent: vaxis.Window, col: usize, row: usize) ?vaxis.Cell {
    const b = self.bounds(parent);
    if (!b.inside(col, row)) return;
    const win = parent.child(.{ .width = @intCast(b.x2 - b.x1), .height = @intCast(b.y2 - b.y1) });
    return win.readCell(@intCast(col -| self.scroll.x), @intCast(row -| self.scroll.y));
}
