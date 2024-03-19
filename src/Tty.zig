const std = @import("std");
const builtin = @import("builtin");
const os = std.os;
const Vaxis = @import("vaxis.zig").Vaxis;
const Parser = @import("Parser.zig");
const GraphemeCache = @import("GraphemeCache.zig");
const ctlseqs = @import("ctlseqs.zig");

const log = std.log.scoped(.tty);

const Tty = @This();

const Writer = std.io.Writer(os.fd_t, os.WriteError, os.write);

const BufferedWriter = std.io.BufferedWriter(4096, Writer);

/// the original state of the terminal, prior to calling makeRaw
termios: os.termios,

/// The file descriptor we are using for I/O
fd: os.fd_t,

should_quit: bool = false,

buffered_writer: BufferedWriter,

/// initializes a Tty instance by opening /dev/tty and "making it raw"
pub fn init() !Tty {
    // Open our tty
    const fd = try os.open("/dev/tty", .{ .ACCMODE = .RDWR }, 0);

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
    os.tcsetattr(self.fd, .FLUSH, self.termios) catch |err| {
        log.err("couldn't restore terminal: {}", .{err});
    };
    os.close(self.fd);
}

/// stops the run loop
pub fn stop(self: *Tty) void {
    self.should_quit = true;
    _ = std.os.write(self.fd, ctlseqs.device_status_report) catch {};
}

/// read input from the tty
pub fn run(
    self: *Tty,
    comptime Event: type,
    vx: *Vaxis(Event),
) !void {

    // get our initial winsize
    const winsize = try getWinsize(self.fd);
    if (@hasField(Event, "winsize")) {
        vx.postEvent(.{ .winsize = winsize });
    }

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

    var parser: Parser = .{};

    // initialize the read buffer
    var buf: [1024]u8 = undefined;
    // read loop
    while (!self.should_quit) {
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

    raw.cc[@intFromEnum(std.posix.V.MIN)] = 1;
    raw.cc[@intFromEnum(std.posix.V.TIME)] = 0;
    try os.tcsetattr(fd, .FLUSH, raw);
    return state;
}

/// The size of the terminal screen
pub const Winsize = struct {
    rows: usize,
    cols: usize,
    x_pixel: usize,
    y_pixel: usize,
};

fn getWinsize(fd: os.fd_t) !Winsize {
    var winsize = os.winsize{
        .ws_row = 0,
        .ws_col = 0,
        .ws_xpixel = 0,
        .ws_ypixel = 0,
    };

    const err = os.system.ioctl(fd, os.T.IOCGWINSZ, @intFromPtr(&winsize));
    if (os.errno(err) == .SUCCESS)
        return Winsize{
            .rows = winsize.ws_row,
            .cols = winsize.ws_col,
            .x_pixel = winsize.ws_xpixel,
            .y_pixel = winsize.ws_ypixel,
        };
    return error.IoctlError;
}
