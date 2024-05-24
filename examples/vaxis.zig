const std = @import("std");
const vaxis = @import("vaxis");
const Cell = vaxis.Cell;

const Event = union(enum) {
    key_press: vaxis.Key,
    winsize: vaxis.Winsize,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const deinit_status = gpa.deinit();
        //fail test; can't try in defer as defer is executed after we return
        if (deinit_status == .leak) {
            std.log.err("memory leak", .{});
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

    const lower_limit = 30;
    var color_idx: u8 = lower_limit;
    var dir: enum {
        up,
        down,
    } = .up;

    // block until we get a resize
    while (true) {
        const event = loop.nextEvent();
        switch (event) {
            .key_press => |key| if (key.matches('c', .{ .ctrl = true })) return,
            .winsize => |ws| {
                try vx.resize(alloc, ws);
                break;
            },
        }
    }

    while (true) {
        while (loop.tryEvent()) |event| {
            switch (event) {
                .key_press => |key| if (key.matches('c', .{ .ctrl = true })) return,
                .winsize => |ws| try vx.resize(alloc, ws),
            }
        }

        const win = vx.window();
        win.clear();

        const style: vaxis.Style = .{ .fg = .{ .rgb = [_]u8{ color_idx, color_idx, color_idx } } };

        const segment: vaxis.Segment = .{
            .text = vaxis.logo,
            .style = style,
        };
        const center = vaxis.widgets.alignment.center(win, 28, 4);
        _ = try center.printSegment(segment, .{ .wrap = .grapheme });
        try vx.render();
        std.time.sleep(8 * std.time.ns_per_ms);
        switch (dir) {
            .up => {
                color_idx += 1;
                if (color_idx == 255) dir = .down;
            },
            .down => {
                color_idx -= 1;
                if (color_idx == lower_limit) dir = .up;
            },
        }
    }
}
