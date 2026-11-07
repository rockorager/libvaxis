const std = @import("std");
const builtin = @import("builtin");

const GraphemeCache = @import("GraphemeCache.zig");
const Parser = @import("Parser.zig");
const Queue = @import("queue.zig").Queue;
const vaxis = @import("main.zig");
const Tty = vaxis.Tty;
const Vaxis = @import("Vaxis.zig");

const log = std.log.scoped(.vaxis);

pub fn Loop(comptime T: type) type {
    return struct {
        const Self = @This();

        const Event = T;

        io: std.Io,
        tty: *Tty,
        vaxis: *Vaxis,

        queue: Queue(T, 512),
        thread: ?std.Io.Future(void) = null,
        // Queued key text must outlive the input task, including on failure.
        cache: GraphemeCache = .{},
        resize_handler_installed: bool = false,

        /// Initialize the event loop. This is an intrusive init so that we have
        /// a stable pointer to register signal callbacks with posix TTYs
        pub fn init(io: std.Io, tty: *Tty, vx: *Vaxis) Self {
            return .{
                .io = io,
                .tty = tty,
                .vaxis = vx,
                .queue = .init(io),
            };
        }

        pub fn installResizeHandler(self: *Self) !void {
            switch (builtin.os.tag) {
                .windows => {},
                else => {
                    if (!builtin.is_test and !self.resize_handler_installed) {
                        try Tty.notifyWinsize(self.resizeHandler());
                        self.resize_handler_installed = true;
                    }
                },
            }
        }

        pub fn uninstallResizeHandler(self: *Self) void {
            switch (builtin.os.tag) {
                .windows => {},
                else => {
                    if (!builtin.is_test and self.resize_handler_installed) {
                        Tty.removeWinsize(self.resizeHandler());
                        self.resize_handler_installed = false;
                    }
                },
            }
        }

        fn resizeHandler(self: *Self) Tty.SignalHandler {
            return .{
                .context = self,
                .callback = Self.winsizeCallback,
            };
        }

        /// spawns the input thread to read input from the tty
        pub fn start(self: *Self) !void {
            if (self.thread) |_| return;
            if (builtin.os.tag == .windows and !builtin.is_test) try self.tty.resetInput();
            self.queue.reopen();
            errdefer self.queue.close(error.Closed);
            self.thread = try self.io.concurrent(Self.ttyRun, .{
                self,
                self.vaxis.opts.system_clipboard_allocator,
            });
        }

        /// stops reading from the tty.
        pub fn stop(self: *Self) void {
            // If we don't have a thread, we have nothing to stop
            if (self.thread == null) return;
            self.queue.close(error.Closed);
            if (builtin.os.tag == .windows and !builtin.is_test) self.tty.interruptInput();

            if (self.thread) |*thread| {
                // Interrupt POSIX reads, retry sleeps, and queue waits as well as
                // joining. Native Windows console waits use input_stop above.
                thread.cancel(self.io);
                self.thread = null;
            }
        }

        /// Returns the next event, blocking until available. After buffered events
        /// are drained, returns Closed on stop or the input task's failure.
        pub fn nextEvent(self: *Self) !T {
            return try self.queue.pop();
        }

        /// blocks until an event is available. Useful when your application is
        /// operating on a poll + drain architecture (see tryEvent)
        pub fn pollEvent(self: *Self) !void {
            try self.queue.poll();
        }

        /// returns an event if one is available, otherwise null. Non-blocking.
        pub fn tryEvent(self: *Self) !?T {
            return try self.queue.tryPop();
        }

        /// posts an event into the event queue. Will block if there is not
        /// capacity for the event
        pub fn postEvent(self: *Self, event: T) !void {
            try self.queue.push(event);
        }

        pub fn tryPostEvent(self: *Self, event: T) !bool {
            return try self.queue.tryPush(event);
        }

        pub fn winsizeCallback(ptr: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            // We will be receiving winsize updates in-band
            if (self.vaxis.state.in_band_resize) return;

            const winsize = self.tty.getWinsize() catch return;
            if (@hasField(Event, "winsize")) {
                // Resize notifications may be coalesced when the queue is full.
                _ = self.tryPostEvent(.{ .winsize = winsize }) catch {};
            }
        }

        /// read input from the tty. This is run in a separate thread
        fn ttyRun(self: *Self, paste_allocator: ?std.mem.Allocator) void {
            self._ttyRun(paste_allocator) catch |err| self.inputFailed(err);
        }

        fn inputFailed(self: *Self, err: anyerror) void {
            if (err != error.Canceled and err != error.Closed)
                log.warn("input stopped: {s}", .{@errorName(err)});
            self.queue.close(if (err == error.Canceled) error.Closed else err);
        }

        fn runWindows(self: *Self, reader: anytype, paste_allocator: ?std.mem.Allocator) !void {
            var parser: Parser = .{ .cursor_position_requests = &self.vaxis.cursor_position_requests };
            var retry: ReadRetry = .{};
            while (true) {
                try self.io.checkCancel();
                const event = reader.nextEvent(&parser, paste_allocator) catch |err| {
                    if (malformedInput(err)) continue;
                    try retry.wait(self.io, err);
                    continue;
                };
                retry = .{};
                try handleEventGeneric(self, self.vaxis, &self.cache, Event, event, paste_allocator);
            }
        }

        fn _ttyRun(
            self: *Self,
            paste_allocator: ?std.mem.Allocator,
        ) !void {
            // Return early if we're in test mode to avoid infinite loops
            if (builtin.is_test) return;

            var parser: Parser = .{ .cursor_position_requests = &self.vaxis.cursor_position_requests };

            switch (builtin.os.tag) {
                .windows => try self.runWindows(self.tty, paste_allocator),
                else => {
                    // get our initial winsize
                    const winsize = try self.tty.getWinsize();
                    if (@hasField(Event, "winsize")) {
                        try self.postEvent(.{ .winsize = winsize });
                    }

                    // initialize the read buffer
                    var buf: [1024]u8 = undefined;
                    var read_start: usize = 0;
                    var retry: ReadRetry = .{};
                    // read loop
                    read_loop: while (true) {
                        try self.io.checkCancel();
                        const bytes_read = self.tty.read(buf[read_start..]) catch |err| {
                            try retry.wait(self.io, err);
                            continue;
                        };
                        if (bytes_read == 0) return error.EndOfStream;
                        retry = .{};
                        const n = read_start + bytes_read;
                        var seq_start: usize = 0;
                        while (seq_start < n) {
                            if (n - seq_start == 1 and buf[seq_start] == 0x1b) {
                                // Preserve ESC only when continuation bytes are already queued.
                                var poll_fds = [1]std.posix.pollfd{.{
                                    .fd = self.tty.fd.handle,
                                    .events = std.posix.POLL.IN,
                                    .revents = 0,
                                }};
                                _ = std.posix.poll(&poll_fds, 0) catch 0;
                                if (poll_fds[0].revents & std.posix.POLL.IN != 0) {
                                    buf[0] = buf[seq_start];
                                    read_start = 1;
                                    continue :read_loop;
                                }
                            }

                            const result = parser.parse(buf[seq_start..n], paste_allocator) catch |err| {
                                if (!malformedInput(err)) return err;
                                // There is no consumed length on parse errors. Discard
                                // this batch rather than retrying the same bad bytes.
                                read_start = 0;
                                continue :read_loop;
                            };
                            if (result.n == 0) {
                                // copy the read to the beginning. We don't use memcpy because
                                // this could be overlapping, and it's also rare
                                const initial_start = seq_start;
                                while (seq_start < n) : (seq_start += 1) {
                                    buf[seq_start - initial_start] = buf[seq_start];
                                }
                                read_start = seq_start - initial_start;
                                continue :read_loop;
                            }
                            read_start = 0;
                            seq_start += result.n;

                            const event = result.event orelse continue;
                            try handleEventGeneric(self, self.vaxis, &self.cache, Event, event, paste_allocator);
                        }
                    }
                },
            }
        }
    };
}

