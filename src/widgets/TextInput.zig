const std = @import("std");
const assert = std.debug.assert;
const Key = @import("../Key.zig");
const Cell = @import("../Cell.zig");
const Window = @import("../Window.zig");
const GapBuffer = @import("gap_buffer").GapBuffer;
const Unicode = @import("../Unicode.zig");

const TextInput = @This();

/// The events that this widget handles
const Event = union(enum) {
    key_press: Key,
};

const ellipsis: Cell.Character = .{ .grapheme = "…", .width = 1 };

// Index of our cursor
cursor_idx: usize = 0,
grapheme_count: usize = 0,
buf: GapBuffer(u8),

/// the number of graphemes to skip when drawing. Used for horizontal scrolling
draw_offset: usize = 0,
/// the column we placed the cursor the last time we drew
prev_cursor_col: usize = 0,
/// the grapheme index of the cursor the last time we drew
prev_cursor_idx: usize = 0,
/// approximate distance from an edge before we scroll
scroll_offset: usize = 4,

unicode: *const Unicode,

pub fn init(alloc: std.mem.Allocator, unicode: *const Unicode) TextInput {
    return TextInput{
        .buf = GapBuffer(u8).init(alloc),
        .unicode = unicode,
    };
}

pub fn deinit(self: *TextInput) void {
    self.buf.deinit();
}

pub fn update(self: *TextInput, event: Event) !void {
    switch (event) {
        .key_press => |key| {
            if (key.matches(Key.backspace, .{})) {
                if (self.cursor_idx == 0) return;
                try self.deleteBeforeCursor();
            } else if (key.matches(Key.delete, .{}) or key.matches('d', .{ .ctrl = true })) {
                if (self.cursor_idx == self.grapheme_count) return;
                try self.deleteAtCursor();
            } else if (key.matches(Key.left, .{}) or key.matches('b', .{ .ctrl = true })) {
                if (self.cursor_idx > 0) self.cursor_idx -= 1;
            } else if (key.matches(Key.right, .{}) or key.matches('f', .{ .ctrl = true })) {
                if (self.cursor_idx < self.grapheme_count) self.cursor_idx += 1;
            } else if (key.matches('a', .{ .ctrl = true })) {
                self.cursor_idx = 0;
            } else if (key.matches('e', .{ .ctrl = true })) {
                self.cursor_idx = self.grapheme_count;
            } else if (key.matches('k', .{ .ctrl = true })) {
                try self.deleteToEnd();
            } else if (key.matches('u', .{ .ctrl = true })) {
                try self.deleteToStart();
            } else if (key.text) |text| {
                try self.buf.insertSliceBefore(self.byteOffsetToCursor(), text);
                self.cursor_idx += 1;
                self.grapheme_count += 1;
            }
        },
    }
}

/// insert text at the cursor position
pub fn insertSliceAtCursor(self: *TextInput, data: []const u8) !void {
    var iter = self.unicode.graphemeIterator(data);
    var byte_offset_to_cursor = self.byteOffsetToCursor();
    while (iter.next()) |text| {
        try self.buf.insertSliceBefore(byte_offset_to_cursor, text.bytes(data));
        byte_offset_to_cursor += text.len;
        self.cursor_idx += 1;
        self.grapheme_count += 1;
    }
}

pub fn sliceToCursor(self: *TextInput, buf: []u8) []const u8 {
    const offset = self.byteOffsetToCursor();
    assert(offset <= buf.len); // provided buf was too small

    if (offset <= self.buf.items.len) {
        @memcpy(buf[0..offset], self.buf.items[0..offset]);
    } else {
        @memcpy(buf[0..self.buf.items.len], self.buf.items);
        const second_half = self.buf.secondHalf();
        const copy_len = offset - self.buf.items.len;
        @memcpy(buf[self.buf.items.len .. self.buf.items.len + copy_len], second_half[0..copy_len]);
    }
    return buf[0..offset];
}

