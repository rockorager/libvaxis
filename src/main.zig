const std = @import("std");
const builtin = @import("builtin");

pub const tty = @import("tty.zig");

pub const Vaxis = @import("Vaxis.zig");

pub const loop = @import("Loop.zig");
pub const Loop = loop.Loop;

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

pub const Panic = struct {
    pub const call = panic_handler;
    pub const sentinelMismatch = std.debug.FormattedPanic.sentinelMismatch;
    pub const unwrapError = std.debug.FormattedPanic.unwrapError;
    pub const outOfBounds = std.debug.FormattedPanic.outOfBounds;
    pub const startGreaterThanEnd = std.debug.FormattedPanic.startGreaterThanEnd;
    pub const inactiveUnionField = std.debug.FormattedPanic.inactiveUnionField;
    pub const messages = std.debug.FormattedPanic.messages;
};

/// Resets terminal state on a panic, then calls the default zig panic handler
pub fn panic_handler(msg: []const u8, _: ?*std.builtin.StackTrace, ret_addr: ?usize) noreturn {
    recover();
    std.debug.defaultPanic(msg, ret_addr);
}

/// Resets the terminal state using the global tty instance. Use this only to recover during a panic
pub fn recover() void {
    if (tty.global_tty) |gty| {
        const reset: []const u8 = ctlseqs.csi_u_pop ++
            ctlseqs.mouse_reset ++
            ctlseqs.bp_reset ++
            ctlseqs.rmcup;

        gty.anyWriter().writeAll(reset) catch {};

        gty.deinit();
    }
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
