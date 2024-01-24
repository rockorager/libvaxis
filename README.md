# libvaxis

```
It begins with them, but ends with me. Their son, Vaxis
```

libvaxis is a zig port of the go TUI library
[Vaxis](https://git.sr.ht/~rockorager/vaxis). The goal is to have the same
feature set, only written in zig.

Like it's sibling library, libvaxis _does not use terminfo_. Support for vt
features is detected through terminal queries.

Contributions are welcome.

## Feature comparison

| Feature                        | Vaxis | libvaxis | notcurses |
| ------------------------------ | :---: | :------: | :-------: |
| RGB                            |  ✅   |    ✅    |    ✅     |
| Hyperlinks                     |  ✅   | planned  |    ❌     |
| Bracketed Paste                |  ✅   |    ✅    |    ❌     |
| Kitty Keyboard                 |  ✅   |    ✅    |    ✅     |
| Styled Underlines              |  ✅   |    ✅    |    ✅     |
| Mouse Shapes (OSC 22)          |  ✅   | planned  |    ❌     |
| System Clipboard (OSC 52)      |  ✅   | planned  |    ❌     |
| System Notifications (OSC 9)   |  ✅   |    ✅    |    ❌     |
| System Notifications (OSC 777) |  ✅   |    ✅    |    ❌     |
| Synchronized Output (DEC 2026) |  ✅   |    ✅    |    ✅     |
| Unicode Core (DEC 2027)        |  ✅   |    ✅    |    ❌     |
| Color Mode Updates (DEC 2031)  |  ✅   | planned  |    ❌     |
| Images (full/space)            |  ✅   | planned  |    ✅     |
| Images (half block)            |  ✅   | planned  |    ✅     |
| Images (quadrant)              |  ✅   | planned  |    ✅     |
| Images (sextant)               |  ❌   |    ❌    |    ✅     |
| Images (sixel)                 |  ✅   | planned  |    ✅     |
| Images (kitty)                 |  ✅   | planned  |    ✅     |
| Images (iterm2)                |  ❌   |    ❌    |    ✅     |
| Video                          |  ❌   |    ❌    |    ✅     |
| Dank                           |  🆗   |    🆗    |    ✅     |

## Usage

The below example can be run using `zig build run 2>log`. stderr must be
redirected in order to not print to the same screen.

```zig
const std = @import("std");
const vaxis = @import("vaxis");
const Cell = vaxis.Cell;
const TextInput = vaxis.widgets.TextInput;
const border = vaxis.widgets.border;

const log = std.log.scoped(.main);

// Our EventType. This can contain internal events as well as Vaxis events.
// Internal events can be posted into the same queue as vaxis events to allow
// for a single event loop with exhaustive switching. Booya
const Event = union(enum) {
    key_press: vaxis.Key,
    winsize: vaxis.Winsize,
    focus_in,
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

    // We'll adjust the color index every keypress for the border
    var color_idx: u8 = 0;

    // init our text input widget. The text input widget needs an allocator to
    // store the contents of the input
    var text_input = TextInput.init(alloc);
    defer text_input.deinit();

    // Sends queries to terminal to detect certain features. This should
    // _always_ be called, but is left to the application to decide when
    try vx.queryTerminal();

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
                if (key.matches('c', .{ .ctrl = true })) {
                    break :outer;
                } else if (key.matches('l', .{ .ctrl = true })) {
                    vx.queueRefresh();
                } else {
                    try text_input.update(.{ .key_press = key });
                }
            },

            // winsize events are sent to the application to ensure that all
            // resizes occur in the main thread. This lets us avoid expensive
            // locks on the screen. All applications must handle this event
            // unless they aren't using a screen (IE only detecting features)
            //
            // This is the only call that the core of Vaxis needs an allocator
            // for. The allocations are because we keep a copy of each cell to
            // optimize renders. When resize is called, we allocated two slices:
            // one for the screen, and one for our buffered screen. Each cell in
            // the buffered screen contains an ArrayList(u8) to be able to store
            // the grapheme for that cell Each cell is initialized with a size
            // of 1, which is sufficient for all of ASCII. Anything requiring
            // more than one byte will incur an allocation on the first render
            // after it is drawn. Thereafter, it will not allocate unless the
            // screen is resized
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
        const child = win.initChild(
            win.width / 2 - 20,
            win.height / 2 - 3,
            .{ .limit = 40 },
            .{ .limit = 3 },
        );
        // draw the text_input using a bordered window
        const style: vaxis.Style = .{
            .fg = .{ .index = color_idx },
        };
        text_input.draw(border.all(child, style));

        // Render the screen
        try vx.render();
    }
}
```
