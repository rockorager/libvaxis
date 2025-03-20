const std = @import("std");
const assert = std.debug.assert;

const Cell = @import("Cell.zig");
const Shape = @import("Mouse.zig").Shape;
const Image = @import("Image.zig");
const Winsize = @import("main.zig").Winsize;
const Unicode = @import("Unicode.zig");
const Method = @import("gwidth.zig").Method;

const Screen = @This();

width: u16 = 0,
height: u16 = 0,

width_pix: u16 = 0,
height_pix: u16 = 0,

buf: []Cell = &.{},

cursor_row: u16 = 0,
cursor_col: u16 = 0,
cursor_vis: bool = false,

unicode: *const Unicode = undefined,

width_method: Method = .wcwidth,

mouse_shape: Shape = .default,
cursor_shape: Cell.CursorShape = .default,

pub fn init(alloc: std.mem.Allocator, winsize: Winsize, unicode: *const Unicode) std.mem.Allocator.Error!Screen {
    const w = winsize.cols;
    const h = winsize.rows;
    const self = Screen{
        .buf = try alloc.alloc(Cell, @as(usize, @intCast(w)) * h),
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
pub fn writeCell(self: *Screen, col: u16, row: u16, cell: Cell) void {
    if (col >= self.width or
        row >= self.height)
        return;
    const i = (@as(usize, @intCast(row)) * self.width) + col;
    assert(i < self.buf.len);
    self.buf[i] = cell;
}

pub fn readCell(self: *const Screen, col: u16, row: u16) ?Cell {
    if (col >= self.width or
        row >= self.height)
        return null;
    const i = (@as(usize, @intCast(row)) * self.width) + col;
    assert(i < self.buf.len);
    return self.buf[i];
}

test "refAllDecls" {
    std.testing.refAllDecls(@This());
}
