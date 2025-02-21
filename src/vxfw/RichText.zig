const std = @import("std");
const vaxis = @import("../main.zig");

const vxfw = @import("vxfw.zig");

const Allocator = std.mem.Allocator;

const RichText = @This();

pub const TextSpan = vaxis.Segment;

text: []const TextSpan,
text_align: enum { left, center, right } = .left,
base_style: vaxis.Style = .{},
softwrap: bool = true,
overflow: enum { ellipsis, clip } = .ellipsis,
width_basis: enum { parent, longest_line } = .longest_line,

pub fn widget(self: *const RichText) vxfw.Widget {
    return .{
        .userdata = @constCast(self),
        .drawFn = typeErasedDrawFn,
    };
}

fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
    const self: *const RichText = @ptrCast(@alignCast(ptr));
    return self.draw(ctx);
}

pub fn draw(self: *const RichText, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
    if (ctx.max.width != null and ctx.max.width.? == 0) {
        return .{
            .size = ctx.min,
            .widget = self.widget(),
            .buffer = &.{},
            .children = &.{},
        };
    }
    var iter = try SoftwrapIterator.init(self.text, ctx);
    const container_size = self.findContainerSize(&iter);

    // Create a surface of target width and max height. We'll trim the result after drawing
    const surface = try vxfw.Surface.init(
        ctx.arena,
        self.widget(),
        container_size,
    );
    const base: vaxis.Cell = .{ .style = self.base_style };
    @memset(surface.buffer, base);

    var row: u16 = 0;
    if (self.softwrap) {
        while (iter.next()) |line| {
            if (ctx.max.outsideHeight(row)) break;
            defer row += 1;
            var col: u16 = switch (self.text_align) {
                .left => 0,
                .center => (container_size.width - line.width) / 2,
                .right => container_size.width - line.width,
            };
            for (line.cells) |cell| {
                surface.writeCell(col, row, cell);
                col += cell.char.width;
            }
        }
    } else {
        while (iter.nextHardBreak()) |line| {
            if (ctx.max.outsideHeight(row)) break;
            const line_width = blk: {
                var w: u16 = 0;
                for (line) |cell| {
                    w +|= cell.char.width;
                }
                break :blk w;
            };
            defer row += 1;
            var col: u16 = switch (self.text_align) {
                .left => 0,
                .center => (container_size.width -| line_width) / 2,
                .right => container_size.width -| line_width,
            };
            for (line) |cell| {
                if (col + cell.char.width >= container_size.width and
                    line_width > container_size.width and
                    self.overflow == .ellipsis)
                {
                    surface.writeCell(col, row, .{
                        .char = .{ .grapheme = "…", .width = 1 },
                        .style = cell.style,
                    });
                    col = container_size.width;
                    continue;
                } else {
                    surface.writeCell(col, row, cell);
                    col += @intCast(cell.char.width);
                }
            }
        }
    }
    return surface.trimHeight(@max(row, ctx.min.height));
}

/// Finds the widest line within the viewable portion of ctx
fn findContainerSize(self: RichText, iter: *SoftwrapIterator) vxfw.Size {
    defer iter.reset();
    var row: u16 = 0;
    var max_width: u16 = iter.ctx.min.width;
    if (self.softwrap) {
        while (iter.next()) |line| {
            if (iter.ctx.max.outsideHeight(row)) break;
            defer row += 1;
            max_width = @max(max_width, line.width);
        }
    } else {
        while (iter.nextHardBreak()) |line| {
            if (iter.ctx.max.outsideHeight(row)) break;
            defer row += 1;
            var w: u16 = 0;
            for (line) |cell| {
                w +|= cell.char.width;
            }
            max_width = @max(max_width, w);
        }
    }
    const result_width = switch (self.width_basis) {
        .longest_line => blk: {
            if (iter.ctx.max.width) |max|
                break :blk @min(max, max_width)
            else
                break :blk max_width;
        },
        .parent => blk: {
            std.debug.assert(iter.ctx.max.width != null);
            break :blk iter.ctx.max.width.?;
        },
    };
    return .{ .width = result_width, .height = @max(row, iter.ctx.min.height) };
}

