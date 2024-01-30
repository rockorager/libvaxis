const std = @import("std");
const math = std.math;
const testing = std.testing;
const zigimg = @import("zigimg");
const png = zigimg.png;

const Window = @import("../Window.zig");
const Winsize = @import("../Tty.zig").Winsize;

const Kitty = @This();

/// the decoded image
img: zigimg.Image,

/// unique identifier for this image. This will be managed by the screen. The ID
/// is only null for images which have not been transmitted to the screen
id: ?u32 = null,

/// width of the image, in cells
cell_width: usize,
/// height of the image, in cells
cell_height: usize,

pub fn deinit(self: *Kitty) void {
    self.img.deinit();
}

pub fn draw(self: *Kitty, win: Window) !void {
    const row: u16 = @truncate(win.y_off);
    const col: u16 = @truncate(win.x_off);
    // the placement id has the high 16 bits as the column and the low 16
    // bits as the row. This means we can only place this image one time at
    // the same location - which is completely sane
    const pid: u32 = col << 16 | row;
    try win.writeImage(win.x_off, win.y_off, self, pid);
}
