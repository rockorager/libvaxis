const std = @import("std");
const builtin = @import("builtin");
const os = std.os;
const Vaxis = @import("vaxis.zig").Vaxis;
const Parser = @import("Parser.zig");
const GraphemeCache = @import("GraphemeCache.zig");
const select = @import("select.zig").select;

const log = std.log.scoped(.tty);

const Tty = @This();

const Writer = std.io.Writer(os.fd_t, os.WriteError, os.write);
const BufferedWriter = std.io.BufferedWriter(4096, Writer);

/// the original state of the terminal, prior to calling makeRaw
termios: os.termios,

/// the file descriptor we are using for I/O
fd: std.fs.File,

/// the write end of a pipe to signal the tty should exit its run loop
quit_fd: ?os.fd_t = null,

buffered_writer: BufferedWriter,

/// initializes a Tty instance by opening /dev/tty and "making it raw"
pub fn init() !Tty {
    // Open our tty
        const fd = try std.fs.cwd().openFile("/dev/tty", .{
            .mode = .read_write,
            .allow_ctty = true,
});

    // Set the termios of the tty
    const termios = try makeRaw(fd.handle);

    return Tty{
        .fd = fd,
        .termios = termios,
        .buffered_writer = std.io.bufferedWriter(Writer{ .context = fd.handle }),
    };
}

/// release resources associated with the Tty and return it to its original state
pub fn deinit(self: *Tty) void {
    os.tcsetattr(self.fd.handle, .FLUSH, self.termios) catch |err| {
        log.err("couldn't restore terminal: {}", .{err});
    };
    self.fd.close();
}

/// stops the run loop
pub fn stop(self: *Tty) void {
    if (self.quit_fd) |fd| {
        _ = std.os.write(fd, "q") catch {};
    }
}

