const std = @import("std");

const Screen = @import("Screen.zig");
const Cell = @import("Cell.zig");
const Mouse = @import("Mouse.zig");
const Segment = @import("Cell.zig").Segment;
const Unicode = @import("Unicode.zig");
const gw = @import("gwidth.zig");

const Window = @This();

/// absolute horizontal offset from the screen
x_off: i17,
/// absolute vertical offset from the screen
y_off: i17,
/// relative horizontal offset, from parent window. This only accumulates if it is negative so that
/// we can clip the window correctly
parent_x_off: i17,
/// relative vertical offset, from parent window. This only accumulates if it is negative so that
/// we can clip the window correctly
parent_y_off: i17,
/// width of the window. This can't be larger than the terminal screen
width: u16,
/// height of the window. This can't be larger than the terminal screen
height: u16,

screen: *Screen,

/// Creates a new window with offset relative to parent and size clamped to the
/// parent's size. Windows do not retain a reference to their parent and are
/// unaware of resizes.
fn initChild(
    self: Window,
    x_off: i17,
    y_off: i17,
    maybe_width: ?u16,
    maybe_height: ?u16,
) Window {
    const max_height = @max(self.height - y_off, 0);
    const max_width = @max(self.width - x_off, 0);
    const width: u16 = maybe_width orelse max_width;
    const height: u16 = maybe_height orelse max_height;

    return Window{
        .x_off = x_off + self.x_off,
        .y_off = y_off + self.y_off,
        .parent_x_off = @min(self.parent_x_off + x_off, 0),
        .parent_y_off = @min(self.parent_y_off + y_off, 0),
        .width = @min(width, max_width),
        .height = @min(height, max_height),
        .screen = self.screen,
    };
}

pub const ChildOptions = struct {
    x_off: i17 = 0,
    y_off: i17 = 0,
    /// the width of the resulting child, including any borders
    width: ?u16 = null,
    /// the height of the resulting child, including any borders
    height: ?u16 = null,
    border: BorderOptions = .{},
};

pub const BorderOptions = struct {
    style: Cell.Style = .{},
    where: union(enum) {
        none,
        all,
        top,
        right,
        bottom,
        left,
        other: Locations,
    } = .none,
    glyphs: Glyphs = .single_rounded,

    pub const Locations = packed struct {
        top: bool = false,
        right: bool = false,
        bottom: bool = false,
        left: bool = false,
    };

    pub const Glyphs = union(enum) {
        single_rounded,
        single_square,
        /// custom border glyphs. each glyph should be one cell wide and the
        /// following indices apply:
        /// [0] = top left
        /// [1] = horizontal
        /// [2] = top right
        /// [3] = vertical
        /// [4] = bottom right
        /// [5] = bottom left
        custom: [6][]const u8,
    };

    const single_rounded: [6][]const u8 = .{ "╭", "─", "╮", "│", "╯", "╰" };
    const single_square: [6][]const u8 = .{ "┌", "─", "┐", "│", "┘", "└" };
};

