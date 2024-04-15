const std = @import("std");
const assert = std.debug.assert;
const Style = @import("Cell.zig").Style;
const Cell = @import("Cell.zig");
const MouseShape = @import("Mouse.zig").Shape;
const CursorShape = Cell.CursorShape;

const log = std.log.scoped(.internal_screen);

const InternalScreen = @This();

pub const InternalCell = struct {
    char: std.ArrayList(u8) = undefined,
    style: Style = .{},
    uri: std.ArrayList(u8) = undefined,
    uri_id: std.ArrayList(u8) = undefined,
    // if we got skipped because of a wide character
    skipped: bool = false,

    pub fn eql(self: InternalCell, cell: Cell) bool {
        return std.mem.eql(u8, self.char.items, cell.char.grapheme) and
            std.meta.eql(self.style, cell.style) and
            std.mem.eql(u8, self.uri.items, cell.link.uri) and
            std.mem.eql(u8, self.uri_id.items, cell.link.params);
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
    self.buf[i].uri.clearRetainingCapacity();
    self.buf[i].uri_id.appendSlice(cell.link.params) catch {
        log.warn("couldn't write uri_id", .{});
    };
    self.buf[i].style = cell.style;
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
