const std = @import("std");
const builtin = @import("builtin");
const atomic = std.atomic;
const base64Encoder = std.base64.standard.Encoder;
const zigimg = @import("zigimg");

const Cell = @import("Cell.zig");
const Image = @import("Image.zig");
const InternalScreen = @import("InternalScreen.zig");
const Key = @import("Key.zig");
const Mouse = @import("Mouse.zig");
const Screen = @import("Screen.zig");
const Unicode = @import("Unicode.zig");
const Window = @import("Window.zig");

const AnyWriter = std.io.AnyWriter;
const Hyperlink = Cell.Hyperlink;
const KittyFlags = Key.KittyFlags;
const Shape = Mouse.Shape;
const Style = Cell.Style;
const Winsize = @import("main.zig").Winsize;

const ctlseqs = @import("ctlseqs.zig");
const gwidth = @import("gwidth.zig");

const assert = std.debug.assert;

const Vaxis = @This();

const log = std.log.scoped(.vaxis);

pub const Capabilities = struct {
    kitty_keyboard: bool = false,
    kitty_graphics: bool = false,
    rgb: bool = false,
    unicode: gwidth.Method = .wcwidth,
    sgr_pixels: bool = false,
    color_scheme_updates: bool = false,
    explicit_width: bool = false,
    scaled_text: bool = false,
};

pub const Options = struct {
    kitty_keyboard_flags: KittyFlags = .{},
    /// When supplied, this allocator will be used for system clipboard
    /// requests. If not supplied, it won't be possible to request the system
    /// clipboard
    system_clipboard_allocator: ?std.mem.Allocator = null,
};

/// the screen we write to
screen: Screen,
/// The last screen we drew. We keep this so we can efficiently update on
/// the next render
screen_last: InternalScreen,

caps: Capabilities = .{},

opts: Options = .{},

/// if we should redraw the entire screen on the next render
refresh: bool = false,

/// blocks the main thread until a DA1 query has been received, or the
/// futex times out
query_futex: atomic.Value(u32) = atomic.Value(u32).init(0),

/// If Queries were sent, we set this to false. We reset to true when all queries are complete. This
/// is used because we do explicit cursor position reports in the queries, which interfere with F3
/// key encoding. This can be used as a flag to determine how we should evaluate this sequence
queries_done: atomic.Value(bool) = atomic.Value(bool).init(true),

// images
next_img_id: u32 = 1,

unicode: Unicode,

sgr: enum {
    standard,
    legacy,
} = .standard,

state: struct {
    /// if we are in the alt screen
    alt_screen: bool = false,
    /// if we have entered kitty keyboard
    kitty_keyboard: bool = false,
    bracketed_paste: bool = false,
    mouse: bool = false,
    pixel_mouse: bool = false,
    color_scheme_updates: bool = false,
    in_band_resize: bool = false,
    changed_default_fg: bool = false,
    changed_default_bg: bool = false,
    changed_cursor_color: bool = false,
    cursor: struct {
        row: u16 = 0,
        col: u16 = 0,
    } = .{},
} = .{},

/// Initialize Vaxis with runtime options
pub fn init(alloc: std.mem.Allocator, opts: Options) !Vaxis {
    return .{
        .opts = opts,
        .screen = .{},
        .screen_last = try .init(alloc, 80, 24),
        .unicode = try Unicode.init(alloc),
    };
}

/// Resets the terminal to it's original state. If an allocator is
/// passed, this will free resources associated with Vaxis. This is left as an
/// optional so applications can choose to not free resources when the
/// application will be exiting anyways
pub fn deinit(self: *Vaxis, alloc: ?std.mem.Allocator, tty: AnyWriter) void {
    self.resetState(tty) catch {};

    if (alloc) |a| {
        self.screen.deinit(a);
        self.screen_last.deinit(a);
    }
    self.unicode.deinit();
}

/// resets enabled features, sends cursor to home and clears below cursor
pub fn resetState(self: *Vaxis, tty: AnyWriter) !void {
    // always show the cursor on state reset
    tty.writeAll(ctlseqs.show_cursor) catch {};
    tty.writeAll(ctlseqs.sgr_reset) catch {};
    if (self.screen.cursor_shape != .default) {
        // In many terminals, `.default` will set to the configured cursor shape. Others, it will
        // change to a blinking block.
        tty.print(ctlseqs.cursor_shape, .{@intFromEnum(Cell.CursorShape.default)}) catch {};
    }
    if (self.state.kitty_keyboard) {
        try tty.writeAll(ctlseqs.csi_u_pop);
        self.state.kitty_keyboard = false;
    }
    if (self.state.mouse) {
        try self.setMouseMode(tty, false);
    }
    if (self.state.bracketed_paste) {
        try self.setBracketedPaste(tty, false);
    }
    if (self.state.alt_screen) {
        try tty.writeAll(ctlseqs.home);
        try tty.writeAll(ctlseqs.erase_below_cursor);
        try self.exitAltScreen(tty);
    } else {
        try tty.writeByte('\r');
        var i: u16 = 0;
        while (i < self.state.cursor.row) : (i += 1) {
            try tty.writeAll(ctlseqs.ri);
        }
        try tty.writeAll(ctlseqs.erase_below_cursor);
    }
    if (self.state.color_scheme_updates) {
        try tty.writeAll(ctlseqs.color_scheme_reset);
        self.state.color_scheme_updates = false;
    }
    if (self.state.in_band_resize) {
        try tty.writeAll(ctlseqs.in_band_resize_reset);
        self.state.in_band_resize = false;
    }
    if (self.state.changed_default_fg) {
        try tty.writeAll(ctlseqs.osc10_reset);
        self.state.changed_default_fg = false;
    }
    if (self.state.changed_default_bg) {
        try tty.writeAll(ctlseqs.osc11_reset);
        self.state.changed_default_bg = false;
    }
    if (self.state.changed_cursor_color) {
        try tty.writeAll(ctlseqs.osc12_reset);
        self.state.changed_cursor_color = false;
    }
}

