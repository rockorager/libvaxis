const std = @import("std");
const vaxis = @import("../main.zig");

const Allocator = std.mem.Allocator;

const vxfw = @import("vxfw.zig");

const Text = @This();

text: []const u8,
style: vaxis.Style = .{},
text_align: enum { left, center, right } = .left,
softwrap: bool = true,
overflow: enum { ellipsis, clip } = .ellipsis,
width_basis: enum { parent, longest_line } = .longest_line,

pub fn widget(self: *const Text) vxfw.Widget {
    return .{
        .userdata = @constCast(self),
        .drawFn = typeErasedDrawFn,
    };
}

fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
    const self: *const Text = @ptrCast(@alignCast(ptr));
    return self.draw(ctx);
}

pub fn draw(self: *const Text, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
    if (ctx.max.width != null and ctx.max.width.? == 0) {
        return .{
            .size = ctx.min,
            .widget = self.widget(),
            .buffer = &.{},
            .children = &.{},
        };
    }
    const container_size = self.findContainerSize(ctx);

    // Create a surface of target width and max height. We'll trim the result after drawing
    const surface = try vxfw.Surface.init(
        ctx.arena,
        self.widget(),
        container_size,
    );
    const base_style: vaxis.Style = .{
        .fg = self.style.fg,
        .bg = self.style.bg,
        .reverse = self.style.reverse,
    };
    const base: vaxis.Cell = .{ .style = base_style };
    @memset(surface.buffer, base);

    var row: u16 = 0;
    if (self.softwrap) {
        var iter = SoftwrapIterator.init(self.text, ctx);
        while (iter.next()) |line| {
            if (row >= container_size.height) break;
            defer row += 1;
            var col: u16 = switch (self.text_align) {
                .left => 0,
                .center => (container_size.width - line.width) / 2,
                .right => container_size.width - line.width,
            };
            var char_iter = ctx.graphemeIterator(line.bytes);
            while (char_iter.next()) |char| {
                const grapheme = char.bytes(line.bytes);
                if (std.mem.eql(u8, grapheme, "\t")) {
                    for (0..8) |i| {
                        surface.writeCell(@intCast(col + i), row, .{
                            .char = .{ .grapheme = " ", .width = 1 },
                            .style = self.style,
                        });
                    }
                    col += 8;
                    continue;
                }
                const grapheme_width: u8 = @intCast(ctx.stringWidth(grapheme));
                surface.writeCell(col, row, .{
                    .char = .{ .grapheme = grapheme, .width = grapheme_width },
                    .style = self.style,
                });
                col += grapheme_width;
            }
        }
    } else {
        var line_iter: LineIterator = .{ .buf = self.text };
        while (line_iter.next()) |line| {
            if (row >= container_size.height) break;
            // \t is default 1 wide. We add 7x the count of tab characters to get the full width
            const line_width = ctx.stringWidth(line) + 7 * std.mem.count(u8, line, "\t");
            defer row += 1;
            const resolved_line_width = @min(container_size.width, line_width);
            var col: u16 = switch (self.text_align) {
                .left => 0,
                .center => (container_size.width - resolved_line_width) / 2,
                .right => container_size.width - resolved_line_width,
            };
            var char_iter = ctx.graphemeIterator(line);
            while (char_iter.next()) |char| {
                if (col >= container_size.width) break;
                const grapheme = char.bytes(line);
                const grapheme_width: u8 = @intCast(ctx.stringWidth(grapheme));

                if (col + grapheme_width >= container_size.width and
                    line_width > container_size.width and
                    self.overflow == .ellipsis)
                {
                    surface.writeCell(col, row, .{
                        .char = .{ .grapheme = "…", .width = 1 },
                        .style = self.style,
                    });
                    col = container_size.width;
                } else {
                    surface.writeCell(col, row, .{
                        .char = .{ .grapheme = grapheme, .width = grapheme_width },
                        .style = self.style,
                    });
                    col += @intCast(grapheme_width);
                }
            }
        }
    }
    return surface.trimHeight(@max(row, ctx.min.height));
}

