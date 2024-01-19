const std = @import("std");
const assert = std.debug.assert;

const Cell = @import("cell.zig").Cell;

const log = std.log.scoped(.screen);

const Screen = @This();

width: usize = 0,
height: usize = 0,

buf: []Cell = undefined,

/// sets each cell to the default cell
pub fn init(self: *Screen) void {
    for (self.buf, 0..) |_, i| {
        self.buf[i] = .{};
    }
}

pub fn deinit(self: *Screen, alloc: std.mem.Allocator) void {
    alloc.free(self.buf);
}

pub fn resize(self: *Screen, alloc: std.mem.Allocator, w: usize, h: usize) !void {
    log.debug("resizing screen: width={d} height={d}", .{ w, h });
    alloc.free(self.buf);
    self.buf = try alloc.alloc(Cell, w * h);
    self.width = w;
    self.height = h;
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
