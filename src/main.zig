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
pub const Winsize = @import("Tty.zig").Winsize;
pub const Window = @import("Window.zig");

pub const widgets = @import("widgets.zig");
pub const gwidth = @import("gwidth.zig");

/// Initialize a Vaxis application.
pub fn init(alloc: std.mem.Allocator, opts: Vaxis.Options) !Vaxis {
    return Vaxis.init(alloc, opts);
}

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(widgets);
    _ = @import("Parser.zig");
    _ = @import("Tty.zig");
}