/// resize allocates a slice of cells equal to the number of cells
/// required to display the screen (ie width x height). Any previous screen is
/// freed when resizing. The cursor will be sent to it's home position and a
/// hardware clear-below-cursor will be sent
pub fn resize(
    self: *Vaxis,
    alloc: std.mem.Allocator,
    tty: AnyWriter,
    winsize: Winsize,
) !void {
    log.debug("resizing screen: width={d} height={d}", .{ winsize.cols, winsize.rows });
    self.screen.deinit(alloc);
    self.screen = try Screen.init(alloc, winsize, &self.unicode);
    self.screen.width_method = self.caps.unicode;
    // try self.screen.int(alloc, winsize.cols, winsize.rows);
    // we only init our current screen. This has the effect of redrawing
    // every cell
    self.screen_last.deinit(alloc);
    self.screen_last = try InternalScreen.init(alloc, winsize.cols, winsize.rows);
    if (self.state.alt_screen)
        try tty.writeAll(ctlseqs.home)
    else {
        try tty.writeBytesNTimes(ctlseqs.ri, self.state.cursor.row);
        try tty.writeByte('\r');
    }
    self.state.cursor.row = 0;
    self.state.cursor.col = 0;
    try tty.writeAll(ctlseqs.sgr_reset ++ ctlseqs.erase_below_cursor);
}

/// returns a Window comprising of the entire terminal screen
pub fn window(self: *Vaxis) Window {
    return .{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = self.screen.width,
        .height = self.screen.height,
        .screen = &self.screen,
    };
}

/// enter the alternate screen. The alternate screen will automatically
/// be exited if calling deinit while in the alt screen
pub fn enterAltScreen(self: *Vaxis, tty: AnyWriter) !void {
    try tty.writeAll(ctlseqs.smcup);
    self.state.alt_screen = true;
}

/// exit the alternate screen
pub fn exitAltScreen(self: *Vaxis, tty: AnyWriter) !void {
    try tty.writeAll(ctlseqs.rmcup);
    self.state.alt_screen = false;
}

/// write queries to the terminal to determine capabilities. Individual
/// capabilities will be delivered to the client and possibly intercepted by
/// Vaxis to enable features.
///
/// This call will block until Vaxis.query_futex is woken up, or the timeout.
/// Event loops can wake up this futex when cap_da1 is received
pub fn queryTerminal(self: *Vaxis, tty: AnyWriter, timeout_ns: u64) !void {
    try self.queryTerminalSend(tty);
    // 1 second timeout
    std.Thread.Futex.timedWait(&self.query_futex, 0, timeout_ns) catch {};
    self.queries_done.store(true, .unordered);
    try self.enableDetectedFeatures(tty);
}

/// write queries to the terminal to determine capabilities. This function
/// is only for use with a custom main loop. Call Vaxis.queryTerminal() if
/// you are using Loop.run()
pub fn queryTerminalSend(vx: *Vaxis, tty: AnyWriter) !void {
    vx.queries_done.store(false, .unordered);

    // TODO: re-enable this
    // const colorterm = std.posix.getenv("COLORTERM") orelse "";
    // if (std.mem.eql(u8, colorterm, "truecolor") or
    //     std.mem.eql(u8, colorterm, "24bit"))
    // {
    //     if (@hasField(Event, "cap_rgb")) {
    //         self.postEvent(.cap_rgb);
    //     }
    // }

    // TODO: XTGETTCAP queries ("RGB", "Smulx")
    // TODO: decide if we actually want to query for focus and sync. It
    // doesn't hurt to blindly use them
    // _ = try tty.write(ctlseqs.decrqm_focus);
    // _ = try tty.write(ctlseqs.decrqm_sync);
    try tty.writeAll(ctlseqs.decrqm_sgr_pixels ++
        ctlseqs.decrqm_unicode ++
        ctlseqs.decrqm_color_scheme ++
        ctlseqs.in_band_resize_set ++

        // Explicit width query. We send the cursor home, then do an explicit width command, then
        // query the position. If the parsed value is an F3 with shift, we support explicit width.
        // The returned response will be something like \x1b[1;2R...which when parsed as a Key is a
        // shift + F3 (the row is ignored). We only care if the column has moved from 1->2, which is
        // why we see a Shift modifier
        ctlseqs.home ++
        ctlseqs.explicit_width_query ++
        ctlseqs.cursor_position_request ++
        // Explicit width query. We send the cursor home, then do an scaled text command, then
        // query the position. If the parsed value is an F3 with al, we support scaled text.
        // The returned response will be something like \x1b[1;3R...which when parsed as a Key is a
        // alt + F3 (the row is ignored). We only care if the column has moved from 1->3, which is
        // why we see a Shift modifier
        ctlseqs.home ++
        ctlseqs.scaled_text_query ++
        ctlseqs.cursor_position_request ++
        ctlseqs.xtversion ++
        ctlseqs.csi_u_query ++
        ctlseqs.kitty_graphics_query ++
        ctlseqs.primary_device_attrs);
}

/// Enable features detected by responses to queryTerminal. This function
/// is only for use with a custom main loop. Call Vaxis.queryTerminal() if
/// you are using Loop.run()
pub fn enableDetectedFeatures(self: *Vaxis, tty: AnyWriter) !void {
    switch (builtin.os.tag) {
        .windows => {
            // No feature detection on windows. We just hard enable some knowns for ConPTY
            self.sgr = .legacy;
        },
        else => {
            // Apply any environment variables
            if (std.posix.getenv("TERMUX_VERSION")) |_|
                self.sgr = .legacy;
            if (std.posix.getenv("VHS_RECORD")) |_| {
                self.caps.unicode = .wcwidth;
                self.caps.kitty_keyboard = false;
                self.sgr = .legacy;
            }
            if (std.posix.getenv("TERM_PROGRAM")) |prg| {
                if (std.mem.eql(u8, prg, "vscode"))
                    self.sgr = .legacy;
            }
            if (std.posix.getenv("VAXIS_FORCE_LEGACY_SGR")) |_|
                self.sgr = .legacy;
            if (std.posix.getenv("VAXIS_FORCE_WCWIDTH")) |_|
                self.caps.unicode = .wcwidth;
            if (std.posix.getenv("VAXIS_FORCE_UNICODE")) |_|
                self.caps.unicode = .unicode;

            // enable detected features
            if (self.caps.kitty_keyboard) {
                try self.enableKittyKeyboard(tty, self.opts.kitty_keyboard_flags);
            }
            // Only enable mode 2027 if we don't have explicit width
            if (self.caps.unicode == .unicode and !self.caps.explicit_width) {
                try tty.writeAll(ctlseqs.unicode_set);
            }
        },
    }
}

