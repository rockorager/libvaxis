pub const Vaxis = @import("vaxis.zig").Vaxis;
pub const Options = @import("Options.zig");

const cell = @import("cell.zig");
pub const Cell = cell.Cell;

pub const Key = @import("Key.zig");
pub const Winsize = @import("Tty.zig").Winsize;

/// Initialize a Vaxis application.
pub fn init(comptime EventType: type, opts: Options) !Vaxis(EventType) {
    return Vaxis(EventType).init(opts);
}

test {
    _ = @import("Key.zig");
    _ = @import("Options.zig");
    _ = @import("Screen.zig");
    _ = @import("Tty.zig");
    _ = @import("Window.zig");
    _ = @import("cell.zig");
    _ = @import("ctlseqs.zig");
    _ = @import("event.zig");
    _ = @import("queue.zig");
    _ = @import("parser.zig");
    _ = @import("vaxis.zig");
}
