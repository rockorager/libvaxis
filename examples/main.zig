const std = @import("std");
const vaxis = @import("vaxis");
const Cell = vaxis.Cell;

const log = std.log.scoped(.main);
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const deinit_status = gpa.deinit();
        //fail test; can't try in defer as defer is executed after we return
        if (deinit_status == .leak) {
            log.err("memory leak", .{});
        }
    }
    const alloc = gpa.allocator();

    var vx = try vaxis.init(Event, .{});
    defer vx.deinit(alloc);

    try vx.start();
    defer vx.stop();

    try vx.enterAltScreen();

    var color_idx: u8 = 0;
    const msg = "Hello, world!";
    outer: while (true) {
        const event = vx.nextEvent();
        log.debug("event: {}\r\n", .{event});
        switch (event) {
            .key_press => |key| {
                if (color_idx == 255) {
                    color_idx = 0;
                } else {
                    color_idx += 1;
                }
                if (key.codepoint == 'c' and key.mods.ctrl) {
                    break :outer;
                }
            },
            .winsize => |ws| {
                try vx.resize(alloc, ws);
            },
            else => {},
        }

        const win = vx.window();
        win.clear();
        const child = win.initChild(win.width / 2 - msg.len / 2, win.height / 2, .expand, .expand);
        for (msg, 0..) |_, i| {
            const cell: Cell = .{
                .char = .{ .grapheme = msg[i .. i + 1] },
                .style = .{ .fg = .{ .index = color_idx } },
            };
            child.writeCell(i, 0, cell);
        }
        try vx.render();
    }
}

const Event = union(enum) {
    key_press: vaxis.Key,
    winsize: vaxis.Winsize,
    foo: u8,
};
