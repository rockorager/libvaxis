const std = @import("std");
const assert = std.debug.assert;
const Style = @import("Cell.zig").Style;
const Cell = @import("Cell.zig");
const MouseShape = @import("Mouse.zig").Shape;
const CursorShape = Cell.CursorShape;

const log = std.log.scoped(.vaxis);

const InternalScreen = @This();

pub const InternalCell = struct {
    char: std.ArrayListUnmanaged(u8) = .empty,
    style: Style = .{},
    uri: std.ArrayListUnmanaged(u8) = .empty,
    uri_id: std.ArrayListUnmanaged(u8) = .empty,
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

        return std.mem.eql(u8, self.char.items, cell.char.grapheme) and
            Style.eql(self.style, cell.style) and
            std.mem.eql(u8, self.uri.items, cell.link.uri) and
            std.mem.eql(u8, self.uri_id.items, cell.link.params);
    }
};

arena: *std.heap.ArenaAllocator = undefined,
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
    const arena = try alloc.create(std.heap.ArenaAllocator);
    arena.* = .init(alloc);
    var screen = InternalScreen{
        .arena = arena,
        .buf = try arena.allocator().alloc(InternalCell, @as(usize, @intCast(w)) * h),
    };
    for (screen.buf, 0..) |_, i| {
        screen.buf[i] = .{
            .char = try std.ArrayListUnmanaged(u8).initCapacity(arena.allocator(), 1),
            .uri = .empty,
            .uri_id = .empty,
        };
        screen.buf[i].char.appendAssumeCapacity(' ');
    }
    screen.width = w;
    screen.height = h;
    return screen;
}

pub fn deinit(self: *InternalScreen, alloc: std.mem.Allocator) void {
    self.arena.deinit();
    alloc.destroy(self.arena);
    self.* = undefined;
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
    self.buf[i].char.clearRetainingCapacity();
    self.buf[i].char.appendSlice(self.arena.allocator(), cell.char.grapheme) catch {
        log.warn("couldn't write grapheme", .{});
    };
    self.buf[i].uri.clearRetainingCapacity();
    self.buf[i].uri.appendSlice(self.arena.allocator(), cell.link.uri) catch {
        log.warn("couldn't write uri", .{});
    };
    self.buf[i].uri_id.clearRetainingCapacity();
    self.buf[i].uri_id.appendSlice(self.arena.allocator(), cell.link.params) catch {
        log.warn("couldn't write uri_id", .{});
    };
    self.buf[i].style = cell.style;
    self.buf[i].default = cell.default;
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
