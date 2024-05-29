const std = @import("std");

pub const Vaxis = @import("Vaxis.zig");
pub const Loop = @import("Loop.zig").Loop;

pub const Queue = @import("queue.zig").Queue;
pub const Key = @import("Key.zig");
pub const Cell = @import("Cell.zig");
pub const Segment = Cell.Segment;
pub const PrintOptions = Window.PrintOptions;
pub const Style = Cell.Style;
pub const Color = Cell.Color;
pub const Image = @import("Image.zig");
pub const Mouse = @import("Mouse.zig");
pub const Screen = @import("Screen.zig");
pub const AllocatingScreen = @import("InternalScreen.zig");
pub const Parser = @import("Parser.zig");
pub const Window = @import("Window.zig");
pub const tty = @import("tty.zig");
pub const Tty = tty.Tty;
pub const Winsize = tty.Winsize;

pub const widgets = @import("widgets.zig");
pub const gwidth = @import("gwidth.zig");

/// Initialize a Vaxis application.
pub fn init(alloc: std.mem.Allocator, opts: Vaxis.Options) !Vaxis {
    return Vaxis.init(alloc, opts);
}

/// the vaxis logo. In PixelCode
pub const logo =
    \\▄   ▄  ▄▄▄  ▄   ▄ ▄▄▄  ▄▄▄
    \\█   █ █▄▄▄█ ▀▄ ▄▀  █  █   ▀
    \\▀▄ ▄▀ █   █  ▄▀▄   █   ▀▀▀▄
    \\ ▀▄▀  █   █ █   █ ▄█▄ ▀▄▄▄▀
;

test {
    _ = @import("gwidth.zig");
    _ = @import("Cell.zig");
    _ = @import("Key.zig");
    _ = @import("Parser.zig");
    _ = @import("Window.zig");

    _ = @import("gwidth.zig");
    _ = @import("queue.zig");
    _ = @import("widgets/TextInput.zig");
}