const ReadRetry = struct {
    attempts: u8 = 0,

    fn delay(self: *ReadRetry, err: anyerror) !std.Io.Duration {
        switch (err) {
            error.InputInterrupted, error.WouldBlock, error.InputOutput, error.SystemResources => {},
            else => return err,
        }
        if (self.attempts == 8) return err;
        const ms = @min(@as(u32, 10) << @intCast(self.attempts), 250);
        self.attempts += 1;
        return .fromMilliseconds(ms);
    }

    fn wait(self: *ReadRetry, io: std.Io, err: anyerror) !void {
        const duration = try self.delay(err);
        if (self.attempts == 1) log.warn("input read failed: {s}; retrying", .{@errorName(err)});
        try io.sleep(duration, .awake);
    }
};

fn malformedInput(err: anyerror) bool {
    return switch (err) {
        error.InvalidCharacter,
        error.InvalidColorSpec,
        error.InvalidPadding,
        error.InvalidUTF8,
        error.Utf8CannotEncodeSurrogateHalf,
        error.CodepointTooLarge,
        error.Overflow,
        => true,
        else => false,
    };
}

// Use return on the self.postEvent's so it can either return error union or void
pub fn handleEventGeneric(self: anytype, vx: *Vaxis, cache: *GraphemeCache, Event: type, event: anytype, paste_allocator: ?std.mem.Allocator) !void {
    switch (event) {
        .cursor_position => {
            // Capability probe answers never get here: the parser claims them
            // under the request lock, so every report is an application's.
            if (@hasField(Event, "cursor_position")) {
                return self.postEvent(.{ .cursor_position = event.cursor_position });
            }
            return;
        },
        .paste_start => {
            if (@hasField(Event, "paste_start")) return self.postEvent(.paste_start);
            return;
        },
        .paste_end => {
            if (@hasField(Event, "paste_end")) return self.postEvent(.paste_end);
            return;
        },
        .paste => |text| {
            if (@hasField(Event, "paste")) {
                errdefer if (paste_allocator) |allocator| allocator.free(text);
                return self.postEvent(.{ .paste = text });
            }
            if (paste_allocator) |allocator| allocator.free(text);
            return;
        },
        .terminal_version => |identity| {
            // Stored on Vaxis.caps rather than forwarded: capability bookkeeping
            // is internal, and handling it here keeps it off the per-platform
            // switches so no backend can drop it. The slice borrows the input,
            // so there is nothing to release.
            vx.setTerminalVersion(identity);
            return;
        },
        else => {},
    }
    switch (builtin.os.tag) {
        .windows => {
            switch (event) {
                .winsize => |ws| {
                    if (@hasField(Event, "winsize")) {
                        return self.postEvent(.{ .winsize = ws });
                    }
                },
                .key_press => |key| {
                    if (@hasField(Event, "key_press")) {
                        // HACK: yuck. there has to be a better way
                        var mut_key = key;
                        if (key.text) |text| {
                            mut_key.text = cache.put(text);
                        }
                        return self.postEvent(.{ .key_press = mut_key });
                    }
                },
                .key_release => |key| {
                    if (@hasField(Event, "key_release")) {
                        // HACK: yuck. there has to be a better way
                        var mut_key = key;
                        if (key.text) |text| {
                            mut_key.text = cache.put(text);
                        }
                        return self.postEvent(.{ .key_release = mut_key });
                    }
                },
                .cap_da1 => {
                    // DA1 is sent after both probes, so any probe report that
                    // has not arrived by now never will.
                    vx.finishQueries();
                    std.Io.futexWake(vx.io, std.atomic.Value(u32), &vx.query_futex, 10);
                },
                .mouse => |mouse| {
                    if (@hasField(Event, "mouse")) {
                        return self.postEvent(.{ .mouse = vx.translateMouse(mouse) });
                    }
                },
                .focus_in => {
                    if (@hasField(Event, "focus_in")) {
                        return self.postEvent(.focus_in);
                    }
                },
                .focus_out => {
                    if (@hasField(Event, "focus_out")) {
                        return self.postEvent(.focus_out);
                    }
                }, // Unsupported currently
                else => {},
            }
        },
        else => {
            switch (event) {
                .key_press => |key| {
                    if (@hasField(Event, "key_press")) {
                        // HACK: yuck. there has to be a better way
                        var mut_key = key;
                        if (key.text) |text| {
                            mut_key.text = cache.put(text);
                        }
                        return self.postEvent(.{ .key_press = mut_key });
                    }
                },
                .key_release => |key| {
                    if (@hasField(Event, "key_release")) {
                        // HACK: yuck. there has to be a better way
                        var mut_key = key;
                        if (key.text) |text| {
                            mut_key.text = cache.put(text);
                        }
                        return self.postEvent(.{ .key_release = mut_key });
                    }
                },
                .mouse => |mouse| {
                    if (@hasField(Event, "mouse")) {
                        return self.postEvent(.{ .mouse = vx.translateMouse(mouse) });
                    }
                },
                .mouse_leave => {
                    if (@hasField(Event, "mouse_leave")) {
                        return self.postEvent(.mouse_leave);
                    }
                },
                .focus_in => {
                    if (@hasField(Event, "focus_in")) {
                        return self.postEvent(.focus_in);
                    }
                },
                .focus_out => {
                    if (@hasField(Event, "focus_out")) {
                        return self.postEvent(.focus_out);
                    }
                },
                .color_report => |report| {
                    if (@hasField(Event, "color_report")) {
                        return self.postEvent(.{ .color_report = report });
                    }
                },
                .cursor_position, .paste_start, .paste_end, .paste, .terminal_version => unreachable, // handled above on all platforms
                .color_scheme => |scheme| {
                    if (@hasField(Event, "color_scheme")) {
                        return self.postEvent(.{ .color_scheme = scheme });
                    }
                },
                .cap_kitty_keyboard => {
                    log.info("kitty keyboard capability detected", .{});
                    vx.caps.kitty_keyboard = true;
                },
                .cap_kitty_graphics => {
                    if (!vx.caps.kitty_graphics) {
                        log.info("kitty graphics capability detected", .{});
                        vx.caps.kitty_graphics = true;
                    }
                },
                .cap_rgb => {
                    log.info("rgb capability detected", .{});
                    vx.caps.rgb = true;
                },
                .cap_unicode => {
                    log.info("unicode capability detected", .{});
                    vx.caps.unicode = .unicode;
                    vx.screen.width_method = .unicode;
                },
                .cap_sgr_pixels => {
                    log.info("pixel mouse capability detected", .{});
                    vx.caps.sgr_pixels = true;
                },
                .cap_color_scheme_updates => {
                    log.info("color_scheme_updates capability detected", .{});
                    vx.caps.color_scheme_updates = true;
                },
                .cap_multi_cursor => {
                    log.info("multi cursor capability detected", .{});
                    vx.caps.multi_cursor = true;
                },
                .cap_program_status => {
                    log.info("program status capability detected", .{});
                    vx.caps.program_status = true;
                },
                .cap_da1 => {
                    // DA1 is sent after both probes, so any probe report that
                    // has not arrived by now never will.
                    vx.finishQueries();
                    std.Io.futexWake(vx.io, std.atomic.Value(u32), &vx.query_futex, 10);
                },
                .winsize => |winsize| {
                    vx.state.in_band_resize = true;
                    switch (builtin.os.tag) {
                        .windows => {},
                        // Reset the signal handler if we are receiving in_band_resize
                        else => Tty.resetSignalHandler(),
                    }
                    if (@hasField(Event, "winsize")) {
                        return self.postEvent(.{ .winsize = winsize });
                    }
                },
            }
        },
    }
}

