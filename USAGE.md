# Usage

## Custom Event Loops

Vaxis provides an abstract enough API to allow the usage of a custom event loop.
An event loop implementation is responsible for three primary tasks:

1. Read raw bytes from the TTY
2. Pass bytes to the Vaxis input event parser
3. Handle the returned events

Everything after this can be left up to user code, or brought into an event loop
to be a more abstract application layer. One important part of handling the
events is to update the Vaxis struct with discovered terminal capabilities. This
let's Vaxis know what features it can use. For example, the Kitty Keyboard
protocol, in-band-resize reports, and Unicode width measurements are just a few
examples.

### `libxev`

Below is an example [`libxev`](https://github.com/mitchellh/libxev) event loop.
Note that this code is not necessarily up-to-date with the latest `libxev`
release and is shown here merely as a proof of concept.

```zig
const std = @import("std");
const xev = @import("xev");

const Tty = @import("main.zig").Tty;
const Winsize = @import("main.zig").Winsize;
const Vaxis = @import("Vaxis.zig");
const Parser = @import("Parser.zig");
const Key = @import("Key.zig");
const Mouse = @import("Mouse.zig");
const Color = @import("Cell.zig").Color;

const log = std.log.scoped(.vaxis_xev);

pub const Event = union(enum) {
    key_press: Key,
    key_release: Key,
    mouse: Mouse,
    focus_in,
    focus_out,
    paste_start, // bracketed paste start
    paste_end, // bracketed paste end
    paste: []const u8, // osc 52 paste, caller must free
    color_report: Color.Report, // osc 4, 10, 11, 12 response
    color_scheme: Color.Scheme,
    winsize: Winsize,
};

pub fn TtyWatcher(comptime Userdata: type) type {
    return struct {
        const Self = @This();

        file: xev.File,
        tty: *Tty,

        read_buf: [4096]u8,
        read_buf_start: usize,
        read_cmp: xev.Completion,

        winsize_wakeup: xev.Async,
        winsize_cmp: xev.Completion,

        callback: *const fn (
            ud: ?*Userdata,
            loop: *xev.Loop,
            watcher: *Self,
            event: Event,
        ) xev.CallbackAction,

        ud: ?*Userdata,
        vx: *Vaxis,
        parser: Parser,

        pub fn init(
            self: *Self,
            tty: *Tty,
            vaxis: *Vaxis,
            loop: *xev.Loop,
            userdata: ?*Userdata,
            callback: *const fn (
                ud: ?*Userdata,
                loop: *xev.Loop,
                watcher: *Self,
                event: Event,
            ) xev.CallbackAction,
        ) !void {
            self.* = .{
                .tty = tty,
                .file = xev.File.initFd(tty.fd),
                .read_buf = undefined,
                .read_buf_start = 0,
                .read_cmp = .{},

                .winsize_wakeup = try xev.Async.init(),
                .winsize_cmp = .{},

                .callback = callback,
                .ud = userdata,
                .vx = vaxis,
                .parser = .{ .grapheme_data = &vaxis.unicode.width_data.g_data },
            };

            self.file.read(
                loop,
                &self.read_cmp,
                .{ .slice = &self.read_buf },
                Self,
                self,
                Self.ttyReadCallback,
            );
            self.winsize_wakeup.wait(
                loop,
                &self.winsize_cmp,
                Self,
                self,
                winsizeCallback,
            );
            const handler: Tty.SignalHandler = .{
                .context = self,
                .callback = Self.signalCallback,
            };
            try Tty.notifyWinsize(handler);
        }

        fn signalCallback(ptr: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            self.winsize_wakeup.notify() catch |err| {
                log.warn("couldn't wake up winsize callback: {}", .{err});
            };
        }

        fn ttyReadCallback(
            ud: ?*Self,
            loop: *xev.Loop,
            c: *xev.Completion,
            _: xev.File,
            buf: xev.ReadBuffer,
            r: xev.ReadError!usize,
        ) xev.CallbackAction {
            const n = r catch |err| {
                log.err("read error: {}", .{err});
                return .disarm;
            };
            const self = ud orelse unreachable;

            // reset read start state
            self.read_buf_start = 0;

            var seq_start: usize = 0;
            parse_loop: while (seq_start < n) {
                const result = self.parser.parse(buf.slice[seq_start..n], null) catch |err| {
                    log.err("couldn't parse input: {}", .{err});
                    return .disarm;
                };
                if (result.n == 0) {
                    // copy the read to the beginning. We don't use memcpy because
                    // this could be overlapping, and it's also rare
                    const initial_start = seq_start;
                    while (seq_start < n) : (seq_start += 1) {
                        self.read_buf[seq_start - initial_start] = self.read_buf[seq_start];
                    }
                    self.read_buf_start = seq_start - initial_start + 1;
                    return .rearm;
                }
                seq_start += n;
                const event_inner = result.event orelse {
                    log.debug("unknown event: {s}", .{self.read_buf[seq_start - n + 1 .. seq_start]});
                    continue :parse_loop;
                };

                // Capture events we want to bubble up
                const event: ?Event = switch (event_inner) {
                    .key_press => |key| .{ .key_press = key },
                    .key_release => |key| .{ .key_release = key },
                    .mouse => |mouse| .{ .mouse = mouse },
                    .focus_in => .focus_in,
                    .focus_out => .focus_out,
                    .paste_start => .paste_start,
                    .paste_end => .paste_end,
                    .paste => |paste| .{ .paste = paste },
                    .color_report => |report| .{ .color_report = report },
                    .color_scheme => |scheme| .{ .color_scheme = scheme },
                    .winsize => |ws| .{ .winsize = ws },

                    // capability events which we handle below
                    .cap_kitty_keyboard,
                    .cap_kitty_graphics,
                    .cap_rgb,
                    .cap_unicode,
                    .cap_sgr_pixels,
                    .cap_color_scheme_updates,
                    .cap_da1,
                    => null, // handled below
                };

                if (event) |ev| {
                    const action = self.callback(self.ud, loop, self, ev);
                    switch (action) {
                        .disarm => return .disarm,
                        else => continue :parse_loop,
                    }
                }

                switch (event_inner) {
                    .key_press,
                    .key_release,
                    .mouse,
                    .focus_in,
                    .focus_out,
                    .paste_start,
                    .paste_end,
                    .paste,
                    .color_report,
                    .color_scheme,
                    .winsize,
                    => unreachable, // handled above

                    .cap_kitty_keyboard => {
                        log.info("kitty keyboard capability detected", .{});
                        self.vx.caps.kitty_keyboard = true;
                    },
                    .cap_kitty_graphics => {
                        if (!self.vx.caps.kitty_graphics) {
                            log.info("kitty graphics capability detected", .{});
                            self.vx.caps.kitty_graphics = true;
                        }
                    },
                    .cap_rgb => {
                        log.info("rgb capability detected", .{});
                        self.vx.caps.rgb = true;
                    },
                    .cap_unicode => {
                        log.info("unicode capability detected", .{});
                        self.vx.caps.unicode = .unicode;
                        self.vx.screen.width_method = .unicode;
                    },
                    .cap_sgr_pixels => {
                        log.info("pixel mouse capability detected", .{});
                        self.vx.caps.sgr_pixels = true;
                    },
                    .cap_color_scheme_updates => {
                        log.info("color_scheme_updates capability detected", .{});
                        self.vx.caps.color_scheme_updates = true;
                    },
                    .cap_da1 => {
                        self.vx.enableDetectedFeatures(self.tty.anyWriter()) catch |err| {
                            log.err("couldn't enable features: {}", .{err});
                        };
                    },
                }
            }

            self.file.read(
                loop,
                c,
                .{ .slice = &self.read_buf },
                Self,
                self,
                Self.ttyReadCallback,
            );
            return .disarm;
        }

        fn winsizeCallback(
            ud: ?*Self,
            l: *xev.Loop,
            c: *xev.Completion,
            r: xev.Async.WaitError!void,
        ) xev.CallbackAction {
            _ = r catch |err| {
                log.err("async error: {}", .{err});
                return .disarm;
            };
            const self = ud orelse unreachable; // no userdata
            const winsize = Tty.getWinsize(self.tty.fd) catch |err| {
                log.err("couldn't get winsize: {}", .{err});
                return .disarm;
            };
            const ret = self.callback(self.ud, l, self, .{ .winsize = winsize });
            if (ret == .disarm) return .disarm;

            self.winsize_wakeup.wait(
                l,
                c,
                Self,
                self,
                winsizeCallback,
            );
            return .disarm;
        }
    };
}
```

### zig-aio

Below is an example [`zig-aio`](https://github.com/Cloudef/zig-aio) event loop.
Note that this code is not necessarily up-to-date with the latest `zig-aio`
release and is shown here merely as a proof of concept.

```zig
const builtin = @import("builtin");
const std = @import("std");
const vaxis = @import("vaxis");
const handleEventGeneric = vaxis.loop.handleEventGeneric;
const log = std.log.scoped(.vaxis_aio);

const Yield = enum { no_state, took_event };

/// zig-aio based event loop
/// <https://github.com/Cloudef/zig-aio>
pub fn LoopWithModules(T: type, aio: type, coro: type) type {
    return struct {
        const Event = T;

        winsize_task: ?coro.Task.Generic2(winsizeTask) = null,
        reader_task: ?coro.Task.Generic2(ttyReaderTask) = null,
        queue: std.BoundedArray(T, 512) = .{},
        source: aio.EventSource,
        fatal: bool = false,

        pub fn init() !@This() {
            return .{ .source = try aio.EventSource.init() };
        }

        pub fn deinit(self: *@This(), vx: *vaxis.Vaxis, tty: *vaxis.Tty) void {
            vx.deviceStatusReport(tty.anyWriter()) catch {};
            if (self.winsize_task) |task| task.cancel();
            if (self.reader_task) |task| task.cancel();
            self.source.deinit();
            self.* = undefined;
        }

        fn winsizeInner(self: *@This(), tty: *vaxis.Tty) !void {
            const Context = struct {
                loop: *@TypeOf(self.*),
                tty: *vaxis.Tty,
                winsize: ?vaxis.Winsize = null,
                fn cb(ptr: *anyopaque) void {
                    std.debug.assert(coro.current() == null);
                    const ctx: *@This() = @ptrCast(@alignCast(ptr));
                    ctx.winsize = vaxis.Tty.getWinsize(ctx.tty.fd) catch return;
                    ctx.loop.source.notify();
                }
            };

            // keep on stack
            var ctx: Context = .{ .loop = self, .tty = tty };
            if (builtin.target.os.tag != .windows) {
                if (@hasField(Event, "winsize")) {
                    const handler: vaxis.Tty.SignalHandler = .{ .context = &ctx, .callback = Context.cb };
                    try vaxis.Tty.notifyWinsize(handler);
                }
            }

            while (true) {
                try coro.io.single(aio.WaitEventSource{ .source = &self.source });
                if (ctx.winsize) |winsize| {
                    if (!@hasField(Event, "winsize")) unreachable;
                    ctx.loop.postEvent(.{ .winsize = winsize }) catch {};
                    ctx.winsize = null;
                }
            }
        }

        fn winsizeTask(self: *@This(), tty: *vaxis.Tty) void {
            self.winsizeInner(tty) catch |err| {
                if (err != error.Canceled) log.err("winsize: {}", .{err});
                self.fatal = true;
            };
        }

        fn windowsReadEvent(tty: *vaxis.Tty) !vaxis.Event {
            var state: vaxis.Tty.EventState = .{};
            while (true) {
                var bytes_read: usize = 0;
                var input_record: vaxis.Tty.INPUT_RECORD = undefined;
                try coro.io.single(aio.ReadTty{
                    .tty = .{ .handle = tty.stdin },
                    .buffer = std.mem.asBytes(&input_record),
                    .out_read = &bytes_read,
                });

                if (try tty.eventFromRecord(&input_record, &state)) |ev| {
                    return ev;
                }
            }
        }

        fn ttyReaderWindows(self: *@This(), vx: *vaxis.Vaxis, tty: *vaxis.Tty) !void {
            var cache: vaxis.GraphemeCache = .{};
            while (true) {
                const event = try windowsReadEvent(tty);
                try handleEventGeneric(self, vx, &cache, Event, event, null);
            }
        }

        fn ttyReaderPosix(self: *@This(), vx: *vaxis.Vaxis, tty: *vaxis.Tty, paste_allocator: ?std.mem.Allocator) !void {
            // initialize a grapheme cache
            var cache: vaxis.GraphemeCache = .{};

            // get our initial winsize
            const winsize = try vaxis.Tty.getWinsize(tty.fd);
            if (@hasField(Event, "winsize")) {
                try self.postEvent(.{ .winsize = winsize });
            }

            var parser: vaxis.Parser = .{
                .grapheme_data = &vx.unicode.width_data.g_data,
            };

            const file: std.fs.File = .{ .handle = tty.fd };
            while (true) {
                var buf: [4096]u8 = undefined;
                var n: usize = undefined;
                var read_start: usize = 0;
                try coro.io.single(aio.ReadTty{ .tty = file, .buffer = buf[read_start..], .out_read = &n });
                var seq_start: usize = 0;
                while (seq_start < n) {
                    const result = try parser.parse(buf[seq_start..n], paste_allocator);
                    if (result.n == 0) {
                        // copy the read to the beginning. We don't use memcpy because
                        // this could be overlapping, and it's also rare
                        const initial_start = seq_start;
                        while (seq_start < n) : (seq_start += 1) {
                            buf[seq_start - initial_start] = buf[seq_start];
                        }
                        read_start = seq_start - initial_start + 1;
                        continue;
                    }
                    read_start = 0;
                    seq_start += result.n;

                    const event = result.event orelse continue;
                    try handleEventGeneric(self, vx, &cache, Event, event, paste_allocator);
                }
            }
        }

        fn ttyReaderTask(self: *@This(), vx: *vaxis.Vaxis, tty: *vaxis.Tty, paste_allocator: ?std.mem.Allocator) void {
            return switch (builtin.target.os.tag) {
                .windows => self.ttyReaderWindows(vx, tty),
                else => self.ttyReaderPosix(vx, tty, paste_allocator),
            } catch |err| {
                if (err != error.Canceled) log.err("ttyReader: {}", .{err});
                self.fatal = true;
            };
        }

        /// Spawns tasks to handle winsize signal and tty
        pub fn spawn(
            self: *@This(),
            scheduler: *coro.Scheduler,
            vx: *vaxis.Vaxis,
            tty: *vaxis.Tty,
            paste_allocator: ?std.mem.Allocator,
            spawn_options: coro.Scheduler.SpawnOptions,
        ) coro.Scheduler.SpawnError!void {
            if (self.reader_task) |_| unreachable; // programming error
            // This is required even if app doesn't care about winsize
            // It is because it consumes the EventSource, so it can wakeup the scheduler
            // Without that custom `postEvent`'s wouldn't wake up the scheduler and UI wouldn't update
            self.winsize_task = try scheduler.spawn(winsizeTask, .{ self, tty }, spawn_options);
            self.reader_task = try scheduler.spawn(ttyReaderTask, .{ self, vx, tty, paste_allocator }, spawn_options);
        }

        pub const PopEventError = error{TtyCommunicationSevered};

        /// Call this in a while loop in the main event handler until it returns null
        pub fn popEvent(self: *@This()) PopEventError!?T {
            if (self.fatal) return error.TtyCommunicationSevered;
            defer self.winsize_task.?.wakeupIf(Yield.took_event);
            defer self.reader_task.?.wakeupIf(Yield.took_event);
            return self.queue.popOrNull();
        }

        pub const PostEventError = error{Overflow};

        pub fn postEvent(self: *@This(), event: T) !void {
            if (coro.current()) |_| {
                while (true) {
                    self.queue.insert(0, event) catch {
                        // wait for the app to take event
                        try coro.yield(Yield.took_event);
                        continue;
                    };
                    break;
                }
            } else {
                // queue can be full, app could handle this error by spinning the scheduler
                try self.queue.insert(0, event);
            }
            // wakes up the scheduler, so custom events update UI
            self.source.notify();
        }
    };
}
```
