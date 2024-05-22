const std = @import("std");
const atomic = std.atomic;
const base64Encoder = std.base64.standard.Encoder;
const zigimg = @import("zigimg");

const Cell = @import("Cell.zig");
const Image = @import("Image.zig");
const InternalScreen = @import("InternalScreen.zig");
const Key = @import("Key.zig");
const Mouse = @import("Mouse.zig");
const Screen = @import("Screen.zig");
const Tty = @import("Tty.zig");
const Unicode = @import("Unicode.zig");
const Window = @import("Window.zig");

const Hyperlink = Cell.Hyperlink;
const KittyFlags = Key.KittyFlags;
const Shape = Mouse.Shape;
const Style = Cell.Style;
const Winsize = Tty.Winsize;

const ctlseqs = @import("ctlseqs.zig");
const gwidth = @import("gwidth.zig");

const Vaxis = @This();

const log = std.log.scoped(.vaxis);

pub const Capabilities = struct {
    kitty_keyboard: bool = false,
    kitty_graphics: bool = false,
    rgb: bool = false,
    unicode: gwidth.Method = .wcwidth,
    sgr_pixels: bool = false,
};

pub const Options = struct {
    kitty_keyboard_flags: KittyFlags = .{},
    /// When supplied, this allocator will be used for system clipboard
    /// requests. If not supplied, it won't be possible to request the system
    /// clipboard
    system_clipboard_allocator: ?std.mem.Allocator = null,
};

tty: ?Tty,

/// the screen we write to
screen: Screen,
/// The last screen we drew. We keep this so we can efficiently update on
/// the next render
screen_last: InternalScreen = undefined,

caps: Capabilities = .{},

opts: Options = .{},

/// if we should redraw the entire screen on the next render
refresh: bool = false,

/// blocks the main thread until a DA1 query has been received, or the
/// futex times out
query_futex: atomic.Value(u32) = atomic.Value(u32).init(0),

// images
next_img_id: u32 = 1,

unicode: Unicode,

// statistics
renders: usize = 0,
render_dur: i128 = 0,
render_timer: std.time.Timer,

sgr: enum {
    standard,
    legacy,
} = .standard,

/// Initialize Vaxis with runtime options
pub fn init(alloc: std.mem.Allocator, opts: Options) !Vaxis {
    return .{
        .opts = opts,
        .tty = null,
        .screen = .{},
        .screen_last = .{},
        .render_timer = try std.time.Timer.start(),
        .unicode = try Unicode.init(alloc),
    };
}

/// Resets the terminal to it's original state. If an allocator is
/// passed, this will free resources associated with Vaxis. This is left as an
/// optional so applications can choose to not free resources when the
/// application will be exiting anyways
pub fn deinit(self: *Vaxis, alloc: ?std.mem.Allocator) void {
    if (self.tty) |*tty| {
        tty.deinit();
    }
    if (alloc) |a| {
        self.screen.deinit(a);
        self.screen_last.deinit(a);
    }
    if (self.renders > 0) {
        const tpr = @divTrunc(self.render_dur, self.renders);
        log.debug("total renders = {d}", .{self.renders});
        log.debug("microseconds per render = {d}", .{tpr});
    }
    self.unicode.deinit();
}

/// resize allocates a slice of cells equal to the number of cells
/// required to display the screen (ie width x height). Any previous screen is
/// freed when resizing. The cursor will be sent to it's home position and a
/// hardware clear-below-cursor will be sent
pub fn resize(self: *Vaxis, alloc: std.mem.Allocator, winsize: Winsize) !void {
    log.debug("resizing screen: width={d} height={d}", .{ winsize.cols, winsize.rows });
    self.screen.deinit(alloc);
    self.screen = try Screen.init(alloc, winsize, &self.unicode);
    self.screen.width_method = self.caps.unicode;
    // try self.screen.int(alloc, winsize.cols, winsize.rows);
    // we only init our current screen. This has the effect of redrawing
    // every cell
    self.screen_last.deinit(alloc);
    self.screen_last = try InternalScreen.init(alloc, winsize.cols, winsize.rows);
    var tty = self.tty orelse return;
    if (tty.state.alt_screen)
        _ = try tty.write(ctlseqs.home)
    else {
        _ = try tty.buffered_writer.write("\r");
        var i: usize = 0;
        while (i < tty.state.cursor.row) : (i += 1) {
            _ = try tty.buffered_writer.write(ctlseqs.ri);
        }
    }
    _ = try tty.write(ctlseqs.erase_below_cursor);
    try tty.flush();
}