/// calculates the display width from the draw_offset to the cursor
fn widthToCursor(self: *TextInput, win: Window) usize {
    var width: usize = 0;
    var first_iter = self.unicode.graphemeIterator(self.buf.items);
    var i: usize = 0;
    while (first_iter.next()) |grapheme| {
        defer i += 1;
        if (i < self.draw_offset) {
            continue;
        }
        if (i == self.cursor_idx) return width;
        const g = grapheme.bytes(self.buf.items);
        width += win.gwidth(g);
    }
    const second_half = self.buf.secondHalf();
    var second_iter = self.unicode.graphemeIterator(second_half);
    while (second_iter.next()) |grapheme| {
        defer i += 1;
        if (i < self.draw_offset) {
            continue;
        }
        if (i == self.cursor_idx) return width;
        const g = grapheme.bytes(second_half);
        width += win.gwidth(g);
    }
    return width;
}

pub fn draw(self: *TextInput, win: Window) void {
    if (self.cursor_idx < self.draw_offset) self.draw_offset = self.cursor_idx;
    if (win.width == 0) return;
    while (true) {
        const width = self.widthToCursor(win);
        if (width >= win.width) {
            self.draw_offset +|= width - win.width + 1;
            continue;
        } else break;
    }

    self.prev_cursor_idx = self.cursor_idx;
    self.prev_cursor_col = 0;

    // assumption!! the gap is never within a grapheme
    // one way to _ensure_ this is to move the gap... but that's a cost we probably don't want to pay.
    var first_iter = self.unicode.graphemeIterator(self.buf.items);
    var col: usize = 0;
    var i: usize = 0;
    while (first_iter.next()) |grapheme| {
        if (i < self.draw_offset) {
            i += 1;
            continue;
        }
        const g = grapheme.bytes(self.buf.items);
        const w = win.gwidth(g);
        if (col + w >= win.width) {
            win.writeCell(win.width - 1, 0, .{ .char = ellipsis });
            break;
        }
        win.writeCell(col, 0, .{
            .char = .{
                .grapheme = g,
                .width = w,
            },
        });
        col += w;
        i += 1;
        if (i == self.cursor_idx) self.prev_cursor_col = col;
    }
    const second_half = self.buf.secondHalf();
    var second_iter = self.unicode.graphemeIterator(second_half);
    while (second_iter.next()) |grapheme| {
        if (i < self.draw_offset) {
            i += 1;
            continue;
        }
        const g = grapheme.bytes(second_half);
        const w = win.gwidth(g);
        if (col + w > win.width) {
            win.writeCell(win.width - 1, 0, .{ .char = ellipsis });
            break;
        }
        win.writeCell(col, 0, .{
            .char = .{
                .grapheme = g,
                .width = w,
            },
        });
        col += w;
        i += 1;
        if (i == self.cursor_idx) self.prev_cursor_col = col;
    }
    if (self.draw_offset > 0) {
        win.writeCell(0, 0, .{ .char = ellipsis });
    }
    win.showCursor(self.prev_cursor_col, 0);
}

pub fn clearAndFree(self: *TextInput) void {
    self.buf.clearAndFree();
    self.reset();
}

pub fn clearRetainingCapacity(self: *TextInput) void {
    self.buf.clearRetainingCapacity();
    self.reset();
}

pub fn toOwnedSlice(self: *TextInput) ![]const u8 {
    defer self.reset();
    return self.buf.toOwnedSlice();
}

fn reset(self: *TextInput) void {
    self.cursor_idx = 0;
    self.grapheme_count = 0;
    self.draw_offset = 0;
    self.prev_cursor_col = 0;
    self.prev_cursor_idx = 0;
}

// returns the number of bytes before the cursor
// (since GapBuffers are strictly speaking not contiguous, this is a number in 0..realLength()
// which would need to be fed to realIndex() to get an actual offset into self.buf.items.ptr)
pub fn byteOffsetToCursor(self: TextInput) usize {
    // assumption! the gap is never in the middle of a grapheme
    // one way to _ensure_ this is to move the gap... but that's a cost we probably don't want to pay.
    var iter = self.unicode.graphemeIterator(self.buf.items);
    var offset: usize = 0;
    var i: usize = 0;
    while (iter.next()) |grapheme| {
        if (i == self.cursor_idx) break;
        offset += grapheme.len;
        i += 1;
    } else {
        var second_iter = self.unicode.graphemeIterator(self.buf.secondHalf());
        while (second_iter.next()) |grapheme| {
            if (i == self.cursor_idx) break;
            offset += grapheme.len;
            i += 1;
        }
    }
    return offset;
}