pub const SoftwrapIterator = struct {
    arena: std.heap.ArenaAllocator,
    ctx: vxfw.DrawContext,
    text: []const vaxis.Cell,
    line: []const vaxis.Cell,
    index: usize = 0,
    // Index of the hard iterator
    hard_index: usize = 0,

    const soft_breaks = " \t";

    pub const Line = struct {
        width: u16,
        cells: []const vaxis.Cell,
    };

    fn init(spans: []const TextSpan, ctx: vxfw.DrawContext) Allocator.Error!SoftwrapIterator {
        // Estimate the number of cells we need
        var len: usize = 0;
        for (spans) |span| {
            len += span.text.len;
        }
        var arena = std.heap.ArenaAllocator.init(ctx.arena);
        var list = try std.ArrayList(vaxis.Cell).initCapacity(arena.allocator(), len);

        for (spans) |span| {
            var iter = ctx.graphemeIterator(span.text);
            while (iter.next()) |grapheme| {
                const char = grapheme.bytes(span.text);
                if (std.mem.eql(u8, char, "\t")) {
                    const cell: vaxis.Cell = .{
                        .char = .{ .grapheme = " ", .width = 1 },
                        .style = span.style,
                        .link = span.link,
                    };
                    for (0..8) |_| {
                        try list.append(cell);
                    }
                    continue;
                }
                const width = ctx.stringWidth(char);
                const cell: vaxis.Cell = .{
                    .char = .{ .grapheme = char, .width = @intCast(width) },
                    .style = span.style,
                    .link = span.link,
                };
                try list.append(cell);
            }
        }
        return .{
            .arena = arena,
            .ctx = ctx,
            .text = list.items,
            .line = &.{},
        };
    }

    fn reset(self: *SoftwrapIterator) void {
        self.index = 0;
        self.hard_index = 0;
        self.line = &.{};
    }

    fn deinit(self: *SoftwrapIterator) void {
        self.arena.deinit();
    }

    fn nextHardBreak(self: *SoftwrapIterator) ?[]const vaxis.Cell {
        if (self.hard_index >= self.text.len) return null;
        const start = self.hard_index;
        var saw_cr: bool = false;
        while (self.hard_index < self.text.len) : (self.hard_index += 1) {
            const cell = self.text[self.hard_index];
            if (std.mem.eql(u8, cell.char.grapheme, "\r")) {
                saw_cr = true;
            }
            if (std.mem.eql(u8, cell.char.grapheme, "\n")) {
                self.hard_index += 1;
                if (saw_cr) {
                    return self.text[start .. self.hard_index - 2];
                }
                return self.text[start .. self.hard_index - 1];
            }
            if (saw_cr) {
                // back up one
                self.hard_index -= 1;
                return self.text[start .. self.hard_index - 1];
            }
        } else return self.text[start..];
    }

    fn trimWSPRight(text: []const vaxis.Cell) []const vaxis.Cell {
        // trim linear whitespace
        var i: usize = text.len;
        while (i > 0) : (i -= 1) {
            if (std.mem.eql(u8, text[i - 1].char.grapheme, " ") or
                std.mem.eql(u8, text[i - 1].char.grapheme, "\t"))
            {
                continue;
            }
            break;
        }
        return text[0..i];
    }

    fn trimWSPLeft(text: []const vaxis.Cell) []const vaxis.Cell {
        // trim linear whitespace
        var i: usize = 0;
        while (i < text.len) : (i += 1) {
            if (std.mem.eql(u8, text[i].char.grapheme, " ") or
                std.mem.eql(u8, text[i].char.grapheme, "\t"))
            {
                continue;
            }
            break;
        }
        return text[i..];
    }

    fn next(self: *SoftwrapIterator) ?Line {
        // Advance the hard iterator
        if (self.index == self.line.len) {
            self.line = self.nextHardBreak() orelse return null;
            // trim linear whitespace
            self.line = trimWSPRight(self.line);
            self.index = 0;
        }

        const max_width = self.ctx.max.width orelse {
            var width: u16 = 0;
            for (self.line) |cell| {
                width += cell.char.width;
            }
            self.index = self.line.len;
            return .{
                .width = width,
                .cells = self.line,
            };
        };

        const start = self.index;
        var cur_width: u16 = 0;
        while (self.index < self.line.len) {
            // Find the width from current position to next word break
            const idx = self.nextWrap();
            const word = self.line[self.index..idx];
            const next_width = blk: {
                var w: usize = 0;
                for (word) |ch| {
                    w += ch.char.width;
                }
                break :blk w;
            };

            if (cur_width + next_width > max_width) {
                // Trim the word to see if it can fit on a line by itself
                const trimmed = trimWSPLeft(word);
                // New width is the previous width minus the number of cells we trimmed because we
                // are only trimming cells that would have been 1 wide (' ' and '\t' both measure as
                // 1 wide)
                const trimmed_width = next_width -| (word.len - trimmed.len);
                if (trimmed_width > max_width) {
                    // Won't fit on line by itself, so fit as much on this line as we can
                    for (word) |cell| {
                        if (cur_width + cell.char.width > max_width) {
                            const end = self.index;
                            return .{ .width = cur_width, .cells = self.line[start..end] };
                        }
                        cur_width += @intCast(cell.char.width);
                        self.index += 1;
                    }
                }
                const end = self.index;
                // We are softwrapping, advance index to the start of the next word. This is equal
                // to the difference in our word length and trimmed word length
                self.index += (word.len - trimmed.len);
                return .{ .width = cur_width, .cells = self.line[start..end] };
            }

            self.index = idx;
            cur_width += @intCast(next_width);
        }
        return .{ .width = cur_width, .cells = self.line[start..] };
    }

    fn nextWrap(self: *SoftwrapIterator) usize {
        var i: usize = self.index;

        // Find the first non-whitespace character
        while (i < self.line.len) : (i += 1) {
            if (std.mem.eql(u8, self.line[i].char.grapheme, " ") or
                std.mem.eql(u8, self.line[i].char.grapheme, "\t"))
            {
                continue;
            }
            break;
        }

        // Now find the first whitespace
        while (i < self.line.len) : (i += 1) {
            if (std.mem.eql(u8, self.line[i].char.grapheme, " ") or
                std.mem.eql(u8, self.line[i].char.grapheme, "\t"))
            {
                return i;
            }
            continue;
        }

        return self.line.len;
    }
};