/// create a child window
pub fn child(self: Window, opts: ChildOptions) Window {
    var result = self.initChild(opts.x_off, opts.y_off, opts.width, opts.height);

    const glyphs = switch (opts.border.glyphs) {
        .single_rounded => BorderOptions.single_rounded,
        .single_square => BorderOptions.single_square,
        .custom => |custom| custom,
    };

    const top_left: Cell.Character = .{ .grapheme = glyphs[0], .width = 1 };
    const horizontal: Cell.Character = .{ .grapheme = glyphs[1], .width = 1 };
    const top_right: Cell.Character = .{ .grapheme = glyphs[2], .width = 1 };
    const vertical: Cell.Character = .{ .grapheme = glyphs[3], .width = 1 };
    const bottom_right: Cell.Character = .{ .grapheme = glyphs[4], .width = 1 };
    const bottom_left: Cell.Character = .{ .grapheme = glyphs[5], .width = 1 };
    const style = opts.border.style;

    const h = result.height;
    const w = result.width;

    const loc: BorderOptions.Locations = switch (opts.border.where) {
        .none => return result,
        .all => .{ .top = true, .bottom = true, .right = true, .left = true },
        .bottom => .{ .bottom = true },
        .right => .{ .right = true },
        .left => .{ .left = true },
        .top => .{ .top = true },
        .other => |loc| loc,
    };
    if (loc.top) {
        var i: u16 = 0;
        while (i < w) : (i += 1) {
            result.writeCell(i, 0, .{ .char = horizontal, .style = style });
        }
    }
    if (loc.bottom) {
        var i: u16 = 0;
        while (i < w) : (i += 1) {
            result.writeCell(i, h -| 1, .{ .char = horizontal, .style = style });
        }
    }
    if (loc.left) {
        var i: u16 = 0;
        while (i < h) : (i += 1) {
            result.writeCell(0, i, .{ .char = vertical, .style = style });
        }
    }
    if (loc.right) {
        var i: u16 = 0;
        while (i < h) : (i += 1) {
            result.writeCell(w -| 1, i, .{ .char = vertical, .style = style });
        }
    }
    // draw corners
    if (loc.top and loc.left)
        result.writeCell(0, 0, .{ .char = top_left, .style = style });
    if (loc.top and loc.right)
        result.writeCell(w -| 1, 0, .{ .char = top_right, .style = style });
    if (loc.bottom and loc.left)
        result.writeCell(0, h -| 1, .{ .char = bottom_left, .style = style });
    if (loc.bottom and loc.right)
        result.writeCell(w -| 1, h -| 1, .{ .char = bottom_right, .style = style });

    const x_off: u16 = if (loc.left) 1 else 0;
    const y_off: u16 = if (loc.top) 1 else 0;
    const h_delt: u16 = if (loc.bottom) 1 else 0;
    const w_delt: u16 = if (loc.right) 1 else 0;
    const h_ch: u16 = h -| y_off -| h_delt;
    const w_ch: u16 = w -| x_off -| w_delt;
    return result.initChild(x_off, y_off, w_ch, h_ch);
}

/// writes a cell to the location in the window
pub fn writeCell(self: Window, col: u16, row: u16, cell: Cell) void {
    if (self.height <= row or
        self.width <= col or
        self.x_off + col < 0 or
        self.y_off + row < 0 or
        self.parent_x_off + col < 0 or
        self.parent_y_off + row < 0)
        return;

    self.screen.writeCell(@intCast(col + self.x_off), @intCast(row + self.y_off), cell);
}

/// reads a cell at the location in the window
pub fn readCell(self: Window, col: u16, row: u16) ?Cell {
    if (self.height <= row or
        self.width <= col or
        self.x_off + col < 0 or
        self.y_off + row < 0 or
        self.parent_x_off + col < 0 or
        self.parent_y_off + row < 0)
        return null;
    return self.screen.readCell(@intCast(col + self.x_off), @intCast(row + self.y_off));
}

/// fills the window with the default cell
pub fn clear(self: Window) void {
    self.fill(.{ .default = true });
}

/// returns the width of the grapheme. This depends on the terminal capabilities
pub fn gwidth(self: Window, str: []const u8) u16 {
    return gw.gwidth(str, self.screen.width_method, &self.screen.unicode.width_data);
}

/// fills the window with the provided cell
pub fn fill(self: Window, cell: Cell) void {
    if (self.x_off + self.width < 0 or
        self.y_off + self.height < 0 or
        self.screen.width < self.x_off or
        self.screen.height < self.y_off)
        return;
    const first_row: usize = @intCast(@max(self.y_off, 0));
    if (self.x_off == 0 and self.width == self.screen.width) {
        // we have a full width window, therefore contiguous memory.
        const start = @min(first_row * self.width, self.screen.buf.len);
        const end = @min(start + (@as(usize, @intCast(self.height)) * self.width), self.screen.buf.len);
        @memset(self.screen.buf[start..end], cell);
    } else {
        // Non-contiguous. Iterate over rows an memset
        var row: usize = first_row;
        const first_col: usize = @max(self.x_off, 0);
        const last_row = @min(self.height + self.y_off, self.screen.height);
        while (row < last_row) : (row += 1) {
            const start = @min(first_col + (row * self.screen.width), self.screen.buf.len);
            var end = @min(start + self.width, start + (self.screen.width - first_col));
            end = @min(end, self.screen.buf.len);
            @memset(self.screen.buf[start..end], cell);
        }
    }
}

/// hide the cursor
pub fn hideCursor(self: Window) void {
    self.screen.cursor_vis = false;
}

/// show the cursor at the given coordinates, 0 indexed
pub fn showCursor(self: Window, col: u16, row: u16) void {
    if (self.x_off + col < 0 or
        self.y_off + row < 0 or
        row >= self.height or
        col >= self.width)
        return;
    self.screen.cursor_vis = true;
    self.screen.cursor_row = @intCast(row + self.y_off);
    self.screen.cursor_col = @intCast(col + self.x_off);
}

