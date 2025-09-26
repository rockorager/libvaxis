const std = @import("std");
const vaxis = @import("vaxis");

const log = std.log.scoped(.main);

const Event = union(enum) {
    key_press: vaxis.Key,
    winsize: vaxis.Winsize,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const deinit_status = gpa.deinit();
        if (deinit_status == .leak) {
            log.err("memory leak", .{});
        }
    }
    const alloc = gpa.allocator();

    var buffer: [1024]u8 = undefined;
    var tty = try vaxis.Tty.init(&buffer);
    defer tty.deinit();

    var vx = try vaxis.init(alloc, .{});
    defer vx.deinit(alloc, tty.writer());

    var loop: vaxis.Loop(Event) = .{ .tty = &tty, .vaxis = &vx };
    try loop.init();

    try loop.start();
    defer loop.stop();

    try vx.enterAltScreen(tty.writer());
    try vx.queryTerminal(tty.writer(), 1 * std.time.ns_per_s);

    var read_buffer: [1024 * 1024]u8 = undefined; // 1MB buffer
    var img1 = try vaxis.zigimg.Image.fromFilePath(alloc, "examples/zig.png", &read_buffer);
    defer img1.deinit();

    const imgs = [_]vaxis.Image{
        try vx.transmitImage(alloc, tty.writer(), &img1, .rgba),
        // var img1 = try vaxis.zigimg.Image.fromFilePath(alloc, "examples/zig.png");
        // try vx.loadImage(alloc, tty.writer(), .{ .path = "examples/zig.png" }),
        try vx.loadImage(alloc, tty.writer(), .{ .path = "examples/vaxis.png" }),
    };
    defer vx.freeImage(tty.writer(), imgs[0].id);
    defer vx.freeImage(tty.writer(), imgs[1].id);

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
