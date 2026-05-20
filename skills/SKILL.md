---
name: vaxis
description: libvaxis is a TUI framework for Zig supporting RGB, hyperlinks, mouse, images, and cross-platform terminals. Use when building TUI applications in Zig.
---

# Vaxis TUI Framework Skill

## When to Use

Use this skill when:
- Building TUI (Terminal User Interface) applications in Zig
- Questions about vaxis architecture, widgets, events, or rendering
- Working with the vxfw (Vaxis Framework) high-level API
- Implementing custom widgets or handling terminal events
- Working with terminal capabilities detection

## Overview

libvaxis is a cross-platform TUI framework for Zig (v0.16.0). It supports:
- RGB/true color, hyperlinks (OSC 8)
- Bracketed paste, Kitty Keyboard Protocol
- Fancy underlines, mouse shapes, system clipboard (OSC 52)
- System notifications, synchronized output (Mode 2026)
- Unicode width handling, in-band resize reports (Mode 2048)
- Images via Kitty graphics protocol
- Does NOT use terminfo - capability detection via terminal queries

## Architecture

### Two API Levels

1. **Low-level API**: Direct screen manipulation via `Window`, `Screen`, `Cell`
2. **High-level API (vxfw)**: Flutter-like widget framework with event handling

### Core Types

#### Vaxis (src/Vaxis.zig)
Main entry point. Initialize with `vaxis.init()`.
```zig
const vaxis = @import("vaxis");
var vx = try vaxis.init(io, allocator, env_map, .{});
```
Handles terminal capabilities, screen rendering, and state management.

#### Window (src/Window.zig)
Represents a rectangular area for drawing. Get from Vaxis:
```zig
const win = vx.window(); // full terminal screen
const child = win.child(.{ .x_off = 1, .y_off = 1, .width = 20, .height = 10 });
```
Methods: `writeCell`, `fill`, `clear`, `print`, `gwidth`, `showCursor`, `hideCursor`

#### Cell (src/Cell.zig)
Represents a terminal cell with character, style, and optional hyperlink/image:
```zig
Cell{ .char = .{ .grapheme = "A", .width = 1 }, .style = .{ .fg = .{ .rgb = .{255,0,0} } } }
```

#### Style (Cell.Style)
```zig
vaxis.Style{
    .fg = .{ .rgb = .{255, 0, 0} },  // or .index = 4, or .default
    .bg = .{ .index = 0 },
    .bold = true,
    .italic = true,
    .reverse = true,
    .ul_style = .double,
}
```

#### Key (src/Key.zig)
Key events with codepoint, modifiers, and text:
```zig
const Key = vaxis.Key;
key.matches('q', .{})  // match letter 'q' with no modifiers
key.matches('c', .{ .ctrl = true })  // Ctrl+C
key.matches(Key.enter, .{})
```

#### Mouse (src/Mouse.zig)
```zig
Mouse{
    .col = 10,
    .row = 5,
    .button = .left,  // or .right, .middle, .wheel_up, .wheel_down
    .type = .press,  // or .release, .motion, .drag
    .mods = .{ .shift = true, .alt = false, .ctrl = false },
}
```

## Events (src/event.zig)

```zig
const Event = union(enum) {
    key_press: Key,
    key_release: Key,
    mouse: Mouse,
    focus_in,
    focus_out,
    paste_start,
    paste_end,
    paste: []const u8,
    color_report: Color.Report,
    color_scheme: Color.Scheme,
    winsize: Winsize,
};
```

## vxfw Framework (src/vxfw/)

### App (src/vxfw/App.zig)
Application entry point with built-in event loop:
```zig
var app: vxfw.App = try .init(io, allocator, init.environ_map, &buffer);
defer app.deinit();
try app.run(root_widget, .{ .framerate = 60 });
```

### Widget Interface (src/vxfw/vxfw.zig)

Custom widgets implement the `Widget` interface:
```zig
pub const Widget = struct {
    userdata: *anyopaque,
    eventHandler: ?*const fn (userdata: *anyopaque, ctx: *EventContext, event: Event) anyerror!void,
    drawFn: *const fn (userdata: *anyopaque, ctx: DrawContext) Allocator.Error!Surface,
};
```

Example widget implementation:
```zig
const Model = struct {
    count: u32 = 0,

    pub fn widget(self: *Model) vxfw.Widget {
        return .{
            .userdata = self,
            .eventHandler = Model.typeErasedEventHandler,
            .drawFn = Model.typeErasedDrawFn,
        };
    }

    fn typeErasedEventHandler(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        const self: *Model = @ptrCast(@alignCast(ptr));
        switch (event) {
            .init => ctx.requestFocus(...),
            .key_press => |key| if (key.matches('q', .{})) ctx.quit = true,
            else => {},
        }
    }

    fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *Model = @ptrCast(@alignCast(ptr));
        // Return Surface with children
    }
};
```

