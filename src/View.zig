//! A View is effectively an "oversized" Window that can be written to and rendered in pieces.

const std = @import("std");
const mem = std.mem;

const View = @This();

const Screen = @import("Screen.zig");
const Window = @import("Window.zig");
const Unicode = @import("Unicode.zig");
const Cell = @import("Cell.zig");

/// View Allocator
alloc: mem.Allocator,
/// Underlying Screen
screen: *Screen,
/// Underlying Window
win: Window,

/// View Initialization Config
pub const Config = struct {
    width: usize,
    height: usize,
};
/// Initialize a new View
pub fn init(alloc: mem.Allocator, unicode: *const Unicode, config: Config) !View {
    const screen = try alloc.create(Screen);
    screen.* = try Screen.init(
        alloc,
        .{
            .cols = config.width,
            .rows = config.height,
            .x_pixel = 0,
            .y_pixel = 0,
        },
        unicode,
    );
    return .{
        .alloc = alloc,
        .screen = screen,
        .win = .{
            .x_off = 0,
            .y_off = 0,
            .width = config.width,
            .height = config.height,
            .screen = screen,
        },
    };
}

/// Deinitialize this View
pub fn deinit(self: *View) void {
    self.screen.deinit(self.alloc);
    self.alloc.destroy(self.screen);
}

/// Render Config f/ `toWin()`
pub const RenderConfig = struct {
    x: usize = 0,
    y: usize = 0,
    width: Extent = .fit,
    height: Extent = .fit,

    pub const Extent = union(enum) {
        fit,
        max: usize,
    };
};
/// Render a portion of this View to the provided Window (`win`).
/// This will return the bounded X (col), Y (row) coordinates based on the rendering.
pub fn toWin(self: *View, win: Window, config: RenderConfig) !struct { usize, usize } {
    var x = @min(self.screen.width - 1, config.x);
    var y = @min(self.screen.height - 1, config.y);
    const width = width: {
        var width = switch (config.width) {
            .fit => win.width,
            .max => |w| @min(win.width, w),
        };
        width = @min(width, self.screen.width);
        break :width @min(width, self.screen.width -| 1 -| x +| win.width);
    };
    const height = height: {
        var height = switch (config.height) {
            .fit => win.height,
            .max => |h| @min(win.height, h),
        };
        height = @min(height, self.screen.height);
        break :height @min(height, self.screen.height -| 1 -| y +| win.height);
    };
    x = @min(x, self.screen.width -| width);
    y = @min(y, self.screen.height -| height);

    for (0..height) |row| {
        for (0..width) |col| {
            win.writeCell(
                col,
                row,
                self.win.readCell(
                    @min(self.screen.width -| 1, x +| col),
                    @min(self.screen.height -| 1, y +| row),
                ) orelse {
                    std.log.err(
                        \\ Position Out of Bounds:
                        \\ - Pos:  {d}, {d}
                        \\ - Size: {d}, {d}
                        , .{
                            col,               row,
                            self.screen.width, self.screen.height,
                        },
                    );
                    return error.PositionOutOfBounds;
                },
            );
        }
    }
    return .{ x, y };
}

/// Writes a cell to the location in the View
pub fn writeCell(self: View, col: usize, row: usize, cell: Cell) void {
    self.win.writeCell(col, row, cell);
}

/// Reads a cell at the location in the View
pub fn readCell(self: View, col: usize, row: usize) ?Cell {
    return self.win.readCell(col, row);
}

/// Fills the View with the default cell
pub fn clear(self: View) void {
    self.win.clear();
}

/// Returns the width of the grapheme. This depends on the terminal capabilities
pub fn gwidth(self: View, str: []const u8) usize {
    return self.win.gwidth(str);
}

/// Fills the View with the provided cell
pub fn fill(self: View, cell: Cell) void {
    self.win.fill(cell);
}

/// Prints segments to the View. Returns true if the text overflowed with the
/// given wrap strategy and size.
pub fn print(self: View, segments: []const Cell.Segment, opts: Window.PrintOptions) !Window.PrintResult {
    return self.win.print(segments, opts);
}

/// Print a single segment. This is just a shortcut for print(&.{segment}, opts)
pub fn printSegment(self: View, segment: Cell.Segment, opts: Window.PrintOptions) !Window.PrintResult {
    return self.print(&.{segment}, opts);
}

/// Create a child window
pub fn child(self: View, opts: Window.ChildOptions) Window {
    return self.win.child(opts);
}