test Loop {
    const io = std.testing.io;
    var env_map = try std.testing.environ.createMap(std.testing.allocator);
    defer env_map.deinit();

    const Event = union(enum) {
        key_press: vaxis.Key,
        winsize: vaxis.Winsize,
        focus_in,
        foo: u8,
    };

    var tty = try vaxis.Tty.init(io, &.{});
    defer tty.deinit();

    var vx = try vaxis.init(io, std.testing.allocator, &env_map, .{});
    defer vx.deinit(std.testing.allocator, tty.writer());

    var loop: vaxis.Loop(Event) = .init(io, &tty, &vx);

    try loop.start();
    defer loop.stop();

    // Optionally enter the alternate screen
    try vx.enterAltScreen(tty.writer());
    try vx.queryTerminal(tty.writer(), .fromSeconds(1));
}

test "cursor queries deliver reports without interfering with capability probes" {
    const testing = std.testing;
    var env = try testing.environ.createMap(testing.allocator);
    defer env.deinit();
    var tty = try Tty.init(testing.io, &.{});
    defer tty.deinit();
    var vx = try vaxis.init(testing.io, testing.allocator, &env, .{});
    defer vx.deinit(testing.allocator, tty.writer());
    const Event = union(enum) {
        cursor_position: vaxis.Screen.Cursor,
        key_press: vaxis.Key,
    };
    var loop: Loop(Event) = .init(testing.io, &tty, &vx);
    var parser: Parser = .{ .cursor_position_requests = &vx.cursor_position_requests };
    var cache: GraphemeCache = .{};

    try vx.queryTerminalSend(tty.writer());
    try testing.expectError(error.TerminalQueriesPending, vx.queryCursorPosition(tty.writer()));
    for ([_][]const u8{ "\x1b[1;2R", "\x1b[1;3R", "\x1b[?c" }) |input|
        try feedForTest(&loop, &vx, &parser, &cache, Event, input);
    try testing.expect(vx.caps.explicit_width);
    try testing.expect(vx.caps.scaled_text);
    try testing.expectEqual(@as(usize, 0), vx.cursor_position_requests.pending());
    try testing.expectEqual(@as(?Event, null), try loop.tryEvent());

    var writer: std.Io.Writer.Allocating = .init(testing.allocator);
    defer writer.deinit();
    try vx.queryCursorPosition(&writer.writer);
    try vx.queryCursorPosition(&writer.writer);
    try testing.expectEqualStrings("\x1b[6n\x1b[6n", writer.written());
    try testing.expectEqual(@as(usize, 2), vx.cursor_position_requests.pending());
    try testing.expectError(error.CursorPositionQueriesPending, vx.queryTerminalSend(tty.writer()));

    for (0..2) |_| {
        const result = try parser.parse("\x1b[12;34R", null);
        try handleEventGeneric(&loop, &vx, &cache, Event, result.event.?, null);
        const report = (try loop.tryEvent()).?.cursor_position;
        try testing.expectEqual(@as(u16, 11), report.row);
        try testing.expectEqual(@as(u16, 33), report.col);
    }
    try testing.expectEqual(@as(usize, 0), vx.cursor_position_requests.pending());

    // Consumers that don't opt into cursor reports silently discard them.
    const KeyEvent = union(enum) { key_press: vaxis.Key };
    var key_loop: Loop(KeyEvent) = .init(testing.io, &tty, &vx);
    try vx.queryCursorPosition(&writer.writer);
    const result = try parser.parse("\x1b[1;1R", null);
    try handleEventGeneric(&key_loop, &vx, &cache, KeyEvent, result.event.?, null);
    try testing.expectEqual(@as(?KeyEvent, null), try key_loop.tryEvent());
    try testing.expectEqual(@as(usize, 0), vx.cursor_position_requests.pending());

    // Expired cursor queries must not block capability discovery indefinitely.
    try vx.queryCursorPosition(&writer.writer);
    vx.cursor_position_requests.last_request_at = vx.cursor_position_requests.last_request_at.subDuration(.fromSeconds(2));
    // A fresh query registers the two probe reports, so they are accounted for
    // instead of being inferred from a misparsed F3.
    try vx.queryTerminalSend(tty.writer());
    try testing.expectEqual(@as(usize, 2), vx.cursor_position_requests.pending());
    try testing.expect(vx.cursor_position_requests.probe_window);
}