/// Determines the container size by finding the widest line in the viewable area
fn findContainerSize(self: Text, ctx: vxfw.DrawContext) vxfw.Size {
    var row: u16 = 0;
    var max_width: u16 = ctx.min.width;
    if (self.softwrap) {
        var iter = SoftwrapIterator.init(self.text, ctx);
        while (iter.next()) |line| {
            if (ctx.max.outsideHeight(row))
                break;

            defer row += 1;
            max_width = @max(max_width, line.width);
        }
    } else {
        var line_iter: LineIterator = .{ .buf = self.text };
        while (line_iter.next()) |line| {
            if (ctx.max.outsideHeight(row))
                break;
            const line_width: u16 = @truncate(ctx.stringWidth(line));
            defer row += 1;
            const resolved_line_width = if (ctx.max.width) |max|
                @min(max, line_width)
            else
                line_width;
            max_width = @max(max_width, resolved_line_width);
        }
    }
    const result_width = switch (self.width_basis) {
        .longest_line => blk: {
            if (ctx.max.width) |max|
                break :blk @min(max, max_width)
            else
                break :blk max_width;
        },
        .parent => blk: {
            std.debug.assert(ctx.max.width != null);
            break :blk ctx.max.width.?;
        },
    };
    return .{ .width = result_width, .height = @max(row, ctx.min.height) };
}