/// returns a Window comprising of the entire terminal screen
pub fn window(self: *Vaxis) Window {
    return .{
        .x_off = 0,
        .y_off = 0,
        .width = self.screen.width,
        .height = self.screen.height,
        .screen = &self.screen,
    };
}

/// enter the alternate screen. The alternate screen will automatically
/// be exited if calling deinit while in the alt screen
pub fn enterAltScreen(self: *Vaxis) !void {
    if (self.tty) |*tty| {
        if (tty.state.alt_screen) return;
        _ = try tty.write(ctlseqs.smcup);
        try tty.flush();
        tty.state.alt_screen = true;
    }
}

/// exit the alternate screen
pub fn exitAltScreen(self: *Vaxis) !void {
    if (self.tty) |*tty| {
        if (!tty.state.alt_screen) return;
        _ = try tty.write(ctlseqs.rmcup);
        try tty.flush();
        tty.state.alt_screen = false;
    }
}

/// write queries to the terminal to determine capabilities. Individual
/// capabilities will be delivered to the client and possibly intercepted by
/// Vaxis to enable features
pub fn queryTerminal(self: *Vaxis) !void {
    try self.queryTerminalSend();

    // 1 second timeout
    std.Thread.Futex.timedWait(&self.query_futex, 0, 1 * std.time.ns_per_s) catch {};

    try self.enableDetectedFeatures();
}

/// write queries to the terminal to determine capabilities. This function
/// is only for use with a custom main loop. Call Vaxis.queryTerminal() if
/// you are using Loop.run()
pub fn queryTerminalSend(self: *Vaxis) !void {
    var tty = self.tty orelse return;

    // TODO: re-enable this
    // const colorterm = std.posix.getenv("COLORTERM") orelse "";
    // if (std.mem.eql(u8, colorterm, "truecolor") or
    //     std.mem.eql(u8, colorterm, "24bit"))
    // {
    //     if (@hasField(Event, "cap_rgb")) {
    //         self.postEvent(.cap_rgb);
    //     }
    // }

    // TODO: decide if we actually want to query for focus and sync. It
    // doesn't hurt to blindly use them
    // _ = try tty.write(ctlseqs.decrqm_focus);
    // _ = try tty.write(ctlseqs.decrqm_sync);
    _ = try tty.write(ctlseqs.decrqm_sgr_pixels);
    _ = try tty.write(ctlseqs.decrqm_unicode);
    _ = try tty.write(ctlseqs.decrqm_color_theme);
    // TODO: XTVERSION has a DCS response. uncomment when we can parse
    // that
    // _ = try tty.write(ctlseqs.xtversion);
    _ = try tty.write(ctlseqs.csi_u_query);
    _ = try tty.write(ctlseqs.kitty_graphics_query);
    // TODO: sixel geometry query interferes with F4 keys.
    // _ = try tty.write(ctlseqs.sixel_geometry_query);

    // TODO: XTGETTCAP queries ("RGB", "Smulx")

    _ = try tty.write(ctlseqs.primary_device_attrs);
    try tty.flush();
}

/// Enable features detected by responses to queryTerminal. This function
/// is only for use with a custom main loop. Call Vaxis.queryTerminal() if
/// you are using Loop.run()
pub fn enableDetectedFeatures(self: *Vaxis) !void {
    var tty = self.tty orelse return;

    // Apply any environment variables
    if (std.posix.getenv("ASCIINEMA_REC")) |_|
        self.sgr = .legacy;
    if (std.posix.getenv("TERMUX_VERSION")) |_|
        self.sgr = .legacy;
    if (std.posix.getenv("VHS_RECORD")) |_| {
        self.caps.unicode = .wcwidth;
        self.caps.kitty_keyboard = false;
    }
    if (std.posix.getenv("VAXIS_FORCE_LEGACY_SGR")) |_|
        self.sgr = .legacy;
    if (std.posix.getenv("VAXIS_FORCE_WCWIDTH")) |_|
        self.caps.unicode = .wcwidth;
    if (std.posix.getenv("VAXIS_FORCE_UNICODE")) |_|
        self.caps.unicode = .unicode;

    // enable detected features
    if (self.caps.kitty_keyboard) {
        try self.enableKittyKeyboard(self.opts.kitty_keyboard_flags);
    }
    if (self.caps.unicode == .unicode) {
        _ = try tty.write(ctlseqs.unicode_set);
    }
}

