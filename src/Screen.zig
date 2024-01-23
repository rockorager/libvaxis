const std = @import("std");
const assert = std.debug.assert;

const Cell = @import("cell.zig").Cell;

const log = std.log.scoped(.screen);

const Screen = @This();

width: usize = 0,
height: usize = 0,

buf: []Cell = undefined,

cursor_row: usize = 0,
cursor_col: usize = 0,
cursor_vis: bool = false,

pub fn init(alloc: std.mem.Allocator, w: usize, h: usize) !Screen {
    var self = Screen{
        .buf = try alloc.alloc(Cell, w * h),
        .width = w,
        .height = h,
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
