const std = @import("std");
const fmt = std.fmt;
const math = std.math;
const testing = std.testing;
const base64 = std.base64.standard.Encoder;
const zigimg = @import("zigimg");

const Window = @import("Window.zig");
const Winsize = @import("Tty.zig").Winsize;

const log = std.log.scoped(.image);

const Image = @This();

const transmit_opener = "\x1b_Gf=32,i={d},s={d},v={d},m={d};";

pub const Source = union(enum) {
    path: []const u8,
    mem: []const u8,
};

pub const Placement = struct {
    img_id: u32,
    z_index: i32,
    scale: bool,
};

pub const CellSize = struct {
    rows: usize,
    cols: usize,
};

/// unique identifier for this image. This will be managed by the screen.
id: u32,

// width in pixels
width: usize,
// height in pixels
height: usize,

pub fn draw(self: Image, win: Window, scale: bool, z_index: i32) void {
    const p = Placement{
        .img_id = self.id,
        .z_index = z_index,
        .scale = scale,
    };
    win.writeCell(0, 0, .{ .image = p });
}

pub fn cellSize(self: Image, winsize: Winsize) !CellSize {
    // cell geometry
    const pix_per_col = try std.math.divCeil(usize, winsize.x_pixel, winsize.cols);
    const pix_per_row = try std.math.divCeil(usize, winsize.y_pixel, winsize.rows);

    const cell_width = std.math.divCeil(usize, self.width, pix_per_col) catch 0;
    const cell_height = std.math.divCeil(usize, self.height, pix_per_row) catch 0;
    return .{
        .rows = cell_height,
        .cols = cell_width,
    };
}
