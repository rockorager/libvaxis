//! A View is effectively an "oversized" Window that can be written to and rendered in pieces.

const std = @import("std");
const mem = std.mem;

const View = @This();

const gw = @import("../gwidth.zig");

const Screen = @import("../Screen.zig");
const Window = @import("../Window.zig");
const Unicode = @import("../Unicode.zig");
const Cell = @import("../Cell.zig");

/// View Allocator
alloc: mem.Allocator,

/// Underlying Screen
screen: Screen,

/// View Initialization Config
pub const Config = struct {
    width: u16,
    height: u16,
};

/// Initialize a new View
pub fn init(alloc: mem.Allocator, unicode: *const Unicode, config: Config) mem.Allocator.Error!View {
    const screen = try Screen.init(
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
    };
}

pub fn window(self: *View) Window {
    return .{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = self.screen.width,
        .height = self.screen.height,
        .screen = &self.screen,
    };
}

/// Deinitialize this View
pub fn deinit(self: *View) void {
    self.screen.deinit(self.alloc);
}

pub const DrawOptions = struct {
    x_off: u16 = 0,
    y_off: u16 = 0,
};

pub fn draw(self: *View, win: Window, opts: DrawOptions) void {
    if (opts.x_off >= self.screen.width) return;
    if (opts.y_off >= self.screen.height) return;

    const width = @min(win.width, self.screen.width - opts.x_off);
    const height = @min(win.height, self.screen.height - opts.y_off);

    for (0..height) |_row| {
        const row: i17 = @intCast(_row);
        const src_start: usize = @intCast(opts.x_off + ((row + opts.y_off) * self.screen.width));
        const src_end: usize = @intCast(src_start + width);
        const dst_start: usize = @intCast(win.x_off + ((row + win.y_off) * win.screen.width));
        const dst_end: usize = @intCast(dst_start + width);
        @memcpy(win.screen.buf[dst_start..dst_end], self.screen.buf[src_start..src_end]);
    }
}

/// Render Config for `toWin()`
pub const RenderConfig = struct {
    x: u16 = 0,
    y: u16 = 0,
    width: Extent = .fit,
    height: Extent = .fit,

    pub const Extent = union(enum) {
        fit,
        max: u16,
    };
};

/// Render a portion of this View to the provided Window (`win`).
/// This will return the bounded X (col), Y (row) coordinates based on the rendering.
pub fn toWin(self: *View, win: Window, config: RenderConfig) !struct { u16, u16 } {
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
    const child = win.child(.{
        .width = width,
        .height = height,
    });
    self.draw(child, .{ .x_off = x, .y_off = y });
    return .{ x, y };
}

/// Writes a cell to the location in the View
pub fn writeCell(self: *View, col: u16, row: u16, cell: Cell) void {
    self.screen.writeCell(col, row, cell);
}

/// Reads a cell at the location in the View
pub fn readCell(self: *const View, col: u16, row: u16) ?Cell {
    return self.screen.readCell(col, row);
}

/// Fills the View with the default cell
pub fn clear(self: View) void {
    self.fill(.{ .default = true });
}

/// Returns the width of the grapheme. This depends on the terminal capabilities
pub fn gwidth(self: View, str: []const u8) u16 {
    return gw.gwidth(str, self.screen.width_method, &self.screen.unicode.width_data);
}

/// Fills the View with the provided cell
pub fn fill(self: View, cell: Cell) void {
    @memset(self.screen.buf, cell);
}

/// Prints segments to the View. Returns true if the text overflowed with the
/// given wrap strategy and size.
pub fn print(self: *View, segments: []const Cell.Segment, opts: Window.PrintOptions) Window.PrintResult {
    return self.window().print(segments, opts);
}

/// Print a single segment. This is just a shortcut for print(&.{segment}, opts)
pub fn printSegment(self: *View, segment: Cell.Segment, opts: Window.PrintOptions) Window.PrintResult {
    return self.print(&.{segment}, opts);
}