test "a probe report that never arrives is cancelled when the query window closes" {
    const testing = std.testing;
    var env = try testing.environ.createMap(testing.allocator);
    defer env.deinit();
    var tty = try Tty.init(testing.io, &.{});
    defer tty.deinit();
    var vx = try vaxis.init(testing.io, testing.allocator, &env, .{});
    defer vx.deinit(testing.allocator, tty.writer());
    const Event = union(enum) {
        cursor_position: vaxis.Screen.Cursor,
        key_press: vaxis.Key,
    };
    var loop: Loop(Event) = .init(testing.io, &tty, &vx);
    var parser: Parser = .{ .cursor_position_requests = &vx.cursor_position_requests };
    var cache: GraphemeCache = .{};

    try vx.queryTerminalSend(tty.writer());
    try testing.expectEqual(@as(usize, 2), vx.cursor_position_requests.pending());

    // Only the first probe is answered. A terminal that ignores the second one
    // must not leave a request behind that a later application report would be
    // credited against.
    try feedForTest(&loop, &vx, &parser, &cache, Event, "\x1b[1;2R");
    try testing.expectEqual(@as(usize, 1), vx.cursor_position_requests.pending());

    // DA1 closes the window and applies what the probes reported.
    try feedForTest(&loop, &vx, &parser, &cache, Event, "\x1b[?62;22c");
    try testing.expect(vx.queries_done.load(.unordered));
    try testing.expect(vx.caps.explicit_width);
    try testing.expect(!vx.caps.scaled_text);
    try testing.expectEqual(@as(usize, 0), vx.cursor_position_requests.pending());
    try testing.expectEqual(@as(?Event, null), try loop.tryEvent());

    // The query window is closed, so an application query works straight away.
    var writer: std.Io.Writer.Allocating = .init(testing.allocator);
    defer writer.deinit();
    try vx.queryCursorPosition(&writer.writer);
}