### EventContext (src/vxfw/vxfw.zig)
Context for widget event handlers:
```zig
ctx.quit = true;           // quit application
ctx.redraw = true;         // request redraw
ctx.consume_event = true;   // stop event propagation
ctx.requestFocus(widget);   // request focus
ctx.tick(ms, widget);      // schedule tick event
ctx.setMouseShape(.pointer); // change cursor
ctx.copyToClipboard(text);   // OSC 52
ctx.setTitle("My App");      // set window title
ctx.queueRefresh();          // full refresh
ctx.sendNotification("Hi", "Body"); // system notification
```

### DrawContext (src/vxfw/vxfw.zig)
Constraints passed to widget draw functions:
```zig
ctx.min   // minimum Size (always set, can be 0x0)
ctx.max   // MaxSize (null width/height = unconstrained)
ctx.arena // Arena allocator (lifetime = until next frame)
ctx.stringWidth(str)  // calculate display width
ctx.graphemeIterator(str)  // iterate graphemes
ctx.withConstraints(min, max) // create child context
```

### Surface (src/vxfw/vxfw.zig)
Returned from widget draw functions:
```zig
Surface{
    .size = .{ .width = 80, .height = 24 },
    .widget = self.widget(),
    .buffer = &.{},  // or allocated cells
    .children = &.{},  // child SubSurfaces
}
```

## Built-in vxfw Widgets

| Widget | Description |
|--------|-------------|
| `Border` | Draw borders around children |
| `Button` | Clickable button with hover/press states |
| `Center` | Center child widget |
| `FlexColumn` | Vertical flexbox layout |
| `FlexRow` | Horizontal flexbox layout |
| `ListView` | Scrollable list of widgets |
| `Padding` | Add padding around child |
| `RichText` | Styled text rendering |
| `ScrollView` | Scrollable container |
| `ScrollBars` | Scrollbar indicators |
| `SizedBox` | Fixed-size container |
| `SplitView` | Split view with adjustable panes |
| `Spinner` | Animated spinner |
| `Text` | Simple text display |
| `TextField` | Text input with cursor/editing |

## Specialized Widgets (src/widgets.zig)

| Widget | Description |
|--------|-------------|
| `TextInput` | Low-level text input (Window-based) |
| `TextView` | Scrollable text display |
| `Table` | Tabular data display |
| `ScrollView` | Scrollable viewport |
| `CodeView` | Syntax-highlighted code |
| `LineNumbers` | Line number gutter |
| `Terminal` | Embedded terminal emulator |
| `View` | General-purpose container |

## Key Patterns

### Creating Custom Widget
```zig
const MyWidget = struct {
    data: MyData,

    pub fn widget(self: *MyWidget) vxfw.Widget {
        return .{
            .userdata = self,
            .eventHandler = MyWidget.typeErasedEventHandler,
            .drawFn = MyWidget.typeErasedDrawFn,
        };
    }
};
```

### Focus Handling
```zig
// Request focus on init
fn typeErasedEventHandler(ptr, ctx, event) anyerror!void {
    switch (event) {
        .init => return ctx.requestFocus(self.widget()),
        .focus_in => return ctx.requestFocus(self.widget()),
        else => {},
    }
}
```

### Mouse Handling
```zig
switch (event) {
    .mouse => |mouse| {
        if (mouse.type == .press and mouse.button == .left) { ... }
        if (mouse.type == .motion) { ... }
    },
    .mouse_enter => { self.has_mouse = true; },
    .mouse_leave => { self.has_mouse = false; },
}
```

### Keyboard Handling
```zig
.key_press => |key| {
    if (key.matches('q', .{})) ctx.quit = true;
    if (key.matches(Key.enter, .{})) { ... }
    if (key.matches(Key.escape, .{})) { ... }
    if (key.matches(Key.left, .{ .shift = true })) { ... }
}
```

## Building with Zig

Add to build.zig:
```zig
const vaxis = b.dependency("vaxis", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("vaxis", vaxis.module("vaxis"));
```

Or fetch:
```console
zig fetch --save git+https://github.com/rockorager/libvaxis.git
```

## Examples

See `examples/` directory:
- `counter.zig` - Button with click counter
- `list_view.zig` - Scrollable list
- `text_input.zig` - Text field example
- `table.zig` - Table widget demo
- `split_view.zig` - Split pane demo
- `fuzzy.zig` - Fuzzy finder demo

Run with: `zig build example -Dexample=counter`

## Important Notes

- Widgets use type-erased interfaces (userdata + function pointers)
- Draw functions must be reentrant (can be called multiple times per frame)
- Event handlers receive `EventContext` for commands and state changes
- Use `ctx.arena` for per-frame allocations (freed after render)
- `Surface.buffer` must be `&.{}` or exactly `size.width * size.height` cells
- Children are positioned via `SubSurface` with origin and z-index
