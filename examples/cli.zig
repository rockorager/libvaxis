const std = @import("std");
const vaxis = @import("vaxis");
const Cell = vaxis.Cell;
const TextInput = vaxis.widgets.TextInput;

const log = std.log.scoped(.main);
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const deinit_status = gpa.deinit();
        if (deinit_status == .leak) {
            log.err("memory leak", .{});
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

    try vx.queryTerminal(tty.anyWriter(), 1 * std.time.ns_per_s);

    var text_input = TextInput.init(alloc, &vx.unicode);
    defer text_input.deinit();

    var selected_option: ?usize = null;

    const options = [_][]const u8{
        "option 1",
        "option 2",
        "option 3",
    };

    // The main event loop. Vaxis provides a thread safe, blocking, buffered
    // queue which can serve as the primary event queue for an application
    while (true) {
        // nextEvent blocks until an event is in the queue
        const event = loop.nextEvent();
        // exhaustive switching ftw. Vaxis will send events if your Event
        // enum has the fields for those events (ie "key_press", "winsize")
        switch (event) {
            .key_press => |key| {
                if (key.codepoint == 'c' and key.mods.ctrl) {
                    break;
                } else if (key.matches(vaxis.Key.tab, .{})) {
                    if (selected_option == null) {
                        selected_option = 0;
                    } else {
                        selected_option.? = @min(options.len - 1, selected_option.? + 1);
                    }
                } else if (key.matches(vaxis.Key.tab, .{ .shift = true })) {
                    if (selected_option == null) {
                        selected_option = 0;
                    } else {
                        selected_option.? = selected_option.? -| 1;
                    }
                } else if (key.matches(vaxis.Key.enter, .{})) {
                    if (selected_option) |i| {
                        log.err("enter", .{});
                        try text_input.insertSliceAtCursor(options[i]);
                        selected_option = null;
                    }
                } else {
                    if (selected_option == null)
                        try text_input.update(.{ .key_press = key });
                }
            },
            .winsize => |ws| {
                try vx.resize(alloc, tty.anyWriter(), ws);
            },
            else => {},
        }

        const win = vx.window();
        win.clear();

        text_input.draw(win);

        if (selected_option) |i| {
            win.hideCursor();
            for (options, 0..) |opt, j| {
                log.err("i = {d}, j = {d}, opt = {s}", .{ i, j, opt });
                var seg = [_]vaxis.Segment{.{
                    .text = opt,
                    .style = if (j == i) .{ .reverse = true } else .{},
                }};
                _ = try win.print(&seg, .{ .row_offset = j + 1 });
            }
        }
        try vx.render(tty.anyWriter());
    }
}

// Our Event. This can contain internal events as well as Vaxis events.
// Internal events can be posted into the same queue as vaxis events to allow
// for a single event loop with exhaustive switching. Booya
const Event = union(enum) {
    key_press: vaxis.Key,
    winsize: vaxis.Winsize,
    focus_in,
    foo: u8,
};