test "a late probe report is still claimed" {
    const testing = std.testing;
    var env = try testing.environ.createMap(testing.allocator);
    defer env.deinit();
    var tty = try Tty.init(testing.io, &.{});
    defer tty.deinit();
    var vx = try vaxis.init(testing.io, testing.allocator, &env, .{});
    defer vx.deinit(testing.allocator, tty.writer());
    const Event = union(enum) {
        cursor_position: vaxis.Screen.Cursor,
        key_press: vaxis.Key,
    };
    var loop: Loop(Event) = .init(testing.io, &tty, &vx);
    var parser: Parser = .{ .cursor_position_requests = &vx.cursor_position_requests };
    var cache: GraphemeCache = .{};

    try vx.queryTerminalSend(tty.writer());
    // The terminal takes longer than the one-second request expiry to answer.
    // While the query window is open the probe requests do not expire, so the
    // parser still claims both answers instead of returning Shift+F3 and Alt+F3.
    vx.cursor_position_requests.last_request_at = vx.cursor_position_requests.last_request_at.subDuration(.fromMilliseconds(1500));
    for ([_][]const u8{ "\x1b[1;2R", "\x1b[1;3R" }) |input| {
        const report = try parser.parse(input, null);
        try testing.expectEqual(@as(?vaxis.Event, null), report.event);
        try testing.expectEqual(input.len, report.n);
    }
    try feedForTest(&loop, &vx, &parser, &cache, Event, "\x1b[?62;22c");

    try testing.expect(vx.caps.explicit_width);
    try testing.expect(vx.caps.scaled_text);
    try testing.expectEqual(@as(?Event, null), try loop.tryEvent());
}

test "a query timeout cancels the probe reports it was waiting for" {
    const testing = std.testing;
    var env = try testing.environ.createMap(testing.allocator);
    defer env.deinit();
    var tty = try Tty.init(testing.io, &.{});
    defer tty.deinit();
    var vx = try vaxis.init(testing.io, testing.allocator, &env, .{});
    defer vx.deinit(testing.allocator, tty.writer());

    // Nothing answers, so the query times out instead of closing on DA1.
    try vx.queryTerminal(tty.writer(), .fromMilliseconds(1));
    try testing.expectEqual(@as(usize, 0), vx.cursor_position_requests.pending());

    // Within the second the stale requests would have lived, querying again
    // must work rather than fail with CursorPositionQueriesPending.
    try vx.queryTerminalSend(tty.writer());
}

test "program status reply sets the capability" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const testing = std.testing;
    var env = try testing.environ.createMap(testing.allocator);
    defer env.deinit();
    var tty = try Tty.init(testing.io, &.{});
    defer tty.deinit();
    var vx = try vaxis.init(testing.io, testing.allocator, &env, .{});
    defer vx.deinit(testing.allocator, tty.writer());
    var loop: Loop(vaxis.Event) = .init(testing.io, &tty, &vx);
    var parser: Parser = .{};
    var cache: GraphemeCache = .{};

    try testing.expect(!vx.caps.program_status);
    const result = try parser.parse("\x1b]7501;?\x1b\\", null);
    try handleEventGeneric(&loop, &vx, &cache, vaxis.Event, result.event.?, null);
    try testing.expect(vx.caps.program_status);
    try testing.expectEqual(@as(?vaxis.Event, null), try loop.tryEvent());
}