// the next render call will refresh the entire screen
pub fn queueRefresh(self: *Vaxis) void {
    self.refresh = true;
}

/// draws the screen to the terminal
pub fn render(self: *Vaxis, tty: AnyWriter) !void {
    defer self.refresh = false;
    assert(self.screen.buf.len == @as(usize, @intCast(self.screen.width)) * self.screen.height); // correct size
    assert(self.screen.buf.len == self.screen_last.buf.len); // same size

    // Set up sync before we write anything
    // TODO: optimize sync so we only sync _when we have changes_. This
    // requires a smarter buffered writer, we'll probably have to write
    // our own
    try tty.writeAll(ctlseqs.sync_set);
    defer tty.writeAll(ctlseqs.sync_reset) catch {};

    // Send the cursor to 0,0
    // TODO: this needs to move after we optimize writes. We only do
    // this if we have an update to make. We also need to hide cursor
    // and then reshow it if needed
    try tty.writeAll(ctlseqs.hide_cursor);
    if (self.state.alt_screen)
        try tty.writeAll(ctlseqs.home)
    else {
        try tty.writeByte('\r');
        try tty.writeBytesNTimes(ctlseqs.ri, self.state.cursor.row);
    }
    try tty.writeAll(ctlseqs.sgr_reset);

    // initialize some variables
    var reposition: bool = false;
    var row: u16 = 0;
    var col: u16 = 0;
    var cursor: Style = .{};
    var link: Hyperlink = .{};
    var cursor_pos: struct {
        row: u16 = 0,
        col: u16 = 0,
    } = .{};

    // Clear all images
    if (self.caps.kitty_graphics)
        try tty.writeAll(ctlseqs.kitty_graphics_clear);

    // Reset skip flag on all last_screen cells
    for (self.screen_last.buf) |*last_cell| {
        last_cell.skip = false;
    }

    var i: usize = 0;
    while (i < self.screen.buf.len) {
        const cell = self.screen.buf[i];
        const w: u16 = blk: {
            if (cell.char.width != 0) break :blk cell.char.width;

            const method: gwidth.Method = self.caps.unicode;
            const width: u16 = @intCast(gwidth.gwidth(cell.char.grapheme, method, &self.unicode.width_data));
            break :blk @max(1, width);
        };
        defer {
            // advance by the width of this char mod 1
            std.debug.assert(w > 0);
            var j = i + 1;
            while (j < i + w) : (j += 1) {
                if (j >= self.screen_last.buf.len) break;
                self.screen_last.buf[j].skipped = true;
            }
            col += w;
            i += w;
        }
        if (col >= self.screen.width) {
            row += 1;
            col = 0;
            // Rely on terminal wrapping to reposition into next row instead of forcing it
            if (!cell.wrapped)
                reposition = true;
        }
        // If cell is the same as our last frame, we don't need to do
        // anything
        const last = self.screen_last.buf[i];
        if ((!self.refresh and
            last.eql(cell) and
            !last.skipped and
            cell.image == null) or
            last.skip)
        {
            reposition = true;
            // Close any osc8 sequence we might be in before
            // repositioning
            if (link.uri.len > 0) {
                try tty.writeAll(ctlseqs.osc8_clear);
            }
            continue;
        }
        self.screen_last.buf[i].skipped = false;
        defer {
            cursor = cell.style;
            link = cell.link;
        }
        // Set this cell in the last frame
        self.screen_last.writeCell(col, row, cell);

        // If we support scaled text, we set the flags now
        if (self.caps.scaled_text and cell.scale.scale > 1) {
            // The cell is scaled. Set appropriate skips. We only need to do this if the scale factor is
            // > 1
            assert(cell.char.width > 0);
            const cols = cell.scale.scale * cell.char.width;
            const rows = cell.scale.scale;
            for (0..rows) |skipped_row| {
                for (0..cols) |skipped_col| {
                    if (skipped_row == 0 and skipped_col == 0) {
                        continue;
                    }
                    const skipped_i = (@as(usize, @intCast(skipped_row + row)) * self.screen_last.width) + (skipped_col + col);
                    self.screen_last.buf[skipped_i].skip = true;
                }
            }
        }

        // reposition the cursor, if needed
        if (reposition) {
            reposition = false;
            link = .{};
            if (self.state.alt_screen)
                try tty.print(ctlseqs.cup, .{ row + 1, col + 1 })
            else {
                if (cursor_pos.row == row) {
                    const n = col - cursor_pos.col;
                    if (n > 0)
                        try tty.print(ctlseqs.cuf, .{n});
                } else {
                    const n = row - cursor_pos.row;
                    try tty.writeByteNTimes('\n', n);
                    try tty.writeByte('\r');
                    if (col > 0)
                        try tty.print(ctlseqs.cuf, .{col});
                }
            }
        }

        if (cell.image) |img| {
            try tty.print(
                ctlseqs.kitty_graphics_preamble,
                .{img.img_id},
            );
            if (img.options.pixel_offset) |offset| {
                try tty.print(
                    ",X={d},Y={d}",
                    .{ offset.x, offset.y },
                );
            }
            if (img.options.clip_region) |clip| {
                if (clip.x) |x|
                    try tty.print(",x={d}", .{x});
                if (clip.y) |y|
                    try tty.print(",y={d}", .{y});
                if (clip.width) |width|
                    try tty.print(",w={d}", .{width});
                if (clip.height) |height|
                    try tty.print(",h={d}", .{height});
            }
            if (img.options.size) |size| {
                if (size.rows) |rows|
                    try tty.print(",r={d}", .{rows});
                if (size.cols) |cols|
                    try tty.print(",c={d}", .{cols});
            }
            if (img.options.z_index) |z| {
                try tty.print(",z={d}", .{z});
            }
            try tty.writeAll(ctlseqs.kitty_graphics_closing);
        }

        // something is different, so let's loop through everything and
        // find out what

        // foreground
        if (!Cell.Color.eql(cursor.fg, cell.style.fg)) {
            switch (cell.style.fg) {
                .default => try tty.writeAll(ctlseqs.fg_reset),
                .index => |idx| {
                    switch (idx) {
                        0...7 => try tty.print(ctlseqs.fg_base, .{idx}),
                        8...15 => try tty.print(ctlseqs.fg_bright, .{idx - 8}),
                        else => {
                            switch (self.sgr) {
                                .standard => try tty.print(ctlseqs.fg_indexed, .{idx}),
                                .legacy => try tty.print(ctlseqs.fg_indexed_legacy, .{idx}),
                            }
                        },
                    }
                },
                .rgb => |rgb| {
                    switch (self.sgr) {
                        .standard => try tty.print(ctlseqs.fg_rgb, .{ rgb[0], rgb[1], rgb[2] }),
                        .legacy => try tty.print(ctlseqs.fg_rgb_legacy, .{ rgb[0], rgb[1], rgb[2] }),
                    }
                },
            }
        }
        // background
        if (!Cell.Color.eql(cursor.bg, cell.style.bg)) {
            switch (cell.style.bg) {
                .default => try tty.writeAll(ctlseqs.bg_reset),
                .index => |idx| {
                    switch (idx) {
                        0...7 => try tty.print(ctlseqs.bg_base, .{idx}),
                        8...15 => try tty.print(ctlseqs.bg_bright, .{idx - 8}),
                        else => {
                            switch (self.sgr) {
                                .standard => try tty.print(ctlseqs.bg_indexed, .{idx}),
                                .legacy => try tty.print(ctlseqs.bg_indexed_legacy, .{idx}),
                            }
                        },
                    }
                },
                .rgb => |rgb| {
                    switch (self.sgr) {
                        .standard => try tty.print(ctlseqs.bg_rgb, .{ rgb[0], rgb[1], rgb[2] }),
                        .legacy => try tty.print(ctlseqs.bg_rgb_legacy, .{ rgb[0], rgb[1], rgb[2] }),
                    }
                },
            }
        }
        // underline color
        if (!Cell.Color.eql(cursor.ul, cell.style.ul)) {
            switch (cell.style.ul) {
                .default => try tty.writeAll(ctlseqs.ul_reset),
                .index => |idx| {
                    switch (self.sgr) {
                        .standard => try tty.print(ctlseqs.ul_indexed, .{idx}),
                        .legacy => try tty.print(ctlseqs.ul_indexed_legacy, .{idx}),
                    }
                },
                .rgb => |rgb| {
                    switch (self.sgr) {
                        .standard => try tty.print(ctlseqs.ul_rgb, .{ rgb[0], rgb[1], rgb[2] }),
                        .legacy => try tty.print(ctlseqs.ul_rgb_legacy, .{ rgb[0], rgb[1], rgb[2] }),
                    }
                },
            }
        }
        // underline style
        if (cursor.ul_style != cell.style.ul_style) {
            const seq = switch (cell.style.ul_style) {
                .off => ctlseqs.ul_off,
                .single => ctlseqs.ul_single,
                .double => ctlseqs.ul_double,
                .curly => ctlseqs.ul_curly,
                .dotted => ctlseqs.ul_dotted,
                .dashed => ctlseqs.ul_dashed,
            };
            try tty.writeAll(seq);
        }
        // bold
        if (cursor.bold != cell.style.bold) {
            const seq = switch (cell.style.bold) {
                true => ctlseqs.bold_set,
                false => ctlseqs.bold_dim_reset,
            };
            try tty.writeAll(seq);
            if (cell.style.dim) {
                try tty.writeAll(ctlseqs.dim_set);
            }
        }
        // dim
        if (cursor.dim != cell.style.dim) {
            const seq = switch (cell.style.dim) {
                true => ctlseqs.dim_set,
                false => ctlseqs.bold_dim_reset,
            };
            try tty.writeAll(seq);
            if (cell.style.bold) {
                try tty.writeAll(ctlseqs.bold_set);
            }
        }
        // dim
        if (cursor.italic != cell.style.italic) {
            const seq = switch (cell.style.italic) {
                true => ctlseqs.italic_set,
                false => ctlseqs.italic_reset,
            };
            try tty.writeAll(seq);
        }
        // dim
        if (cursor.blink != cell.style.blink) {
            const seq = switch (cell.style.blink) {
                true => ctlseqs.blink_set,
                false => ctlseqs.blink_reset,
            };
            try tty.writeAll(seq);
        }
        // reverse
        if (cursor.reverse != cell.style.reverse) {
            const seq = switch (cell.style.reverse) {
                true => ctlseqs.reverse_set,
                false => ctlseqs.reverse_reset,
            };
            try tty.writeAll(seq);
        }
        // invisible
        if (cursor.invisible != cell.style.invisible) {
            const seq = switch (cell.style.invisible) {
                true => ctlseqs.invisible_set,
                false => ctlseqs.invisible_reset,
            };
            try tty.writeAll(seq);
        }
        // strikethrough
        if (cursor.strikethrough != cell.style.strikethrough) {
            const seq = switch (cell.style.strikethrough) {
                true => ctlseqs.strikethrough_set,
                false => ctlseqs.strikethrough_reset,
            };
            try tty.writeAll(seq);
        }

        // url
        if (!std.mem.eql(u8, link.uri, cell.link.uri)) {
            var ps = cell.link.params;
            if (cell.link.uri.len == 0) {
                // Empty out the params no matter what if we don't have
                // a url
                ps = "";
            }
            try tty.print(ctlseqs.osc8, .{ ps, cell.link.uri });
        }

        // scale
        if (self.caps.scaled_text and !cell.scale.eql(.{})) {
            const scale = cell.scale;
            // We have a scaled cell.
            switch (cell.scale.denominator) {
                // Denominator cannot be 0
                0 => unreachable,
                1 => {
                    // no fractional scaling, just a straight scale factor
                    try tty.print(
                        ctlseqs.scaled_text,
                        .{ scale.scale, w, cell.char.grapheme },
                    );
                },
                else => {
                    // fractional scaling
                    // no fractional scaling, just a straight scale factor
                    try tty.print(
                        ctlseqs.scaled_text_with_fractions,
                        .{
                            scale.scale,
                            w,
                            scale.numerator,
                            scale.denominator,
                            @intFromEnum(scale.vertical_alignment),
                            cell.char.grapheme,
                        },
                    );
                },
            }
            cursor_pos.col = col + (w * scale.scale);
            cursor_pos.row = row;
            continue;
        }

        // If we have explicit width and our width is greater than 1, let's use it
        if (self.caps.explicit_width and w > 1) {
            try tty.print(ctlseqs.explicit_width, .{ w, cell.char.grapheme });
        } else {
            try tty.writeAll(cell.char.grapheme);
        }
        cursor_pos.col = col + w;
        cursor_pos.row = row;
    }
    if (self.screen.cursor_vis) {
        if (self.state.alt_screen) {
            try tty.print(
                ctlseqs.cup,
                .{
                    self.screen.cursor_row + 1,
                    self.screen.cursor_col + 1,
                },
            );
        } else {
            // TODO: position cursor relative to current location
            try tty.writeByte('\r');
            if (self.screen.cursor_row >= cursor_pos.row)
                try tty.writeByteNTimes('\n', self.screen.cursor_row - cursor_pos.row)
            else
                try tty.writeBytesNTimes(ctlseqs.ri, cursor_pos.row - self.screen.cursor_row);
            if (self.screen.cursor_col > 0)
                try tty.print(ctlseqs.cuf, .{self.screen.cursor_col});
        }
        self.state.cursor.row = self.screen.cursor_row;
        self.state.cursor.col = self.screen.cursor_col;
        try tty.writeAll(ctlseqs.show_cursor);
    } else {
        self.state.cursor.row = cursor_pos.row;
        self.state.cursor.col = cursor_pos.col;
    }
    if (self.screen.mouse_shape != self.screen_last.mouse_shape) {
        try tty.print(
            ctlseqs.osc22_mouse_shape,
            .{@tagName(self.screen.mouse_shape)},
        );
        self.screen_last.mouse_shape = self.screen.mouse_shape;
    }
    if (self.screen.cursor_shape != self.screen_last.cursor_shape) {
        try tty.print(
            ctlseqs.cursor_shape,
            .{@intFromEnum(self.screen.cursor_shape)},
        );
        self.screen_last.cursor_shape = self.screen.cursor_shape;
    }
}

