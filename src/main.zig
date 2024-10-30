const std = @import("std");
const builtin = @import("builtin");

const tty = @import("tty.zig");

pub const Vaxis = @import("Vaxis.zig");

pub const Loop = @import("Loop.zig").Loop;

pub const zigimg = @import("zigimg");

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

pub const vxfw = @import("vxfw/vxfw.zig");

pub const Tty = tty.Tty;

/// The size of the terminal screen
pub const Winsize = struct {
    rows: u16,
    cols: u16,
    x_pixel: u16,
    y_pixel: u16,
};

/// Initialize a Vaxis application.
pub fn init(alloc: std.mem.Allocator, opts: Vaxis.Options) !Vaxis {
    return Vaxis.init(alloc, opts);
}

/// Resets terminal state on a panic, then calls the default zig panic handler
pub fn panic_handler(msg: []const u8, error_return_trace: ?*std.builtin.StackTrace, ret_addr: ?usize) noreturn {
    if (tty.global_tty) |gty| {
        const reset: []const u8 = ctlseqs.csi_u_pop ++
            ctlseqs.mouse_reset ++
            ctlseqs.bp_reset ++
            ctlseqs.rmcup;

        gty.anyWriter().writeAll(reset) catch {};

        gty.deinit();
    }

    std.builtin.default_panic(msg, error_return_trace, ret_addr);
}

pub const log_scopes = enum {
    vaxis,
};

/// the vaxis logo. In PixelCode
pub const logo =
    \\▄   ▄  ▄▄▄  ▄   ▄ ▄▄▄  ▄▄▄
    \\█   █ █▄▄▄█ ▀▄ ▄▀  █  █   ▀
    \\▀▄ ▄▀ █   █  ▄▀▄   █   ▀▀▀▄
    \\ ▀▄▀  █   █ █   █ ▄█▄ ▀▄▄▄▀
;

test "refAllDecls" {
    std.testing.refAllDecls(@This());
}
