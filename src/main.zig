const std = @import("std");

pub const Vaxis = @import("vaxis.zig").Vaxis;
pub const Options = @import("Options.zig");

pub const Key = @import("Key.zig");
pub const Cell = @import("Cell.zig");
pub const Image = @import("Image.zig");
pub const Mouse = @import("Mouse.zig");
pub const Winsize = @import("Tty.zig").Winsize;

pub const widgets = @import("widgets.zig");

/// Initialize a Vaxis application.
pub fn init(comptime Event: type, opts: Options) !Vaxis(Event) {
    return Vaxis(Event).init(opts);
}

test {
    std.testing.refAllDecls(@This());
}
