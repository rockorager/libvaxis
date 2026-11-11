const std = @import("std");
const assert = std.debug.assert;
const Style = @import("Cell.zig").Style;
const Cell = @import("Cell.zig");
const MouseShape = @import("Mouse.zig").Shape;
const CursorShape = Cell.CursorShape;

const InternalScreen = @This();

pub const InternalCell = struct {
    char: std.ArrayList(u8) = .empty,
    style: Style = .{},
    uri: std.ArrayList(u8) = .empty,
    uri_id: std.ArrayList(u8) = .empty,
    // if we got skipped because of a wide character
    skipped: bool = false,
    default: bool = true,

    // If we should skip rendering *this* round due to being printed over previously (from a scaled
    // cell, for example)
    skip: bool = false,

    scale: Cell.Scale = .{},

    pub fn eql(self: *const InternalCell, cell: *const Cell) bool {

        // fastpath when both cells are default
        if (self.default and cell.default) return true;

        return std.mem.eql(u8, self.char.items, cell.char.grapheme) and
            Style.eql(self.style, cell.style) and
            std.mem.eql(u8, self.uri.items, cell.link.uri) and
            std.mem.eql(u8, self.uri_id.items, cell.link.params);
    }
};

arena: *std.heap.ArenaAllocator,
width: u16 = 0,
height: u16 = 0,

buf: []InternalCell,

cursor_vis: bool = false,
cursor_shape: CursorShape = .default,

mouse_shape: MouseShape = .default,

/// sets each cell to the default cell
pub fn init(gpa: std.mem.Allocator, w: u16, h: u16) !InternalScreen {
    const arena = try gpa.create(std.heap.ArenaAllocator);
    errdefer gpa.destroy(arena);
    arena.* = .init(gpa);
    errdefer arena.deinit();
    var screen = InternalScreen{
        .arena = arena,
        .buf = try arena.allocator().alloc(InternalCell, @as(usize, @intCast(w)) * h),
    };
    for (screen.buf, 0..) |_, i| {
        screen.buf[i] = .{
            .char = try .initCapacity(arena.allocator(), 1),
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

/// Writes a cell to a location. 0 indexed.
/// On allocation failure the cell may be partially updated.
pub fn writeCell(
    self: *InternalScreen,
    col: u16,
    row: u16,
    cell: Cell,
) std.mem.Allocator.Error!void {
    if (self.width <= col) {
        // column out of bounds
        return;
    }
    if (self.height <= row) {
        // height out of bounds
        return;
    }
    const i = (@as(usize, @intCast(row)) * self.width) + col;
    assert(i < self.buf.len);
    self.buf[i].char.clearRetainingCapacity();
    try self.buf[i].char.ensureTotalCapacityPrecise(self.arena.allocator(), cell.char.grapheme.len);
    self.buf[i].char.appendSliceAssumeCapacity(cell.char.grapheme);
    self.buf[i].uri.clearRetainingCapacity();
    try self.buf[i].uri.ensureTotalCapacityPrecise(self.arena.allocator(), cell.link.uri.len);
    self.buf[i].uri.appendSliceAssumeCapacity(cell.link.uri);
    self.buf[i].uri_id.clearRetainingCapacity();
    try self.buf[i].uri_id.ensureTotalCapacityPrecise(self.arena.allocator(), cell.link.params.len);
    self.buf[i].uri_id.appendSliceAssumeCapacity(cell.link.params);
    self.buf[i].style = cell.style;
    self.buf[i].default = cell.default;
}

pub fn readCell(self: *InternalScreen, col: u16, row: u16) ?Cell {
    if (self.width <= col) {
        // column out of bounds
        return null;
    }
    if (self.height <= row) {
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

test "InternalScreen: out-of-bounds read/write are ignored" {
    var screen = try InternalScreen.init(std.testing.allocator, 2, 2);
    defer screen.deinit(std.testing.allocator);

    const sentinel: Cell = .{ .char = .{ .grapheme = "A", .width = 1 } };
    try screen.writeCell(0, 1, sentinel);

    const oob_cell: Cell = .{ .char = .{ .grapheme = "X", .width = 1 } };
    try screen.writeCell(2, 0, oob_cell);
    const read_back = screen.readCell(0, 1) orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.eql(u8, read_back.char.grapheme, "A"));
    try std.testing.expect(screen.readCell(2, 0) == null);
}

test "InternalScreen: dense text and links reserve precisely and reuse replacements" {
    var screen = try InternalScreen.init(std.testing.allocator, 256, 192);
    defer screen.deinit(std.testing.allocator);
    const values = [_]Cell{
        .{ .char = .{ .grapheme = "e\u{0301}", .width = 1 }, .link = .{ .uri = "https://x", .params = "id=a" } },
        .{ .char = .{ .grapheme = "A", .width = 1 } },
        .{ .char = .{ .grapheme = "o\u{0301}\u{0308}", .width = 1 }, .link = .{ .uri = "https://xy", .params = "id=bc" } },
    };
    var settled_capacity: usize = 0;
    for (0..4) |cycle| {
        for (values) |value| {
            for (0..192) |row| for (0..256) |col| {
                try screen.writeCell(@intCast(col), @intCast(row), value);
                const actual = screen.readCell(@intCast(col), @intCast(row)).?;
                try std.testing.expectEqualStrings(value.char.grapheme, actual.char.grapheme);
                try std.testing.expectEqualStrings(value.link.uri, actual.link.uri);
                try std.testing.expectEqualStrings(value.link.params, actual.link.params);
            };
        }
        for (screen.buf) |cell| {
            try std.testing.expectEqual(@as(usize, 5), cell.char.capacity);
            try std.testing.expectEqual(@as(usize, 10), cell.uri.capacity);
            try std.testing.expectEqual(@as(usize, 5), cell.uri_id.capacity);
        }
        if (cycle == 0) settled_capacity = screen.arena.queryCapacity() else try std.testing.expectEqual(settled_capacity, screen.arena.queryCapacity());
    }
}

test {
    std.testing.refAllDecls(@This());
}