fn enableKittyKeyboard(self: *Vaxis, tty: AnyWriter, flags: Key.KittyFlags) !void {
    const flag_int: u5 = @bitCast(flags);
    try tty.print(ctlseqs.csi_u_push, .{flag_int});
    self.state.kitty_keyboard = true;
}

/// send a system notification
pub fn notify(_: *Vaxis, tty: AnyWriter, title: ?[]const u8, body: []const u8) !void {
    if (title) |t|
        try tty.print(ctlseqs.osc777_notify, .{ t, body })
    else
        try tty.print(ctlseqs.osc9_notify, .{body});
}

/// sets the window title
pub fn setTitle(_: *Vaxis, tty: AnyWriter, title: []const u8) !void {
    try tty.print(ctlseqs.osc2_set_title, .{title});
}

// turn bracketed paste on or off. An event will be sent at the
// beginning and end of a detected paste. All keystrokes between these
// events were pasted
pub fn setBracketedPaste(self: *Vaxis, tty: AnyWriter, enable: bool) !void {
    const seq = if (enable)
        ctlseqs.bp_set
    else
        ctlseqs.bp_reset;
    try tty.writeAll(seq);
    self.state.bracketed_paste = enable;
}

/// set the mouse shape
pub fn setMouseShape(self: *Vaxis, shape: Shape) void {
    self.screen.mouse_shape = shape;
}

