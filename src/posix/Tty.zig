//! TTY implementation conforming to posix standards
const Posix = @This();

const std = @import("std");
const builtin = @import("builtin");

const posix = std.posix;
const Winsize = @import("../main.zig").Winsize;

/// the original state of the terminal, prior to calling makeRaw
termios: posix.termios,

/// The file descriptor of the tty
fd: posix.fd_t,

pub const SignalHandler = struct {
    context: *anyopaque,
    callback: *const fn (context: *anyopaque) void,
};

/// global signal handlers
var handlers: [8]SignalHandler = undefined;
var handler_mutex: std.Thread.Mutex = .{};
var handler_idx: usize = 0;

var handler_installed: bool = false;

/// global tty instance, used in case of a panic. Not guaranteed to work if
/// for some reason there are multiple TTYs open under a single vaxis
/// compilation unit - but this is better than nothing
pub var global_tty: ?Posix = null;

/// initializes a Tty instance by opening /dev/tty and "making it raw". A
/// signal handler is installed for SIGWINCH. No callbacks are installed, be
/// sure to register a callback when initializing the event loop
pub fn init() !Posix {
    // Open our tty
    const fd = try posix.open("/dev/tty", .{ .ACCMODE = .RDWR }, 0);

    // Set the termios of the tty
    const termios = try makeRaw(fd);

    var act = posix.Sigaction{
        .handler = .{ .handler = Posix.handleWinch },
        .mask = switch (builtin.os.tag) {
            .macos => 0,
            .linux => posix.empty_sigset,
            .freebsd => posix.empty_sigset,
            else => @compileError("os not supported"),
        },
        .flags = 0,
    };
    try posix.sigaction(posix.SIG.WINCH, &act, null);
    handler_installed = true;

    const self: Posix = .{
        .fd = fd,
        .termios = termios,
    };

    global_tty = self;

    return self;
}

/// release resources associated with the Tty return it to its original state
pub fn deinit(self: Posix) void {
    posix.tcsetattr(self.fd, .FLUSH, self.termios) catch |err| {
        std.log.err("couldn't restore terminal: {}", .{err});
    };
    if (builtin.os.tag != .macos) // closing /dev/tty may block indefinitely on macos
        posix.close(self.fd);
}

/// Resets the signal handler to it's default
pub fn resetSignalHandler() void {
    if (!handler_installed) return;
    handler_installed = false;
    var act = posix.Sigaction{
        .handler = posix.SIG.DFL,
        .mask = switch (builtin.os.tag) {
            .macos => 0,
            .linux => posix.empty_sigset,
            .freebsd => posix.empty_sigset,
            else => @compileError("os not supported"),
        },
        .flags = 0,
    };
    posix.sigaction(posix.SIG.WINCH, &act, null) catch {};
}

/// Write bytes to the tty
pub fn write(self: *const Posix, bytes: []const u8) !usize {
    return posix.write(self.fd, bytes);
}

pub fn opaqueWrite(ptr: *const anyopaque, bytes: []const u8) !usize {
    const self: *const Posix = @ptrCast(@alignCast(ptr));
    return posix.write(self.fd, bytes);
}

pub fn anyWriter(self: *const Posix) std.io.AnyWriter {
    return .{
        .context = self,
        .writeFn = Posix.opaqueWrite,
    };
}

pub fn read(self: *const Posix, buf: []u8) !usize {
    return posix.read(self.fd, buf);
}

pub fn opaqueRead(ptr: *const anyopaque, buf: []u8) !usize {
    const self: *const Posix = @ptrCast(@alignCast(ptr));
    return posix.read(self.fd, buf);
}

pub fn anyReader(self: *const Posix) std.io.AnyReader {
    return .{
        .context = self,
        .readFn = Posix.opaqueRead,
    };
}

/// Install a signal handler for winsize. A maximum of 8 handlers may be
/// installed
pub fn notifyWinsize(handler: SignalHandler) !void {
    handler_mutex.lock();
    defer handler_mutex.unlock();
    if (handler_idx == handlers.len) return error.OutOfMemory;
    handlers[handler_idx] = handler;
    handler_idx += 1;
}

fn handleWinch(_: c_int) callconv(.C) void {
    handler_mutex.lock();
    defer handler_mutex.unlock();
    var i: usize = 0;
    while (i < handler_idx) : (i += 1) {
        const handler = handlers[i];
        handler.callback(handler.context);
    }
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

/// Get the window size from the kernel
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

pub fn bufferedWriter(self: *const Posix) std.io.BufferedWriter(4096, std.io.AnyWriter) {
    return std.io.bufferedWriter(self.anyWriter());
}
