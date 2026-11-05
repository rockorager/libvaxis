const std = @import("std");
const vaxis = @import("vaxis");

const log = std.log.scoped(.main);

const Event = union(enum) {
    key_press: vaxis.Key,
    winsize: vaxis.Winsize,
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const alloc = init.gpa;

    var buffer: [1024]u8 = undefined;
    var tty = try vaxis.Tty.init(io, &buffer);
    defer tty.deinit();

    var vx = try vaxis.init(io, alloc, init.environ_map, .{});
    defer vx.deinit(alloc, tty.writer());

    var loop: vaxis.Loop(Event) = .init(io, &tty, &vx);
    try loop.start();
    defer loop.stop();

    try vx.enterAltScreen(tty.writer());
    try vx.queryTerminal(tty.writer(), .fromSeconds(1));

    // Pixels from anywhere, such as an image library or, here, a gradient.
    const w = 256;
    const h = 128;
    var gradient: [w * h * 4]u8 = undefined;
    for (0..h) |y| {
        for (0..w) |x| {
            const px = gradient[(y * w + x) * 4 ..][0..4];
            px.* = .{ @intCast(x), @intCast(y * 2), 255 - @as(u8, @intCast(x)), 255 };
        }
    }

    const imgs = [_]vaxis.Image{
        try vx.transmitImage(alloc, tty.writer(), &gradient, w, h, .rgba),
        try vx.loadImage(alloc, tty.writer(), .{ .path = "examples/vaxis.png" }),
    };
    defer vx.freeImage(tty.writer(), imgs[0].id);
    defer vx.freeImage(tty.writer(), imgs[1].id);

    var n: usize = 0;

    var clip_y: u16 = 0;

    while (true) {
        const event = try loop.nextEvent();
        switch (event) {
            .key_press => |key| {
                if (key.matches('c', .{ .ctrl = true })) {
                    return;
                } else if (key.matches('l', .{ .ctrl = true })) {
                    vx.queueRefresh();
                } else if (key.matches('j', .{}))
                    clip_y += 1
                else if (key.matches('k', .{}))
                    clip_y -|= 1;
            },
            .winsize => |ws| try vx.resize(alloc, tty.writer(), ws),
        }

        n = (n + 1) % imgs.len;
        const win = vx.window();
        win.clear();

        const img = imgs[n];
        const dims = try img.cellSize(win);
        const center = vaxis.widgets.alignment.center(win, dims.cols, dims.rows);
        try img.draw(center, .{ .scale = .contain, .clip_region = .{
            .y = clip_y,
        } });

        try vx.render(tty.writer());
    }
}

// test {
//     std.testing.refAllDecls(@This());
// }
