const std = @import("std");

const Screen = @import("Screen.zig");
const Cell = @import("Cell.zig");
const Mouse = @import("Mouse.zig");
const Segment = @import("Cell.zig").Segment;
const Unicode = @import("Unicode.zig");
const gw = @import("gwidth.zig");

const log = std.log.scoped(.window);

const Window = @This();

pub const Size = union(enum) {
    expand,
    limit: usize,
};

/// horizontal offset from the screen
x_off: usize,
/// vertical offset from the screen
y_off: usize,
/// width of the window. This can't be larger than the terminal screen
width: usize,
/// height of the window. This can't be larger than the terminal screen
height: usize,

screen: *Screen,

/// Deprecated. Use `child` instead
///
/// Creates a new window with offset relative to parent and size clamped to the
/// parent's size. Windows do not retain a reference to their parent and are
/// unaware of resizes.
pub fn initChild(
    self: Window,
    x_off: usize,
    y_off: usize,
    width: Size,
    height: Size,
) Window {
    const resolved_width = switch (width) {
        .expand => self.width -| x_off,
        .limit => |w| blk: {
            if (w + x_off > self.width) {
                break :blk self.width -| x_off;
            }
            break :blk w;
        },
    };
    const resolved_height = switch (height) {
        .expand => self.height -| y_off,
        .limit => |h| blk: {
            if (h + y_off > self.height) {
                break :blk self.height -| y_off;
            }
            break :blk h;
        },
    };
    return Window{
        .x_off = x_off + self.x_off,
        .y_off = y_off + self.y_off,
        .width = resolved_width,
        .height = resolved_height,
        .screen = self.screen,
    };
}

pub const ChildOptions = struct {
    x_off: usize = 0,
    y_off: usize = 0,
    /// the width of the resulting child, including any borders
    width: Size = .expand,
    /// the height of the resulting child, including any borders
    height: Size = .expand,
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
        var i: usize = 0;
        while (i < w) : (i += 1) {
            result.writeCell(i, 0, .{ .char = horizontal, .style = style });
        }
    }
    if (loc.bottom) {
        var i: usize = 0;
        while (i < w) : (i += 1) {
            result.writeCell(i, h -| 1, .{ .char = horizontal, .style = style });
        }
    }
    if (loc.left) {
        var i: usize = 0;
        while (i < h) : (i += 1) {
            result.writeCell(0, i, .{ .char = vertical, .style = style });
        }
    }
    if (loc.right) {
        var i: usize = 0;
        while (i < h) : (i += 1) {
            result.writeCell(w -| 1, i, .{ .char = vertical, .style = style });
        }
    }
    // draw corners
    if (loc.top and loc.left)
        result.writeCell(0, 0, .{ .char = top_left, .style = style });
    if (loc.top and loc.right)
        result.writeCell(w - 1, 0, .{ .char = top_right, .style = style });
    if (loc.bottom and loc.left)
        result.writeCell(0, h -| 1, .{ .char = bottom_left, .style = style });
    if (loc.bottom and loc.right)
        result.writeCell(w - 1, h -| 1, .{ .char = bottom_right, .style = style });

    const x_off: usize = if (loc.left) 1 else 0;
    const y_off: usize = if (loc.top) 1 else 0;
    const h_delt: usize = if (loc.bottom) 1 else 0;
    const w_delt: usize = if (loc.right) 1 else 0;
    const h_ch: usize = h - y_off - h_delt;
    const w_ch: usize = w - x_off - w_delt;
    return result.initChild(x_off, y_off, .{ .limit = w_ch }, .{ .limit = h_ch });
}

/// writes a cell to the location in the window
pub fn writeCell(self: Window, col: usize, row: usize, cell: Cell) void {
    if (self.height == 0 or self.width == 0) return;
    if (self.height <= row or self.width <= col) return;
    self.screen.writeCell(col + self.x_off, row + self.y_off, cell);
}

/// reads a cell at the location in the window
pub fn readCell(self: Window, col: usize, row: usize) ?Cell {
    if (self.height == 0 or self.width == 0) return null;
    if (self.height <= row or self.width <= col) return null;
    return self.screen.readCell(col + self.x_off, row + self.y_off);
}

