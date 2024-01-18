const std = @import("std");
const os = std.os;
const xev = @import("xev");

const log = std.log.scoped(.tty);

const Tty = @This();

/// the original state of the terminal, prior to calling makeRaw
termios: os.termios,

/// The file descriptor we are using for I/O
fd: os.fd_t,

/// Stream attached to our fd
stream: xev.Stream,

/// event loop
loop: xev.Loop,

read_buffer: [1024]u8 = undefined,

/// initializes a Tty instance by opening /dev/tty and "making it raw"
pub fn init() !Tty {
    // Open our tty
    const fd = try os.open("/dev/tty", os.system.O.RDWR, 0);

    // Initialize the stream
    const stream = xev.Stream.initFd(fd);

    // Initialize event loop
    const loop = try xev.Loop.init(.{});

    // Set the termios of the tty
    const termios = try makeRaw(fd);

    return Tty{
        .fd = fd,
        .stream = stream,
        .termios = termios,
        .loop = loop,
    };
}

/// release resources associated with the Tty return it to it's original state
pub fn deinit(self: *Tty) void {
    os.tcsetattr(self.fd, .FLUSH, self.termios) catch |err| {
        log.err("couldn't restore terminal: {}", .{err});
    };
    os.close(self.fd);
    self.stream.deinit();
    self.loop.deinit();
}

/// read input from the tty
pub fn run(self: *Tty) !void {
    var c_stream: xev.Completion = undefined;

    // Initialize our read event
    self.stream.read(
        &self.loop,
        &c_stream,
        .{ .slice = self.read_buffer[0..] },
        Tty,
        self,
        readCallback,
    );

    try self.loop.run(.until_done);
}

fn readCallback(
    ud: ?*Tty,
    loop: *xev.Loop,
    c: *xev.Completion,
    stream: xev.Stream,
    buf: xev.ReadBuffer,
    r: xev.ReadError!usize,
) xev.CallbackAction {
    _ = stream; // autofix
    _ = c; // autofix
    _ = loop; // autofix
    const tty = ud.?;
    _ = tty; // autofix
    const n = r catch |err| {
        // Log the error and shutdown
        log.err("read error: {}", .{err});
        return .disarm;
    };
    log.info("{s}\r", .{buf.slice[0..n]});
    return .rearm;
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
