const std = @import("std");

const Cell = @import("cell.zig").Cell;

const Screen = @This();

width: usize,
height: usize,

buf: []Cell = undefined,

pub fn init() Screen {
    return Screen{
        .width = 0,
        .height = 0,
    };
}

pub fn deinit(self: *Screen, alloc: std.mem.Allocator) void {
    alloc.free(self.buf);
}

pub fn resize(self: *Screen, alloc: std.mem.Allocator, w: usize, h: usize) !void {
    alloc.free(self.buf);
    self.buf = try alloc.alloc(Cell, w * h);
    self.width = w;
    self.height = h;
}

/// writes a cell to a location. 0 indexed
pub fn writeCell(self: *Screen, cell: Cell, row: usize, col: usize) void {
    if (self.width < col) {
        // column out of bounds
        return;
    }
    if (self.height < row) {
        // height out of bounds
        return;
    }
    const i = (col * self.width) + row;
    std.debug.assert(i < self.buf.len);
    self.buf[i] = cell;
}
