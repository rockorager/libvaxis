const std = @import("std");
const assert = std.debug.assert;
const Style = @import("cell.zig").Style;
const Cell = @import("cell.zig").Cell;

const log = std.log.scoped(.internal_screen);

const InternalScreen = @This();

pub const InternalCell = struct {
    char: std.ArrayList(u8) = undefined,
    style: Style = .{},

    pub fn eql(self: InternalCell, cell: Cell) bool {
        return std.mem.eql(u8, self.char.items, cell.char.grapheme) and std.meta.eql(self.style, cell.style);
    }
};

width: usize = 0,
height: usize = 0,

buf: []InternalCell = undefined,

cursor_row: usize = 0,
cursor_col: usize = 0,
cursor_vis: bool = false,

/// sets each cell to the default cell
pub fn init(alloc: std.mem.Allocator, w: usize, h: usize) !InternalScreen {
    var screen = InternalScreen{};
    screen.buf = try alloc.alloc(InternalCell, w * h);
    for (screen.buf, 0..) |_, i| {
        screen.buf[i] = .{
            .char = try std.ArrayList(u8).initCapacity(alloc, 1),
        };
    }
    screen.width = w;
    screen.height = h;
    return screen;
}

pub fn deinit(self: *InternalScreen, alloc: std.mem.Allocator) void {
    for (self.buf, 0..) |_, i| {
        self.buf[i].char.deinit();
    }

    alloc.free(self.buf);
}

/// writes a cell to a location. 0 indexed
pub fn writeCell(
    self: *InternalScreen,
    col: usize,
    row: usize,
    char: []const u8,
    style: Style,
) void {
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
    self.buf[i].char.clearRetainingCapacity();
    self.buf[i].char.appendSlice(char) catch {
        log.warn("couldn't write grapheme", .{});
    };
    self.buf[i].style = style;
}
