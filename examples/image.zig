const std = @import("std");
const vaxis = @import("vaxis");

const log = std.log.scoped(.main);

// Our EventType. This can contain internal events as well as Vaxis events.
// Internal events can be posted into the same queue as vaxis events to allow
// for a single event loop with exhaustive switching. Booya
const Event = union(enum) {
    key_press: vaxis.Key,
    winsize: vaxis.Winsize,
    focus_in,
    focus_out,
    foo: u8,
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

    // Initialize Vaxis with our event type
    var vx = try vaxis.init(Event, .{});
    // deinit takes an optional allocator. If your program is exiting, you can
    // choose to pass a null allocator to save some exit time.
    defer vx.deinit(alloc);

    // Start the read loop. This puts the terminal in raw mode and begins
    // reading user input
    try vx.startReadThread();
    defer vx.stopReadThread();

    // Optionally enter the alternate screen
    try vx.enterAltScreen();

    // Sends queries to terminal to detect certain features. This should
    // _always_ be called, but is left to the application to decide when
    try vx.queryTerminal();

    const img = try vx.loadImage(alloc, .{ .path = "vaxis.png" });

    var n: usize = 0;

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
                n += 1;
                if (key.matches('c', .{ .ctrl = true })) {
                    break :outer;
                } else if (key.matches('l', .{ .ctrl = true })) {
                    vx.queueRefresh();
                } else if (key.matches('n', .{ .ctrl = true })) {
                    try vx.notify("vaxis", "hello from vaxis");
                } else {}
            },

            .winsize => |ws| try vx.resize(alloc, ws),
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

        const child = win.initChild(n, n, .expand, .expand);

        img.draw(child, false, 0);

        // Render the screen
        try vx.render();
    }
}