/// Iterates a slice of bytes by linebreaks. Lines are split by '\r', '\n', or '\r\n'
pub const LineIterator = struct {
    buf: []const u8,
    index: usize = 0,

    fn next(self: *LineIterator) ?[]const u8 {
        if (self.index >= self.buf.len) return null;

        const start = self.index;
        const end = std.mem.indexOfAnyPos(u8, self.buf, self.index, "\r\n") orelse {
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

pub const SoftwrapIterator = struct {
    ctx: vxfw.DrawContext,
    line: []const u8 = "",
    index: usize = 0,
    hard_iter: LineIterator,

    pub const Line = struct {
        width: u16,
        bytes: []const u8,
    };

    const soft_breaks = " \t";

    fn init(buf: []const u8, ctx: vxfw.DrawContext) SoftwrapIterator {
        return .{
            .ctx = ctx,
            .hard_iter = .{ .buf = buf },
        };
    }

    fn next(self: *SoftwrapIterator) ?Line {
        // Advance the hard iterator
        if (self.index == self.line.len) {
            self.line = self.hard_iter.next() orelse return null;
            self.line = std.mem.trimRight(u8, self.line, " \t");
            self.index = 0;
        }

        const start = self.index;
        var cur_width: u16 = 0;
        while (self.index < self.line.len) {
            const idx = self.nextWrap();
            const word = self.line[self.index..idx];
            const next_width = self.ctx.stringWidth(word);

            if (self.ctx.max.width) |max| {
                if (cur_width + next_width > max) {
                    // Trim the word to see if it can fit on a line by itself
                    const trimmed = std.mem.trimLeft(u8, word, " \t");
                    const trimmed_bytes = word.len - trimmed.len;
                    // The number of bytes we trimmed is equal to the reduction in length
                    const trimmed_width = next_width - trimmed_bytes;
                    if (trimmed_width > max) {
                        // Won't fit on line by itself, so fit as much on this line as we can
                        var iter = self.ctx.graphemeIterator(word);
                        while (iter.next()) |item| {
                            const grapheme = item.bytes(word);
                            const w = self.ctx.stringWidth(grapheme);
                            if (cur_width + w > max) {
                                const end = self.index;
                                return .{ .width = cur_width, .bytes = self.line[start..end] };
                            }
                            cur_width += @intCast(w);
                            self.index += grapheme.len;
                        }
                    }
                    // We are softwrapping, advance index to the start of the next word
                    const end = self.index;
                    self.index = std.mem.indexOfNonePos(u8, self.line, self.index, soft_breaks) orelse self.line.len;
                    return .{ .width = cur_width, .bytes = self.line[start..end] };
                }
            }

            self.index = idx;
            cur_width += @intCast(next_width);
        }
        return .{ .width = cur_width, .bytes = self.line[start..] };
    }

    /// Determines the index of the end of the next word
    fn nextWrap(self: *SoftwrapIterator) usize {
        // Find the first linear whitespace char
        const start_pos = std.mem.indexOfNonePos(u8, self.line, self.index, soft_breaks) orelse
            return self.line.len;
        if (std.mem.indexOfAnyPos(u8, self.line, start_pos, soft_breaks)) |idx| {
            return idx;
        }
        return self.line.len;
    }

    // consumes a \n byte
    fn consumeLF(self: *SoftwrapIterator) void {
        if (self.index >= self.buf.len) return;
        if (self.buf[self.index] == '\n') self.index += 1;
    }

    // consumes a \r byte
    fn consumeCR(self: *SoftwrapIterator) void {
        if (self.index >= self.buf.len) return;
        if (self.buf[self.index] == '\r') self.index += 1;
    }
};

test "SoftwrapIterator: LF breaks" {
    const unicode = try vaxis.Unicode.init(std.testing.allocator);
    defer unicode.deinit();
    vxfw.DrawContext.init(&unicode, .unicode);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const ctx: vxfw.DrawContext = .{
        .min = .{ .width = 0, .height = 0 },
        .max = .{ .width = 20, .height = 10 },
        .arena = arena.allocator(),
        .cell_size = .{ .width = 10, .height = 20 },
    };
    var iter = SoftwrapIterator.init("Hello, \n world", ctx);
    const first = iter.next();
    try std.testing.expect(first != null);
    try std.testing.expectEqualStrings("Hello,", first.?.bytes);
    try std.testing.expectEqual(6, first.?.width);

    const second = iter.next();
    try std.testing.expect(second != null);
    try std.testing.expectEqualStrings(" world", second.?.bytes);
    try std.testing.expectEqual(6, second.?.width);

    const end = iter.next();
    try std.testing.expect(end == null);
}

test "SoftwrapIterator: soft breaks that fit" {
    const unicode = try vaxis.Unicode.init(std.testing.allocator);
    defer unicode.deinit();
    vxfw.DrawContext.init(&unicode, .unicode);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const ctx: vxfw.DrawContext = .{
        .min = .{ .width = 0, .height = 0 },
        .max = .{ .width = 6, .height = 10 },
        .arena = arena.allocator(),
        .cell_size = .{ .width = 10, .height = 20 },
    };
    var iter = SoftwrapIterator.init("Hello, \nworld", ctx);
    const first = iter.next();
    try std.testing.expect(first != null);
    try std.testing.expectEqualStrings("Hello,", first.?.bytes);
    try std.testing.expectEqual(6, first.?.width);

    const second = iter.next();
    try std.testing.expect(second != null);
    try std.testing.expectEqualStrings("world", second.?.bytes);
    try std.testing.expectEqual(5, second.?.width);

    const end = iter.next();
    try std.testing.expect(end == null);
}

test "SoftwrapIterator: soft breaks that are longer than width" {
    const unicode = try vaxis.Unicode.init(std.testing.allocator);
    defer unicode.deinit();
    vxfw.DrawContext.init(&unicode, .unicode);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const ctx: vxfw.DrawContext = .{
        .min = .{ .width = 0, .height = 0 },
        .max = .{ .width = 6, .height = 10 },
        .arena = arena.allocator(),
        .cell_size = .{ .width = 10, .height = 20 },
    };
    var iter = SoftwrapIterator.init("very-long-word \nworld", ctx);
    const first = iter.next();
    try std.testing.expect(first != null);
    try std.testing.expectEqualStrings("very-l", first.?.bytes);
    try std.testing.expectEqual(6, first.?.width);

    const second = iter.next();
    try std.testing.expect(second != null);
    try std.testing.expectEqualStrings("ong-wo", second.?.bytes);
    try std.testing.expectEqual(6, second.?.width);

    const third = iter.next();
    try std.testing.expect(third != null);
    try std.testing.expectEqualStrings("rd", third.?.bytes);
    try std.testing.expectEqual(2, third.?.width);

    const fourth = iter.next();
    try std.testing.expect(fourth != null);
    try std.testing.expectEqualStrings("world", fourth.?.bytes);
    try std.testing.expectEqual(5, fourth.?.width);

    const end = iter.next();
    try std.testing.expect(end == null);
}

test "SoftwrapIterator: soft breaks with leading spaces" {
    const unicode = try vaxis.Unicode.init(std.testing.allocator);
    defer unicode.deinit();
    vxfw.DrawContext.init(&unicode, .unicode);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const ctx: vxfw.DrawContext = .{
        .min = .{ .width = 0, .height = 0 },
        .max = .{ .width = 6, .height = 10 },
        .arena = arena.allocator(),
        .cell_size = .{ .width = 10, .height = 20 },
    };
    var iter = SoftwrapIterator.init("Hello,        \n world", ctx);
    const first = iter.next();
    try std.testing.expect(first != null);
    try std.testing.expectEqualStrings("Hello,", first.?.bytes);
    try std.testing.expectEqual(6, first.?.width);

    const second = iter.next();
    try std.testing.expect(second != null);
    try std.testing.expectEqualStrings(" world", second.?.bytes);
    try std.testing.expectEqual(6, second.?.width);

    const end = iter.next();
    try std.testing.expect(end == null);
}

test "LineIterator: LF breaks" {
    const input = "Hello, \n world";
    var iter: LineIterator = .{ .buf = input };
    const first = iter.next();
    try std.testing.expect(first != null);
    try std.testing.expectEqualStrings("Hello, ", first.?);

    const second = iter.next();
    try std.testing.expect(second != null);
    try std.testing.expectEqualStrings(" world", second.?);

    const end = iter.next();
    try std.testing.expect(end == null);
}

test "LineIterator: CR breaks" {
    const input = "Hello, \r world";
    var iter: LineIterator = .{ .buf = input };
    const first = iter.next();
    try std.testing.expect(first != null);
    try std.testing.expectEqualStrings("Hello, ", first.?);

    const second = iter.next();
    try std.testing.expect(second != null);
    try std.testing.expectEqualStrings(" world", second.?);

    const end = iter.next();
    try std.testing.expect(end == null);
}

test "LineIterator: CRLF breaks" {
    const input = "Hello, \r\n world";
    var iter: LineIterator = .{ .buf = input };
    const first = iter.next();
    try std.testing.expect(first != null);
    try std.testing.expectEqualStrings("Hello, ", first.?);

    const second = iter.next();
    try std.testing.expect(second != null);
    try std.testing.expectEqualStrings(" world", second.?);

    const end = iter.next();
    try std.testing.expect(end == null);
}

test "LineIterator: CRLF breaks with empty line" {
    const input = "Hello, \r\n\r\n world";
    var iter: LineIterator = .{ .buf = input };
    const first = iter.next();
    try std.testing.expect(first != null);
    try std.testing.expectEqualStrings("Hello, ", first.?);

    const second = iter.next();
    try std.testing.expect(second != null);
    try std.testing.expectEqualStrings("", second.?);

    const third = iter.next();
    try std.testing.expect(third != null);
    try std.testing.expectEqualStrings(" world", third.?);

    const end = iter.next();
    try std.testing.expect(end == null);
}

test Text {
    var text: Text = .{ .text = "Hello, world" };
    const text_widget = text.widget();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ucd = try vaxis.Unicode.init(arena.allocator());
    vxfw.DrawContext.init(&ucd, .unicode);

    // Center expands to the max size. It must therefore have non-null max width and max height.
    // These values are asserted in draw
    const ctx: vxfw.DrawContext = .{
        .arena = arena.allocator(),
        .min = .{},
        .max = .{ .width = 7, .height = 2 },
        .cell_size = .{ .width = 10, .height = 20 },
    };

    {
        // Text softwraps by default
        const surface = try text_widget.draw(ctx);
        try std.testing.expectEqual(@as(vxfw.Size, .{ .width = 6, .height = 2 }), surface.size);
    }

    {
        text.softwrap = false;
        text.overflow = .ellipsis;
        const surface = try text_widget.draw(ctx);
        try std.testing.expectEqual(@as(vxfw.Size, .{ .width = 7, .height = 1 }), surface.size);
        // The last character will be an ellipsis
        try std.testing.expectEqualStrings("…", surface.buffer[surface.buffer.len - 1].char.grapheme);
    }
}

test "refAllDecls" {
    std.testing.refAllDecls(@This());
}
