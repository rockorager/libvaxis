const build_options = @import("build_options");
const builtin = @import("builtin");
const std = @import("std");
const vaxis = @import("main.zig");
const handleEventGeneric = @import("Loop.zig").handleEventGeneric;
const log = std.log.scoped(.vaxis_aio);

const Yield = enum { no_state, took_event };

pub fn Loop(T: type) type {
    if (!build_options.aio) {
        @compileError(
            \\build_options.aio is not enabled.
            \\Use `LoopWithModules` instead to provide `aio` and `coro` modules from outside vaxis.
        );
    }
    return LoopWithModules(T, @import("aio"), @import("coro"));
}

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
                .grapheme_data = &vx.unicode.grapheme_data,
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
