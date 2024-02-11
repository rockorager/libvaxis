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

    var vx = try vaxis.init(Event, .{});
    defer vx.deinit(alloc);

    try vx.startReadThread();
    defer vx.stopReadThread();

    try vx.enterAltScreen();

    try vx.queryTerminal();

    const imgs = [_]vaxis.Image{
        try vx.loadImage(alloc, .{ .path = "examples/zig.png" }),
        try vx.loadImage(alloc, .{ .path = "examples/vaxis.png" }),
    };
    defer vx.freeImage(imgs[0].id);
    defer vx.freeImage(imgs[1].id);

    var n: usize = 0;

    while (true) {
        const event = vx.nextEvent();
        switch (event) {
            .key_press => |key| {
                if (key.matches('c', .{ .ctrl = true })) {
                    return;
                } else if (key.matches('l', .{ .ctrl = true })) {
                    vx.queueRefresh();
                }
            },
            .winsize => |ws| try vx.resize(alloc, ws),
        }

        n = (n + 1) % imgs.len;
        const win = vx.window();
        win.clear();

        const img = imgs[n];
        const dims = try img.cellSize(win);
        const center = vaxis.widgets.alignment.center(win, dims.cols, dims.rows);
        const scale = false;
        const z_index = 0;
        img.draw(center, scale, z_index);

        try vx.render();
    }
}
