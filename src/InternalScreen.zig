const std = @import("std");
const assert = std.debug.assert;
const Style = @import("Cell.zig").Style;
const Cell = @import("Cell.zig");
const MouseShape = @import("Mouse.zig").Shape;
const CursorShape = Cell.CursorShape;

const log = std.log.scoped(.vaxis);

const InternalScreen = @This();

pub const InternalCell = struct {
    char: std.ArrayList(u8) = undefined,
    style: Style = .{},
    uri: std.ArrayList(u8) = undefined,
    uri_id: std.ArrayList(u8) = undefined,
    // if we got skipped because of a wide character
    skipped: bool = false,
    default: bool = true,

    pub fn eql(self: InternalCell, cell: Cell) bool {
        // fastpath when both cells are default
        if (self.default and cell.default) return true;
        // this is actually faster than std.meta.eql on the individual items.
        // Our strings are always small, usually less than 4 bytes so the simd
        // usage in std.mem.eql has too much overhead vs looping the bytes
        if (!std.mem.eql(u8, self.char.items, cell.char.grapheme)) return false;
        if (!Style.eql(self.style, cell.style)) return false;
        if (!std.mem.eql(u8, self.uri.items, cell.link.uri)) return false;
        if (!std.mem.eql(u8, self.uri_id.items, cell.link.params)) return false;
        return true;
    }
};

width: usize = 0,
height: usize = 0,

buf: []InternalCell = undefined,

cursor_row: usize = 0,
cursor_col: usize = 0,
cursor_vis: bool = false,
cursor_shape: CursorShape = .default,

mouse_shape: MouseShape = .default,

/// sets each cell to the default cell
pub fn init(alloc: std.mem.Allocator, w: usize, h: usize) !InternalScreen {
    var screen = InternalScreen{
        .buf = try alloc.alloc(InternalCell, w * h),
    };
    for (screen.buf, 0..) |_, i| {
        screen.buf[i] = .{
            .char = try std.ArrayList(u8).initCapacity(alloc, 1),
            .uri = std.ArrayList(u8).init(alloc),
            .uri_id = std.ArrayList(u8).init(alloc),
        };
        try screen.buf[i].char.append(' ');
    }
    screen.width = w;
    screen.height = h;
    return screen;
}

pub fn deinit(self: *InternalScreen, alloc: std.mem.Allocator) void {
    for (self.buf, 0..) |_, i| {
        self.buf[i].char.deinit();
        self.buf[i].uri.deinit();
        self.buf[i].uri_id.deinit();
    }

    alloc.free(self.buf);
}

/// writes a cell to a location. 0 indexed
pub fn writeCell(
    self: *InternalScreen,
    col: usize,
    row: usize,
    cell: Cell,
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
    self.buf[i].char.appendSlice(cell.char.grapheme) catch {
        log.warn("couldn't write grapheme", .{});
    };
    self.buf[i].uri.clearRetainingCapacity();
    self.buf[i].uri.appendSlice(cell.link.uri) catch {
        log.warn("couldn't write uri", .{});
    };
    self.buf[i].uri_id.clearRetainingCapacity();
    self.buf[i].uri_id.appendSlice(cell.link.params) catch {
        log.warn("couldn't write uri_id", .{});
    };
    self.buf[i].style = cell.style;
    self.buf[i].default = cell.default;
}

pub fn readCell(self: *InternalScreen, col: usize, row: usize) ?Cell {
    if (self.width < col) {
        // column out of bounds
        return null;
    }
    if (self.height < row) {
        // height out of bounds
        return null;
    }
    const i = (row * self.width) + col;
    assert(i < self.buf.len);
    return .{
        .char = .{ .grapheme = self.buf[i].char.items },
        .style = self.buf[i].style,
    };
}
