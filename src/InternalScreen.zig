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

    // If we should skip rendering *this* round due to being printed over previously (from a scaled
    // cell, for example)
    skip: bool = false,

    scale: Cell.Scale = .{},

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
        if (!self.scale.eql(cell.scale)) return false;
        return true;
    }
};

width: u16 = 0,
height: u16 = 0,

buf: []InternalCell = undefined,

cursor_row: u16 = 0,
cursor_col: u16 = 0,
cursor_vis: bool = false,
cursor_shape: CursorShape = .default,

mouse_shape: MouseShape = .default,

/// sets each cell to the default cell
pub fn init(alloc: std.mem.Allocator, w: u16, h: u16) !InternalScreen {
    var screen = InternalScreen{
        .buf = try alloc.alloc(InternalCell, @as(usize, @intCast(w)) * h),
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
    col: u16,
    row: u16,
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
    const i = (@as(usize, @intCast(row)) * self.width) + col;
    assert(i < self.buf.len);
    const last_cell = &self.buf[i];
    last_cell.char.clearRetainingCapacity();
    last_cell.char.appendSlice(cell.char.grapheme) catch {
        log.warn("couldn't write grapheme", .{});
    };
    last_cell.uri.clearRetainingCapacity();
    last_cell.uri.appendSlice(cell.link.uri) catch {
        log.warn("couldn't write uri", .{});
    };
    last_cell.uri_id.clearRetainingCapacity();
    last_cell.uri_id.appendSlice(cell.link.params) catch {
        log.warn("couldn't write uri_id", .{});
    };
    last_cell.style = cell.style;
    last_cell.default = cell.default;
}

pub fn readCell(self: *InternalScreen, col: u16, row: u16) ?Cell {
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
    const cell = self.buf[i];
    return .{
        .char = .{ .grapheme = cell.char.items },
        .style = cell.style,
        .link = .{
            .uri = cell.uri.items,
            .params = cell.uri_id.items,
        },
        .default = cell.default,
    };
}
