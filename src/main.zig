const std = @import("std");
const Tty = @import("tty/Tty.zig");
const odditui = @import("odditui.zig");

const log = std.log.scoped(.main);
pub fn main() !void {
    var app: odditui.App(Event) = try odditui.App(Event).init(.{});

    try app.start();

    while (true) {
        const event = app.nextEvent();
        log.debug("event: {}", .{event});
    }

    app.stop();
}

const Event = union(enum) {
    key: u8,
    mouse: u8,
};

fn eventCallback(_: Event) void {}

test "simple test" {
    _ = @import("odditui.zig");
    _ = @import("queue.zig");
}
