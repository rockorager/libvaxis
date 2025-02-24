# libvaxis

```
It begins with them, but ends with me. Their son, Vaxis
```

![vaxis demo gif](vaxis.gif)

Libvaxis _does not use terminfo_. Support for vt features is detected through
terminal queries.

Vaxis uses zig `0.13.0`.

## Features

libvaxis supports all major platforms: macOS, Windows, Linux/BSD/and other
Unix-likes.

- RGB
- [Hyperlinks](https://gist.github.com/egmontkob/eb114294efbcd5adb1944c9f3cb5feda) (OSC 8)
- Bracketed Paste
- [Kitty Keyboard Protocol](https://sw.kovidgoyal.net/kitty/keyboard-protocol/)
- [Fancy underlines](https://sw.kovidgoyal.net/kitty/underlines/) (undercurl, etc)
- Mouse Shapes (OSC 22)
- System Clipboard (OSC 52)
- System Notifications (OSC 9)
- System Notifications (OSC 777)
- Synchronized Output (Mode 2026)
- [Unicode Core](https://github.com/contour-terminal/terminal-unicode-core) (Mode 2027)
- Color Mode Updates (Mode 2031)
- [In-Band Resize Reports](https://gist.github.com/rockorager/e695fb2924d36b2bcf1fff4a3704bd83) (Mode 2048)
- Images ([kitty graphics protocol](https://sw.kovidgoyal.net/kitty/graphics-protocol/))
- [Explicit Width](https://github.com/kovidgoyal/kitty/blob/master/docs/text-sizing-protocol.rst) (width modifiers only)

## Usage

[Documentation](https://rockorager.github.io/libvaxis/#vaxis.Vaxis)

The library provides both a low level API suitable for making applications of
any sort as well as a higher level framework. The low level API is suitable for
making applications of any type, providing your own event loop, and gives you
full control over each cell on the screen.

The high level API, called `vxfw` (Vaxis framework), provides a Flutter-like
style of API. The framework provides an application runtime which handles the
event loop, focus management, mouse handling, and more. Several widgets are
provided, and custom widgets are easy to build. This API is most likely what you
want to use for typical TUI applications.

### vxfw (Vaxis framework)

Let's build a simple button counter application. This example can be run using
the command `zig build example -Dexample=counter`. The below application has
full mouse support: the button *and mouse shape* will change style on hover, on
click, and has enough logic to cancel a press if the release does not occur over
the button. Try it! Click the button, move the mouse off the button and release.
All of this logic is baked into the base `Button` widget.

```zig
const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

/// Our main application state
const Model = struct {
    /// State of the counter
    count: u32 = 0,
    /// The button. This widget is stateful and must live between frames
    button: vxfw.Button,

    /// Helper function to return a vxfw.Widget struct
    pub fn widget(self: *Model) vxfw.Widget {
        return .{
            .userdata = self,
            .eventHandler = Model.typeErasedEventHandler,
            .drawFn = Model.typeErasedDrawFn,
        };
    }

    /// This function will be called from the vxfw runtime.
    fn typeErasedEventHandler(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        const self: *Model = @ptrCast(@alignCast(ptr));
        switch (event) {
            // The root widget is always sent an init event as the first event. Users of the
            // library can also send this event to other widgets they create if they need to do
            // some initialization.
            .init => return ctx.requestFocus(self.button.widget()),
            .key_press => |key| {
                if (key.matches('c', .{ .ctrl = true })) {
                    ctx.quit = true;
                    return;
                }
            },
            // We can request a specific widget gets focus. In this case, we always want to focus
            // our button. Having focus means that key events will be sent up the widget tree to
            // the focused widget, and then bubble back down the tree to the root. Users can tell
            // the runtime the event was handled and the capture or bubble phase will stop
            .focus_in => return ctx.requestFocus(self.button.widget()),
            else => {},
        }
    }

    /// This function is called from the vxfw runtime. It will be called on a regular interval, and
    /// only when any event handler has marked the redraw flag in EventContext as true. By
    /// explicitly requiring setting the redraw flag, vxfw can prevent excessive redraws for events
    /// which don't change state (ie mouse motion, unhandled key events, etc)
    fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *Model = @ptrCast(@alignCast(ptr));
        // The DrawContext is inspired from Flutter. Each widget will receive a minimum and maximum
        // constraint. The minimum constraint will always be set, even if it is set to 0x0. The
        // maximum constraint can have null width and/or height - meaning there is no constraint in
        // that direction and the widget should take up as much space as it needs. By calling size()
        // on the max, we assert that it has some constrained size. This is *always* the case for
        // the root widget - the maximum size will always be the size of the terminal screen.
        const max_size = ctx.max.size();

        // The DrawContext also contains an arena allocator that can be used for each frame. The
        // lifetime of this allocation is until the next time we draw a frame. This is useful for
        // temporary allocations such as the one below: we have an integer we want to print as text.
        // We can safely allocate this with the ctx arena since we only need it for this frame.
        const count_text = try std.fmt.allocPrint(ctx.arena, "{d}", .{self.count});
        const text: vxfw.Text = .{ .text = count_text };

        // Each widget returns a Surface from it's draw function. A Surface contains the rectangular
        // area of the widget, as well as some information about the surface or widget: can we focus
        // it? does it handle the mouse?
        //
        // It DOES NOT contain the location it should be within it's parent. Only the parent can set
        // this via a SubSurface. Here, we will return a Surface for the root widget (Model), which
        // has two SubSurfaces: one for the text and one for the button. A SubSurface is a Surface
        // with an offset and a z-index - the offset can be negative. This lets a parent draw a
        // child and place it within itself
        const text_child: vxfw.SubSurface = .{
            .origin = .{ .row = 0, .col = 0 },
            .surface = try text.draw(ctx),
        };

        const button_child: vxfw.SubSurface = .{
            .origin = .{ .row = 2, .col = 0 },
            .surface = try self.button.draw(ctx.withConstraints(
                ctx.min,
                // Here we explicitly set a new maximum size constraint for the Button. A Button will
                // expand to fill it's area and must have some hard limit in the maximum constraint
                .{ .width = 16, .height = 3 },
            )),
        };

        // We also can use our arena to allocate the slice for our SubSurfaces. This slice only
        // needs to live until the next frame, making this safe.
        const children = try ctx.arena.alloc(vxfw.SubSurface, 2);
        children[0] = text_child;
        children[1] = button_child;

        return .{
            // A Surface must have a size. Our root widget is the size of the screen
            .size = max_size,
            .widget = self.widget(),
            // We didn't actually need to draw anything for the root. In this case, we can set
            // buffer to a zero length slice. If this slice is *not zero length*, the runtime will
            // assert that it's length is equal to the size.width * size.height.
            .buffer = &.{},
            .children = children,
        };
    }

    /// The onClick callback for our button. This is also called if we press enter while the button
    /// has focus
    fn onClick(maybe_ptr: ?*anyopaque, ctx: *vxfw.EventContext) anyerror!void {
        const ptr = maybe_ptr orelse return;
        const self: *Model = @ptrCast(@alignCast(ptr));
        self.count +|= 1;
        return ctx.consumeAndRedraw();
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();

    var app = try vxfw.App.init(allocator);
    defer app.deinit();

    // We heap allocate our model because we will require a stable pointer to it in our Button
    // widget
    const model = try allocator.create(Model);
    defer allocator.destroy(model);

    // Set the initial state of our button
    model.* = .{
        .count = 0,
        .button = .{
            .label = "Click me!",
            .onClick = Model.onClick,
            .userdata = model,
        },
    };

    try app.run(model.widget(), .{});
}
```

### Low level API

Vaxis requires three basic primitives to operate:

1. A TTY instance
2. An instance of Vaxis
3. An event loop

The library provides a general purpose posix TTY implementation, as well as a
multi-threaded event loop implementation. Users of the library are encouraged to
use the event loop of their choice. The event loop is responsible for reading
the TTY, passing the read bytes to the vaxis parser, and handling events.

A core feature of Vaxis is it's ability to detect features via terminal queries
instead of relying on a terminfo database. This requires that the event loop
also handle these query responses and update the Vaxis.caps struct accordingly.
See the `Loop` implementation to see how this is done if writing your own event
loop.

```zig
const std = @import("std");
const vaxis = @import("vaxis");
const Cell = vaxis.Cell;
const TextInput = vaxis.widgets.TextInput;
const border = vaxis.widgets.border;

// This can contain internal events as well as Vaxis events.
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
            std.log.err("memory leak", .{});
        }
    }
    const alloc = gpa.allocator();

    // Initialize a tty
    var tty = try vaxis.Tty.init();
    defer tty.deinit();

    // Initialize Vaxis
    var vx = try vaxis.init(alloc, .{});
    // deinit takes an optional allocator. If your program is exiting, you can
    // choose to pass a null allocator to save some exit time.
    defer vx.deinit(alloc, tty.anyWriter());


    // The event loop requires an intrusive init. We create an instance with
    // stable pointers to Vaxis and our TTY, then init the instance. Doing so
    // installs a signal handler for SIGWINCH on posix TTYs
    //
    // This event loop is thread safe. It reads the tty in a separate thread
    var loop: vaxis.Loop(Event) = .{
      .tty = &tty,
      .vaxis = &vx,
    };
    try loop.init();

    // Start the read loop. This puts the terminal in raw mode and begins
    // reading user input
    try loop.start();
    defer loop.stop();

    // Optionally enter the alternate screen
    try vx.enterAltScreen(tty.anyWriter());

    // We'll adjust the color index every keypress for the border
    var color_idx: u8 = 0;

    // init our text input widget. The text input widget needs an allocator to
    // store the contents of the input
    var text_input = TextInput.init(alloc, &vx.unicode);
    defer text_input.deinit();

    // Sends queries to terminal to detect certain features. This should always
    // be called after entering the alt screen, if you are using the alt screen
    try vx.queryTerminal(tty.anyWriter(), 1 * std.time.ns_per_s);

    while (true) {
        // nextEvent blocks until an event is in the queue
        const event = loop.nextEvent();
        // exhaustive switching ftw. Vaxis will send events if your Event enum
        // has the fields for those events (ie "key_press", "winsize")
        switch (event) {
            .key_press => |key| {
                color_idx = switch (color_idx) {
                    255 => 0,
                    else => color_idx + 1,
                };
                if (key.matches('c', .{ .ctrl = true })) {
                    break;
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
            // The allocations are because we keep a copy of each cell to
            // optimize renders. When resize is called, we allocated two slices:
            // one for the screen, and one for our buffered screen. Each cell in
            // the buffered screen contains an ArrayList(u8) to be able to store
            // the grapheme for that cell. Each cell is initialized with a size
            // of 1, which is sufficient for all of ASCII. Anything requiring
            // more than one byte will incur an allocation on the first render
            // after it is drawn. Thereafter, it will not allocate unless the
            // screen is resized
            .winsize => |ws| try vx.resize(alloc, tty.anyWriter(), ws),
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

        // Create a style
        const style: vaxis.Style = .{
            .fg = .{ .index = color_idx },
        };

        // Create a bordered child window
        const child = win.child(.{
            .x_off = win.width / 2 - 20,
            .y_off = win.height / 2 - 3,
            .width = 40 ,
            .height = 3 ,
            .border = .{
                .where = .all,
                .style = style,
            },
        });

        // Draw the text_input in the child window
        text_input.draw(child);

        // Render the screen. Using a buffered writer will offer much better
	// performance, but is not required
        try vx.render(tty.anyWriter());
    }
}
```

## Contributing

Contributions are welcome. Please submit a PR on Github or a patch on the
[mailing list](mailto:~rockorager/libvaxis@lists.sr.ht)

## Community

We use [Github Discussions](https://github.com/rockorager/libvaxis/discussions)
as the primary location for community support, showcasing what you are working
on, and discussing library features and usage.

We also have an IRC channel on libera.chat: join us in #vaxis.
