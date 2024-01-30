const std = @import("std");
const assert = std.debug.assert;

const Cell = @import("cell.zig").Cell;
const Shape = @import("Mouse.zig").Shape;
const Image = @import("Image.zig");
const Winsize = @import("Tty.zig").Winsize;

const log = std.log.scoped(.screen);

const Screen = @This();

width: usize = 0,
height: usize = 0,

width_pix: usize = 0,
height_pix: usize = 0,

buf: []Cell = undefined,

cursor_row: usize = 0,
cursor_col: usize = 0,
cursor_vis: bool = false,

unicode: bool = false,

mouse_shape: Shape = .default,

pub fn init(alloc: std.mem.Allocator, winsize: Winsize) !Screen {
    const w = winsize.cols;
    const h = winsize.rows;
    var self = Screen{
        .buf = try alloc.alloc(Cell, w * h),
        .width = w,
        .height = h,
        .width_pix = winsize.x_pixel,
        .height_pix = winsize.y_pixel,
    };
    for (self.buf, 0..) |_, i| {
        self.buf[i] = .{};
    }
    return self;
}
pub fn deinit(self: *Screen, alloc: std.mem.Allocator) void {
    alloc.free(self.buf);
}

/// writes a cell to a location. 0 indexed
pub fn writeCell(self: *Screen, col: usize, row: usize, cell: Cell) void {
    if (self.width < col) {
        // column out of bounds
        return;
    }
    if (self.height < row) {
        // height out of bounds
        return;
    }
    const i = (row * self.width) + col;
    assert(i < self.buf.len);
    self.buf[i] = cell;
}
