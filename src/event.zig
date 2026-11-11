pub const Key = @import("Key.zig");
pub const Mouse = @import("Mouse.zig");
pub const Color = @import("Cell.zig").Color;
pub const Winsize = @import("main.zig").Winsize;

/// The events that Vaxis emits internally
pub const Event = union(enum) {
    key_press: Key,
    key_release: Key,
    invalid_key,
    mouse: Mouse,
    mouse_leave,
    focus_in,
    focus_out,
    paste_start, // bracketed paste start
    paste_end, // bracketed paste end
    paste: []const u8, // osc 52 paste, caller must free
    color_report: Color.Report, // osc 4, 10, 11, 12 response
    color_scheme: Color.Scheme,
    winsize: Winsize,
    /// Cursor position report, with zero-based row and column.
    cursor_position: @import("Screen.zig").Cursor,
    /// The terminal's identification from the XTVERSION reply. Borrows the
    /// parser's input and is valid only until the next parse, so consumers must
    /// copy it. vaxis handles this event internally and never posts it.
    terminal_version: []const u8,

    // these are delivered as discovered terminal capabilities
    cap_kitty_keyboard,
    cap_kitty_graphics,
    cap_rgb,
    cap_sgr_pixels,
    cap_unicode,
    cap_da1,
    cap_color_scheme_updates,
    cap_multi_cursor,
    cap_program_status,
};

test {
    const std = @import("std");
    std.testing.refAllDecls(@This());
}