fn deleteToEnd(self: *TextInput) !void {
    const offset = self.byteOffsetToCursor();
    try self.buf.replaceRangeAfter(offset, self.buf.realLength() - offset, &.{});
    self.grapheme_count = self.cursor_idx;
}

fn deleteToStart(self: *TextInput) !void {
    const offset = self.byteOffsetToCursor();
    try self.buf.replaceRangeBefore(0, offset, &.{});
    self.grapheme_count -= self.cursor_idx;
    self.cursor_idx = 0;
}

fn deleteBeforeCursor(self: *TextInput) !void {
    // assumption! the gap is never in the middle of a grapheme
    // one way to _ensure_ this is to move the gap... but that's a cost we probably don't want to pay.
    var iter = self.unicode.graphemeIterator(self.buf.items);
    var offset: usize = 0;
    var i: usize = 1;
    while (iter.next()) |grapheme| {
        if (i == self.cursor_idx) {
            try self.buf.replaceRangeBefore(offset, grapheme.len, &.{});
            self.cursor_idx -= 1;
            self.grapheme_count -= 1;
            return;
        }
        offset += grapheme.len;
        i += 1;
    } else {
        var second_iter = self.unicode.graphemeIterator(self.buf.secondHalf());
        while (second_iter.next()) |grapheme| {
            if (i == self.cursor_idx) {
                try self.buf.replaceRangeBefore(offset, grapheme.len, &.{});
                self.cursor_idx -= 1;
                self.grapheme_count -= 1;
                return;
            }
            offset += grapheme.len;
            i += 1;
        }
    }
}

fn deleteAtCursor(self: *TextInput) !void {
    // assumption! the gap is never in the middle of a grapheme
    // one way to _ensure_ this is to move the gap... but that's a cost we probably don't want to pay.
    var iter = self.unicode.graphemeIterator(self.buf.items);
    var offset: usize = 0;
    var i: usize = 1;
    while (iter.next()) |grapheme| {
        if (i == self.cursor_idx + 1) {
            try self.buf.replaceRangeAfter(offset, grapheme.len, &.{});
            self.grapheme_count -= 1;
            return;
        }
        offset += grapheme.len;
        i += 1;
    } else {
        var second_iter = self.unicode.graphemeIterator(self.buf.secondHalf());
        while (second_iter.next()) |grapheme| {
            if (i == self.cursor_idx + 1) {
                try self.buf.replaceRangeAfter(offset, grapheme.len, &.{});
                self.grapheme_count -= 1;
                return;
            }
            offset += grapheme.len;
            i += 1;
        }
    }
}

test "assertion" {
    const alloc = std.testing.allocator_instance.allocator();
    const unicode = try Unicode.init(alloc);
    defer unicode.deinit();
    const astronaut = "👩‍🚀";
    const astronaut_emoji: Key = .{
        .text = astronaut,
        .codepoint = try std.unicode.utf8Decode(astronaut[0..4]),
    };
    var input = TextInput.init(std.testing.allocator, &unicode);
    defer input.deinit();
    for (0..6) |_| {
        try input.update(.{ .key_press = astronaut_emoji });
    }
}

test "sliceToCursor" {
    const alloc = std.testing.allocator_instance.allocator();
    const unicode = try Unicode.init(alloc);
    defer unicode.deinit();
    var input = init(alloc, &unicode);
    defer input.deinit();
    try input.insertSliceAtCursor("hello, world");
    input.cursor_idx = 2;
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("he", input.sliceToCursor(&buf));
    input.buf.moveGap(3);
    input.cursor_idx = 5;
    try std.testing.expectEqualStrings("hello", input.sliceToCursor(&buf));
}
