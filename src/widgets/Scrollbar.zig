const std = @import("std");
const vaxis = @import("../main.zig");

const Scrollbar = @This();

/// character to use for the scrollbar
character: vaxis.Cell.Character = .{ .grapheme = "▐", .width = 1 },

/// style to draw the bar character with
style: vaxis.Style = .{},

/// index of the top of the visible area
top: usize = 0,

/// total items in the list
total: usize,

/// total items that fit within the view area
view_size: usize,

pub fn draw(self: Scrollbar, win: vaxis.Window) void {
    // don't draw when 0 items
    if (self.total < 1) return;

    // don't draw when all items can be shown
    if (self.view_size >= self.total) return;

    const bar_height = @max(std.math.divCeil(usize, self.view_size * win.height, self.total) catch unreachable, 1);
    const bar_top = self.top * win.height / self.total;
    var i: usize = 0;
    while (i < bar_height) : (i += 1)
        win.writeCell(0, @intCast(i + bar_top), .{ .char = self.character, .style = self.style });
}
