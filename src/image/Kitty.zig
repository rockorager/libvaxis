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

/// unique identifier for this image
id: u32,

/// width of the image, in cells
cell_width: usize,
/// height of the image, in cells
cell_height: usize,

/// initialize a new image
pub fn init(
    alloc: std.mem.Allocator,
    winsize: Winsize,
    src: []const u8,
    id: u32,
) !Kitty {
    const img = switch (src) {
        .path => |path| try zigimg.Image.fromFilePath(alloc, path),
        .mem => |bytes| try zigimg.Image.fromMemory(alloc, bytes),
    };
    // cell geometry
    const pix_per_col = try math.divCeil(usize, winsize.x_pixel, winsize.cols);
    const pix_per_row = try math.divCeil(usize, winsize.y_pixel, winsize.rows);

    const cell_width = math.divCeil(usize, img.width, pix_per_col) catch 0;
    const cell_height = math.divCeil(usize, img.height, pix_per_row) catch 0;

    return Image{
        .img = img,
        .cell_width = cell_width,
        .cell_height = cell_height,
        .id = id,
    };
}

pub fn deinit(self: *Image) void {
    self.img.deinit();
}

pub fn draw(self: *Image, win: Window, placement_id: u32) !void {
    try win.writeImage(win.x_off, win.y_off, self, placement_id);
}

test "image" {
    const alloc = testing.allocator;
    var img = try init(
        alloc,
        .{
            .rows = 1,
            .cols = 1,
            .x_pixel = 1,
            .y_pixel = 1,
        },
        .{ .path = "vaxis.png" },
        0,
        .kitty,
    );
    defer img.deinit();
    try testing.expectEqual(200, img.cell_width);
    try testing.expectEqual(197, img.cell_height);
}
