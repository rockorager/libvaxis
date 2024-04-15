const std = @import("std");
const vaxis = @import("vaxis");
const Cell = vaxis.Cell;

// Our Event. This can contain internal events as well as Vaxis events.
// Internal events can be posted into the same queue as vaxis events to allow
// for a single event loop with exhaustive switching. Booya
const Event = union(enum) {
    key_press: vaxis.Key,
    winsize: vaxis.Winsize,
    focus_in,
    nvim: vaxis.widgets.nvim.Event,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const deinit_status = gpa.deinit();
        //fail test; can't try in defer as defer is executed after we return
        if (deinit_status == .leak) {
            std.log.err("memory leak", .{});
        }
    }
    const alloc = gpa.allocator();

    // Initialize Vaxis
    var vx = try vaxis.init(Event, .{});
    defer vx.deinit(alloc);

    // Start the read loop. This puts the terminal in raw mode and begins
    // reading user input
    try vx.startReadThread();
    defer vx.stopReadThread();

    // Optionally enter the alternate screen
    try vx.enterAltScreen();

    var nvim = try vaxis.widgets.nvim.Nvim(Event).init(alloc, &vx);
    try nvim.spawn();
    defer nvim.deinit();

    // The main event loop. Vaxis provides a thread safe, blocking, buffered
    // queue which can serve as the primary event queue for an application
    while (true) {
        // nextEvent blocks until an event is in the queue
        const event = vx.nextEvent();
        std.log.debug("event: {}", .{event});
        // exhaustive switching ftw. Vaxis will send events if your Event
        // enum has the fields for those events (ie "key_press", "winsize")
        switch (event) {
            .key_press => |key| {
                try nvim.update(.{ .key_press = key });
            },
            .winsize => |ws| {
                try vx.resize(alloc, ws);
            },
            .nvim => |nvim_event| {
                switch (nvim_event) {
                    .redraw => {},
                    .quit => return,
                }
            },
            else => {},
        }

        const win = vx.window();
        win.clear();
        const child = win.child(
            .{
                .height = .{ .limit = 40 },
                .width = .{ .limit = 80 },
                .border = .{ .where = .all },
            },
        );
        try nvim.draw(child);
        try vx.render();
    }
}
