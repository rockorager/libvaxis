const std = @import("std");
const math = std.math;
const testing = std.testing;
const zigimg = @import("zigimg");

const Winsize = @import("../Tty.zig").Winsize;
const Window = @import("../Window.zig");

const Kitty = @import("Kitty.zig");

pub const Image = union(enum) {
    kitty: Kitty,

    pub const Protocol = enum {
        kitty,
        // TODO: sixel, full block, half block, quad block
    };

    /// initialize a new image
    pub fn init(
        alloc: std.mem.Allocator,
        winsize: Winsize,
        src: []const u8,
        id: u32,
        protocol: Protocol,
    ) !Image {
        switch (protocol) {
            .kitty => {
                const img = try Kitty.init(alloc, winsize, src, id);
                return .{ .kitty = img };
            },
        }
    }

    pub fn deinit(self: *Image) void {
        self.img.deinit();
    }

    pub fn draw(self: *Image, win: Window, placement_id: u32) !void {
        try win.writeImage(win.x_off, win.y_off, self, placement_id);
    }
};
