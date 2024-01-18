const std = @import("std");
const os = std.os;
const xev = @import("xev");

const log = std.log.scoped(.tty);

const Tty = @This();

/// the original state of the terminal, prior to calling makeRaw
termios: os.termios,

/// The file descriptor we are using for I/O
fd: os.fd_t,

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

/// read input from the tty
pub fn run(self: *Tty, quit: os.fd_t) !void {
    defer os.close(quit);
    var buf: [1024]u8 = undefined;
    var pollfds: [2]std.os.pollfd = .{
        .{ .fd = self.fd, .events = std.os.POLL.IN, .revents = undefined },
        .{ .fd = quit, .events = std.os.POLL.IN, .revents = undefined },
    };
    while (true) {
        _ = try std.os.poll(&pollfds, -1);
        if (pollfds[1].revents & std.os.POLL.IN != 0) {
            log.info("read thread got quit signal", .{});
            return;
        }

        const n = try os.read(self.fd, &buf);
        log.err("{s}", .{buf[0..n]});
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