test "paste dispatch preserves boundaries and transfers or frees clipboard text" {
    const testing = std.testing;
    var env = try testing.environ.createMap(testing.allocator);
    defer env.deinit();
    var tty = try Tty.init(testing.io, &.{});
    defer tty.deinit();
    var vx = try vaxis.init(testing.io, testing.allocator, &env, .{});
    defer vx.deinit(testing.allocator, tty.writer());
    var loop: Loop(vaxis.Event) = .init(testing.io, &tty, &vx);
    var cache: GraphemeCache = .{};

    const events = [_]vaxis.Event{
        .{ .key_press = .{ .codepoint = vaxis.Key.enter } },
        .paste_start,
        .{ .key_press = .{ .codepoint = vaxis.Key.enter } },
        .paste_end,
        .{ .key_press = .{ .codepoint = vaxis.Key.enter } },
    };
    for (events) |event| try handleEventGeneric(&loop, &vx, &cache, vaxis.Event, event, testing.allocator);
    for (events) |event| try testing.expectEqualDeep(event, (try loop.tryEvent()).?);
    try testing.expectEqual(@as(?vaxis.Event, null), try loop.tryEvent());

    const text = try testing.allocator.dupe(u8, "clipboard\ntext");
    try handleEventGeneric(&loop, &vx, &cache, vaxis.Event, @as(vaxis.Event, .{ .paste = text }), testing.allocator);
    const pasted = (try loop.tryEvent()).?.paste;
    defer testing.allocator.free(pasted);
    try testing.expectEqualStrings("clipboard\ntext", pasted);

    const KeyEvent = union(enum) { key_press: vaxis.Key };
    var keys: Loop(KeyEvent) = .init(testing.io, &tty, &vx);
    for ([_]vaxis.Event{ .paste_start, .paste_end, .{ .paste = try testing.allocator.dupe(u8, "ignored") } }) |event| {
        try handleEventGeneric(&keys, &vx, &cache, KeyEvent, event, testing.allocator);
    }
    try testing.expectEqual(@as(?KeyEvent, null), try keys.tryEvent());
}

test "read retries back off, cap attempts, and reject permanent errors" {
    const testing = std.testing;
    var retry: ReadRetry = .{};
    for ([_]i64{ 10, 20, 40, 80, 160, 250, 250, 250 }) |ms| {
        const duration = try retry.delay(error.InputInterrupted);
        try testing.expectEqual(ms, duration.toMilliseconds());
    }
    try testing.expectError(error.InputInterrupted, retry.delay(error.InputInterrupted));
    retry = .{};
    for ([_]anyerror{ error.Canceled, error.AccessDenied, error.InvalidHandle, error.OutOfMemory, error.EndOfStream }) |err| {
        try testing.expectError(err, retry.delay(err));
    }
    try testing.expectEqual(0, retry.attempts);
}

test "Windows reader recovers, resets retries, and reports failure after queued keys" {
    const testing = std.testing;
    const Event = union(enum) { key_press: vaxis.Key };
    const Reader = struct {
        calls: usize = 0,

        fn nextEvent(self: *@This(), _: *Parser, _: ?std.mem.Allocator) !vaxis.Event {
            defer self.calls += 1;
            return switch (self.calls) {
                0...7, 9 => error.InputInterrupted,
                8 => .{ .key_press = .{ .codepoint = 'a', .text = "abc" } },
                10 => error.InvalidUTF8,
                11 => .{ .key_press = .{ .codepoint = 'z', .text = "zy" } },
                else => error.AccessDenied,
            };
        }

        fn run(self: *@This(), loop: *Loop(Event)) void {
            loop.runWindows(self, null) catch |err| loop.inputFailed(err);
        }
    };
    var vx: Vaxis = undefined;
    var loop: Loop(Event) = .init(testing.io, undefined, &vx);
    var reader: Reader = .{};
    var task = try testing.io.concurrent(Reader.run, .{ &reader, &loop });
    task.await(testing.io);
    try testing.expectEqual(13, reader.calls);
    const first = (try loop.nextEvent()).key_press;
    const second = (try loop.nextEvent()).key_press;
    try testing.expectEqual('a', first.codepoint);
    try testing.expectEqual('z', second.codepoint);
    try testing.expectEqualStrings("abc", first.text.?);
    try testing.expectEqualStrings("zy", second.text.?);
    try testing.expect(first.text.?.ptr == loop.cache.buf[0..].ptr);
    try testing.expectError(error.AccessDenied, loop.nextEvent());
    try testing.expectError(error.AccessDenied, loop.tryEvent());
    try testing.expectError(error.AccessDenied, loop.pollEvent());
}

test "stop interrupts a reader posting to a full queue" {
    const testing = std.testing;
    const Event = union(enum) { focus_in };
    const Reader = struct {
        ready: std.Io.Event = .unset,
        calls: usize = 0,

        fn nextEvent(self: *@This(), _: *Parser, _: ?std.mem.Allocator) !vaxis.Event {
            self.calls += 1;
            self.ready.set(testing.io);
            return .focus_in;
        }

        fn run(self: *@This(), loop: *Loop(Event)) void {
            loop.runWindows(self, null) catch |err| loop.inputFailed(err);
        }
    };
    var vx: Vaxis = undefined;
    var loop: Loop(Event) = .init(testing.io, undefined, &vx);
    for (0..512) |_| try loop.postEvent(.focus_in);
    var reader: Reader = .{};
    loop.thread = try testing.io.concurrent(Reader.run, .{ &reader, &loop });
    defer loop.stop();
    try reader.ready.wait(testing.io);
    try testing.io.sleep(.fromMilliseconds(10), .awake);
    loop.stop();
    try testing.expectEqual(1, reader.calls);
    try testing.expect(loop.thread == null);
    for (0..512) |_| try testing.expectEqual(Event.focus_in, try loop.nextEvent());
    try testing.expectError(error.Closed, loop.nextEvent());
}

