const std = @import("std");
const builtin = @import("builtin");
const os = std.os;
const vaxis = @import("main.zig");
const Vaxis = vaxis.Vaxis;
const Key = vaxis.Key;

const log = std.log.scoped(.tty);

const Tty = @This();

/// the original state of the terminal, prior to calling makeRaw
termios: os.termios,

/// The file descriptor we are using for I/O
fd: os.fd_t,

/// the write end of a pipe to signal the tty should exit it's run loop
quit_fd: ?os.fd_t = null,

/// initializes a Tty instance by opening /dev/tty and "making it raw"
pub fn init() !Tty {
    // Open our tty
    const fd = try os.open("/dev/tty", os.system.O.RDWR, 0);

    // Set the termios of the tty
    const termios = try makeRaw(fd);

    return Tty{
        .fd = fd,
        .termios = termios,
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
    comptime EventType: type,
    vx: *Vaxis(EventType),
) !void {
    // create a pipe so we can signal to exit the run loop
    const pipe = try os.pipe();
    defer os.close(pipe[0]);
    defer os.close(pipe[1]);

    // get our initial winsize
    const winsize = try getWinsize(self.fd);
    if (@hasField(EventType, "winsize")) {
        vx.postEvent(.{ .winsize = winsize });
    }

    // assign the write end of the pipe to our quit_fd
    self.quit_fd = pipe[1];

    // Build a winch handler. We need build this struct to get an anonymous
    // function which can post the winsize event
    // TODO: more signals, move this outside of this function?
    const WinchHandler = struct {
        const Self = @This();

        var vx_winch: *Vaxis(EventType) = undefined;
        var fd: os.fd_t = undefined;

        fn init(vx_arg: *Vaxis(EventType), fd_arg: os.fd_t) !void {
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
            if (@hasField(EventType, "winsize")) {
                vx_winch.postEvent(.{ .winsize = ws });
            }
        }
    };
    try WinchHandler.init(vx, self.fd);

    // the state of the parser
    const State = enum {
        ground,
        escape,
        csi,
        osc,
        dcs,
        sos,
        pm,
        apc,
        ss2,
        ss3,
    };

    var state: State = .ground;

    // Set up fds for polling
    var pollfds: [2]std.os.pollfd = .{
        .{ .fd = self.fd, .events = std.os.POLL.IN, .revents = undefined },
        .{ .fd = pipe[0], .events = std.os.POLL.IN, .revents = undefined },
    };

    // initialize the read buffer
    var buf: [1024]u8 = undefined;
    while (true) {
        _ = try std.os.poll(&pollfds, -1);
        if (pollfds[1].revents & std.os.POLL.IN != 0) {
            log.info("quitting read thread", .{});
            return;
        }

        const n = try os.read(self.fd, &buf);
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const b = buf[i];
            switch (state) {
                .ground => {
                    const key: ?Key = switch (b) {
                        0x00 => Key{ .codepoint = '@', .mods = .{ .ctrl = true } },
                        0x01...0x1A => Key{ .codepoint = b + 0x60, .mods = .{ .ctrl = true } },
                        0x1B => escape: {
                            // NOTE: This could be an errant escape at the end
                            // of a large read. That is _incredibly_ unlikely
                            // given the size of read inputs and our read buffer
                            if (i == (n - 1)) {
                                const event = Key{
                                    .codepoint = Key.escape,
                                };
                                break :escape event;
                            }
                            state = .escape;
                            break :escape null;
                        },
                        0x20...0x7E => Key{ .codepoint = b },
                        0x7F => Key{ .codepoint = Key.backspace },
                        else => Key{ .codepoint = b },
                    };
                    if (key) |k| {
                        if (@hasField(EventType, "key_press")) {
                            vx.postEvent(.{ .key_press = k });
                        }
                    }
                },
                .escape => state = .ground,
                else => {},
            }
        }
    }
}

const Writer = std.io.Writer(os.fd_t, os.WriteError, os.write);

pub fn writer(self: *Tty) Writer {
    return .{ .context = self.fd };
}
/// write to the tty
//
// TODO: buffer the writes
pub fn write(self: *Tty, bytes: []const u8) !usize {
    return os.write(self.fd, bytes);
}

/// makeRaw enters the raw state for the terminal.
pub fn makeRaw(fd: os.fd_t) !os.termios {
    const state = try os.tcgetattr(fd);
    var raw = state;
    // see termios(3)
    raw.iflag &= ~@as(
        os.tcflag_t,
        os.system.IGNBRK |
            os.system.BRKINT |
            os.system.PARMRK |
            os.system.ISTRIP |
            os.system.INLCR |
            os.system.IGNCR |
            os.system.ICRNL |
            os.system.IXON,
    );
    raw.oflag &= ~@as(os.tcflag_t, os.system.OPOST);
    raw.lflag &= ~@as(
        os.tcflag_t,
        os.system.ECHO |
            os.system.ECHONL |
            os.system.ICANON |
            os.system.ISIG |
            os.system.IEXTEN,
    );
    raw.cflag &= ~@as(
        os.tcflag_t,
        os.system.CSIZE |
            os.system.PARENB,
    );
    raw.cflag |= @as(
        os.tcflag_t,
        os.system.CS8,
    );
    raw.cc[os.system.V.MIN] = 1;
    raw.cc[os.system.V.TIME] = 0;
    try os.tcsetattr(fd, .FLUSH, raw);
    return state;
}

const TIOCGWINSZ = switch (builtin.os.tag) {
    .linux => 0x5413,
    .macos => ior(0x40000000, 't', 104, @sizeOf(os.system.winsize)),
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
    var winsize = os.system.winsize{
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
