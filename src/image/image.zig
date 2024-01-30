const std = @import("std");
const math = std.math;
const testing = std.testing;
const zigimg = @import("zigimg");

const Winsize = @import("../Tty.zig").Winsize;
const Window = @import("../Window.zig");

const Kitty = @import("Kitty.zig");

pub const Protocol = enum {
    kitty,
    // TODO: sixel, full block, half block, quad block
};

pub const Image = union(enum) {
    kitty: Kitty,

    /// initialize a new image
    pub fn init(
        alloc: std.mem.Allocator,
        winsize: Winsize,
        src: []const u8,
        protocol: Protocol,
    ) !Image {
        const img = switch (src) {
            .path => |path| try zigimg.Image.fromFilePath(alloc, path),
            .mem => |bytes| try zigimg.Image.fromMemory(alloc, bytes),
        };
        // cell geometry
        const pix_per_col = try math.divCeil(usize, winsize.x_pixel, winsize.cols);
        const pix_per_row = try math.divCeil(usize, winsize.y_pixel, winsize.rows);

        const cell_width = math.divCeil(usize, img.width, pix_per_col) catch 0;
        const cell_height = math.divCeil(usize, img.height, pix_per_row) catch 0;

        switch (protocol) {
            .kitty => {
                return .{
                    .kitty = Kitty{
                        .img = img,
                        .cell_width = cell_width,
                        .cell_height = cell_height,
                    },
                };
            },
        }
    }

    pub fn deinit(self: Image) void {
        switch (self) {
            inline else => |case| case.deinit(),
        }
    }

    pub fn draw(self: Image, win: Window) !void {
        switch (self) {
            inline else => |case| case.draw(win),
        }
    }

    pub fn getId(self: Image) ?u32 {
        switch (self) {
            .kitty => |k| return k.id,
        }
    }
};
