const std = @import("std");
const assert = std.debug.assert;

const Cell = @import("cell.zig").Cell;
const Shape = @import("Mouse.zig").Shape;
const Image = @import("image/image.zig").Image;

const log = std.log.scoped(.screen);

const Screen = @This();

pub const Placement = struct {
    img: *Image,
    placement_id: u32,
    col: usize,
    row: usize,

    /// two placements are considered equal if their image id and their
    /// placement id are equal
    pub fn eql(self: Placement, tgt: Placement) bool {
        if (self.img.getId() != tgt.img.getId()) return false;
        if (self.placement_id != tgt.placement_id) return false;
        return true;
    }
};

width: usize = 0,
height: usize = 0,

buf: []Cell = undefined,

cursor_row: usize = 0,
cursor_col: usize = 0,
cursor_vis: bool = false,

unicode: bool = false,

mouse_shape: Shape = .default,

images: std.ArrayList(Placement) = undefined,

pub fn init(alloc: std.mem.Allocator, w: usize, h: usize) !Screen {
    var self = Screen{
        .buf = try alloc.alloc(Cell, w * h),
        .width = w,
        .height = h,
        .images = std.ArrayList(Placement).init(alloc),
    };
    for (self.buf, 0..) |_, i| {
        self.buf[i] = .{};
    }
    return self;
}
pub fn deinit(self: *Screen, alloc: std.mem.Allocator) void {
    alloc.free(self.buf);
    self.images.deinit();
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

pub fn writeImage(
    self: *Screen,
    col: usize,
    row: usize,
    img: *Image,
    placement_id: u32,
) !void {
    const p = Placement{
        .img = img,
        .placement_id = placement_id,
        .col = col,
        .row = row,
    };
    try self.images.append(p);
}