test RichText {
    var rich_text: RichText = .{
        .text = &.{
            .{ .text = "Hello, " },
            .{ .text = "World", .style = .{ .bold = true } },
        },
    };

    const rich_widget = rich_text.widget();

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
        // RichText softwraps by default
        const surface = try rich_widget.draw(ctx);
        try std.testing.expectEqual(@as(vxfw.Size, .{ .width = 6, .height = 2 }), surface.size);
    }

    {
        rich_text.softwrap = false;
        rich_text.overflow = .ellipsis;
        const surface = try rich_widget.draw(ctx);
        try std.testing.expectEqual(@as(vxfw.Size, .{ .width = 7, .height = 1 }), surface.size);
        // The last character will be an ellipsis
        try std.testing.expectEqualStrings("…", surface.buffer[surface.buffer.len - 1].char.grapheme);
    }
}

test "long word wrapping" {
    var rich_text: RichText = .{
        .text = &.{
            .{ .text = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" },
        },
    };

    const rich_widget = rich_text.widget();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ucd = try vaxis.Unicode.init(arena.allocator());
    vxfw.DrawContext.init(&ucd, .unicode);

    const len = rich_text.text[0].text.len;
    const width: u16 = 8;

    const ctx: vxfw.DrawContext = .{
        .arena = arena.allocator(),
        .min = .{},
        .max = .{ .width = width, .height = null },
        .cell_size = .{ .width = 10, .height = 20 },
    };

    const surface = try rich_widget.draw(ctx);
    // Height should be length / width
    try std.testing.expectEqual(len / width, surface.size.height);
}

test "refAllDecls" {
    std.testing.refAllDecls(@This());
}
