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
                    // Check for a cursor position response for our explicit width query. This will
                    // always be an F3 key with shift = true, and we must be looking for queries
                    if (key.codepoint == vaxis.Key.f3 and
                        key.mods.shift and
                        !vx.queries_done.load(.unordered))
                    {
                        log.info("explicit width capability detected", .{});
                        vx.caps.explicit_width = true;
                        vx.caps.unicode = .unicode;
                        vx.screen.width_method = .unicode;
                        return;
                    }
                    // Check for a cursor position response for our scaled text query. This will
                    // always be an F3 key with alt = true, and we must be looking for queries
                    if (key.codepoint == vaxis.Key.f3 and
                        key.mods.alt and
                        !vx.queries_done.load(.unordered))
                    {
                        log.info("scaled text capability detected", .{});
                        vx.caps.scaled_text = true;
                        return;
                    }
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
                    std.Io.futexWake(vx.io, std.atomic.Value(u32), &vx.query_futex, 10);
                    vx.queries_done.store(true, .unordered);
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
                    // Check for a cursor position response for our explicitly width query. This will
                    // always be an F3 key with shift = true, and we must be looking for queries
                    if (key.codepoint == vaxis.Key.f3 and
                        key.mods.shift and
                        !vx.queries_done.load(.unordered))
                    {
                        log.info("explicit width capability detected", .{});
                        vx.caps.explicit_width = true;
                        vx.caps.unicode = .unicode;
                        vx.screen.width_method = .unicode;
                        return;
                    }
                    // Check for a cursor position response for our scaled text query. This will
                    // always be an F3 key with alt = true, and we must be looking for queries
                    if (key.codepoint == vaxis.Key.f3 and
                        key.mods.alt and
                        !vx.queries_done.load(.unordered))
                    {
                        log.info("scaled text capability detected", .{});
                        vx.caps.scaled_text = true;
                        return;
                    }
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
                .cursor_position, .paste_start, .paste_end, .paste => unreachable, // handled above on all platforms
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
                .cap_da1 => {
                    std.Io.futexWake(vx.io, std.atomic.Value(u32), &vx.query_futex, 10);
                    vx.queries_done.store(true, .unordered);
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
    for ([_][]const u8{ "\x1b[1;2R", "\x1b[1;3R", "\x1b[?c" }) |input| {
        const result = try parser.parse(input, null);
        try handleEventGeneric(&loop, &vx, &cache, Event, result.event.?, null);
    }
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
    try vx.queryTerminalSend(tty.writer());
    try testing.expectEqual(@as(usize, 0), vx.cursor_position_requests.pending());
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