pub fn setCursorShape(self: Window, shape: Cell.CursorShape) void {
    self.screen.cursor_shape = shape;
}

/// Options to use when printing Segments to a window
pub const PrintOptions = struct {
    /// vertical offset to start printing at
    row_offset: u16 = 0,
    /// horizontal offset to start printing at
    col_offset: u16 = 0,

    /// wrap behavior for printing
    wrap: enum {
        /// wrap at grapheme boundaries
        grapheme,
        /// wrap at word boundaries
        word,
        /// stop printing after one line
        none,
    } = .grapheme,

    /// when true, print will write to the screen for rendering. When false,
    /// nothing is written. The return value describes the size of the wrapped
    /// text
    commit: bool = true,
};

pub const PrintResult = struct {
    col: u16,
    row: u16,
    overflow: bool,
};

/// prints segments to the window. returns true if the text overflowed with the
/// given wrap strategy and size.
pub fn print(self: Window, segments: []const Segment, opts: PrintOptions) PrintResult {
    var row = opts.row_offset;
    switch (opts.wrap) {
        .grapheme => {
            var col: u16 = opts.col_offset;
            const overflow: bool = blk: for (segments) |segment| {
                var iter = self.screen.unicode.graphemeIterator(segment.text);
                while (iter.next()) |grapheme| {
                    if (col >= self.width) {
                        row += 1;
                        col = 0;
                    }
                    if (row >= self.height) break :blk true;
                    const s = grapheme.bytes(segment.text);
                    if (std.mem.eql(u8, s, "\n")) {
                        row +|= 1;
                        col = 0;
                        continue;
                    }
                    const w = self.gwidth(s);
                    if (w == 0) continue;
                    if (opts.commit) self.writeCell(col, row, .{
                        .char = .{
                            .grapheme = s,
                            .width = @intCast(w),
                        },
                        .style = segment.style,
                        .link = segment.link,
                        .wrapped = col + w >= self.width,
                    });
                    col += w;
                }
            } else false;
            if (col >= self.width) {
                row += 1;
                col = 0;
            }
            return .{
                .row = row,
                .col = col,
                .overflow = overflow,
            };
        },
        .word => {
            var col: u16 = opts.col_offset;
            var overflow: bool = false;
            var soft_wrapped: bool = false;
            outer: for (segments) |segment| {
                var line_iter: LineIterator = .{ .buf = segment.text };
                while (line_iter.next()) |line| {
                    defer {
                        // We only set soft_wrapped to false if a segment actually contains a linebreak
                        if (line_iter.has_break) {
                            soft_wrapped = false;
                            row += 1;
                            col = 0;
                        }
                    }
                    var iter: WhitespaceTokenizer = .{ .buf = line };
                    while (iter.next()) |token| {
                        switch (token) {
                            .whitespace => |len| {
                                if (soft_wrapped) continue;
                                for (0..len) |_| {
                                    if (col >= self.width) {
                                        col = 0;
                                        row += 1;
                                        break;
                                    }
                                    if (opts.commit) {
                                        self.writeCell(col, row, .{
                                            .char = .{
                                                .grapheme = " ",
                                                .width = 1,
                                            },
                                            .style = segment.style,
                                            .link = segment.link,
                                        });
                                    }
                                    col += 1;
                                }
                            },
                            .word => |word| {
                                const width = self.gwidth(word);
                                if (width + col > self.width and width < self.width) {
                                    row += 1;
                                    col = 0;
                                }

                                var grapheme_iterator = self.screen.unicode.graphemeIterator(word);
                                while (grapheme_iterator.next()) |grapheme| {
                                    soft_wrapped = false;
                                    if (row >= self.height) {
                                        overflow = true;
                                        break :outer;
                                    }
                                    const s = grapheme.bytes(word);
                                    const w = self.gwidth(s);
                                    if (opts.commit) self.writeCell(col, row, .{
                                        .char = .{
                                            .grapheme = s,
                                            .width = @intCast(w),
                                        },
                                        .style = segment.style,
                                        .link = segment.link,
                                    });
                                    col += w;
                                    if (col >= self.width) {
                                        row += 1;
                                        col = 0;
                                        soft_wrapped = true;
                                    }
                                }
                            },
                        }
                    }
                }
            }
            return .{
                // remove last row counter
                .row = row,
                .col = col,
                .overflow = overflow,
            };
        },
        .none => {
            var col: u16 = opts.col_offset;
            const overflow: bool = blk: for (segments) |segment| {
                var iter = self.screen.unicode.graphemeIterator(segment.text);
                while (iter.next()) |grapheme| {
                    if (col >= self.width) break :blk true;
                    const s = grapheme.bytes(segment.text);
                    if (std.mem.eql(u8, s, "\n")) break :blk true;
                    const w = self.gwidth(s);
                    if (w == 0) continue;
                    if (opts.commit) self.writeCell(col, row, .{
                        .char = .{
                            .grapheme = s,
                            .width = @intCast(w),
                        },
                        .style = segment.style,
                        .link = segment.link,
                    });
                    col +|= w;
                }
            } else false;
            return .{
                .row = row,
                .col = col,
                .overflow = overflow,
            };
        },
    }
    return false;
}

