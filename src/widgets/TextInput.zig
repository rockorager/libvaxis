const std = @import("std");
const Cell = @import("../cell.zig").Cell;
const Key = @import("../Key.zig");
const Window = @import("../Window.zig");
const GraphemeIterator = @import("ziglyph").GraphemeIterator;
const strWidth = @import("ziglyph").display_width.strWidth;

const log = std.log.scoped(.text_input);

const TextInput = @This();

/// The events that this widget handles
const Event = union(enum) {
    key_press: Key,
};

// Index of our cursor
cursor_idx: usize = 0,
grapheme_count: usize = 0,

// TODO: an ArrayList is not great for this. orderedRemove is O(n) and we can
// only remove one byte at a time. Make a bespoke ArrayList which allows removal
// of a slice at a time, or truncating even would be nice
buf: std.ArrayList(u8),

pub fn init(alloc: std.mem.Allocator) TextInput {
    return TextInput{
        .buf = std.ArrayList(u8).init(alloc),
    };
}

pub fn deinit(self: *TextInput) void {
    self.buf.deinit();
}

pub fn update(self: *TextInput, event: Event) !void {
    switch (event) {
        .key_press => |key| {
            if (key.text) |text| {
                try self.buf.insertSlice(self.byteOffsetToCursor(), text);
                self.cursor_idx += 1;
                self.grapheme_count += 1;
            }
            if (key.matches(Key.backspace, .{})) {
                if (self.cursor_idx == 0) return;
                self.deleteBeforeCursor();
            }
            if (key.matches(Key.delete, .{})) {
                if (self.cursor_idx == self.grapheme_count) return;
                self.deleteAtCursor();
            }
            if (key.matches(Key.left, .{})) {
                if (self.cursor_idx > 0) self.cursor_idx -= 1;
            }
            if (key.matches(Key.right, .{})) {
                if (self.cursor_idx < self.grapheme_count) self.cursor_idx += 1;
            }
            // TODO: readline bindings
        },
    }
}

pub fn draw(self: *TextInput, win: Window) void {
    var iter = GraphemeIterator.init(self.buf.items);
    var col: usize = 0;
    var i: usize = 0;
    var cursor_idx: usize = 0;
    while (iter.next()) |grapheme| {
        const g = grapheme.slice(self.buf.items);
        const w = strWidth(g, .half) catch 1;
        win.writeCell(col, 0, .{
            .char = .{
                .grapheme = g,
                .width = w,
            },
        });
        col += w;
        i += 1;
        if (i == self.cursor_idx) cursor_idx = col;
    }
    win.showCursor(cursor_idx, 0);
}

// returns the number of bytes before the cursor
fn byteOffsetToCursor(self: TextInput) usize {
    var iter = GraphemeIterator.init(self.buf.items);
    var offset: usize = 0;
    var i: usize = 0;
    while (iter.next()) |grapheme| {
        if (i == self.cursor_idx) break;
        offset += grapheme.len;
        i += 1;
    }
    return offset;
}

fn deleteBeforeCursor(self: *TextInput) void {
    var iter = GraphemeIterator.init(self.buf.items);
    var offset: usize = 0;
    var i: usize = 1;
    while (iter.next()) |grapheme| {
        if (i == self.cursor_idx) {
            var j: usize = 0;
            while (j < grapheme.len) : (j += 1) {
                _ = self.buf.orderedRemove(offset);
            }
            self.cursor_idx -= 1;
            self.grapheme_count -= 1;
            return;
        }
        offset += grapheme.len;
        i += 1;
    }
}

fn deleteAtCursor(self: *TextInput) void {
    var iter = GraphemeIterator.init(self.buf.items);
    var offset: usize = 0;
    var i: usize = 1;
    while (iter.next()) |grapheme| {
        if (i == self.cursor_idx + 1) {
            var j: usize = 0;
            while (j < grapheme.len) : (j += 1) {
                _ = self.buf.orderedRemove(offset);
            }
            self.grapheme_count -= 1;
            return;
        }
        offset += grapheme.len;
        i += 1;
    }
}
