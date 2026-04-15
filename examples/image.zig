const std = @import("std");
const vaxis = @import("vaxis");

const log = std.log.scoped(.main);

const Event = union(enum) {
    key_press: vaxis.Key,
    winsize: vaxis.Winsize,
};

pub fn main(init: std.process.Init) !void {
    std.log.warn("YYYYY", .{});
    const io = init.io;
    const alloc = init.gpa;

    var buffer: [1024]u8 = undefined;
    std.log.warn("ZZZZ", .{});
    var tty = try vaxis.Tty.init(io, &buffer);
    defer tty.deinit();
    std.log.warn("1111", .{});

    var vx = try vaxis.init(io, alloc, init.environ_map, .{});
    defer vx.deinit(alloc, tty.writer());
    std.log.warn("2222", .{});

    var loop: vaxis.Loop(Event) = .init(io, &tty, &vx);
    std.log.warn("AAAA", .{});
    try loop.start();
    defer loop.stop();

    std.log.warn("BBBB", .{});
    try vx.enterAltScreen(tty.writer());
    std.log.warn("CCCC", .{});
    try vx.queryTerminal(tty.writer(), .fromSeconds(1));

    std.log.warn("DDDD", .{});
    var read_buffer: [1024 * 1024]u8 = undefined; // 1MB buffer
    var img1 = try vaxis.zigimg.Image.fromFilePath(alloc, io, "examples/zig.png", &read_buffer);
    std.log.warn("EEEE", .{});
    defer img1.deinit(alloc);

    std.log.warn("FFFF", .{});
    const imgs = [_]vaxis.Image{
        try vx.transmitImage(alloc, tty.writer(), &img1, .rgba),
        // var img1 = try vaxis.zigimg.Image.fromFilePath(alloc, "examples/zig.png");
        // try vx.loadImage(alloc, tty.writer(), .{ .path = "examples/zig.png" }),
        try vx.loadImage(alloc, tty.writer(), .{ .path = "examples/vaxis.png" }),
    };
    std.log.warn("GGGG", .{});
    defer vx.freeImage(tty.writer(), imgs[0].id);
    std.log.warn("HHHH", .{});
    defer vx.freeImage(tty.writer(), imgs[1].id);
    std.log.warn("JJJJ", .{});

    var n: usize = 0;

    var clip_y: u16 = 0;

    while (true) {
        const event = loop.nextEvent();
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
