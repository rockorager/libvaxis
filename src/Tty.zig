const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const Loop = @import("Loop.zig").Loop;
const Parser = @import("Parser.zig");
const GraphemeCache = @import("GraphemeCache.zig");
const ctlseqs = @import("ctlseqs.zig");
const grapheme = @import("grapheme");

const log = std.log.scoped(.tty);

const Tty = @This();

const Writer = std.io.Writer(posix.fd_t, posix.WriteError, posix.write);
const BufferedWriter = std.io.BufferedWriter(4096, Writer);

/// the original state of the terminal, prior to calling makeRaw
termios: posix.termios,

/// The file descriptor we are using for I/O
fd: posix.fd_t,

should_quit: bool = false,

buffered_writer: BufferedWriter,

state: struct {
    /// if we are in the alt screen
    alt_screen: bool = false,
    /// if we have entered kitty keyboard
    kitty_keyboard: bool = false,
    bracketed_paste: bool = false,
    mouse: bool = false,
    pixel_mouse: bool = false,
    cursor: struct {
        row: usize = 0,
        col: usize = 0,
    } = .{},
} = .{},

/// initializes a Tty instance by opening /dev/tty and "making it raw"
pub fn init() !Tty {
    // Open our tty
    const fd = try posix.open("/dev/tty", .{ .ACCMODE = .RDWR }, 0);

    // Set the termios of the tty
    const termios = try makeRaw(fd);

    return Tty{
        .fd = fd,
        .termios = termios,
        .buffered_writer = std.io.bufferedWriter(Writer{ .context = fd }),
    };
}

/// release resources associated with the Tty return it to its original state
pub fn deinit(self: *Tty) void {
    if (self.state.kitty_keyboard) {
        _ = self.write(ctlseqs.csi_u_pop) catch {};
    }
    if (self.state.mouse) {
        _ = self.write(ctlseqs.mouse_reset) catch {};
    }
    if (self.state.bracketed_paste) {
        _ = self.write(ctlseqs.bp_reset) catch {};
    }
    if (self.state.alt_screen) {
        _ = self.write(ctlseqs.rmcup) catch {};
    }
    // always show the cursor on exit
    _ = self.write(ctlseqs.show_cursor) catch {};
    self.flush() catch {};
    posix.tcsetattr(self.fd, .FLUSH, self.termios) catch |err| {
        log.err("couldn't restore terminal: {}", .{err});
    };
    if (builtin.os.tag != .macos) // closing /dev/tty may block indefinitely on macos
        posix.close(self.fd);
}

/// stops the run loop
pub fn stop(self: *Tty) void {
    self.should_quit = true;
    _ = posix.write(self.fd, ctlseqs.device_status_report) catch |err| {
        log.err("TTY Stop Error: {}", .{err});
    };
}