/// read input from the tty
pub fn run(
    self: *Tty,
    comptime Event: type,
    vx: *Vaxis(Event),
) !void {
    // create a pipe so we can signal to exit the run loop
    const read_end, const write_end = try os.pipe();
    defer os.close(read_end);
    defer os.close(write_end);

    // get our initial winsize
    const winsize = try getWinsize(self.fd.handle);
    if (@hasField(Event, "winsize")) {
        vx.postEvent(.{ .winsize = winsize });
    }

    self.quit_fd = write_end;

    // Build a winch handler. We need build this struct to get an anonymous
    // function which can post the winsize event
    // TODO: more signals, move this outside of this function?
    const WinchHandler = struct {
        const Self = @This();

        var vx_winch: *Vaxis(Event) = undefined;
        var fd: os.fd_t = undefined;

        fn init(vx_arg: *Vaxis(Event), fd_arg: os.fd_t) !void {
            vx_winch = vx_arg;
            fd = fd_arg;
            var act = os.Sigaction{
                .handler = .{ .handler = Self.handleWinch },
                .mask = switch (builtin.os.tag) {
                    .macos => 0,
                    .linux => std.os.empty_sigset,
                    else => @compileError("os not supported"),
                },
                .flags = 0,
            };

            try os.sigaction(os.SIG.WINCH, &act, null);
        }

        fn handleWinch(_: c_int) callconv(.C) void {
            const ws = getWinsize(fd) catch {
                return;
            };
            if (@hasField(Event, "winsize")) {
                vx_winch.postEvent(.{ .winsize = ws });
            }
        }
    };
    try WinchHandler.init(vx, self.fd.handle);

    // initialize a grapheme cache
    var cache: GraphemeCache = .{};

    var parser: Parser = .{};

    // 2kb ought to be more than enough? given that we reset after each call?
    var io_buf: [2 * 1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&io_buf);

    // set up fds for selecting
        var selector = try select(fba.allocator(), enum { tty, quit }, .{
            .tty = self.fd,
        .quit = .{ .handle = read_end },
    });

    // read loop
    while (true) {
        fba.reset();
        try selector.select();

        if (selector.fifo(.quit).readableLength() > 0) {
            log.debug("quitting read thread", .{});
            return;
        }

        const tty = selector.fifo(.tty);
        const n = tty.readableLength();
        var start: usize = 0;
        defer tty.discard(n);
        while (start < n) {
            const result = try parser.parse(tty.readableSlice(start));
            start += result.n;
            // TODO: if we get 0 byte read, copy the remaining bytes to the
            // beginning of the buffer and read mmore? this should only happen
            // if we are in the middle of a grapheme at and filled our
            // buffer. Probably can happen on large pastes so needs to be
            // implemented but low priority

            const event = result.event orelse continue;
            switch (event) {
                .key_press => |key| {
                    if (@hasField(Event, "key_press")) {
                        // HACK: yuck. there has to be a better way
                        var mut_key = key;
                        if (key.text) |text| {
                            mut_key.text = cache.put(text);
                        }
                        vx.postEvent(.{ .key_press = mut_key });
                    }
                },
                .mouse => |mouse| {
                    if (@hasField(Event, "mouse")) {
                        vx.postEvent(.{ .mouse = mouse });
                    }
                },
                .focus_in => {
                    if (@hasField(Event, "focus_in")) {
                        vx.postEvent(.focus_in);
                    }
                },
                .focus_out => {
                    if (@hasField(Event, "focus_out")) {
                        vx.postEvent(.focus_out);
                    }
                },
                .paste_start => {
                    if (@hasField(Event, "paste_start")) {
                        vx.postEvent(.paste_start);
                    }
                },
                .paste_end => {
                    if (@hasField(Event, "paste_end")) {
                        vx.postEvent(.paste_end);
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
                    vx.caps.unicode = true;
                    vx.screen.unicode = true;
                },
                .cap_da1 => {
                    std.Thread.Futex.wake(&vx.query_futex, 10);
                },
            }
        }
    }
}

/// write to the tty. These writes are buffered and require calling flush to
/// flush writes to the tty
pub fn write(self: *Tty, bytes: []const u8) !usize {
    return self.buffered_writer.write(bytes);
}

/// flushes the write buffer to the tty
pub fn flush(self: *Tty) !void {
    try self.buffered_writer.flush();
}

/// makeRaw enters the raw state for the terminal.
pub fn makeRaw(fd: os.fd_t) !os.termios {
    const state = try os.tcgetattr(fd);
    var raw = state;
    // see termios(3)
    raw.iflag.IGNBRK = false;
    raw.iflag.BRKINT = false;
    raw.iflag.PARMRK = false;
    raw.iflag.ISTRIP = false;
    raw.iflag.INLCR = false;
    raw.iflag.IGNCR = false;
    raw.iflag.ICRNL = false;
    raw.iflag.IXON = false;
    raw.iflag.IUTF8 = true;

    raw.oflag.OPOST = false;

    raw.lflag.ECHO = false;
    raw.lflag.ECHONL = false;
    raw.lflag.ICANON = false;
    raw.lflag.ISIG = false;
    raw.lflag.IEXTEN = false;

    raw.cflag.CSIZE = .CS8;
    raw.cflag.PARENB = false;

    raw.cc[@intFromEnum(std.posix.V.MIN)] = 1;
    raw.cc[@intFromEnum(std.posix.V.TIME)] = 0;
    try os.tcsetattr(fd, .FLUSH, raw);

    return state;
}

/// The size of the terminal screen
pub const Winsize = @import("Tty.zig").Winsize;

fn getWinsize(fd: os.fd_t) !Winsize {
    var winsize = os.winsize{
        .ws_row = 0,
        .ws_col = 0,
        .ws_xpixel = 0,
        .ws_ypixel = 0,
    };

    const TIOCGWINSZ = 1074295912;
    const err = os.system.ioctl(fd, @as(c_int, TIOCGWINSZ), @intFromPtr(&winsize));
    const e = os.errno(err);
    if (e == .SUCCESS)
        return Winsize{
            .rows = winsize.ws_row,
            .cols = winsize.ws_col,
            .x_pixel = winsize.ws_xpixel,
            .y_pixel = winsize.ws_ypixel,
        };
    return error.IoctlError;
}

test "run" {
    if (true) return error.SkipZigTest;
    const TestEvent = union(enum) {
        winsize: Winsize,
        key_press: @import("Key.zig"),
    };

    var vx = try Vaxis(TestEvent).init(.{});
    defer vx.deinit(null);
    var tty = try init();
    defer tty.deinit();

    const inner = struct {
        fn f(t: *Tty) void {
            std.time.sleep(std.time.ns_per_s);
            t.stop();
        }
    };

    const pid = try std.Thread.spawn(.{}, inner.f, .{&tty});
    defer pid.join();

    try tty.run(TestEvent, &vx);
}

test "get winsize" {
    const tty = try init();
    _ = try getWinsize(tty.fd);
}