// the next render call will refresh the entire screen
pub fn queueRefresh(self: *Vaxis) void {
    self.refresh = true;
}

/// draws the screen to the terminal
pub fn render(self: *Vaxis) !void {
    var tty = self.tty orelse return;
    self.renders += 1;
    self.render_timer.reset();
    defer {
        self.render_dur += self.render_timer.read() / std.time.ns_per_us;
    }

    defer self.refresh = false;
    defer tty.flush() catch {};

    // Set up sync before we write anything
    // TODO: optimize sync so we only sync _when we have changes_. This
    // requires a smarter buffered writer, we'll probably have to write
    // our own
    _ = try tty.write(ctlseqs.sync_set);
    defer _ = tty.write(ctlseqs.sync_reset) catch {};

    // Send the cursor to 0,0
    // TODO: this needs to move after we optimize writes. We only do
    // this if we have an update to make. We also need to hide cursor
    // and then reshow it if needed
    _ = try tty.write(ctlseqs.hide_cursor);
    if (tty.state.alt_screen)
        _ = try tty.write(ctlseqs.home)
    else {
        _ = try tty.write("\r");
        var i: usize = 0;
        while (i < tty.state.cursor.row) : (i += 1) {
            _ = try tty.write(ctlseqs.ri);
        }
    }
    _ = try tty.write(ctlseqs.sgr_reset);

    // initialize some variables
    var reposition: bool = false;
    var row: usize = 0;
    var col: usize = 0;
    var cursor: Style = .{};
    var link: Hyperlink = .{};
    var cursor_pos: struct {
        row: usize = 0,
        col: usize = 0,
    } = .{};

    // Clear all images
    if (self.caps.kitty_graphics)
        _ = try tty.write(ctlseqs.kitty_graphics_clear);

    var i: usize = 0;
    while (i < self.screen.buf.len) {
        const cell = self.screen.buf[i];
        const w = blk: {
            if (cell.char.width != 0) break :blk cell.char.width;

            const method: gwidth.Method = self.caps.unicode;
            const width = gwidth.gwidth(cell.char.grapheme, method, &self.unicode.width_data) catch 1;
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
            reposition = true;
        }
        // If cell is the same as our last frame, we don't need to do
        // anything
        const last = self.screen_last.buf[i];
        if (!self.refresh and last.eql(cell) and !last.skipped and cell.image == null) {
            reposition = true;
            // Close any osc8 sequence we might be in before
            // repositioning
            if (link.uri.len > 0) {
                _ = try tty.write(ctlseqs.osc8_clear);
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

        // reposition the cursor, if needed
        if (reposition) {
            reposition = false;
            if (tty.state.alt_screen)
                try std.fmt.format(tty.buffered_writer.writer(), ctlseqs.cup, .{ row + 1, col + 1 })
            else {
                if (cursor_pos.row == row) {
                    const n = col - cursor_pos.col;
                    try std.fmt.format(tty.buffered_writer.writer(), ctlseqs.cuf, .{n});
                } else {
                    const n = row - cursor_pos.row;
                    var _i: usize = 0;
                    _ = try tty.buffered_writer.write("\r");
                    while (_i < n) : (_i += 1) {
                        _ = try tty.buffered_writer.write("\n");
                    }
                    if (col > 0)
                        try std.fmt.format(tty.buffered_writer.writer(), ctlseqs.cuf, .{col});
                }
            }
        }

        if (cell.image) |img| {
            try tty.buffered_writer.writer().print(
                ctlseqs.kitty_graphics_preamble,
                .{img.img_id},
            );
            if (img.options.pixel_offset) |offset| {
                try tty.buffered_writer.writer().print(
                    ",X={d},Y={d}",
                    .{ offset.x, offset.y },
                );
            }
            if (img.options.clip_region) |clip| {
                if (clip.x) |x|
                    try tty.buffered_writer.writer().print(
                        ",x={d}",
                        .{x},
                    );
                if (clip.y) |y|
                    try tty.buffered_writer.writer().print(
                        ",y={d}",
                        .{y},
                    );
                if (clip.width) |width|
                    try tty.buffered_writer.writer().print(
                        ",w={d}",
                        .{width},
                    );
                if (clip.height) |height|
                    try tty.buffered_writer.writer().print(
                        ",h={d}",
                        .{height},
                    );
            }
            if (img.options.size) |size| {
                if (size.rows) |rows|
                    try tty.buffered_writer.writer().print(
                        ",r={d}",
                        .{rows},
                    );
                if (size.cols) |cols|
                    try tty.buffered_writer.writer().print(
                        ",c={d}",
                        .{cols},
                    );
            }
            if (img.options.z_index) |z| {
                try tty.buffered_writer.writer().print(
                    ",z={d}",
                    .{z},
                );
            }
            try tty.buffered_writer.writer().writeAll(ctlseqs.kitty_graphics_closing);
        }

        // something is different, so let's loop through everything and
        // find out what

        // foreground
        if (!Cell.Color.eql(cursor.fg, cell.style.fg)) {
            const writer = tty.buffered_writer.writer();
            switch (cell.style.fg) {
                .default => _ = try tty.write(ctlseqs.fg_reset),
                .index => |idx| {
                    switch (idx) {
                        0...7 => try std.fmt.format(writer, ctlseqs.fg_base, .{idx}),
                        8...15 => try std.fmt.format(writer, ctlseqs.fg_bright, .{idx - 8}),
                        else => {
                            switch (self.sgr) {
                                .standard => try std.fmt.format(writer, ctlseqs.fg_indexed, .{idx}),
                                .legacy => try std.fmt.format(writer, ctlseqs.fg_indexed_legacy, .{idx}),
                            }
                        },
                    }
                },
                .rgb => |rgb| {
                    switch (self.sgr) {
                        .standard => try std.fmt.format(writer, ctlseqs.fg_rgb, .{ rgb[0], rgb[1], rgb[2] }),
                        .legacy => try std.fmt.format(writer, ctlseqs.fg_rgb_legacy, .{ rgb[0], rgb[1], rgb[2] }),
                    }
                },
            }
        }
        // background
        if (!Cell.Color.eql(cursor.bg, cell.style.bg)) {
            const writer = tty.buffered_writer.writer();
            switch (cell.style.bg) {
                .default => _ = try tty.write(ctlseqs.bg_reset),
                .index => |idx| {
                    switch (idx) {
                        0...7 => try std.fmt.format(writer, ctlseqs.bg_base, .{idx}),
                        8...15 => try std.fmt.format(writer, ctlseqs.bg_bright, .{idx - 8}),
                        else => {
                            switch (self.sgr) {
                                .standard => try std.fmt.format(writer, ctlseqs.bg_indexed, .{idx}),
                                .legacy => try std.fmt.format(writer, ctlseqs.bg_indexed_legacy, .{idx}),
                            }
                        },
                    }
                },
                .rgb => |rgb| {
                    switch (self.sgr) {
                        .standard => try std.fmt.format(writer, ctlseqs.bg_rgb, .{ rgb[0], rgb[1], rgb[2] }),
                        .legacy => try std.fmt.format(writer, ctlseqs.bg_rgb_legacy, .{ rgb[0], rgb[1], rgb[2] }),
                    }
                },
            }
        }
        // underline color
        if (!Cell.Color.eql(cursor.ul, cell.style.ul)) {
            const writer = tty.buffered_writer.writer();
            switch (cell.style.bg) {
                .default => _ = try tty.write(ctlseqs.ul_reset),
                .index => |idx| {
                    switch (self.sgr) {
                        .standard => try std.fmt.format(writer, ctlseqs.ul_indexed, .{idx}),
                        .legacy => try std.fmt.format(writer, ctlseqs.ul_indexed_legacy, .{idx}),
                    }
                },
                .rgb => |rgb| {
                    switch (self.sgr) {
                        .standard => try std.fmt.format(writer, ctlseqs.ul_rgb, .{ rgb[0], rgb[1], rgb[2] }),
                        .legacy => try std.fmt.format(writer, ctlseqs.ul_rgb_legacy, .{ rgb[0], rgb[1], rgb[2] }),
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
            _ = try tty.write(seq);
        }
        // bold
        if (cursor.bold != cell.style.bold) {
            const seq = switch (cell.style.bold) {
                true => ctlseqs.bold_set,
                false => ctlseqs.bold_dim_reset,
            };
            _ = try tty.write(seq);
            if (cell.style.dim) {
                _ = try tty.write(ctlseqs.dim_set);
            }
        }
        // dim
        if (cursor.dim != cell.style.dim) {
            const seq = switch (cell.style.dim) {
                true => ctlseqs.dim_set,
                false => ctlseqs.bold_dim_reset,
            };
            _ = try tty.write(seq);
            if (cell.style.bold) {
                _ = try tty.write(ctlseqs.bold_set);
            }
        }
        // dim
        if (cursor.italic != cell.style.italic) {
            const seq = switch (cell.style.italic) {
                true => ctlseqs.italic_set,
                false => ctlseqs.italic_reset,
            };
            _ = try tty.write(seq);
        }
        // dim
        if (cursor.blink != cell.style.blink) {
            const seq = switch (cell.style.blink) {
                true => ctlseqs.blink_set,
                false => ctlseqs.blink_reset,
            };
            _ = try tty.write(seq);
        }
        // reverse
        if (cursor.reverse != cell.style.reverse) {
            const seq = switch (cell.style.reverse) {
                true => ctlseqs.reverse_set,
                false => ctlseqs.reverse_reset,
            };
            _ = try tty.write(seq);
        }
        // invisible
        if (cursor.invisible != cell.style.invisible) {
            const seq = switch (cell.style.invisible) {
                true => ctlseqs.invisible_set,
                false => ctlseqs.invisible_reset,
            };
            _ = try tty.write(seq);
        }
        // strikethrough
        if (cursor.strikethrough != cell.style.strikethrough) {
            const seq = switch (cell.style.strikethrough) {
                true => ctlseqs.strikethrough_set,
                false => ctlseqs.strikethrough_reset,
            };
            _ = try tty.write(seq);
        }

        // url
        if (!std.mem.eql(u8, link.uri, cell.link.uri)) {
            var ps = cell.link.params;
            if (cell.link.uri.len == 0) {
                // Empty out the params no matter what if we don't have
                // a url
                ps = "";
            }
            const writer = tty.buffered_writer.writer();
            try std.fmt.format(writer, ctlseqs.osc8, .{ ps, cell.link.uri });
        }
        _ = try tty.write(cell.char.grapheme);
        cursor_pos.col = col + w;
        cursor_pos.row = row;
    }
    if (self.screen.cursor_vis) {
        if (tty.state.alt_screen) {
            try std.fmt.format(
                tty.buffered_writer.writer(),
                ctlseqs.cup,
                .{
                    self.screen.cursor_row + 1,
                    self.screen.cursor_col + 1,
                },
            );
        } else {
            // TODO: position cursor relative to current location
            _ = try tty.write("\r");
            var r: usize = 0;
            if (self.screen.cursor_row >= cursor_pos.row) {
                while (r < (self.screen.cursor_row - cursor_pos.row)) : (r += 1) {
                    _ = try tty.write("\n");
                }
            } else {
                while (r < (cursor_pos.row - self.screen.cursor_row)) : (r += 1) {
                    _ = try tty.write(ctlseqs.ri);
                }
            }
            if (self.screen.cursor_col > 0) {
                try std.fmt.format(tty.buffered_writer.writer(), ctlseqs.cuf, .{self.screen.cursor_col});
            }
        }
        self.tty.?.state.cursor.row = self.screen.cursor_row;
        self.tty.?.state.cursor.col = self.screen.cursor_col;
        _ = try tty.write(ctlseqs.show_cursor);
    } else {
        self.tty.?.state.cursor.row = cursor_pos.row;
        self.tty.?.state.cursor.col = cursor_pos.col;
    }
    if (self.screen.mouse_shape != self.screen_last.mouse_shape) {
        try std.fmt.format(
            tty.buffered_writer.writer(),
            ctlseqs.osc22_mouse_shape,
            .{@tagName(self.screen.mouse_shape)},
        );
        self.screen_last.mouse_shape = self.screen.mouse_shape;
    }
    if (self.screen.cursor_shape != self.screen_last.cursor_shape) {
        try std.fmt.format(
            tty.buffered_writer.writer(),
            ctlseqs.cursor_shape,
            .{@intFromEnum(self.screen.cursor_shape)},
        );
        self.screen_last.cursor_shape = self.screen.cursor_shape;
    }
}

fn enableKittyKeyboard(self: *Vaxis, flags: Key.KittyFlags) !void {
    if (self.tty) |*tty| {
        const flag_int: u5 = @bitCast(flags);
        try std.fmt.format(
            tty.buffered_writer.writer(),
            ctlseqs.csi_u_push,
            .{
                flag_int,
            },
        );
        try tty.flush();
        tty.state.kitty_keyboard = true;
    }
}

/// send a system notification
pub fn notify(self: *Vaxis, title: ?[]const u8, body: []const u8) !void {
    if (self.tty == null) return;
    if (title) |t| {
        try std.fmt.format(
            self.tty.?.buffered_writer.writer(),
            ctlseqs.osc777_notify,
            .{ t, body },
        );
    } else {
        try std.fmt.format(
            self.tty.?.buffered_writer.writer(),
            ctlseqs.osc9_notify,
            .{body},
        );
    }
    try self.tty.?.flush();
}

/// sets the window title
pub fn setTitle(self: *Vaxis, title: []const u8) !void {
    if (self.tty == null) return;
    try std.fmt.format(
        self.tty.?.buffered_writer.writer(),
        ctlseqs.osc2_set_title,
        .{title},
    );
    try self.tty.?.flush();
}

// turn bracketed paste on or off. An event will be sent at the
// beginning and end of a detected paste. All keystrokes between these
// events were pasted
pub fn setBracketedPaste(self: *Vaxis, enable: bool) !void {
    if (self.tty) |*tty| {
        const seq = if (enable)
            ctlseqs.bp_set
        else
            ctlseqs.bp_reset;
        _ = try tty.write(seq);
        try tty.flush();
        tty.state.bracketed_paste = enable;
    }
}

/// set the mouse shape
pub fn setMouseShape(self: *Vaxis, shape: Shape) void {
    self.screen.mouse_shape = shape;
}

/// Change the mouse reporting mode
pub fn setMouseMode(self: *Vaxis, enable: bool) !void {
    if (self.tty) |*tty| {
        if (enable) {
            tty.state.mouse = true;
            if (self.caps.sgr_pixels) {
                log.debug("enabling mouse mode: pixel coordinates", .{});
                tty.state.pixel_mouse = true;
                _ = try tty.write(ctlseqs.mouse_set_pixels);
            } else {
                log.debug("enabling mouse mode: cell coordinates", .{});
                _ = try tty.write(ctlseqs.mouse_set);
            }
        } else {
            _ = try tty.write(ctlseqs.mouse_reset);
        }
        try tty.flush();
    }
}

/// Translate pixel mouse coordinates to cell + offset
pub fn translateMouse(self: Vaxis, mouse: Mouse) Mouse {
    var result = mouse;
    const tty = self.tty orelse return result;
    if (tty.state.pixel_mouse) {
        std.debug.assert(mouse.xoffset == 0);
        std.debug.assert(mouse.yoffset == 0);
        const xpos = mouse.col;
        const ypos = mouse.row;
        const xextra = self.screen.width_pix % self.screen.width;
        const yextra = self.screen.height_pix % self.screen.height;
        const xcell = (self.screen.width_pix - xextra) / self.screen.width;
        const ycell = (self.screen.height_pix - yextra) / self.screen.height;
        result.col = xpos / xcell;
        result.row = ypos / ycell;
        result.xoffset = xpos % xcell;
        result.yoffset = ypos % ycell;
        log.debug("translateMouse x/ypos:{d}/{d} cell:{d}/{d} xtra:{d}/{d} col/rol:{d}/{d} x/y:{d}/{d}", .{
            xpos,           ypos,
            xcell,          ycell,
            xextra,         yextra,
            result.col,     result.row,
            result.xoffset, result.yoffset,
        });
    } else {
        log.debug("translateMouse col/rol:{d}/{d} x/y:{d}/{d}", .{
            result.col,     result.row,
            result.xoffset, result.yoffset,
        });
    }
    return result;
}

pub fn loadImage(
    self: *Vaxis,
    alloc: std.mem.Allocator,
    src: Image.Source,
) !Image {
    if (!self.caps.kitty_graphics) return error.NoGraphicsCapability;
    var tty = self.tty orelse return error.NoTTY;
    defer self.next_img_id += 1;

    const writer = tty.buffered_writer.writer();

    var img = switch (src) {
        .path => |path| try zigimg.Image.fromFilePath(alloc, path),
        .mem => |bytes| try zigimg.Image.fromMemory(alloc, bytes),
    };
    defer img.deinit();
    const png_buf = try alloc.alloc(u8, img.imageByteSize());
    defer alloc.free(png_buf);
    const png = try img.writeToMemory(png_buf, .{ .png = .{} });
    const b64_buf = try alloc.alloc(u8, base64Encoder.calcSize(png.len));
    const encoded = base64Encoder.encode(b64_buf, png);
    defer alloc.free(b64_buf);

    const id = self.next_img_id;

    if (encoded.len < 4096) {
        try std.fmt.format(
            writer,
            "\x1b_Gf=100,i={d};{s}\x1b\\",
            .{
                id,
                encoded,
            },
        );
    } else {
        var n: usize = 4096;

        try std.fmt.format(
            writer,
            "\x1b_Gf=100,i={d},m=1;{s}\x1b\\",
            .{ id, encoded[0..n] },
        );
        while (n < encoded.len) : (n += 4096) {
            const end: usize = @min(n + 4096, encoded.len);
            const m: u2 = if (end == encoded.len) 0 else 1;
            try std.fmt.format(
                writer,
                "\x1b_Gm={d};{s}\x1b\\",
                .{
                    m,
                    encoded[n..end],
                },
            );
        }
    }
    try tty.buffered_writer.flush();
    return .{
        .id = id,
        .width = img.width,
        .height = img.height,
    };
}

/// deletes an image from the terminal's memory
pub fn freeImage(self: Vaxis, id: u32) void {
    var tty = self.tty orelse return;
    const writer = tty.buffered_writer.writer();
    std.fmt.format(writer, "\x1b_Ga=d,d=I,i={d};\x1b\\", .{id}) catch |err| {
        log.err("couldn't delete image {d}: {}", .{ id, err });
        return;
    };
    tty.buffered_writer.flush() catch |err| {
        log.err("couldn't flush writer: {}", .{err});
    };
}

pub fn copyToSystemClipboard(self: Vaxis, text: []const u8, encode_allocator: std.mem.Allocator) !void {
    var tty = self.tty orelse return;
    const encoder = std.base64.standard.Encoder;
    const size = encoder.calcSize(text.len);
    const buf = try encode_allocator.alloc(u8, size);
    const b64 = encoder.encode(buf, text);
    defer encode_allocator.free(buf);
    try std.fmt.format(
        tty.buffered_writer.writer(),
        ctlseqs.osc52_clipboard_copy,
        .{b64},
    );
    try tty.flush();
}

pub fn requestSystemClipboard(self: Vaxis) !void {
    if (self.opts.system_clipboard_allocator == null) return error.NoClipboardAllocator;
    var tty = self.tty orelse return;
    try std.fmt.format(
        tty.buffered_writer.writer(),
        ctlseqs.osc52_clipboard_request,
        .{},
    );
    try tty.flush();
}
