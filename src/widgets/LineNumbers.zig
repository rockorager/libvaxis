const std = @import("std");
const vaxis = @import("../main.zig");

const digits = "0123456789";

num_lines: usize = std.math.maxInt(usize),
highlighted_line: usize = 0,
style: vaxis.Style = .{ .dim = true },
highlighted_style: vaxis.Style = .{ .dim = true, .bg = .{ .index = 0 } },

pub fn extractDigit(v: usize, n: usize) usize {
    return (v / (std.math.powi(usize, 10, n) catch unreachable)) % 10;
}

pub fn numDigits(v: usize) u8 {
    return switch (v) {
        0...9 => 1,
        10...99 => 2,
        100...999 => 3,
        1000...9999 => 4,
        10000...99999 => 5,
        100000...999999 => 6,
        1000000...9999999 => 7,
        10000000...99999999 => 8,
        else => 0,
    };
}

pub fn draw(self: @This(), win: vaxis.Window, y_scroll: usize) void {
    for (1 + y_scroll..self.num_lines) |line| {
        if (line - 1 >= y_scroll +| win.height) {
            break;
        }
        const highlighted = line == self.highlighted_line;
        const num_digits = numDigits(line);
        for (0..num_digits) |i| {
            const digit = extractDigit(line, i);
            win.writeCell(@intCast(win.width -| (i + 2)), @intCast(line -| (y_scroll +| 1)), .{
                .char = .{
                    .width = 1,
                    .grapheme = digits[digit .. digit + 1],
                },
                .style = if (highlighted) self.highlighted_style else self.style,
            });
        }
        if (highlighted) {
            for (num_digits + 1..win.width) |i| {
                win.writeCell(@intCast(i), @intCast(line -| (y_scroll +| 1)), .{
                    .style = if (highlighted) self.highlighted_style else self.style,
                });
            }
        }
    }
}
