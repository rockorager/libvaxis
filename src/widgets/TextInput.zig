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

// the actual line of input
buffer: [4096]u8 = undefined,
buffer_idx: usize = 0,

pub fn update(self: *TextInput, event: Event) void {
    switch (event) {
        .key_press => |key| {
            if (key.text) |text| {
                @memcpy(self.buffer[self.buffer_idx .. self.buffer_idx + text.len], text);
                self.buffer_idx += text.len;
                self.cursor_idx += strWidth(text, .full) catch 1;
            }
            switch (key.codepoint) {
                Key.backspace => {
                    // TODO: this only works at the end of the array. Then
                    // again, we don't have any means to move  the cursor yet
                    // This also doesn't work with graphemes yet
                    if (self.buffer_idx == 0) return;
                    self.buffer_idx -= 1;
                    self.cursor_idx -= 1;
                },
                else => {},
            }
        },
    }
}

pub fn draw(self: *TextInput, win: Window) void {
    const input = self.buffer[0..self.buffer_idx];
    var iter = GraphemeIterator.init(input);
    var col: usize = 0;
    while (iter.next()) |grapheme| {
        const g = grapheme.slice(input);
        const w = strWidth(g, .full) catch 1;
        win.writeCell(col, 0, .{
            .char = .{
                .grapheme = g,
                .width = w,
            },
        });
        col += w;
    }
    win.showCursor(self.cursor_idx, 0);
}
