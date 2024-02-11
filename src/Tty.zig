const std = @import("std");
const builtin = @import("builtin");
const os = std.os;
const Vaxis = @import("vaxis.zig").Vaxis;
const Parser = @import("Parser.zig");
const GraphemeCache = @import("GraphemeCache.zig");

const log = std.log.scoped(.tty);

const Tty = @This();

const Writer = std.io.Writer(os.fd_t, os.WriteError, os.write);

const BufferedWriter = std.io.BufferedWriter(4096, Writer);

const system = switch (builtin.os.tag) {
    .linux => os.linux,
    .plan9 => os.plan9,
    .wasi => os.wasi,
    .uefi => os.uefi,
    else => std.c,
};

/// the original state of the terminal, prior to calling makeRaw
termios: os.termios,

/// The file descriptor we are using for I/O
fd: os.fd_t,

/// the write end of a pipe to signal the tty should exit it's run loop
quit_fd: ?os.fd_t = null,

buffered_writer: BufferedWriter,

/// initializes a Tty instance by opening /dev/tty and "making it raw"
pub fn init() !Tty {
    // Open our tty
    const fd = try os.open("/dev/tty", os.system.O.RDWR, 0);

    // Set the termios of the tty
    const termios = try makeRaw(fd);

    return Tty{
        .fd = fd,
        .termios = termios,
        .buffered_writer = std.io.bufferedWriter(Writer{ .context = fd }),
    };
}

/// release resources associated with the Tty return it to it's original state
pub fn deinit(self: *Tty) void {
    os.tcsetattr(self.fd, .FLUSH, self.termios) catch |err| {
        log.err("couldn't restore terminal: {}", .{err});
    };
    os.close(self.fd);
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
    const pipe = try os.pipe();
    defer os.close(pipe[0]);
    defer os.close(pipe[1]);

    // get our initial winsize
    const winsize = try getWinsize(self.fd);
    if (@hasField(Event, "winsize")) {
        vx.postEvent(.{ .winsize = winsize });
    }

    // assign the write end of the pipe to our quit_fd
    self.quit_fd = pipe[1];

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
    try WinchHandler.init(vx, self.fd);

    // initialize a grapheme cache
    var cache: GraphemeCache = .{};

    // Set up fds for polling
    var pollfds: [2]std.os.pollfd = .{
        .{ .fd = self.fd, .events = std.os.POLL.IN, .revents = undefined },
        .{ .fd = pipe[0], .events = std.os.POLL.IN, .revents = undefined },
    };

    var parser: Parser = .{};

    // initialize the read buffer
    var buf: [1024]u8 = undefined;
    // read loop
    while (true) {
        _ = try std.os.poll(&pollfds, -1);
        if (pollfds[1].revents & std.os.POLL.IN != 0) {
            log.info("quitting read thread", .{});
            return;
        }

        const n = try os.read(self.fd, &buf);
        var start: usize = 0;
        while (start < n) {
            const result = try parser.parse(buf[start..n]);
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
    raw.iflag &= ~@as(
        os.tcflag_t,
        system.IGNBRK |
            system.BRKINT |
            system.PARMRK |
            system.ISTRIP |
            system.INLCR |
            system.IGNCR |
            system.ICRNL |
            system.IXON,
    );
    raw.oflag &= ~@as(os.tcflag_t, system.OPOST);
    raw.lflag &= ~@as(
        os.tcflag_t,
        system.ECHO |
            system.ECHONL |
            system.ICANON |
            system.ISIG |
            system.IEXTEN,
    );
    raw.cflag &= ~@as(
        os.tcflag_t,
        system.CSIZE |
            system.PARENB,
    );
    raw.cflag |= @as(
        os.tcflag_t,
        system.CS8,
    );
    raw.cc[system.V.MIN] = 1;
    raw.cc[system.V.TIME] = 0;
    try os.tcsetattr(fd, .FLUSH, raw);
    return state;
}

const TIOCGWINSZ = switch (builtin.os.tag) {
    .linux => 0x5413,
    .macos => ior(0x40000000, 't', 104, @sizeOf(system.winsize)),
    else => @compileError("Missing termiosbits for this target, sorry."),
};

const IOCPARM_MASK = 0x1fff;
fn ior(inout: u32, group: usize, num: usize, len: usize) usize {
    return (inout | ((len & IOCPARM_MASK) << 16) | ((group) << 8) | (num));
}

/// The size of the terminal screen
pub const Winsize = struct {
    rows: usize,
    cols: usize,
    x_pixel: usize,
    y_pixel: usize,
};

fn getWinsize(fd: os.fd_t) !Winsize {
    var winsize = system.winsize{
        .ws_row = 0,
        .ws_col = 0,
        .ws_xpixel = 0,
        .ws_ypixel = 0,
    };

    const err = os.system.ioctl(fd, TIOCGWINSZ, @intFromPtr(&winsize));
    if (os.errno(err) == .SUCCESS)
        return Winsize{
            .rows = winsize.ws_row,
            .cols = winsize.ws_col,
            .x_pixel = winsize.ws_xpixel,
            .y_pixel = winsize.ws_ypixel,
        };
    return error.IoctlError;
}
