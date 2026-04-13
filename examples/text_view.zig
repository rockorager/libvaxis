const std = @import("std");
const log = std.log.scoped(.main);
const vaxis = @import("vaxis");

const TextView = vaxis.widgets.TextView;

const Event = union(enum) {
    key_press: vaxis.Key,
    winsize: vaxis.Winsize,
};

pub const std_options: std.Options = .{
    .log_scope_levels = &[_]std.log.ScopeLevel{
        .{ .scope = .vaxis, .level = .err },
    },
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
    var buffer: [1024]u8 = undefined;
    var tty = try vaxis.Tty.init(&buffer);
    defer tty.deinit();
    var vx = try vaxis.init(alloc, .{});
    defer vx.deinit(alloc, tty.writer());
    var loop: vaxis.Loop(Event) = .{
        .vaxis = &vx,
        .tty = &tty,
    };
    try loop.init();
    try loop.start();
    defer loop.stop();
    try vx.enterAltScreen(tty.writer());
    try vx.queryTerminal(tty.writer(), 20 * std.time.ns_per_s);
    var text_view = TextView{};
    var text_view_buffer = TextView.Buffer{};
    defer text_view_buffer.deinit(alloc);
    try text_view_buffer.append(alloc, .{ .bytes = "Press Enter to add a line, Up/Down to scroll, 'c' to close." });

    var counter: i32 = 0;
    var lineBuf: [128]u8 = undefined;

    while (true) {
        const event = loop.nextEvent();
        switch (event) {
            .key_press => |key| {
                // Close demo
                if (key.matches('c', .{}) or key.matches('c', .{ .ctrl = true })) break;
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