/// fills the window with the default cell
pub fn clear(self: Window) void {
    self.fill(.{ .default = true });
}

/// returns the width of the grapheme. This depends on the terminal capabilities
pub fn gwidth(self: Window, str: []const u8) usize {
    return gw.gwidth(str, self.screen.width_method, &self.screen.unicode.width_data) catch 1;
}

/// fills the window with the provided cell
pub fn fill(self: Window, cell: Cell) void {
    if (self.x_off == 0 and self.width == self.screen.width) {
        // we have a full width window, therefore contiguous memory.
        const start = self.y_off * self.width;
        const end = start + (self.height * self.width);
        @memset(self.screen.buf[start..end], cell);
    } else {
        // Non-contiguous. Iterate over rows an memset
        var row: usize = self.y_off;
        while (row < (self.height + self.y_off)) : (row += 1) {
            const start = self.x_off + (row * self.screen.width);
            const end = start + self.width;
            @memset(self.screen.buf[start..end], cell);
        }
    }
}

/// hide the cursor
pub fn hideCursor(self: Window) void {
    self.screen.cursor_vis = false;
}

/// show the cursor at the given coordinates, 0 indexed
pub fn showCursor(self: Window, col: usize, row: usize) void {
    if (self.height == 0 or self.width == 0) return;
    if (self.height <= row or self.width <= col) return;
    self.screen.cursor_vis = true;
    self.screen.cursor_row = row + self.y_off;
    self.screen.cursor_col = col + self.x_off;
}

pub fn setCursorShape(self: Window, shape: Cell.CursorShape) void {
    self.screen.cursor_shape = shape;
}

/// Options to use when printing Segments to a window
pub const PrintOptions = struct {
    /// vertical offset to start printing at
    row_offset: usize = 0,

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
    col: usize,
    row: usize,
    overflow: bool,
};

