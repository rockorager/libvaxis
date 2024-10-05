const std = @import("std");
const assert = std.debug.assert;

const Cell = @import("Cell.zig");
const Shape = @import("Mouse.zig").Shape;
const Image = @import("Image.zig");
const Winsize = @import("main.zig").Winsize;
const Unicode = @import("Unicode.zig");
const Method = @import("gwidth.zig").Method;

const Screen = @This();

width: usize = 0,
height: usize = 0,

width_pix: usize = 0,
height_pix: usize = 0,

buf: []Cell = undefined,

cursor_row: usize = 0,
cursor_col: usize = 0,
cursor_vis: bool = false,

unicode: *const Unicode = undefined,

width_method: Method = .wcwidth,

mouse_shape: Shape = .default,
cursor_shape: Cell.CursorShape = .default,

pub fn init(alloc: std.mem.Allocator, winsize: Winsize, unicode: *const Unicode) std.mem.Allocator.Error!Screen {
    const w = winsize.cols;
    const h = winsize.rows;
    const self = Screen{
        .buf = try alloc.alloc(Cell, w * h),
        .width = w,
        .height = h,
        .width_pix = winsize.x_pixel,
        .height_pix = winsize.y_pixel,
        .unicode = unicode,
    };
    const base_cell: Cell = .{};
    @memset(self.buf, base_cell);
    return self;
}
pub fn deinit(self: *Screen, alloc: std.mem.Allocator) void {
    alloc.free(self.buf);
}

/// writes a cell to a location. 0 indexed
pub fn writeCell(self: *Screen, col: usize, row: usize, cell: Cell) void {
    if (self.width <= col) {
        // column out of bounds
        return;
    }
    if (self.height <= row) {
        // height out of bounds
        return;
    }
    const i = (row * self.width) + col;
    assert(i < self.buf.len);
    self.buf[i] = cell;
}

pub fn readCell(self: *const Screen, col: usize, row: usize) ?Cell {
    if (self.width <= col) {
        // column out of bounds
        return null;
    }
    if (self.height <= row) {
        // height out of bounds
        return null;
    }
    const i = (row * self.width) + col;
    assert(i < self.buf.len);
    return self.buf[i];
}