/// Change the mouse reporting mode
pub fn setMouseMode(self: *Vaxis, tty: AnyWriter, enable: bool) !void {
    if (enable) {
        self.state.mouse = true;
        if (self.caps.sgr_pixels) {
            log.debug("enabling mouse mode: pixel coordinates", .{});
            self.state.pixel_mouse = true;
            try tty.writeAll(ctlseqs.mouse_set_pixels);
        } else {
            log.debug("enabling mouse mode: cell coordinates", .{});
            try tty.writeAll(ctlseqs.mouse_set);
        }
    } else {
        try tty.writeAll(ctlseqs.mouse_reset);
    }
}

/// Translate pixel mouse coordinates to cell + offset
pub fn translateMouse(self: Vaxis, mouse: Mouse) Mouse {
    if (self.screen.width == 0 or self.screen.height == 0) return mouse;
    var result = mouse;
    if (self.state.pixel_mouse) {
        std.debug.assert(mouse.xoffset == 0);
        std.debug.assert(mouse.yoffset == 0);
        const xpos = mouse.col;
        const ypos = mouse.row;
        const xextra = self.screen.width_pix % self.screen.width;
        const yextra = self.screen.height_pix % self.screen.height;
        const xcell = (self.screen.width_pix - xextra) / self.screen.width;
        const ycell = (self.screen.height_pix - yextra) / self.screen.height;
        if (xcell == 0 or ycell == 0) return mouse;
        result.col = xpos / xcell;
        result.row = ypos / ycell;
        result.xoffset = xpos % xcell;
        result.yoffset = ypos % ycell;
    }
    return result;
}

