const std = @import("std");
const atomic = std.atomic;

const Queue = @import("queue.zig").Queue;
const ctlseqs = @import("ctlseqs.zig");
const Tty = @import("Tty.zig");
const Winsize = Tty.Winsize;
const Key = @import("Key.zig");
const Screen = @import("Screen.zig");
const InternalScreen = @import("InternalScreen.zig");
const Window = @import("Window.zig");
const Options = @import("Options.zig");
const Style = @import("cell.zig").Style;
const strWidth = @import("ziglyph").display_width.strWidth;
const gwidth = @import("gwidth.zig");

/// Vaxis is the entrypoint for a Vaxis application. The provided type T should
/// be a tagged union which contains all of the events the application will
/// handle. Vaxis will look for the following fields on the union and, if
/// found, emit them via the "nextEvent" method
///
/// The following events are available:
/// - `key_press: Key`, for key press events
/// - `winsize: Winsize`, for resize events. Must call app.resize when receiving
///    this event
/// - `focus_in` and `focus_out` for focus events
pub fn Vaxis(comptime T: type) type {
    return struct {
        const Self = @This();

        const log = std.log.scoped(.vaxis);

        pub const EventType = T;

        pub const Capabilities = struct {
            kitty_keyboard: bool = false,
            rgb: bool = false,
            unicode: bool = false,
        };

        /// the event queue for Vaxis
        //
        // TODO: is 512 ok?
        queue: Queue(T, 512),

        tty: ?Tty,

        /// the screen we write to
        screen: Screen,
        /// The last screen we drew. We keep this so we can efficiently update on
        /// the next render
        screen_last: InternalScreen = undefined,

        /// alt_screen state. We track so we can exit on deinit
        alt_screen: bool,

        /// if we have entered kitty keyboard
        kitty_keyboard: bool = false,

        caps: Capabilities = .{},

        /// if we should redraw the entire screen on the next render
        refresh: bool = false,

        /// blocks the main thread until a DA1 query has been received, or the
        /// futex times out
        query_futex: atomic.Value(u32) = atomic.Value(u32).init(0),

        // statistics
        renders: usize = 0,
        render_dur: i128 = 0,

        /// Initialize Vaxis with runtime options
        pub fn init(_: Options) !Self {
            return Self{
                .queue = .{},
                .tty = null,
                .screen = .{},
                .screen_last = .{},
                .alt_screen = false,
            };
        }

        /// Resets the terminal to it's original state. If an allocator is
        /// passed, this will free resources associated with Vaxis. This is left as an
        /// optional so applications can choose to not free resources when the
        /// application will be exiting anyways
        pub fn deinit(self: *Self, alloc: ?std.mem.Allocator) void {
            if (self.tty) |_| {
                var tty = &self.tty.?;
                if (self.kitty_keyboard) {
                    _ = tty.write(ctlseqs.csi_u_pop) catch {};
                }
                if (self.alt_screen) {
                    _ = tty.write(ctlseqs.rmcup) catch {};
                }
                tty.flush() catch {};
                tty.deinit();
            }
            if (alloc) |a| {
                self.screen.deinit(a);
                self.screen_last.deinit(a);
            }
            if (self.renders > 0) {
                const tpr = @divTrunc(self.render_dur, self.renders);
                log.info("total renders = {d}", .{self.renders});
                log.info("microseconds per render = {d}", .{tpr});
            }
        }

        /// spawns the input thread to start listening to the tty for input
        pub fn startReadThread(self: *Self) !void {
            self.tty = try Tty.init();
            // run our tty read loop in it's own thread
            const read_thread = try std.Thread.spawn(.{}, Tty.run, .{ &self.tty.?, T, self });
            try read_thread.setName("tty");
        }

        /// stops reading from the tty
        pub fn stopReadThread(self: *Self) void {
            if (self.tty) |_| {
                var tty = &self.tty.?;
                tty.stop();
            }
        }

        /// returns the next available event, blocking until one is available
        pub fn nextEvent(self: *Self) T {
            return self.queue.pop();
        }

        /// posts an event into the event queue. Will block if there is not
        /// capacity for the event
        pub fn postEvent(self: *Self, event: T) void {
            self.queue.push(event);
        }

        /// resize allocates a slice of cellsequal to the number of cells
        /// required to display the screen (ie width x height). Any previous screen is
        /// freed when resizing
        pub fn resize(self: *Self, alloc: std.mem.Allocator, winsize: Winsize) !void {
            log.debug("resizing screen: width={d} height={d}", .{ winsize.cols, winsize.rows });
            self.screen.deinit(alloc);
            self.screen = try Screen.init(alloc, winsize.cols, winsize.rows);
            self.screen.unicode = self.caps.unicode;
            // try self.screen.int(alloc, winsize.cols, winsize.rows);
            // we only init our current screen. This has the effect of redrawing
            // every cell
            self.screen_last.deinit(alloc);
            self.screen_last = try InternalScreen.init(alloc, winsize.cols, winsize.rows);
            // try self.screen_last.resize(alloc, winsize.cols, winsize.rows);
        }

        /// returns a Window comprising of the entire terminal screen
        pub fn window(self: *Self) Window {
            return Window{
                .x_off = 0,
                .y_off = 0,
                .width = self.screen.width,
                .height = self.screen.height,
                .screen = &self.screen,
            };
        }

        /// enter the alternate screen. The alternate screen will automatically
        /// be exited if calling deinit while in the alt screen
        pub fn enterAltScreen(self: *Self) !void {
            if (self.alt_screen) return;
            var tty = self.tty orelse return;
            _ = try tty.write(ctlseqs.smcup);
            try tty.flush();
            self.alt_screen = true;
        }

        /// exit the alternate screen
        pub fn exitAltScreen(self: *Self) !void {
            if (!self.alt_screen) return;
            var tty = self.tty orelse return;
            _ = try tty.write(ctlseqs.rmcup);
            try tty.flush();
            self.alt_screen = false;
        }

        /// write queries to the terminal to determine capabilities. Individual
        /// capabilities will be delivered to the client and possibly intercepted by
        /// Vaxis to enable features
        pub fn queryTerminal(self: *Self) !void {
            var tty = self.tty orelse return;

            const colorterm = std.os.getenv("COLORTERM") orelse "";
            if (std.mem.eql(u8, colorterm, "truecolor") or
                std.mem.eql(u8, colorterm, "24bit"))
            {
                if (@hasField(EventType, "cap_rgb")) {
                    self.postEvent(.cap_rgb);
                }
            }

            // TODO: decide if we actually want to query for focus and sync. It
            // doesn't hurt to blindly use them
            // _ = try tty.write(ctlseqs.decrqm_focus);
            // _ = try tty.write(ctlseqs.decrqm_sync);
            _ = try tty.write(ctlseqs.decrqm_unicode);
            _ = try tty.write(ctlseqs.decrqm_color_theme);
            // TODO: XTVERSION has a DCS response. uncomment when we can parse
            // that
            // _ = try tty.write(ctlseqs.xtversion);
            _ = try tty.write(ctlseqs.csi_u_query);
            // TODO: KITTY_GRAPHICS has an APC response. uncomment when we can
            // parse that
            // that
            // _ = try tty.write(ctlseqs.kitty_graphics_query);
            // TODO: sixel geometry query interferes with F4 keys.
            // _ = try tty.write(ctlseqs.sixel_geometry_query);

            // TODO: XTGETTCAP queries ("RGB", "Smulx")

            _ = try tty.write(ctlseqs.primary_device_attrs);
            try tty.flush();

            // 1 second timeout
            std.Thread.Futex.timedWait(&self.query_futex, 0, 1 * std.time.ns_per_s) catch {};

            // enable detected features
            if (self.caps.kitty_keyboard) {
                try self.enableKittyKeyboard(.{});
            }
            if (self.caps.unicode) {
                _ = try tty.write(ctlseqs.unicode_set);
            }
        }

        // the next render call will refresh the entire screen
        pub fn queueRefresh(self: *Self) void {
            self.refresh = true;
        }

        /// draws the screen to the terminal
        pub fn render(self: *Self) !void {
            var tty = self.tty orelse return;
            self.renders += 1;
            const timer_start = std.time.microTimestamp();
            defer {
                self.render_dur += std.time.microTimestamp() - timer_start;
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
            _ = try tty.write(ctlseqs.home);
            _ = try tty.write(ctlseqs.sgr_reset);

            // initialize some variables
            var reposition: bool = false;
            var row: usize = 0;
            var col: usize = 0;
            var cursor: Style = .{};

            var i: usize = 0;
            while (i < self.screen.buf.len) {
                const cell = self.screen.buf[i];
                defer {
                    // advance by the width of this char mod 1
                    const method: gwidth.Method = if (self.caps.unicode) .unicode else .wcwidth;
                    const w = gwidth.gwidth(cell.char.grapheme, method) catch 1;
                    var j = i + 1;
                    while (j < i + w) : (j += 1) {
                        self.screen_last.buf[j].skipped = true;
                    }
                    col += w;
                    i += w;
                }
                if (col >= self.screen.width) {
                    row += 1;
                    col = 0;
                }
                // If cell is the same as our last frame, we don't need to do
                // anything
                const last = self.screen_last.buf[i];
                if (!self.refresh and last.eql(cell) and !last.skipped) {
                    reposition = true;
                    // Close any osc8 sequence we might be in before
                    // repositioning
                    if (cursor.url) |_| {
                        _ = try tty.write(ctlseqs.osc8_clear);
                    }
                    continue;
                }
                self.screen_last.buf[i].skipped = false;
                defer cursor = cell.style;
                // Set this cell in the last frame
                self.screen_last.writeCell(col, row, cell.char.grapheme, cell.style);

                // reposition the cursor, if needed
                if (reposition) {
                    try std.fmt.format(tty.buffered_writer.writer(), ctlseqs.cup, .{ row + 1, col + 1 });
                }

                // something is different, so let's loop throuugh everything and
                // find out what

                // foreground
                if (!std.meta.eql(cursor.fg, cell.style.fg)) {
                    const writer = tty.buffered_writer.writer();
                    switch (cell.style.fg) {
                        .default => _ = try tty.write(ctlseqs.fg_reset),
                        .index => |idx| {
                            switch (idx) {
                                0...7 => try std.fmt.format(writer, ctlseqs.fg_base, .{idx}),
                                8...15 => try std.fmt.format(writer, ctlseqs.fg_bright, .{idx}),
                                else => try std.fmt.format(writer, ctlseqs.fg_indexed, .{idx}),
                            }
                        },
                        .rgb => |rgb| {
                            try std.fmt.format(writer, ctlseqs.fg_rgb, .{ rgb[0], rgb[1], rgb[2] });
                        },
                    }
                }
                // background
                if (!std.meta.eql(cursor.bg, cell.style.bg)) {
                    const writer = tty.buffered_writer.writer();
                    switch (cell.style.bg) {
                        .default => _ = try tty.write(ctlseqs.bg_reset),
                        .index => |idx| {
                            switch (idx) {
                                0...7 => try std.fmt.format(writer, ctlseqs.bg_base, .{idx}),
                                8...15 => try std.fmt.format(writer, ctlseqs.bg_bright, .{idx}),
                                else => try std.fmt.format(writer, ctlseqs.bg_indexed, .{idx}),
                            }
                        },
                        .rgb => |rgb| {
                            try std.fmt.format(writer, ctlseqs.bg_rgb, .{ rgb[0], rgb[1], rgb[2] });
                        },
                    }
                }
                // underline color
                if (!std.meta.eql(cursor.ul, cell.style.ul)) {
                    const writer = tty.buffered_writer.writer();
                    switch (cell.style.bg) {
                        .default => _ = try tty.write(ctlseqs.ul_reset),
                        .index => |idx| {
                            try std.fmt.format(writer, ctlseqs.ul_indexed, .{idx});
                        },
                        .rgb => |rgb| {
                            try std.fmt.format(writer, ctlseqs.ul_rgb, .{ rgb[0], rgb[1], rgb[2] });
                        },
                    }
                }
                // underline style
                if (!std.meta.eql(cursor.ul_style, cell.style.ul_style)) {
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
                if (!std.meta.eql(cursor.url, cell.style.url)) {
                    const url = cell.style.url orelse "";
                    var ps = cell.style.url_params orelse "";
                    if (url.len == 0) {
                        // Empty out the params no matter what if we don't have
                        // a url
                        ps = "";
                    }
                    const writer = tty.buffered_writer.writer();
                    try std.fmt.format(writer, ctlseqs.osc8, .{ ps, url });
                }
                _ = try tty.write(cell.char.grapheme);
            }
            if (self.screen.cursor_vis) {
                try std.fmt.format(
                    tty.buffered_writer.writer(),
                    ctlseqs.cup,
                    .{
                        self.screen.cursor_row + 1,
                        self.screen.cursor_col + 1,
                    },
                );
                _ = try tty.write(ctlseqs.show_cursor);
            }
        }

        fn enableKittyKeyboard(self: *Self, flags: Key.KittyFlags) !void {
            self.kitty_keyboard = true;
            const flag_int: u5 = @bitCast(flags);
            try std.fmt.format(
                self.tty.?.buffered_writer.writer(),
                ctlseqs.csi_u_push,
                .{
                    flag_int,
                },
            );
            try self.tty.?.flush();
        }

        /// send a system notification
        pub fn notify(self: *Self, title: ?[]const u8, body: []const u8) !void {
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
        }

        /// sets the window title
        pub fn setTitle(self: *Self, title: []const u8) !void {
            if (self.tty == null) return;
            try std.fmt.format(
                self.tty.?.buffered_writer.writer(),
                ctlseqs.osc2_set_title,
                .{title},
            );
        }
    };
}

test "Vaxis: event queueing" {
    const Event = union(enum) {
        key,
    };
    var vx: Vaxis(Event) = try Vaxis(Event).init(.{});
    defer vx.deinit(null);
    vx.postEvent(.key);
    const event = vx.nextEvent();
    try std.testing.expect(event == .key);
}
