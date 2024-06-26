const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");

pub const Vaxis = @import("Vaxis.zig");

pub const Loop = @import("Loop.zig").Loop;
pub const xev = @import("xev.zig");
pub const aio = @import("aio.zig");

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
pub const widgets = @import("widgets.zig");
pub const gwidth = @import("gwidth.zig");
pub const ctlseqs = @import("ctlseqs.zig");
pub const GraphemeCache = @import("GraphemeCache.zig");
pub const grapheme = @import("grapheme");
pub const Event = @import("event.zig").Event;
pub const Unicode = @import("Unicode.zig");

/// The target TTY implementation
pub const Tty = switch (builtin.os.tag) {
    .windows => @import("windows/Tty.zig"),
    else => @import("posix/Tty.zig"),
};

/// The size of the terminal screen
pub const Winsize = struct {
    rows: usize,
    cols: usize,
    x_pixel: usize,
    y_pixel: usize,
};

/// Initialize a Vaxis application.
pub fn init(alloc: std.mem.Allocator, opts: Vaxis.Options) !Vaxis {
    return Vaxis.init(alloc, opts);
}

/// Resets terminal state on a panic, then calls the default zig panic handler
pub fn panic_handler(msg: []const u8, error_return_trace: ?*std.builtin.StackTrace, ret_addr: ?usize) noreturn {
    if (Tty.global_tty) |gty| {
        const reset: []const u8 = ctlseqs.csi_u_pop ++
            ctlseqs.mouse_reset ++
            ctlseqs.bp_reset ++
            ctlseqs.rmcup;

        gty.anyWriter().writeAll(reset) catch {};

        gty.deinit();
    }

    std.builtin.default_panic(msg, error_return_trace, ret_addr);
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
    if (build_options.text_input)
        _ = @import("widgets/TextInput.zig");
}
