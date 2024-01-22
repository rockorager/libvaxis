const std = @import("std");
const Cell = @import("../cell.zig").Cell;
const Key = @import("../Key.zig");
const Window = @import("../Window.zig");

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
            switch (key.codepoint) {
                0x20...0x7E => {
                    self.buffer[self.buffer_idx] = @truncate(key.codepoint);
                    self.buffer_idx += 1;
                    self.cursor_idx += 1;
                },
                Key.backspace => {
                    // TODO: this only works at the end of the array. Then
                    // again, we don't have any means to move  the cursor yet
                    if (self.buffer_idx == 0) return;
                    self.buffer_idx -= 1;
                },
                else => {},
            }
        },
    }
}

pub fn draw(self: *TextInput, win: Window) void {
    for (0.., self.buffer[0..self.buffer_idx]) |i, b| {
        win.writeCell(i, 0, .{
            .char = .{
                .grapheme = &[_]u8{b},
                .width = 1,
            },
        });
    }
}
