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

    // Initialize Vaxis
    var vx = try vaxis.init(Event, .{});
    defer vx.deinit(alloc);

    // Start the read loop. This puts the terminal in raw mode and begins
    // reading user input
    try vx.start();
    defer vx.stop();

    // Optionally enter the alternate screen
    try vx.enterAltScreen();

    // We'll adjust the color index every keypress
    var color_idx: u8 = 0;
    const msg = "Hello, world!";

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
                color_idx = switch (color_idx) {
                    255 => 0,
                    else => color_idx + 1,
                };
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

        // Create some child window. .expand means the height and width will
        // fill the remaining space of the parent. Child windows do not store a
        // reference to their parent: this is true immediate mode. Do not store
        // windows, always create new windows each render cycle
        const child = win.initChild(win.width / 2 - msg.len / 2, win.height / 2, .expand, .expand);
        // Loop through the message and print the cells to the screen
        for (msg, 0..) |_, i| {
            const cell: Cell = .{
                // each cell takes a _grapheme_ as opposed to a single
                // codepoint. This allows Vaxis to handle emoji properly,
                // particularly with terminals that the Unicode Core extension
                // (IE Mode 2027)
                .char = .{ .grapheme = msg[i .. i + 1] },
                .style = .{
                    .fg = .{ .index = color_idx },
                },
            };
            child.writeCell(i, 0, cell);
        }
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
    foo: u8,
};
