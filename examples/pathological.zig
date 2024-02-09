const std = @import("std");
const vaxis = @import("vaxis");
const Cell = vaxis.Cell;

const log = std.log.scoped(.main);

const Event = union(enum) {
    winsize: vaxis.Winsize,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const alloc = gpa.allocator();
    var vx = try vaxis.init(Event, .{});
    errdefer vx.deinit(alloc);

    try vx.startReadThread();
    defer vx.stopReadThread();
    try vx.enterAltScreen();
    try vx.queryTerminal();

    outer: while (true) {
        const event = vx.nextEvent();
        switch (event) {
            .winsize => |ws| {
                try vx.resize(alloc, ws);
                break :outer;
            },
        }
    }

    const timer_start = std.time.microTimestamp();
    var iter: usize = 0;
    while (iter < 10_000) : (iter += 1) {
        const win = vx.window();
        const child = win.initChild(0, 0, .{ .limit = 20 }, .{ .limit = 20 });
        win.clear();
        var row: usize = 0;
        while (row < child.height) : (row += 1) {
            var col: usize = 0;
            while (col < child.width) : (col += 1) {
                child.writeCell(col, row, .{
                    .char = .{
                        .grapheme = " ",
                        .width = 1,
                    },
                    .style = .{
                        .bg = .{ .index = @truncate(col + iter) },
                    },
                });
            }
        }
        try vx.render();
    }
    const took = std.time.microTimestamp() - timer_start;
    vx.deinit(alloc);
    log.info("took {d}ms", .{@divTrunc(took, std.time.us_per_ms)});
}