test "stop cancels an idle POSIX read without a terminal response" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const testing = std.testing;
    const Event = union(enum) { focus_in };
    var tty = try Tty.init(testing.io, &.{});
    defer tty.deinit();
    const Reader = struct {
        tty: @import("tty.zig").PosixTty,
        ready: std.Io.Event = .unset,
        result: anyerror!usize = undefined,

        fn run(self: *@This(), loop: *Loop(Event)) void {
            var buf: [16]u8 = undefined;
            self.ready.set(testing.io);
            self.result = self.tty.read(&buf);
            _ = self.result catch |err| {
                loop.inputFailed(err);
                return;
            };
        }
    };
    var reader: Reader = .{ .tty = undefined };
    reader.tty.io = testing.io;
    reader.tty.fd = .{ .handle = tty.pipe_read, .flags = .{ .nonblocking = false } };
    var vx: Vaxis = undefined;
    var loop: Loop(Event) = .init(testing.io, &tty, &vx);
    loop.thread = try testing.io.concurrent(Reader.run, .{ &reader, &loop });
    defer loop.stop();
    try reader.ready.wait(testing.io);
    try testing.io.sleep(.fromMilliseconds(10), .awake);
    loop.stop();
    try testing.expectError(error.Canceled, reader.result);
    try testing.expectError(error.Closed, loop.tryEvent());
}

test "failed paste enqueue frees its allocation" {
    const Event = union(enum) { paste: []const u8 };
    var vx: Vaxis = undefined;
    var loop: Loop(Event) = .init(std.testing.io, undefined, &vx);
    loop.queue.close(error.Closed);
    const text = try std.testing.allocator.dupe(u8, "owned paste");
    try std.testing.expectError(error.Closed, handleEventGeneric(
        &loop,
        &vx,
        &loop.cache,
        Event,
        @as(vaxis.Event, .{ .paste = text }),
        std.testing.allocator,
    ));
}

test {
    std.testing.refAllDecls(@This());
}

test "terminal version is stored on caps and its payload is released" {
    const testing = std.testing;
    var env = try testing.environ.createMap(testing.allocator);
    defer env.deinit();
    var tty = try Tty.init(testing.io, &.{});
    defer tty.deinit();
    var vx = try vaxis.init(testing.io, testing.allocator, &env, .{});
    defer vx.deinit(testing.allocator, tty.writer());
    var loop: Loop(vaxis.Event) = .init(testing.io, &tty, &vx);
    var cache: GraphemeCache = .{};

    // The payload borrows the input, so the handler must still work for a
    // caller that supplied no allocator at all.
    const identity = "kitty(0.42.2)";
    try handleEventGeneric(
        &loop,
        &vx,
        &cache,
        vaxis.Event,
        @as(vaxis.Event, .{ .terminal_version = identity }),
        testing.allocator,
    );

    try testing.expectEqualStrings("kitty(0.42.2)", vx.terminalVersion());
    // Capability bookkeeping stays internal; it is not posted to the app queue.
    try testing.expectEqual(@as(?vaxis.Event, null), try loop.tryEvent());
}

test "a duplicate DA1 does not consume an application request" {
    const testing = std.testing;
    var env = try testing.environ.createMap(testing.allocator);
    defer env.deinit();
    var tty = try Tty.init(testing.io, &.{});
    defer tty.deinit();
    var vx = try vaxis.init(testing.io, testing.allocator, &env, .{});
    defer vx.deinit(testing.allocator, tty.writer());
    const Event = union(enum) {
        cursor_position: vaxis.Screen.Cursor,
        key_press: vaxis.Key,
    };
    var loop: Loop(Event) = .init(testing.io, &tty, &vx);
    var parser: Parser = .{ .cursor_position_requests = &vx.cursor_position_requests };
    var cache: GraphemeCache = .{};

    // A complete discovery: both probes answer and DA1 closes the window.
    try vx.queryTerminalSend(tty.writer());
    for ([_][]const u8{ "\x1b[1;1R", "\x1b[1;1R", "\x1b[?62;22c" }) |input|
        try feedForTest(&loop, &vx, &parser, &cache, Event, input);

    // The application then queries the cursor, and the terminal repeats DA1.
    var writer: std.Io.Writer.Allocating = .init(testing.allocator);
    defer writer.deinit();
    try vx.queryCursorPosition(&writer.writer);
    try feedForTest(&loop, &vx, &parser, &cache, Event, "\x1b[?62;22c");
    try testing.expectEqual(@as(usize, 1), vx.cursor_position_requests.pending());

    // Its report still arrives as a report.
    try feedForTest(&loop, &vx, &parser, &cache, Event, "\x1b[3;4R");
    const got = (try loop.tryEvent()).?.cursor_position;
    try testing.expectEqual(@as(u16, 2), got.row);
    try testing.expectEqual(@as(u16, 3), got.col);
}

