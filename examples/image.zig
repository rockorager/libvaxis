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

    var vx = try vaxis.init(alloc, .{});
    defer vx.deinit(alloc);

    var loop: vaxis.Loop(Event) = .{ .vaxis = &vx };

    try loop.run();
    defer loop.stop();

    try vx.enterAltScreen();

    try vx.queryTerminal();

    const imgs = [_]vaxis.Image{
        try vx.loadImage(alloc, .{ .path = "examples/zig.png" }),
        try vx.loadImage(alloc, .{ .path = "examples/vaxis.png" }),
    };
    defer vx.freeImage(imgs[0].id);
    defer vx.freeImage(imgs[1].id);

    var n: usize = 0;

    var clip_y: usize = 0;

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
            .winsize => |ws| try vx.resize(alloc, ws),
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

        try vx.render();
    }
}
