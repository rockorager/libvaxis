const std = @import("std");
const log = std.log.scoped(.main);
const vaxis = @import("vaxis");

const TextView = vaxis.widgets.TextView;

const Event = union(enum) {
    key_press: vaxis.Key,
    winsize: vaxis.Winsize,
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const alloc = init.gpa;

    var buffer: [1024]u8 = undefined;
    var tty: vaxis.Tty = try .init(io, &buffer);
    defer tty.deinit();

    var vx = try vaxis.init(io, alloc, init.environ_map, .{});
    defer vx.deinit(alloc, tty.writer());

    var loop: vaxis.Loop(Event) = .init(io, &tty, &vx);
    try loop.start();
    defer loop.stop();

    try vx.enterAltScreen(tty.writer());
    try vx.queryTerminal(tty.writer(), .fromSeconds(20));

    var text_view = TextView{};
    var text_view_buffer = TextView.Buffer{};
    defer text_view_buffer.deinit(alloc);
    try text_view_buffer.append(alloc, .{ .bytes = "Press Enter to add a line, Up/Down to scroll, 'c' to close." });

    var counter: i32 = 0;
    var lineBuf: [128]u8 = undefined;

    while (true) {
        const event = try loop.nextEvent();
        switch (event) {
            .key_press => |key| {
                // Close demo
                if (key.matches('c', .{})) break;
                if (key.matches(vaxis.Key.enter, .{})) {
                    counter += 1;
                    const new_content = try std.fmt.bufPrint(&lineBuf, "\nLine {d}", .{counter});
                    try text_view_buffer.append(alloc, .{ .bytes = new_content });
                }
                text_view.input(key);
            },
            .winsize => |ws| try vx.resize(alloc, tty.writer(), ws),
        }
        const win = vx.window();
        win.clear();
        text_view.draw(win, text_view_buffer);
        try vx.render(tty.writer());
        try tty.writer().flush();
    }
}