/// Transmit an image using the local filesystem. Allocates only for base64 encoding
pub fn transmitLocalImagePath(
    self: *Vaxis,
    allocator: std.mem.Allocator,
    tty: AnyWriter,
    payload: []const u8,
    width: u16,
    height: u16,
    medium: Image.TransmitMedium,
    format: Image.TransmitFormat,
) !Image {
    if (!self.caps.kitty_graphics) return error.NoGraphicsCapability;

    defer self.next_img_id += 1;

    const id = self.next_img_id;

    const size = base64Encoder.calcSize(payload.len);
    if (size >= 4096) return error.PathTooLong;

    const buf = try allocator.alloc(u8, size);
    const encoded = base64Encoder.encode(buf, payload);
    defer allocator.free(buf);

    const medium_char: u8 = switch (medium) {
        .file => 'f',
        .temp_file => 't',
        .shared_mem => 's',
    };

    switch (format) {
        .rgb => {
            try tty.print(
                "\x1b_Gf=24,s={d},v={d},i={d},t={c};{s}\x1b\\",
                .{ width, height, id, medium_char, encoded },
            );
        },
        .rgba => {
            try tty.print(
                "\x1b_Gf=32,s={d},v={d},i={d},t={c};{s}\x1b\\",
                .{ width, height, id, medium_char, encoded },
            );
        },
        .png => {
            try tty.print(
                "\x1b_Gf=100,i={d},t={c};{s}\x1b\\",
                .{ id, medium_char, encoded },
            );
        },
    }
    return .{
        .id = id,
        .width = width,
        .height = height,
    };
}

/// Transmit an image which has been pre-base64 encoded
pub fn transmitPreEncodedImage(
    self: *Vaxis,
    tty: AnyWriter,
    bytes: []const u8,
    width: u16,
    height: u16,
    format: Image.TransmitFormat,
) !Image {
    if (!self.caps.kitty_graphics) return error.NoGraphicsCapability;

    defer self.next_img_id += 1;
    const id = self.next_img_id;

    const fmt: u8 = switch (format) {
        .rgb => 24,
        .rgba => 32,
        .png => 100,
    };

    if (bytes.len < 4096) {
        try tty.print(
            "\x1b_Gf={d},s={d},v={d},i={d};{s}\x1b\\",
            .{
                fmt,
                width,
                height,
                id,
                bytes,
            },
        );
    } else {
        var n: usize = 4096;

        try tty.print(
            "\x1b_Gf={d},s={d},v={d},i={d},m=1;{s}\x1b\\",
            .{ fmt, width, height, id, bytes[0..n] },
        );
        while (n < bytes.len) : (n += 4096) {
            const end: usize = @min(n + 4096, bytes.len);
            const m: u2 = if (end == bytes.len) 0 else 1;
            try tty.print(
                "\x1b_Gm={d};{s}\x1b\\",
                .{
                    m,
                    bytes[n..end],
                },
            );
        }
    }
    return .{
        .id = id,
        .width = width,
        .height = height,
    };
}

pub fn transmitImage(
    self: *Vaxis,
    alloc: std.mem.Allocator,
    tty: AnyWriter,
    img: *zigimg.Image,
    format: Image.TransmitFormat,
) !Image {
    if (!self.caps.kitty_graphics) return error.NoGraphicsCapability;

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    const buf = switch (format) {
        .png => png: {
            const png_buf = try arena.allocator().alloc(u8, img.imageByteSize());
            const png = try img.writeToMemory(png_buf, .{ .png = .{} });
            break :png png;
        },
        .rgb => rgb: {
            try img.convert(.rgb24);
            break :rgb img.rawBytes();
        },
        .rgba => rgba: {
            try img.convert(.rgba32);
            break :rgba img.rawBytes();
        },
    };

    const b64_buf = try arena.allocator().alloc(u8, base64Encoder.calcSize(buf.len));
    const encoded = base64Encoder.encode(b64_buf, buf);

    return self.transmitPreEncodedImage(tty, encoded, @intCast(img.width), @intCast(img.height), format);
}

pub fn loadImage(
    self: *Vaxis,
    alloc: std.mem.Allocator,
    tty: AnyWriter,
    src: Image.Source,
) !Image {
    if (!self.caps.kitty_graphics) return error.NoGraphicsCapability;

    var img = switch (src) {
        .path => |path| try zigimg.Image.fromFilePath(alloc, path),
        .mem => |bytes| try zigimg.Image.fromMemory(alloc, bytes),
    };
    defer img.deinit();
    return self.transmitImage(alloc, tty, &img, .png);
}

/// deletes an image from the terminal's memory
pub fn freeImage(_: Vaxis, tty: AnyWriter, id: u32) void {
    tty.print("\x1b_Ga=d,d=I,i={d};\x1b\\", .{id}) catch |err| {
        log.err("couldn't delete image {d}: {}", .{ id, err });
        return;
    };
}

pub fn copyToSystemClipboard(_: Vaxis, tty: AnyWriter, text: []const u8, encode_allocator: std.mem.Allocator) !void {
    const encoder = std.base64.standard.Encoder;
    const size = encoder.calcSize(text.len);
    const buf = try encode_allocator.alloc(u8, size);
    const b64 = encoder.encode(buf, text);
    defer encode_allocator.free(buf);
    try tty.print(
        ctlseqs.osc52_clipboard_copy,
        .{b64},
    );
}

pub fn requestSystemClipboard(self: Vaxis, tty: AnyWriter) !void {
    if (self.opts.system_clipboard_allocator == null) return error.NoClipboardAllocator;
    try tty.print(
        ctlseqs.osc52_clipboard_request,
        .{},
    );
}

/// Set the default terminal foreground color
pub fn setTerminalForegroundColor(self: *Vaxis, tty: AnyWriter, rgb: [3]u8) !void {
    try tty.print(ctlseqs.osc10_set, .{ rgb[0], rgb[0], rgb[1], rgb[1], rgb[2], rgb[2] });
    self.state.changed_default_fg = true;
}