/// read input from the tty
pub fn run(
    self: *Tty,
    comptime Event: type,
    loop: *Loop(Event),
    grapheme_data: *const grapheme.GraphemeData,
    paste_allocator: ?std.mem.Allocator,
) !void {
    // get our initial winsize
    const winsize = try getWinsize(self.fd);
    if (@hasField(Event, "winsize")) {
        loop.postEvent(.{ .winsize = winsize });
    }

    // Build a winch handler. We need build this struct to get an anonymous
    // function which can post the winsize event
    // TODO: more signals, move this outside of this function?
    const WinchHandler = struct {
        const Self = @This();

        var vx_winch: *Loop(Event) = undefined;
        var fd: posix.fd_t = undefined;

        fn init(vx_arg: *Loop(Event), fd_arg: posix.fd_t) !void {
            vx_winch = vx_arg;
            fd = fd_arg;
            var act = posix.Sigaction{
                .handler = .{ .handler = Self.handleWinch },
                .mask = switch (builtin.os.tag) {
                    .macos => 0,
                    .linux => posix.empty_sigset,
                    else => @compileError("os not supported"),
                },
                .flags = 0,
            };

            try posix.sigaction(posix.SIG.WINCH, &act, null);
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
    try WinchHandler.init(loop, self.fd);

    // initialize a grapheme cache
    var cache: GraphemeCache = .{};

    var parser: Parser = .{
        .grapheme_data = grapheme_data,
    };

    // initialize the read buffer
    var buf: [1024]u8 = undefined;
    var read_start: usize = 0;
    // read loop
    while (!self.should_quit) {
        const n = try posix.read(self.fd, buf[read_start..]);
        var start: usize = 0;
        while (start < n) {
            const result = try parser.parse(buf[start..n], paste_allocator);
            if (result.n == 0) {
                // copy the read to the beginning. We don't use memcpy because
                // this could be overlapping, and it's also rare
                const initial_start = start;
                while (start < n) : (start += 1) {
                    buf[start - initial_start] = buf[start];
                }
                read_start = start - initial_start + 1;
                continue;
            }
            read_start = 0;
            start += result.n;

            const event = result.event orelse continue;
            switch (event) {
                .key_press => |key| {
                    if (@hasField(Event, "key_press")) {
                        // HACK: yuck. there has to be a better way
                        var mut_key = key;
                        if (key.text) |text| {
                            mut_key.text = cache.put(text);
                        }
                        loop.postEvent(.{ .key_press = mut_key });
                    }
                },
                .key_release => |*key| {
                    if (@hasField(Event, "key_release")) {
                        // HACK: yuck. there has to be a better way
                        var mut_key = key;
                        if (key.text) |text| {
                            mut_key.text = cache.put(text);
                        }
                        loop.postEvent(.{ .key_release = mut_key });
                    }
                },
                .mouse => |mouse| {
                    if (@hasField(Event, "mouse")) {
                        loop.postEvent(.{ .mouse = loop.vaxis.translateMouse(mouse) });
                    }
                },
                .focus_in => {
                    if (@hasField(Event, "focus_in")) {
                        loop.postEvent(.focus_in);
                    }
                },
                .focus_out => {
                    if (@hasField(Event, "focus_out")) {
                        loop.postEvent(.focus_out);
                    }
                },
                .paste_start => {
                    if (@hasField(Event, "paste_start")) {
                        loop.postEvent(.paste_start);
                    }
                },
                .paste_end => {
                    if (@hasField(Event, "paste_end")) {
                        loop.postEvent(.paste_end);
                    }
                },
                .paste => |text| {
                    if (@hasField(Event, "paste")) {
                        loop.postEvent(.{ .paste = text });
                    } else {
                        if (paste_allocator) |_|
                            paste_allocator.?.free(text);
                    }
                },
                .cap_kitty_keyboard => {
                    log.info("kitty keyboard capability detected", .{});
                    loop.vaxis.caps.kitty_keyboard = true;
                },
                .cap_kitty_graphics => {
                    if (!loop.vaxis.caps.kitty_graphics) {
                        log.info("kitty graphics capability detected", .{});
                        loop.vaxis.caps.kitty_graphics = true;
                    }
                },
                .cap_rgb => {
                    log.info("rgb capability detected", .{});
                    loop.vaxis.caps.rgb = true;
                },
                .cap_unicode => {
                    log.info("unicode capability detected", .{});
                    loop.vaxis.caps.unicode = .unicode;
                    loop.vaxis.screen.width_method = .unicode;
                },
                .cap_sgr_pixels => {
                    log.info("pixel mouse capability detected", .{});
                    loop.vaxis.caps.sgr_pixels = true;
                },
                .cap_da1 => {
                    std.Thread.Futex.wake(&loop.vaxis.query_futex, 10);
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
pub fn makeRaw(fd: posix.fd_t) !posix.termios {
    const state = try posix.tcgetattr(fd);
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

    raw.oflag.OPOST = false;

    raw.lflag.ECHO = false;
    raw.lflag.ECHONL = false;
    raw.lflag.ICANON = false;
    raw.lflag.ISIG = false;
    raw.lflag.IEXTEN = false;

    raw.cflag.CSIZE = .CS8;
    raw.cflag.PARENB = false;

    raw.cc[@intFromEnum(posix.V.MIN)] = 1;
    raw.cc[@intFromEnum(posix.V.TIME)] = 0;
    try posix.tcsetattr(fd, .FLUSH, raw);
    return state;
}

/// The size of the terminal screen
pub const Winsize = struct {
    rows: usize,
    cols: usize,
    x_pixel: usize,
    y_pixel: usize,
};

pub fn getWinsize(fd: posix.fd_t) !Winsize {
    var winsize = posix.winsize{
        .ws_row = 0,
        .ws_col = 0,
        .ws_xpixel = 0,
        .ws_ypixel = 0,
    };

    const err = posix.system.ioctl(fd, posix.T.IOCGWINSZ, @intFromPtr(&winsize));
    if (posix.errno(err) == .SUCCESS)
        return Winsize{
            .rows = winsize.ws_row,
            .cols = winsize.ws_col,
            .x_pixel = winsize.ws_xpixel,
            .y_pixel = winsize.ws_ypixel,
        };
    return error.IoctlError;
}
