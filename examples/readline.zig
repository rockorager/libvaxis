const std = @import("std");
const vaxis = @import("vaxis");
const Cell = vaxis.Cell;
const TextInput = vaxis.widgets.TextInput;
const border = vaxis.widgets.border;

const log = std.log.scoped(.main);

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
            log.err("memory leak", .{});
        }
    }
    const alloc = gpa.allocator();

    var line: ?[]const u8 = null;
    defer {
        // do this in defer so that vaxis cleans up terminal state before we
        // print to stdout
        if (line) |_| {
            const stdout = std.io.getStdOut().writer();
            stdout.print("\n{s}\n", .{line.?}) catch {};
            alloc.free(line.?);
        }
    }
    var vx = try vaxis.init(alloc, .{});
    defer vx.deinit(alloc);

    var loop: vaxis.Loop(Event) = .{ .vaxis = &vx };
    try loop.run();
    defer loop.stop();

    var text_input = TextInput.init(alloc, &vx.unicode);
    defer text_input.deinit();

    try vx.queryTerminal();

    const prompt: vaxis.Segment = .{ .text = "$ " };

    while (true) {
        const event = loop.nextEvent();
        switch (event) {
            .key_press => |key| {
                if (key.matches('c', .{ .ctrl = true })) {
                    break;
                } else if (key.matches(vaxis.Key.enter, .{})) {
                    line = try text_input.toOwnedSlice();
                    text_input.clearAndFree();
                    break;
                } else {
                    try text_input.update(.{ .key_press = key });
                }
            },
            .winsize => |ws| try vx.resize(alloc, ws),
        }

        const win = vx.window();

        win.clear();
        _ = try win.printSegment(prompt, .{});

        const input_win = win.child(.{ .x_off = 2 });
        text_input.draw(input_win);
        try vx.render();
    }
}
