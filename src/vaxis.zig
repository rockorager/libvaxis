const std = @import("std");
const builtin = @import("builtin");
const atomic = std.atomic;
const base64 = std.base64.standard.Encoder;

const Queue = @import("queue.zig").Queue;
const ctlseqs = @import("ctlseqs.zig");
const Tty = if (builtin.os.tag.isDarwin()) @import("Tty-macos.zig") else @import("Tty.zig");
const Winsize = Tty.Winsize;
const Key = @import("Key.zig");
const Screen = @import("Screen.zig");
const InternalScreen = @import("InternalScreen.zig");
const Window = @import("Window.zig");
const Options = @import("Options.zig");
const Style = @import("Cell.zig").Style;
const Hyperlink = @import("Cell.zig").Hyperlink;
const gwidth = @import("gwidth.zig");
const Shape = @import("Mouse.zig").Shape;
const Image = @import("Image.zig");
const zigimg = @import("zigimg");

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

        pub const Event = T;

        pub const Capabilities = struct {
            kitty_keyboard: bool = false,
            kitty_graphics: bool = false,
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

        state: struct {
            /// if we are in the alt screen
            alt_screen: bool = false,
            /// if we have entered kitty keyboard
            kitty_keyboard: bool = false,
            bracketed_paste: bool = false,
            mouse: bool = false,
        } = .{},

        caps: Capabilities = .{},

        /// if we should redraw the entire screen on the next render
        refresh: bool = false,

        /// blocks the main thread until a DA1 query has been received, or the
        /// futex times out
        query_futex: atomic.Value(u32) = atomic.Value(u32).init(0),

        // images
        next_img_id: u32 = 1,

        // statistics
        renders: usize = 0,
        render_dur: i128 = 0,

        /// Initialize Vaxis with runtime options
        pub fn init(_: Options) !Self {
            return .{
                .queue = .{},
                .tty = null,
                .screen = .{},
                .screen_last = .{},
            };
        }

        /// Resets the terminal to it's original state. If an allocator is
        /// passed, this will free resources associated with Vaxis. This is left as an
        /// optional so applications can choose to not free resources when the
        /// application will be exiting anyways
        pub fn deinit(self: *Self, alloc: ?std.mem.Allocator) void {
            if (self.tty) |_| {
                var tty = &self.tty.?;
                if (self.state.kitty_keyboard) {
                    _ = tty.write(ctlseqs.csi_u_pop) catch {};
                }
                if (self.state.mouse) {
                    _ = tty.write(ctlseqs.mouse_reset) catch {};
                }
                if (self.state.bracketed_paste) {
                    _ = tty.write(ctlseqs.bp_reset) catch {};
                }
                if (self.state.alt_screen) {
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
                log.debug("total renders = {d}", .{self.renders});
                log.debug("microseconds per render = {d}", .{tpr});
            }
        }

        /// spawns the input thread to start listening to the tty for input
        pub fn startReadThread(self: *Self) !void {
            self.tty = try Tty.init();
            // run our tty read loop in it's own thread
            _ = try std.Thread.spawn(.{}, Tty.run, .{ &self.tty.?, T, self });
            // try read_thread.setName("tty");
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

        /// blocks until an event is available. Useful when your application is
        /// operating on a poll + drain architecture (see tryEvent)
        pub fn pollEvent(self: *Self) void {
            self.queue.poll();
        }

        /// returns an event if one is available, otherwise null. Non-blocking.
        pub fn tryEvent(self: *Self) ?Event {
            return self.queue.tryPop();
        }

        /// posts an event into the event queue. Will block if there is not
        /// capacity for the event
        pub fn postEvent(self: *Self, event: T) void {
            self.queue.push(event);
        }

        /// resize allocates a slice of cells equal to the number of cells
        /// required to display the screen (ie width x height). Any previous screen is
        /// freed when resizing
        pub fn resize(self: *Self, alloc: std.mem.Allocator, winsize: Winsize) !void {
            log.debug("resizing screen: width={d} height={d}", .{ winsize.cols, winsize.rows });
            self.screen.deinit(alloc);
            self.screen = try Screen.init(alloc, winsize);
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
        pub fn enterAltScreen(self: *Self) !void {
            if (self.state.alt_screen) return;
            var tty = self.tty orelse return;
            _ = try tty.write(ctlseqs.smcup);
            try tty.flush();
            self.state.alt_screen = true;
        }

        /// exit the alternate screen
        pub fn exitAltScreen(self: *Self) !void {
            if (!self.state.alt_screen) return;
            var tty = self.tty orelse return;
            _ = try tty.write(ctlseqs.rmcup);
            try tty.flush();
            self.state.alt_screen = false;
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
                if (@hasField(Event, "cap_rgb")) {
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
            _ = try tty.write(ctlseqs.kitty_graphics_query);
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
            var link: Hyperlink = .{};

            // Clear all images
            _ = try tty.write(ctlseqs.kitty_graphics_clear);

            var i: usize = 0;
            while (i < self.screen.buf.len) {
                const cell = self.screen.buf[i];
                defer {
                    // advance by the width of this char mod 1
                    const w = blk: {
                        if (cell.char.width != 0) break :blk cell.char.width;

                        const method: gwidth.Method = if (self.caps.unicode) .unicode else .wcwidth;
                        const width = gwidth.gwidth(cell.char.grapheme, method) catch 1;
                        break :blk @max(1, width);
                    };
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
                    try std.fmt.format(tty.buffered_writer.writer(), ctlseqs.cup, .{ row + 1, col + 1 });
                }

                if (cell.image) |img| {
                    if (img.size) |size| {
                        try std.fmt.format(
                            tty.buffered_writer.writer(),
                            ctlseqs.kitty_graphics_scale,
                            .{ img.img_id, img.z_index, size.cols, size.rows },
                        );
                    } else {
                        try std.fmt.format(
                            tty.buffered_writer.writer(),
                            ctlseqs.kitty_graphics_place,
                            .{ img.img_id, img.z_index },
                        );
                    }
                }

                // something is different, so let's loop through everything and
                // find out what

                // foreground
                if (!std.meta.eql(cursor.fg, cell.style.fg)) {
                    const writer = tty.buffered_writer.writer();
                    switch (cell.style.fg) {
                        .default => _ = try tty.write(ctlseqs.fg_reset),
                        .index => |idx| {
                            switch (idx) {
                                0...7 => try std.fmt.format(writer, ctlseqs.fg_base, .{idx}),
                                8...15 => try std.fmt.format(writer, ctlseqs.fg_bright, .{idx - 8}),
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
                                8...15 => try std.fmt.format(writer, ctlseqs.bg_bright, .{idx - 8}),
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
                if (!std.meta.eql(link.uri, cell.link.uri)) {
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
            if (self.screen.mouse_shape != self.screen_last.mouse_shape) {
                try std.fmt.format(
                    tty.buffered_writer.writer(),
                    ctlseqs.osc22_mouse_shape,
                    .{@tagName(self.screen.mouse_shape)},
                );
            }
        }

        fn enableKittyKeyboard(self: *Self, flags: Key.KittyFlags) !void {
            self.state.kitty_keyboard = true;
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
            try self.tty.?.flush();
        }

        /// sets the window title
        pub fn setTitle(self: *Self, title: []const u8) !void {
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
        pub fn setBracketedPaste(self: *Self, enable: bool) !void {
            if (self.tty == null) return;
            self.state.bracketed_paste = enable;
            const seq = if (enable) {
                self.state.bracketed_paste = true;
                ctlseqs.bp_set;
            } else {
                self.state.bracketed_paste = true;
                ctlseqs.bp_reset;
            };
            _ = try self.tty.?.write(seq);
            try self.tty.?.flush();
        }

        /// set the mouse shape
        pub fn setMouseShape(self: *Self, shape: Shape) void {
            self.screen.mouse_shape = shape;
        }

        /// turn mouse reporting on or off
        pub fn setMouseMode(self: *Self, enable: bool) !void {
            var tty = self.tty orelse return;
            self.state.mouse = enable;
            if (enable) {
                _ = try tty.write(ctlseqs.mouse_set);
                try tty.flush();
            } else {
                _ = try tty.write(ctlseqs.mouse_reset);
                try tty.flush();
            }
        }

        pub fn loadImage(
            self: *Self,
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
            const b64_buf = try alloc.alloc(u8, base64.calcSize(png.len));
            const encoded = base64.encode(b64_buf, png);
            defer alloc.free(b64_buf);

            const id = self.next_img_id;

            log.debug("transmitting kitty image: id={d}, len={d}", .{ id, encoded.len });

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
        pub fn freeImage(self: Self, id: u32) void {
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
    };
}

// test "Vaxis: event queueing" {
// const Event = union(enum) {
// key: void,
// };
// var vx: Vaxis(Event) = try Vaxis(Event).init(.{});
// defer vx.deinit(null);
// vx.postEvent(.{ .key = {} });
// const event = vx.nextEvent();
// try std.testing.expect(event == .key);
// }