/// print a single segment. This is just a shortcut for print(&.{segment}, opts)
pub fn printSegment(self: Window, segment: Segment, opts: PrintOptions) PrintResult {
    return self.print(&.{segment}, opts);
}

/// scrolls the window down one row (IE inserts a blank row at the bottom of the
/// screen and shifts all rows up one)
pub fn scroll(self: Window, n: u16) void {
    if (n > self.height) return;
    var row: u16 = @max(self.y_off, 0);
    const first_col: u16 = @max(self.x_off, 0);
    while (row < self.height - n) : (row += 1) {
        const dst_start = (row * self.screen.width) + first_col;
        const dst_end = dst_start + self.width;

        const src_start = ((row + n) * self.screen.width) + first_col;
        const src_end = src_start + self.width;
        @memcpy(self.screen.buf[dst_start..dst_end], self.screen.buf[src_start..src_end]);
    }
    const last_row = self.child(.{
        .y_off = self.height - n,
    });
    last_row.clear();
}

/// returns the mouse event if the mouse event occurred within the window. If
/// the mouse event occurred outside the window, null is returned
pub fn hasMouse(win: Window, mouse: ?Mouse) ?Mouse {
    const event = mouse orelse return null;
    if (event.col >= win.x_off and
        event.col < (win.x_off + win.width) and
        event.row >= win.y_off and
        event.row < (win.y_off + win.height)) return event else return null;
}

test "Window size set" {
    var parent = Window{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = 20,
        .height = 20,
        .screen = undefined,
    };

    const ch = parent.initChild(1, 1, null, null);
    try std.testing.expectEqual(19, ch.width);
    try std.testing.expectEqual(19, ch.height);
}

test "Window size set too big" {
    var parent = Window{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = 20,
        .height = 20,
        .screen = undefined,
    };

    const ch = parent.initChild(0, 0, 21, 21);
    try std.testing.expectEqual(20, ch.width);
    try std.testing.expectEqual(20, ch.height);
}

test "Window size set too big with offset" {
    var parent = Window{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = 20,
        .height = 20,
        .screen = undefined,
    };

    const ch = parent.initChild(10, 10, 21, 21);
    try std.testing.expectEqual(10, ch.width);
    try std.testing.expectEqual(10, ch.height);
}

test "Window size nested offsets" {
    var parent = Window{
        .x_off = 1,
        .y_off = 1,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = 20,
        .height = 20,
        .screen = undefined,
    };

    const ch = parent.initChild(10, 10, 21, 21);
    try std.testing.expectEqual(11, ch.x_off);
    try std.testing.expectEqual(11, ch.y_off);
}

test "Window offsets" {
    var parent = Window{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = 20,
        .height = 20,
        .screen = undefined,
    };

    const ch = parent.initChild(10, 10, 21, 21);
    const ch2 = ch.initChild(-4, -4, null, null);
    // Reading ch2 at row 0 should be null
    try std.testing.expect(ch2.readCell(0, 0) == null);
    // Should not panic us
    ch2.writeCell(0, 0, undefined);
}

