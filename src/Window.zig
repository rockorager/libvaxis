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
        .expand => self.width - x_off,
        .limit => |w| blk: {
            if (w + x_off > self.width) {
                break :blk self.width - x_off;
            }
            break :blk w;
        },
    };
    const resolved_height = switch (height) {
        .expand => self.height - y_off,
        .limit => |h| blk: {
            if (h + y_off > self.height) {
                break :blk self.height - y_off;
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

/// prints text in the window with simple word wrapping.
pub fn wrap(self: Window, segments: []Segment) !void {
    // pub fn wrap(self: Window, str: []const u8) !void {
    var row: usize = 0;
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
            if (word_width + col >= self.width and word_width < self.width) {
                row += 1;
                col = 0;
                wrapped = true;
            }
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
}

test "Window size set" {
    var parent = Window{
        .x_off = 0,
        .y_off = 0,
        .width = 20,
        .height = 20,
        .screen = undefined,
    };

    const child = parent.initChild(1, 1, .expand, .expand);
    try std.testing.expectEqual(19, child.width);
    try std.testing.expectEqual(19, child.height);
}

test "Window size set too big" {
    var parent = Window{
        .x_off = 0,
        .y_off = 0,
        .width = 20,
        .height = 20,
        .screen = undefined,
    };

    const child = parent.initChild(0, 0, .{ .limit = 21 }, .{ .limit = 21 });
    try std.testing.expectEqual(20, child.width);
    try std.testing.expectEqual(20, child.height);
}

test "Window size set too big with offset" {
    var parent = Window{
        .x_off = 0,
        .y_off = 0,
        .width = 20,
        .height = 20,
        .screen = undefined,
    };

    const child = parent.initChild(10, 10, .{ .limit = 21 }, .{ .limit = 21 });
    try std.testing.expectEqual(10, child.width);
    try std.testing.expectEqual(10, child.height);
}

test "Window size nested offsets" {
    var parent = Window{
        .x_off = 1,
        .y_off = 1,
        .width = 20,
        .height = 20,
        .screen = undefined,
    };

    const child = parent.initChild(10, 10, .{ .limit = 21 }, .{ .limit = 21 });
    try std.testing.expectEqual(11, child.x_off);
    try std.testing.expectEqual(11, child.y_off);
}
