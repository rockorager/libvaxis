const std = @import("std");

pub const Vaxis = @import("vaxis.zig").Vaxis;
pub const Options = @import("Options.zig");

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

pub const ziglyph = @import("ziglyph");
pub const widgets = @import("widgets.zig");
pub const gwidth = @import("gwidth.zig");

/// Initialize a Vaxis application.
pub fn init(comptime Event: type, opts: Options) !Vaxis(Event) {
    return Vaxis(Event).init(opts);
}

test {
    std.testing.refAllDecls(@This());
}
