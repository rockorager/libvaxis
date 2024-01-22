const std = @import("std");
const vaxis = @import("vaxis");
const Cell = vaxis.Cell;
const TextInput = vaxis.widgets.TextInput;
const border = vaxis.widgets.border;

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

    // Initialize Vaxis
    var vx = try vaxis.init(Event, .{});
    defer vx.deinit(alloc);

    // Start the read loop. This puts the terminal in raw mode and begins
    // reading user input
    try vx.start();
    defer vx.stop();

    // Optionally enter the alternate screen
    try vx.enterAltScreen();

    var text_input: TextInput = .{};

    // The main event loop. Vaxis provides a thread safe, blocking, buffered
    // queue which can serve as the primary event queue for an application
    outer: while (true) {
        // nextEvent blocks until an event is in the queue
        const event = vx.nextEvent();
        log.debug("event: {}\r\n", .{event});
        // exhaustive switching ftw. Vaxis will send events if your EventType
        // enum has the fields for those events (ie "key_press", "winsize")
        switch (event) {
            .key_press => |key| {
                text_input.update(.{ .key_press = key });
                if (key.codepoint == 'c' and key.mods.ctrl) {
                    break :outer;
                }
            },
            .winsize => |ws| {
                try vx.resize(alloc, ws);
            },
            else => {},
        }

        // vx.window() returns the root window. This window is the size of the
        // terminal and can spawn child windows as logical areas. Child windows
        // cannot draw outside of their bounds
        const win = vx.window();
        // Clear the entire space because we are drawing in immediate mode.
        // vaxis double buffers the screen. This new frame will be compared to
        // the old and only updated cells will be drawn
        win.clear();
        const child = win.initChild(win.width / 2 - 20, win.height / 2 - 3, .{ .limit = 40 }, .{ .limit = 3 });
        // draw the text_input using a bordered window
        text_input.draw(border.all(child, .{}));

        // Render the screen
        try vx.render();
    }
}

// Our EventType. This can contain internal events as well as Vaxis events.
// Internal events can be posted into the same queue as vaxis events to allow
// for a single event loop with exhaustive switching. Booya
const Event = union(enum) {
    key_press: vaxis.Key,
    winsize: vaxis.Winsize,
    focus_in,
    foo: u8,
};
