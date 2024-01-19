const std = @import("std");
const os = std.os;
const odditui = @import("main.zig");
const App = odditui.App;
const Key = odditui.Key;

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
    app: *App(EventType),
) !void {
    // create a pipe so we can signal to exit the run loop
    const pipe = try os.pipe();
    defer os.close(pipe[0]);
    defer os.close(pipe[1]);

    // assign the write end of the pipe to our quit_fd
    self.quit_fd = pipe[1];

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
                        app.postEvent(.{ .key_press = k });
                    }
                },
                .escape => state = .ground,
                else => {},
            }
        }
    }
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