test "print: grapheme" {
    const alloc = std.testing.allocator_instance.allocator();
    const unicode = try Unicode.init(alloc);
    defer unicode.deinit();
    var screen: Screen = .{ .width_method = .unicode, .unicode = &unicode };
    const win: Window = .{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = 4,
        .height = 2,
        .screen = &screen,
    };
    const opts: PrintOptions = .{
        .commit = false,
        .wrap = .grapheme,
    };

    {
        var segments = [_]Segment{
            .{ .text = "a" },
        };
        const result = win.print(&segments, opts);
        try std.testing.expectEqual(1, result.col);
        try std.testing.expectEqual(0, result.row);
        try std.testing.expectEqual(false, result.overflow);
    }
    {
        var segments = [_]Segment{
            .{ .text = "abcd" },
        };
        const result = win.print(&segments, opts);
        try std.testing.expectEqual(0, result.col);
        try std.testing.expectEqual(1, result.row);
        try std.testing.expectEqual(false, result.overflow);
    }
    {
        var segments = [_]Segment{
            .{ .text = "abcde" },
        };
        const result = win.print(&segments, opts);
        try std.testing.expectEqual(1, result.col);
        try std.testing.expectEqual(1, result.row);
        try std.testing.expectEqual(false, result.overflow);
    }
    {
        var segments = [_]Segment{
            .{ .text = "abcdefgh" },
        };
        const result = win.print(&segments, opts);
        try std.testing.expectEqual(0, result.col);
        try std.testing.expectEqual(2, result.row);
        try std.testing.expectEqual(false, result.overflow);
    }
    {
        var segments = [_]Segment{
            .{ .text = "abcdefghi" },
        };
        const result = win.print(&segments, opts);
        try std.testing.expectEqual(0, result.col);
        try std.testing.expectEqual(2, result.row);
        try std.testing.expectEqual(true, result.overflow);
    }
}

test "print: word" {
    const alloc = std.testing.allocator_instance.allocator();
    const unicode = try Unicode.init(alloc);
    defer unicode.deinit();
    var screen: Screen = .{
        .width_method = .unicode,
        .unicode = &unicode,
    };
    const win: Window = .{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = 4,
        .height = 2,
        .screen = &screen,
    };
    const opts: PrintOptions = .{
        .commit = false,
        .wrap = .word,
    };

    {
        var segments = [_]Segment{
            .{ .text = "a" },
        };
        const result = win.print(&segments, opts);
        try std.testing.expectEqual(1, result.col);
        try std.testing.expectEqual(0, result.row);
        try std.testing.expectEqual(false, result.overflow);
    }
    {
        var segments = [_]Segment{
            .{ .text = " " },
        };
        const result = win.print(&segments, opts);
        try std.testing.expectEqual(1, result.col);
        try std.testing.expectEqual(0, result.row);
        try std.testing.expectEqual(false, result.overflow);
    }
    {
        var segments = [_]Segment{
            .{ .text = " a" },
        };
        const result = win.print(&segments, opts);
        try std.testing.expectEqual(2, result.col);
        try std.testing.expectEqual(0, result.row);
        try std.testing.expectEqual(false, result.overflow);
    }
    {
        var segments = [_]Segment{
            .{ .text = "a b" },
        };
        const result = win.print(&segments, opts);
        try std.testing.expectEqual(3, result.col);
        try std.testing.expectEqual(0, result.row);
        try std.testing.expectEqual(false, result.overflow);
    }
    {
        var segments = [_]Segment{
            .{ .text = "a b c" },
        };
        const result = win.print(&segments, opts);
        try std.testing.expectEqual(1, result.col);
        try std.testing.expectEqual(1, result.row);
        try std.testing.expectEqual(false, result.overflow);
    }
    {
        var segments = [_]Segment{
            .{ .text = "hello" },
        };
        const result = win.print(&segments, opts);
        try std.testing.expectEqual(1, result.col);
        try std.testing.expectEqual(1, result.row);
        try std.testing.expectEqual(false, result.overflow);
    }
    {
        var segments = [_]Segment{
            .{ .text = "hi tim" },
        };
        const result = win.print(&segments, opts);
        try std.testing.expectEqual(3, result.col);
        try std.testing.expectEqual(1, result.row);
        try std.testing.expectEqual(false, result.overflow);
    }
    {
        var segments = [_]Segment{
            .{ .text = "hello tim" },
        };
        const result = win.print(&segments, opts);
        try std.testing.expectEqual(0, result.col);
        try std.testing.expectEqual(2, result.row);
        try std.testing.expectEqual(true, result.overflow);
    }
    {
        var segments = [_]Segment{
            .{ .text = "hello ti" },
        };
        const result = win.print(&segments, opts);
        try std.testing.expectEqual(0, result.col);
        try std.testing.expectEqual(2, result.row);
        try std.testing.expectEqual(false, result.overflow);
    }
    {
        var segments = [_]Segment{
            .{ .text = "h" },
            .{ .text = "e" },
        };
        const result = win.print(&segments, opts);
        try std.testing.expectEqual(2, result.col);
        try std.testing.expectEqual(0, result.row);
        try std.testing.expectEqual(false, result.overflow);
    }
    {
        var segments = [_]Segment{
            .{ .text = "h" },
            .{ .text = "e" },
            .{ .text = "l" },
            .{ .text = "l" },
            .{ .text = "o" },
        };
        const result = win.print(&segments, opts);
        try std.testing.expectEqual(1, result.col);
        try std.testing.expectEqual(1, result.row);
        try std.testing.expectEqual(false, result.overflow);
    }
    {
        var segments = [_]Segment{
            .{ .text = "he\n" },
        };
        const result = win.print(&segments, opts);
        try std.testing.expectEqual(0, result.col);
        try std.testing.expectEqual(1, result.row);
        try std.testing.expectEqual(false, result.overflow);
    }
    {
        var segments = [_]Segment{
            .{ .text = "he\n\n" },
        };
        const result = win.print(&segments, opts);
        try std.testing.expectEqual(0, result.col);
        try std.testing.expectEqual(2, result.row);
        try std.testing.expectEqual(false, result.overflow);
    }
    {
        var segments = [_]Segment{
            .{ .text = "not now" },
        };
        const result = win.print(&segments, opts);
        try std.testing.expectEqual(3, result.col);
        try std.testing.expectEqual(1, result.row);
        try std.testing.expectEqual(false, result.overflow);
    }
    {
        var segments = [_]Segment{
            .{ .text = "note now" },
        };
        const result = win.print(&segments, opts);
        try std.testing.expectEqual(3, result.col);
        try std.testing.expectEqual(1, result.row);
        try std.testing.expectEqual(false, result.overflow);
    }
    {
        var segments = [_]Segment{
            .{ .text = "note" },
            .{ .text = " now" },
        };
        const result = win.print(&segments, opts);
        try std.testing.expectEqual(3, result.col);
        try std.testing.expectEqual(1, result.row);
        try std.testing.expectEqual(false, result.overflow);
    }
    {
        var segments = [_]Segment{
            .{ .text = "note " },
            .{ .text = "now" },
        };
        const result = win.print(&segments, opts);
        try std.testing.expectEqual(3, result.col);
        try std.testing.expectEqual(1, result.row);
        try std.testing.expectEqual(false, result.overflow);
    }
}