test "a terminal without OSC 66 does not leak its probe reports as F3" {
    const testing = std.testing;
    var env = try testing.environ.createMap(testing.allocator);
    defer env.deinit();
    var tty = try Tty.init(testing.io, &.{});
    defer tty.deinit();
    var vx = try vaxis.init(testing.io, testing.allocator, &env, .{});
    defer vx.deinit(testing.allocator, tty.writer());
    const Event = union(enum) {
        cursor_position: vaxis.Screen.Cursor,
        key_press: vaxis.Key,
    };
    var loop: Loop(Event) = .init(testing.io, &tty, &vx);
    var parser: Parser = .{ .cursor_position_requests = &vx.cursor_position_requests };
    var cache: GraphemeCache = .{};

    try vx.queryTerminalSend(tty.writer());

    // A terminal without OSC 66 swallows both probe payloads, so both reports
    // leave the cursor on the first column. In the legacy key encoding this
    // is an unmodified F3, which must not reach the application.
    for (0..2) |_| try feedForTest(&loop, &vx, &parser, &cache, Event, "\x1b[1;1R");
    try feedForTest(&loop, &vx, &parser, &cache, Event, "\x1b[?62;22c");

    try testing.expect(!vx.caps.explicit_width);
    try testing.expect(!vx.caps.scaled_text);
    if (try loop.tryEvent()) |event| {
        std.debug.print("leaked event: {any}\n", .{event});
        return error.TestUnexpectedResult;
    }
}

test "a real F3 during the query window reaches the application" {
    const testing = std.testing;
    var env = try testing.environ.createMap(testing.allocator);
    defer env.deinit();
    var tty = try Tty.init(testing.io, &.{});
    defer tty.deinit();
    var vx = try vaxis.init(testing.io, testing.allocator, &env, .{});
    defer vx.deinit(testing.allocator, tty.writer());
    const Event = union(enum) {
        cursor_position: vaxis.Screen.Cursor,
        key_press: vaxis.Key,
    };
    var loop: Loop(Event) = .init(testing.io, &tty, &vx);
    var parser: Parser = .{ .cursor_position_requests = &vx.cursor_position_requests };
    var cache: GraphemeCache = .{};

    try vx.queryTerminalSend(tty.writer());
    // The user presses F3 (SS3 R) before the terminal answers the probes. It
    // is not a cursor report, so it must neither be taken for a probe answer
    // nor shift the answers onto the wrong probes.
    try feedForTest(&loop, &vx, &parser, &cache, Event, "\x1bOR");
    for ([_][]const u8{ "\x1b[1;2R", "\x1b[1;3R", "\x1b[?62;22c" }) |input|
        try feedForTest(&loop, &vx, &parser, &cache, Event, input);

    const key = (try loop.tryEvent()).?.key_press;
    try testing.expectEqual(vaxis.Key.f3, key.codepoint);
    try testing.expectEqual(@as(?Event, null), try loop.tryEvent());
    try testing.expect(vx.caps.explicit_width);
    try testing.expect(vx.caps.scaled_text);
}

test "finishQueries applies the probe columns once" {
    const testing = std.testing;
    var env = try testing.environ.createMap(testing.allocator);
    defer env.deinit();
    var tty = try Tty.init(testing.io, &.{});
    defer tty.deinit();
    var vx = try vaxis.init(testing.io, testing.allocator, &env, .{});
    defer vx.deinit(testing.allocator, tty.writer());
    const Event = union(enum) {
        cursor_position: vaxis.Screen.Cursor,
        key_press: vaxis.Key,
    };
    var loop: Loop(Event) = .init(testing.io, &tty, &vx);
    var parser: Parser = .{ .cursor_position_requests = &vx.cursor_position_requests };
    var cache: GraphemeCache = .{};

    try vx.queryTerminalSend(tty.writer());
    for ([_][]const u8{ "\x1b[1;2R", "\x1b[1;3R" }) |input|
        try feedForTest(&loop, &vx, &parser, &cache, Event, input);
    // Nothing is applied until the window closes.
    try testing.expect(!vx.caps.explicit_width);

    vx.finishQueries();
    try testing.expect(vx.caps.explicit_width);
    try testing.expect(vx.caps.scaled_text);
    try testing.expect(vx.queries_done.load(.unordered));

    // A second close, as when DA1 races the query timeout, changes nothing.
    vx.caps.scaled_text = false;
    vx.finishQueries();
    try testing.expect(!vx.caps.scaled_text);
    try testing.expectEqual(@as(usize, 0), vx.cursor_position_requests.pending());
}

/// Parse one input and dispatch its event, if any. Capability probe answers
/// are consumed by the parser and produce no event.
fn feedForTest(
    loop: anytype,
    vx: *Vaxis,
    parser: *Parser,
    cache: *GraphemeCache,
    Event: type,
    input: []const u8,
) !void {
    const result = try parser.parse(input, null);
    try std.testing.expectEqual(input.len, result.n);
    if (result.event) |event| try handleEventGeneric(loop, vx, cache, Event, event, null);
}