/// Set the default terminal background color
pub fn setTerminalBackgroundColor(self: *Vaxis, tty: AnyWriter, rgb: [3]u8) !void {
    try tty.print(ctlseqs.osc11_set, .{ rgb[0], rgb[0], rgb[1], rgb[1], rgb[2], rgb[2] });
    self.state.changed_default_bg = true;
}

/// Set the terminal cursor color
pub fn setTerminalCursorColor(self: *Vaxis, tty: AnyWriter, rgb: [3]u8) !void {
    try tty.print(ctlseqs.osc12_set, .{ rgb[0], rgb[0], rgb[1], rgb[1], rgb[2], rgb[2] });
    self.state.changed_cursor_color = true;
}

/// Request a color report from the terminal. Note: not all terminals support
/// reporting colors. It is always safe to try, but you may not receive a
/// response.
pub fn queryColor(_: Vaxis, tty: AnyWriter, kind: Cell.Color.Kind) !void {
    switch (kind) {
        .fg => try tty.writeAll(ctlseqs.osc10_query),
        .bg => try tty.writeAll(ctlseqs.osc11_query),
        .cursor => try tty.writeAll(ctlseqs.osc12_query),
        .index => |idx| try tty.print(ctlseqs.osc4_query, .{idx}),
    }
}

/// Subscribe to color theme updates. A `color_scheme: Color.Scheme` tag must
/// exist on your Event type to receive the response. This is a queried
/// capability. Support can be detected by checking the value of
/// vaxis.caps.color_scheme_updates. The initial scheme will be reported when
/// subscribing.
pub fn subscribeToColorSchemeUpdates(self: *Vaxis, tty: AnyWriter) !void {
    try tty.writeAll(ctlseqs.color_scheme_request);
    try tty.writeAll(ctlseqs.color_scheme_set);
    self.state.color_scheme_updates = true;
}

pub fn deviceStatusReport(_: Vaxis, tty: AnyWriter) !void {
    try tty.writeAll(ctlseqs.device_status_report);
}