/// prints segments to the window. returns true if the text overflowed with the
/// given wrap strategy and size.
pub fn print(self: Window, segments: []const Segment, opts: PrintOptions) !PrintResult {
    var row = opts.row_offset;
    switch (opts.wrap) {
        .grapheme => {
            var col: usize = 0;
            const overflow: bool = blk: for (segments) |segment| {
                var iter = self.screen.unicode.graphemeIterator(segment.text);
                while (iter.next()) |grapheme| {
                    if (row >= self.height) break :blk true;
                    const s = grapheme.bytes(segment.text);
                    if (std.mem.eql(u8, s, "\n")) {
                        row += 1;
                        col = 0;
                        continue;
                    }
                    const w = self.gwidth(s);
                    if (w == 0) continue;
                    if (opts.commit) self.writeCell(col, row, .{
                        .char = .{
                            .grapheme = s,
                            .width = w,
                        },
                        .style = segment.style,
                        .link = segment.link,
                    });
                    col += w;
                    if (col >= self.width) {
                        row += 1;
                        col = 0;
                    }
                }
            } else false;

            return .{
                .row = row,
                .col = col,
                .overflow = overflow,
            };
        },
        .word => {
            var col: usize = 0;
            var overflow: bool = false;
            var soft_wrapped: bool = false;
            for (segments) |segment| {
                var start: usize = 0;
                var i: usize = 0;
                while (i < segment.text.len) : (i += 1) {
                    // for (segment.text, 0..) |b, i| {
                    const b = segment.text[i];
                    const end = switch (b) {
                        ' ',
                        '\r',
                        '\n',
                        => i,
                        else => if (i != segment.text.len - 1) continue else i + 1,
                    };
                    const word = segment.text[start..end];
                    // find the start of the next word
                    start = while (i + 1 < segment.text.len) : (i += 1) {
                        if (segment.text[i + 1] == ' ') continue;
                        break i + 1;
                    } else i;
                    const width = self.gwidth(word);
                    const non_wsp_width: usize = for (word, 0..) |wb, wi| {
                        if (wb == '\r' or wb == '\n') {
                            row += 1;
                            col = 0;
                            break width -| wi -| 1;
                        }
                        if (wb != ' ') break width - wi;
                    } else 0;

                    if (width + col > self.width and non_wsp_width < self.width) {
                        // wrap
                        row += 1;
                        col = 0;
                        soft_wrapped = true;
                    }
                    if (row >= self.height) {
                        overflow = true;
                        break;
                    }
                    // if we are soft wrapped, (col == 0 and row > 0), then trim
                    // leading spaces
                    const printed_word = if (soft_wrapped)
                        std.mem.trimLeft(u8, word, " ")
                    else
                        word;
                    defer soft_wrapped = false;
                    var iter = self.screen.unicode.graphemeIterator(printed_word);
                    while (iter.next()) |grapheme| {
                        const s = grapheme.bytes(printed_word);
                        const w = self.gwidth(s);
                        if (opts.commit) self.writeCell(col, row, .{
                            .char = .{
                                .grapheme = s,
                                .width = w,
                            },
                            .style = segment.style,
                            .link = segment.link,
                        });
                        col += w;
                        if (col >= self.width) {
                            row += 1;
                            col = 0;
                        }
                    }
                    switch (b) {
                        ' ' => {
                            if (col > 0) {
                                if (opts.commit) self.writeCell(col, row, .{
                                    .char = .{
                                        .grapheme = " ",
                                        .width = 1,
                                    },
                                    .style = segment.style,
                                    .link = segment.link,
                                });
                                col += 1;
                            }
                        },
                        '\r',
                        '\n',
                        => {
                            col = 0;
                            row += 1;
                        },
                        else => {},
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
            var col: usize = 0;
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
                            .width = w,
                        },
                        .style = segment.style,
                        .link = segment.link,
                    });
                    col += w;
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

/// Deprecated. use print instead
pub fn wrap(self: Window, segments: []const Segment) !void {
    _ = try self.print(segments, .{ .wrap = .word });
}

/// scrolls the window down one row (IE inserts a blank row at the bottom of the
/// screen and shifts all rows up one)
pub fn scroll(self: Window, n: usize) void {
    if (n > self.height) return;
    var row = self.y_off;
    while (row < self.height - n) : (row += 1) {
        const dst_start = (row * self.width) + self.x_off;
        const dst_end = dst_start + self.width;

        const src_start = ((row + n) * self.width) + self.x_off;
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
        .width = 20,
        .height = 20,
        .screen = undefined,
    };

    const ch = parent.initChild(1, 1, .expand, .expand);
    try std.testing.expectEqual(19, ch.width);
    try std.testing.expectEqual(19, ch.height);
}

test "Window size set too big" {
    var parent = Window{
        .x_off = 0,
        .y_off = 0,
        .width = 20,
        .height = 20,
        .screen = undefined,
    };

    const ch = parent.initChild(0, 0, .{ .limit = 21 }, .{ .limit = 21 });
    try std.testing.expectEqual(20, ch.width);
    try std.testing.expectEqual(20, ch.height);
}

test "Window size set too big with offset" {
    var parent = Window{
        .x_off = 0,
        .y_off = 0,
        .width = 20,
        .height = 20,
        .screen = undefined,
    };

    const ch = parent.initChild(10, 10, .{ .limit = 21 }, .{ .limit = 21 });
    try std.testing.expectEqual(10, ch.width);
    try std.testing.expectEqual(10, ch.height);
}

test "Window size nested offsets" {
    var parent = Window{
        .x_off = 1,
        .y_off = 1,
        .width = 20,
        .height = 20,
        .screen = undefined,
    };

    const ch = parent.initChild(10, 10, .{ .limit = 21 }, .{ .limit = 21 });
    try std.testing.expectEqual(11, ch.x_off);
    try std.testing.expectEqual(11, ch.y_off);
}

test "print: grapheme" {
    const alloc = std.testing.allocator_instance.allocator();
    const unicode = try Unicode.init(alloc);
    defer unicode.deinit();
    var screen: Screen = .{ .width_method = .unicode, .unicode = &unicode };
    const win: Window = .{
        .x_off = 0,
        .y_off = 0,
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
        const result = try win.print(&segments, opts);
        try std.testing.expectEqual(1, result.col);
        try std.testing.expectEqual(0, result.row);
        try std.testing.expectEqual(false, result.overflow);
    }
    {
        var segments = [_]Segment{
            .{ .text = "abcd" },
        };
        const result = try win.print(&segments, opts);
        try std.testing.expectEqual(0, result.col);
        try std.testing.expectEqual(1, result.row);
        try std.testing.expectEqual(false, result.overflow);
    }
    {
        var segments = [_]Segment{
            .{ .text = "abcde" },
        };
        const result = try win.print(&segments, opts);
        try std.testing.expectEqual(1, result.col);
        try std.testing.expectEqual(1, result.row);
        try std.testing.expectEqual(false, result.overflow);
    }
    {
        var segments = [_]Segment{
            .{ .text = "abcdefgh" },
        };
        const result = try win.print(&segments, opts);
        try std.testing.expectEqual(0, result.col);
        try std.testing.expectEqual(2, result.row);
        try std.testing.expectEqual(false, result.overflow);
    }
    {
        var segments = [_]Segment{
            .{ .text = "abcdefghi" },
        };
        const result = try win.print(&segments, opts);
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
        const result = try win.print(&segments, opts);
        try std.testing.expectEqual(1, result.col);
        try std.testing.expectEqual(0, result.row);
        try std.testing.expectEqual(false, result.overflow);
    }
    {
        var segments = [_]Segment{
            .{ .text = "a b" },
        };
        const result = try win.print(&segments, opts);
        try std.testing.expectEqual(3, result.col);
        try std.testing.expectEqual(0, result.row);
        try std.testing.expectEqual(false, result.overflow);
    }
    {
        var segments = [_]Segment{
            .{ .text = "a b c" },
        };
        const result = try win.print(&segments, opts);
        try std.testing.expectEqual(1, result.col);
        try std.testing.expectEqual(1, result.row);
        try std.testing.expectEqual(false, result.overflow);
    }
    {
        var segments = [_]Segment{
            .{ .text = "hello" },
        };
        const result = try win.print(&segments, opts);
        try std.testing.expectEqual(1, result.col);
        try std.testing.expectEqual(1, result.row);
        try std.testing.expectEqual(false, result.overflow);
    }
    {
        var segments = [_]Segment{
            .{ .text = "hi tim" },
        };
        const result = try win.print(&segments, opts);
        try std.testing.expectEqual(3, result.col);
        try std.testing.expectEqual(1, result.row);
        try std.testing.expectEqual(false, result.overflow);
    }
    {
        var segments = [_]Segment{
            .{ .text = "hello tim" },
        };
        const result = try win.print(&segments, opts);
        try std.testing.expectEqual(0, result.col);
        try std.testing.expectEqual(2, result.row);
        try std.testing.expectEqual(true, result.overflow);
    }
    {
        var segments = [_]Segment{
            .{ .text = "hello ti" },
        };
        const result = try win.print(&segments, opts);
        try std.testing.expectEqual(0, result.col);
        try std.testing.expectEqual(2, result.row);
        try std.testing.expectEqual(false, result.overflow);
    }
    {
        var segments = [_]Segment{
            .{ .text = "h" },
            .{ .text = "e" },
        };
        const result = try win.print(&segments, opts);
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
        const result = try win.print(&segments, opts);
        try std.testing.expectEqual(1, result.col);
        try std.testing.expectEqual(1, result.row);
        try std.testing.expectEqual(false, result.overflow);
    }
    {
        var segments = [_]Segment{
            .{ .text = "he\n" },
        };
        const result = try win.print(&segments, opts);
        try std.testing.expectEqual(0, result.col);
        try std.testing.expectEqual(1, result.row);
        try std.testing.expectEqual(false, result.overflow);
    }
    {
        var segments = [_]Segment{
            .{ .text = "he\n\n" },
        };
        const result = try win.print(&segments, opts);
        try std.testing.expectEqual(0, result.col);
        try std.testing.expectEqual(2, result.row);
        try std.testing.expectEqual(false, result.overflow);
    }
    {
        var segments = [_]Segment{
            .{ .text = "not now" },
        };
        const result = try win.print(&segments, opts);
        try std.testing.expectEqual(3, result.col);
        try std.testing.expectEqual(1, result.row);
        try std.testing.expectEqual(false, result.overflow);
    }
    {
        var segments = [_]Segment{
            .{ .text = "note now" },
        };
        const result = try win.print(&segments, opts);
        try std.testing.expectEqual(3, result.col);
        try std.testing.expectEqual(1, result.row);
        try std.testing.expectEqual(false, result.overflow);
    }
}
