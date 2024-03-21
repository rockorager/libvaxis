const std = @import("std");
const ziglyph = @import("ziglyph");
const WordIterator = ziglyph.WordIterator;
const GraphemeIterator = ziglyph.GraphemeIterator;

const Screen = @import("Screen.zig");
const Cell = @import("Cell.zig");
const Segment = @import("Cell.zig").Segment;
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
    where: enum {
        none,
        all,
        top,
        right,
        bottom,
        left,
    } = .none,
    glyphs: Glyphs = .single_rounded,

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

    switch (opts.border.where) {
        .none => return result,
        .all => {
            result.writeCell(0, 0, .{ .char = top_left, .style = style });
            result.writeCell(0, h -| 1, .{ .char = bottom_left, .style = style });
            result.writeCell(w - 1, 0, .{ .char = top_right, .style = style });
            result.writeCell(w - 1, h -| 1, .{ .char = bottom_right, .style = style });
            var i: usize = 1;
            while (i < (h - 1)) : (i += 1) {
                result.writeCell(0, i, .{ .char = vertical, .style = style });
                result.writeCell(w -| 1, i, .{ .char = vertical, .style = style });
            }
            i = 1;
            while (i < w - 1) : (i += 1) {
                result.writeCell(i, 0, .{ .char = horizontal, .style = style });
                result.writeCell(i, h -| 1, .{ .char = horizontal, .style = style });
            }
            return result.initChild(1, 1, .{ .limit = w - 2 }, .{ .limit = h - 2 });
        },
        .top => {
            var i: usize = 0;
            while (i < w) : (i += 1) {
                result.writeCell(i, 0, .{ .char = horizontal, .style = style });
            }
            return result.initChild(1, 0, .expand, .expand);
        },
        .right => {
            var i: usize = 0;
            while (i < h) : (i += 1) {
                result.writeCell(w -| 1, i, .{ .char = vertical, .style = style });
            }
            return result.initChild(0, 0, .{ .limit = w -| 1 }, .expand);
        },
        .bottom => {
            var i: usize = 0;
            while (i < w) : (i += 1) {
                result.writeCell(i, h -| 1, .{ .char = horizontal, .style = style });
            }
            return result.initChild(0, 0, .expand, .{ .limit = h -| 1 });
        },
        .left => {
            var i: usize = 0;
            while (i < h) : (i += 1) {
                result.writeCell(0, i, .{ .char = vertical, .style = style });
            }
            return result.initChild(1, 0, .expand, .expand);
        },
    }

    return result;
}

/// writes a cell to the location in the window
pub fn writeCell(self: Window, col: usize, row: usize, cell: Cell) void {
    if (self.height == 0 or self.width == 0) return;
    if (self.height <= row or self.width <= col) return;
    self.screen.writeCell(col + self.x_off, row + self.y_off, cell);
}

/// fills the window with the default cell
pub fn clear(self: Window) void {
    self.fill(.{});
}

/// returns the width of the grapheme. This depends on the terminal capabilities
pub fn gwidth(self: Window, str: []const u8) usize {
    const m: gw.Method = if (self.screen.unicode) .unicode else .wcwidth;
    return gw.gwidth(str, m) catch 1;
}

/// fills the window with the provided cell
pub fn fill(self: Window, cell: Cell) void {
    var row: usize = self.y_off;
    while (row < (self.height + self.y_off)) : (row += 1) {
        var col: usize = self.x_off;
        while (col < (self.width + self.x_off)) : (col += 1) {
            self.screen.writeCell(col, row, cell);
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
};

/// prints segments to the window. returns true if the text overflowed with the
/// given wrap strategy and size.
pub fn print(self: Window, segments: []Segment, opts: PrintOptions) !bool {
    var row = opts.row_offset;
    switch (opts.wrap) {
        .grapheme => {
            var col: usize = 0;
            for (segments) |segment| {
                var iter = GraphemeIterator.init(segment.text);
                while (iter.next()) |grapheme| {
                    if (col >= self.width) {
                        row += 1;
                        col = 0;
                    }
                    if (row >= self.height) return true;
                    const s = grapheme.slice(segment.text);
                    if (std.mem.eql(u8, s, "\n")) {
                        row += 1;
                        col = 0;
                        continue;
                    }
                    const w = self.gwidth(s);
                    if (w == 0) continue;
                    self.writeCell(col, row, .{
                        .char = .{
                            .grapheme = s,
                            .width = w,
                        },
                        .style = segment.style,
                        .link = segment.link,
                    });
                    col += w;
                }
            }
        },
        .word => {
            var col: usize = 0;
            var wrapped: bool = false;
            for (segments) |segment| {
                var word_iter = try WordIterator.init(segment.text);
                while (word_iter.next()) |word| {
                    // break lines when we need
                    if (word.bytes[0] == '\r' or word.bytes[0] == '\n') {
                        row += 1;
                        col = 0;
                        wrapped = false;
                        continue;
                    }
                    // break lines when we can't fit this word, and the word isn't longer
                    // than our width
                    const word_width = self.gwidth(word.bytes);
                    if (word_width == 0) continue;
                    if (word_width + col > self.width and word_width < self.width) {
                        row += 1;
                        col = 0;
                        wrapped = true;
                    }
                    if (row >= self.height) return true;
                    // don't print whitespace in the first column, unless we had a hard
                    // break
                    if (col == 0 and std.mem.eql(u8, word.bytes, " ") and wrapped) continue;
                    var iter = GraphemeIterator.init(word.bytes);
                    while (iter.next()) |grapheme| {
                        if (col >= self.width) {
                            row += 1;
                            col = 0;
                            wrapped = true;
                        }
                        const s = grapheme.slice(word.bytes);
                        const w = self.gwidth(s);
                        self.writeCell(col, row, .{
                            .char = .{
                                .grapheme = s,
                                .width = w,
                            },
                            .style = segment.style,
                            .link = segment.link,
                        });
                        col += w;
                    }
                }
            }
        },
        .none => {
            var col: usize = 0;
            for (segments) |segment| {
                var iter = GraphemeIterator.init(segment.text);
                while (iter.next()) |grapheme| {
                    if (col >= self.width) return true;
                    const s = grapheme.slice(segment.text);
                    if (std.mem.eql(u8, s, "\n")) return true;
                    const w = self.gwidth(s);
                    if (w == 0) continue;
                    self.writeCell(col, row, .{
                        .char = .{
                            .grapheme = s,
                            .width = w,
                        },
                        .style = segment.style,
                        .link = segment.link,
                    });
                    col += w;
                }
            }
        },
    }
    return false;
}

/// prints text in the window with simple word wrapping.
pub fn wrap(self: Window, segments: []Segment) !void {
    _ = try self.print(segments, .{ .wrap = .word });
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