/// prettyPrint is used to print the contents of the Screen to the tty. The state is not stored, and
/// the cursor will be put on the next line after the last line is printed. This is useful to
/// sequentially print data in a styled format to eg. stdout. This function returns an error if you
/// are not in the alt screen. The cursor is always hidden, and mouse shapes are not available
pub fn prettyPrint(self: *Vaxis, tty: AnyWriter) !void {
    if (self.state.alt_screen) return error.NotInPrimaryScreen;

    try tty.writeAll(ctlseqs.hide_cursor);
    try tty.writeAll(ctlseqs.sync_set);
    defer tty.writeAll(ctlseqs.sync_reset) catch {};
    try tty.writeAll(ctlseqs.sgr_reset);
    defer tty.writeAll(ctlseqs.sgr_reset) catch {};

    var reposition: bool = false;
    var row: u16 = 0;
    var col: u16 = 0;
    var cursor: Style = .{};
    var link: Hyperlink = .{};
    var cursor_pos: struct {
        row: u16 = 0,
        col: u16 = 0,
    } = .{};

    var i: u16 = 0;
    while (i < self.screen.buf.len) {
        const cell = self.screen.buf[i];
        const w = blk: {
            if (cell.char.width != 0) break :blk cell.char.width;

            const method: gwidth.Method = self.caps.unicode;
            const width = gwidth.gwidth(cell.char.grapheme, method, &self.unicode.width_data);
            break :blk @max(1, width);
        };
        defer {
            // advance by the width of this char mod 1
            std.debug.assert(w > 0);
            var j = i + 1;
            while (j < i + w) : (j += 1) {
                if (j >= self.screen_last.buf.len) break;
                self.screen_last.buf[j].skipped = true;
            }
            col += w;
            i += w;
        }
        if (col >= self.screen.width) {
            row += 1;
            col = 0;
            // Rely on terminal wrapping to reposition into next row instead of forcing it
            if (!cell.wrapped)
                reposition = true;
        }
        if (cell.default) {
            reposition = true;
            continue;
        }
        defer {
            cursor = cell.style;
            link = cell.link;
        }

        // reposition the cursor, if needed
        if (reposition) {
            reposition = false;
            link = .{};
            if (cursor_pos.row == row) {
                const n = col - cursor_pos.col;
                if (n > 0)
                    try tty.print(ctlseqs.cuf, .{n});
            } else {
                const n = row - cursor_pos.row;
                try tty.writeByteNTimes('\n', n);
                try tty.writeByte('\r');
                if (col > 0)
                    try tty.print(ctlseqs.cuf, .{col});
            }
        }

        if (cell.image) |img| {
            try tty.print(
                ctlseqs.kitty_graphics_preamble,
                .{img.img_id},
            );
            if (img.options.pixel_offset) |offset| {
                try tty.print(
                    ",X={d},Y={d}",
                    .{ offset.x, offset.y },
                );
            }
            if (img.options.clip_region) |clip| {
                if (clip.x) |x|
                    try tty.print(",x={d}", .{x});
                if (clip.y) |y|
                    try tty.print(",y={d}", .{y});
                if (clip.width) |width|
                    try tty.print(",w={d}", .{width});
                if (clip.height) |height|
                    try tty.print(",h={d}", .{height});
            }
            if (img.options.size) |size| {
                if (size.rows) |rows|
                    try tty.print(",r={d}", .{rows});
                if (size.cols) |cols|
                    try tty.print(",c={d}", .{cols});
            }
            if (img.options.z_index) |z| {
                try tty.print(",z={d}", .{z});
            }
            try tty.writeAll(ctlseqs.kitty_graphics_closing);
        }

        // something is different, so let's loop through everything and
        // find out what

        // foreground
        if (!Cell.Color.eql(cursor.fg, cell.style.fg)) {
            switch (cell.style.fg) {
                .default => try tty.writeAll(ctlseqs.fg_reset),
                .index => |idx| {
                    switch (idx) {
                        0...7 => try tty.print(ctlseqs.fg_base, .{idx}),
                        8...15 => try tty.print(ctlseqs.fg_bright, .{idx - 8}),
                        else => {
                            switch (self.sgr) {
                                .standard => try tty.print(ctlseqs.fg_indexed, .{idx}),
                                .legacy => try tty.print(ctlseqs.fg_indexed_legacy, .{idx}),
                            }
                        },
                    }
                },
                .rgb => |rgb| {
                    switch (self.sgr) {
                        .standard => try tty.print(ctlseqs.fg_rgb, .{ rgb[0], rgb[1], rgb[2] }),
                        .legacy => try tty.print(ctlseqs.fg_rgb_legacy, .{ rgb[0], rgb[1], rgb[2] }),
                    }
                },
            }
        }
        // background
        if (!Cell.Color.eql(cursor.bg, cell.style.bg)) {
            switch (cell.style.bg) {
                .default => try tty.writeAll(ctlseqs.bg_reset),
                .index => |idx| {
                    switch (idx) {
                        0...7 => try tty.print(ctlseqs.bg_base, .{idx}),
                        8...15 => try tty.print(ctlseqs.bg_bright, .{idx - 8}),
                        else => {
                            switch (self.sgr) {
                                .standard => try tty.print(ctlseqs.bg_indexed, .{idx}),
                                .legacy => try tty.print(ctlseqs.bg_indexed_legacy, .{idx}),
                            }
                        },
                    }
                },
                .rgb => |rgb| {
                    switch (self.sgr) {
                        .standard => try tty.print(ctlseqs.bg_rgb, .{ rgb[0], rgb[1], rgb[2] }),
                        .legacy => try tty.print(ctlseqs.bg_rgb_legacy, .{ rgb[0], rgb[1], rgb[2] }),
                    }
                },
            }
        }
        // underline color
        if (!Cell.Color.eql(cursor.ul, cell.style.ul)) {
            switch (cell.style.ul) {
                .default => try tty.writeAll(ctlseqs.ul_reset),
                .index => |idx| {
                    switch (self.sgr) {
                        .standard => try tty.print(ctlseqs.ul_indexed, .{idx}),
                        .legacy => try tty.print(ctlseqs.ul_indexed_legacy, .{idx}),
                    }
                },
                .rgb => |rgb| {
                    switch (self.sgr) {
                        .standard => try tty.print(ctlseqs.ul_rgb, .{ rgb[0], rgb[1], rgb[2] }),
                        .legacy => try tty.print(ctlseqs.ul_rgb_legacy, .{ rgb[0], rgb[1], rgb[2] }),
                    }
                },
            }
        }
        // underline style
        if (cursor.ul_style != cell.style.ul_style) {
            const seq = switch (cell.style.ul_style) {
                .off => ctlseqs.ul_off,
                .single => ctlseqs.ul_single,
                .double => ctlseqs.ul_double,
                .curly => ctlseqs.ul_curly,
                .dotted => ctlseqs.ul_dotted,
                .dashed => ctlseqs.ul_dashed,
            };
            try tty.writeAll(seq);
        }
        // bold
        if (cursor.bold != cell.style.bold) {
            const seq = switch (cell.style.bold) {
                true => ctlseqs.bold_set,
                false => ctlseqs.bold_dim_reset,
            };
            try tty.writeAll(seq);
            if (cell.style.dim) {
                try tty.writeAll(ctlseqs.dim_set);
            }
        }
        // dim
        if (cursor.dim != cell.style.dim) {
            const seq = switch (cell.style.dim) {
                true => ctlseqs.dim_set,
                false => ctlseqs.bold_dim_reset,
            };
            try tty.writeAll(seq);
            if (cell.style.bold) {
                try tty.writeAll(ctlseqs.bold_set);
            }
        }
        // dim
        if (cursor.italic != cell.style.italic) {
            const seq = switch (cell.style.italic) {
                true => ctlseqs.italic_set,
                false => ctlseqs.italic_reset,
            };
            try tty.writeAll(seq);
        }
        // dim
        if (cursor.blink != cell.style.blink) {
            const seq = switch (cell.style.blink) {
                true => ctlseqs.blink_set,
                false => ctlseqs.blink_reset,
            };
            try tty.writeAll(seq);
        }
        // reverse
        if (cursor.reverse != cell.style.reverse) {
            const seq = switch (cell.style.reverse) {
                true => ctlseqs.reverse_set,
                false => ctlseqs.reverse_reset,
            };
            try tty.writeAll(seq);
        }
        // invisible
        if (cursor.invisible != cell.style.invisible) {
            const seq = switch (cell.style.invisible) {
                true => ctlseqs.invisible_set,
                false => ctlseqs.invisible_reset,
            };
            try tty.writeAll(seq);
        }
        // strikethrough
        if (cursor.strikethrough != cell.style.strikethrough) {
            const seq = switch (cell.style.strikethrough) {
                true => ctlseqs.strikethrough_set,
                false => ctlseqs.strikethrough_reset,
            };
            try tty.writeAll(seq);
        }

        // url
        if (!std.mem.eql(u8, link.uri, cell.link.uri)) {
            var ps = cell.link.params;
            if (cell.link.uri.len == 0) {
                // Empty out the params no matter what if we don't have
                // a url
                ps = "";
            }
            try tty.print(ctlseqs.osc8, .{ ps, cell.link.uri });
        }
        try tty.writeAll(cell.char.grapheme);
        cursor_pos.col = col + w;
        cursor_pos.row = row;
    }
    try tty.writeAll("\r\n");
}

/// Set the terminal's current working directory
pub fn setTerminalWorkingDirectory(_: *Vaxis, tty: AnyWriter, path: []const u8) !void {
    if (path.len == 0 or path[0] != '/')
        return error.InvalidAbsolutePath;
    const hostname = switch (builtin.os.tag) {
        .windows => null,
        else => std.posix.getenv("HOSTNAME"),
    } orelse "localhost";

    const uri: std.Uri = .{
        .scheme = "file",
        .host = .{ .raw = hostname },
        .path = .{ .raw = path },
    };
    try tty.print(ctlseqs.osc7, .{uri});
}
