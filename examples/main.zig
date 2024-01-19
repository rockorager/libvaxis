const std = @import("std");
const odditui = @import("odditui");

const log = std.log.scoped(.main);
pub fn main() !void {
    var app: odditui.App(Event) = try odditui.App(Event).init(.{});
    defer app.deinit();

    try app.start();
    defer app.stop();

    outer: while (true) {
        const event = app.nextEvent();
        switch (event) {
            .key_press => |key| {
                if (key.codepoint == 'c' and key.mods.ctrl) {
                    break :outer;
                }
            },
            else => {},
        }
        log.debug("event: {}\r\n", .{event});
    }
}

const Event = union(enum) {
    key_press: odditui.Key,
    mouse: u8,
};