/// Iterates a slice of bytes by linebreaks. Lines are split by '\r', '\n', or '\r\n'
const LineIterator = struct {
    buf: []const u8,
    index: usize = 0,
    has_break: bool = true,

    fn next(self: *LineIterator) ?[]const u8 {
        if (self.index >= self.buf.len) return null;

        const start = self.index;
        const end = std.mem.indexOfAnyPos(u8, self.buf, self.index, "\r\n") orelse {
            if (start == 0) self.has_break = false;
            self.index = self.buf.len;
            return self.buf[start..];
        };

        self.index = end;
        self.consumeCR();
        self.consumeLF();
        return self.buf[start..end];
    }

    // consumes a \n byte
    fn consumeLF(self: *LineIterator) void {
        if (self.index >= self.buf.len) return;
        if (self.buf[self.index] == '\n') self.index += 1;
    }

    // consumes a \r byte
    fn consumeCR(self: *LineIterator) void {
        if (self.index >= self.buf.len) return;
        if (self.buf[self.index] == '\r') self.index += 1;
    }
};

/// Returns tokens of text and whitespace
const WhitespaceTokenizer = struct {
    buf: []const u8,
    index: usize = 0,

    const Token = union(enum) {
        // the length of whitespace. Tab = 8
        whitespace: usize,
        word: []const u8,
    };

    fn next(self: *WhitespaceTokenizer) ?Token {
        if (self.index >= self.buf.len) return null;
        const Mode = enum {
            whitespace,
            word,
        };
        const first = self.buf[self.index];
        const mode: Mode = if (first == ' ' or first == '\t') .whitespace else .word;
        switch (mode) {
            .whitespace => {
                var len: usize = 0;
                while (self.index < self.buf.len) : (self.index += 1) {
                    switch (self.buf[self.index]) {
                        ' ' => len += 1,
                        '\t' => len += 8,
                        else => break,
                    }
                }
                return .{ .whitespace = len };
            },
            .word => {
                const start = self.index;
                while (self.index < self.buf.len) : (self.index += 1) {
                    switch (self.buf[self.index]) {
                        ' ', '\t' => break,
                        else => {},
                    }
                }
                return .{ .word = self.buf[start..self.index] };
            },
        }
    }
};

test "refAllDecls" {
    std.testing.refAllDecls(@This());
}
