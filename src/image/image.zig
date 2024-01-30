const std = @import("std");
const math = std.math;
const testing = std.testing;
const zigimg = @import("zigimg");

const Winsize = @import("../Tty.zig").Winsize;
const Window = @import("../Window.zig");

const Kitty = @import("Kitty.zig");

const log = std.log.scoped(.image);

pub const Image = union(enum) {
    kitty: Kitty,

    pub const Protocol = enum {
        kitty,
        // TODO: sixel, full block, half block, quad block
    };

    pub const CellSize = struct {
        rows: usize,
        cols: usize,
    };

    pub const Source = union(enum) {
        path: []const u8,
        mem: []const u8,
    };

    /// initialize a new image
    pub fn init(
        alloc: std.mem.Allocator,
        src: Source,
        id: u32,
        protocol: Protocol,
    ) !Image {
        const img = switch (src) {
            .path => |path| try zigimg.Image.fromFilePath(alloc, path),
            .mem => |bytes| try zigimg.Image.fromMemory(alloc, bytes),
        };

        switch (protocol) {
            .kitty => {
                return .{
                    .kitty = Kitty{
                        .alloc = alloc,
                        .img = img,
                        .id = id,
                    },
                };
            },
        }
    }

    pub fn deinit(self: Image) void {
        switch (self) {
            inline else => |*case| case.deinit(),
        }
    }

    pub fn draw(self: Image, win: Window) !void {
        switch (self) {
            .kitty => {
                const row: u16 = @truncate(win.y_off);
                const col: u16 = @truncate(win.x_off);
                // the placement id has the high 16 bits as the column and the low 16
                // bits as the row. This means we can only place this image one time at
                // the same location - which is completely sane
                const pid: u32 = col << 15 | row;
                try win.writeImage(self, pid);
            },
        }
    }

    pub fn transmit(self: Image, writer: anytype) !void {
        switch (self) {
            .kitty => |k| return k.transmit(writer),
        }
    }

    pub fn getId(self: Image) ?u32 {
        switch (self) {
            .kitty => |k| return k.id,
        }
    }

    pub fn cellSize(self: Image, winsize: Winsize) !CellSize {
        // cell geometry
        const pix_per_col = try math.divCeil(usize, winsize.x_pixel, winsize.cols);
        const pix_per_row = try math.divCeil(usize, winsize.y_pixel, winsize.rows);

        const cell_width = math.divCeil(usize, self.img.width, pix_per_col) catch 0;
        const cell_height = math.divCeil(usize, self.img.height, pix_per_row) catch 0;

        return CellSize{
            .rows = cell_height,
            .cols = cell_width,
        };
    }
};
