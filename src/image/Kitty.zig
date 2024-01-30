const std = @import("std");
const fmt = std.fmt;
const math = std.math;
const testing = std.testing;
const base64 = std.base64.standard.Encoder;
const zigimg = @import("zigimg");

const Window = @import("../Window.zig");
const Winsize = @import("../Tty.zig").Winsize;

const log = std.log.scoped(.kitty);

const Kitty = @This();

const max_chunk: usize = 4096;

const transmit_opener = "\x1b_Gf=32,i={d},s={d},v={d},m={d};";

alloc: std.mem.Allocator,

/// the decoded image
img: zigimg.Image,

/// unique identifier for this image. This will be managed by the screen. The ID
/// is only null for images which have not been transmitted to the screen
id: u32,

pub fn deinit(self: *const Kitty) void {
    var img = self.img;
    img.deinit();
}

/// transmit encodes and transmits the image to the terminal
pub fn transmit(self: Kitty, writer: anytype) !void {
    var alloc = self.alloc;
    const png_buf = try alloc.alloc(u8, self.img.imageByteSize());
    defer alloc.free(png_buf);
    const png = try self.img.writeToMemory(png_buf, .{ .png = .{} });
    const b64_buf = try alloc.alloc(u8, base64.calcSize(png.len));
    const encoded = base64.encode(b64_buf, png);
    defer alloc.free(b64_buf);

    log.debug("transmitting kitty image: id={d}, len={d}", .{ self.id, encoded.len });

    if (encoded.len < max_chunk) {
        try fmt.format(
            writer,
            "\x1b_Gf=100,i={d};{s}\x1b\\",
            .{
                self.id,
                encoded,
            },
        );
    } else {
        var n: usize = max_chunk;

        try fmt.format(
            writer,
            "\x1b_Gf=100,i={d},m=1;{s}\x1b\\",
            .{ self.id, encoded[0..n] },
        );
        while (n < encoded.len) : (n += max_chunk) {
            const end: usize = @min(n + max_chunk, encoded.len);
            const m: u2 = if (end == encoded.len) 0 else 1;
            try fmt.format(
                writer,
                "\x1b_Gm={d};{s}\x1b\\",
                .{
                    m,
                    encoded[n..end],
                },
            );
        }
    }
}
