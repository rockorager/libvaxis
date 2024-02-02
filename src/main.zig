pub const Vaxis = @import("vaxis.zig").Vaxis;
pub const Options = @import("Options.zig");

const cell = @import("cell.zig");
pub const Cell = cell.Cell;
pub const Style = cell.Style;
pub const Segment = cell.Segment;
pub const Color = cell.Color;

pub const Key = @import("Key.zig");
pub const Mouse = @import("Mouse.zig");
pub const Winsize = @import("Tty.zig").Winsize;

pub const widgets = @import("widgets/main.zig");
pub const alignment = widgets.alignment;
pub const border = widgets.border;

pub const Image = @import("Image.zig");

/// Initialize a Vaxis application.
pub fn init(comptime EventType: type, opts: Options) !Vaxis(EventType) {
    return Vaxis(EventType).init(opts);
}

test {
    _ = @import("GraphemeCache.zig");
    _ = @import("Key.zig");
    _ = @import("Mouse.zig");
    _ = @import("Options.zig");
    _ = @import("Parser.zig");
    _ = @import("Screen.zig");
    _ = @import("Tty.zig");
    _ = @import("Window.zig");
    _ = @import("cell.zig");
    _ = @import("ctlseqs.zig");
    _ = @import("event.zig");
    _ = @import("gwidth.zig");
    _ = @import("queue.zig");
    _ = @import("vaxis.zig");
}
