const std = @import("std");
const odditui = @import("odditui");

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

    var app: odditui.App(Event) = try odditui.App(Event).init(.{});
    defer app.deinit(alloc);

    try app.start();
    defer app.stop();

    outer: while (true) {
        const event = app.nextEvent();
        log.debug("event: {}\r\n", .{event});
        switch (event) {
            .key_press => |key| {
                if (key.codepoint == 'c' and key.mods.ctrl) {
                    break :outer;
                }
            },
            .winsize => |ws| {
                try app.resize(alloc, ws.rows, ws.cols);
            },
            else => {},
        }
    }
}

const Event = union(enum) {
    key_press: odditui.Key,
    winsize: odditui.Winsize,
    mouse: u8,
};
