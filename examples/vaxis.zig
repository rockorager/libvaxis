const std = @import("std");
const vaxis = @import("vaxis");
const Cell = vaxis.Cell;

const Event = union(enum) {
    key_press: vaxis.Key,
    winsize: vaxis.Winsize,
};

pub const panic = vaxis.panic_handler;

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

    var tty = try vaxis.Tty.init();
    defer tty.deinit();

    var vx = try vaxis.init(alloc, .{});
    defer vx.deinit(alloc, tty.anyWriter());

    var loop: vaxis.Loop(Event) = .{ .tty = &tty, .vaxis = &vx };
    try loop.init();

    try loop.start();
    defer loop.stop();

    try vx.enterAltScreen(tty.anyWriter());
    try vx.queryTerminal(tty.anyWriter(), 1 * std.time.ns_per_s);

    try vx.queryColor(tty.anyWriter(), .fg);
    try vx.queryColor(tty.anyWriter(), .bg);
    var pct: u8 = 0;
    var dir: enum {
        up,
        down,
    } = .up;

    const fg = [_]u8{ 192, 202, 245 };
    const bg = [_]u8{ 26, 27, 38 };

    // block until we get a resize
    while (true) {
        const event = loop.nextEvent();
        switch (event) {
            .key_press => |key| if (key.matches('c', .{ .ctrl = true })) return,
            .winsize => |ws| {
                try vx.resize(alloc, tty.anyWriter(), ws);
                break;
            },
        }
    }

    while (true) {
        while (loop.tryEvent()) |event| {
            switch (event) {
                .key_press => |key| if (key.matches('c', .{ .ctrl = true })) return,
                .winsize => |ws| try vx.resize(alloc, tty.anyWriter(), ws),
            }
        }

        const win = vx.window();
        win.clear();

        const color = try blendColors(bg, fg, pct);

        const style: vaxis.Style = .{ .fg = color };

        const segment: vaxis.Segment = .{
            .text = vaxis.logo,
            .style = style,
        };
        const center = vaxis.widgets.alignment.center(win, 28, 4);
        _ = try center.printSegment(segment, .{ .wrap = .grapheme });
        try vx.render(tty.anyWriter());
        std.time.sleep(16 * std.time.ns_per_ms);
        switch (dir) {
            .up => {
                pct += 1;
                if (pct == 100) dir = .down;
            },
            .down => {
                pct -= 1;
                if (pct == 0) dir = .up;
            },
        }
    }
}

/// blend two rgb colors. pct is an integer percentage for te portion of 'b' in
/// 'a'
fn blendColors(a: [3]u8, b: [3]u8, pct: u8) !vaxis.Color {
    // const r_a = (a[0] * (100 -| pct)) / 100;

    const r_a = (@as(u16, a[0]) * @as(u16, (100 -| pct))) / 100;
    const r_b = (@as(u16, b[0]) * @as(u16, pct)) / 100;

    const g_a = (@as(u16, a[1]) * @as(u16, (100 -| pct))) / 100;
    const g_b = (@as(u16, b[1]) * @as(u16, pct)) / 100;
    // const g_a = try std.math.mul(u8, a[1], (100 -| pct) / 100);
    // const g_b = (b[1] * pct) / 100;

    const b_a = (@as(u16, a[2]) * @as(u16, (100 -| pct))) / 100;
    const b_b = (@as(u16, b[2]) * @as(u16, pct)) / 100;
    // const b_a = try std.math.mul(u8, a[2], (100 -| pct) / 100);
    // const b_b = (b[2] * pct) / 100;
    return .{ .rgb = [_]u8{
        @min(r_a + r_b, 255),
        @min(g_a + g_b, 255),
        @min(b_a + b_b, 255),
    } };
}
