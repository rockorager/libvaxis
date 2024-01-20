const std = @import("std");
const builtin = @import("builtin");
const os = std.os;
const vaxis = @import("main.zig");
const Vaxis = vaxis.Vaxis;
const Key = vaxis.Key;

const log = std.log.scoped(.tty);

const Tty = @This();

const Writer = std.io.Writer(os.fd_t, os.WriteError, os.write);

const BufferedWriter = std.io.BufferedWriter(4096, Writer);

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

    // an intermediate data structure to hold sequence data while we are
    // scanning more bytes. This is tailored for input parsing only
    const Sequence = struct {
        // private indicators are 0x3C-0x3F
        private_indicator: ?u8 = null,
        // we won't be handling any sequences with more than one intermediate
        intermediate: ?u8 = null,
        // we should absolutely never have more then 16 params
        params: [16]u16 = undefined,
        param_idx: usize = 0,
        param_buf: [8]u8 = undefined,
        param_buf_idx: usize = 0,
        sub_state: std.StaticBitSet(16) = std.StaticBitSet(16).initEmpty(),
    };

    var seq: Sequence = .{};

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
        var start: usize = 0;
        while (i < n) : (i += 1) {
            const b = buf[i];
            switch (state) {
                .ground => {
                    // ground state generates keypresses when parsing input. We
                    // generally get ascii characters, but anything less than
                    // 0x20 is a Ctrl+<c> keypress. We map these to lowercase
                    // ascii characters when we can
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
                .escape => {
                    seq = .{};
                    start = i;
                    switch (b) {
                        0x4F => state = .ss3,
                        0x50 => state = .dcs,
                        0x58 => state = .sos,
                        0x5B => state = .csi,
                        0x5D => state = .osc,
                        0x5E => state = .pm,
                        0x5F => state = .apc,
                        else => {
                            // Anything else is an "alt + <b>" keypress
                            if (@hasField(EventType, "key_press")) {
                                vx.postEvent(.{
                                    .key_press = .{
                                        .codepoint = b,
                                        .mods = .{ .alt = true },
                                    },
                                });
                            }
                            state = .ground;
                        },
                    }
                },
                .ss3 => {
                    const key: ?Key = switch (b) {
                        'A' => .{ .codepoint = Key.up },
                        'B' => .{ .codepoint = Key.down },
                        'C' => .{ .codepoint = Key.right },
                        'D' => .{ .codepoint = Key.left },
                        'F' => .{ .codepoint = Key.end },
                        'H' => .{ .codepoint = Key.home },
                        'P' => .{ .codepoint = Key.f1 },
                        'Q' => .{ .codepoint = Key.f2 },
                        'R' => .{ .codepoint = Key.f3 },
                        'S' => .{ .codepoint = Key.f4 },
                        else => blk: {
                            log.warn("unhandled ss3: {x}", .{b});
                            break :blk null;
                        },
                    };
                    if (key) |k| {
                        if (@hasField(EventType, "key_press")) {
                            vx.postEvent(.{ .key_press = k });
                        }
                    }
                    state = .ground;
                },
                .csi => {
                    switch (b) {
                        // c0 controls. we ignore these even though we should
                        // "execute" them. This isn't seen in practice
                        0x00...0x1F => {},
                        // intermediates. we only handle one. technically there
                        // can be more
                        0x20...0x2F => seq.intermediate = b,
                        0x30...0x39 => {
                            seq.param_buf[seq.param_buf_idx] = b;
                            seq.param_buf_idx += 1;
                        },
                        // private indicators. These come before any params ('?')
                        0x3C...0x3F => seq.private_indicator = b,
                        ';' => {
                            if (seq.param_buf_idx == 0) {
                                // empty param. default it to 1
                                seq.params[seq.param_idx] = 1;
                                seq.param_idx += 1;
                            } else {
                                const p = try std.fmt.parseUnsigned(u16, seq.param_buf[0..seq.param_buf_idx], 10);
                                seq.param_buf_idx = 0;
                                seq.params[seq.param_idx] = p;
                                seq.param_idx += 1;
                            }
                        },
                        ':' => {
                            if (seq.param_buf_idx == 0) {
                                // empty param. default it to 1
                                seq.params[seq.param_idx] = 1;
                                seq.param_idx += 1;
                                // Set the *next* param as a subparam
                                seq.sub_state.set(seq.param_idx);
                            } else {
                                const p = try std.fmt.parseUnsigned(u16, seq.param_buf[0..seq.param_buf_idx], 10);
                                seq.param_buf_idx = 0;
                                seq.params[seq.param_idx] = p;
                                seq.param_idx += 1;
                                // Set the *next* param as a subparam
                                seq.sub_state.set(seq.param_idx);
                            }
                        },
                        0x40...0xFF => {
                            // dispatch our sequence
                            state = .ground;
                            const codepoint: u21 = switch (b) {
                                'A' => Key.up,
                                'B' => Key.down,
                                'C' => Key.right,
                                'D' => Key.left,
                                'E' => Key.kp_begin,
                                'F' => Key.end,
                                'H' => Key.home,
                                'P' => Key.f1,
                                'Q' => Key.f2,
                                'R' => Key.f3,
                                'S' => Key.f4,
                                '~' => blk: {
                                    // The first param will define this
                                    // codepoint
                                    if (seq.param_idx < 1) {
                                        log.warn("unhandled csi: CSI {s}", .{buf[start + 1 .. i + 1]});
                                        continue;
                                    }
                                    switch (seq.params[0]) {
                                        2 => break :blk Key.insert,
                                        3 => break :blk Key.delete,
                                        5 => break :blk Key.page_up,
                                        6 => break :blk Key.page_down,
                                        7 => break :blk Key.home,
                                        8 => break :blk Key.end,
                                        11 => break :blk Key.f1,
                                        12 => break :blk Key.f2,
                                        13 => break :blk Key.f3,
                                        14 => break :blk Key.f4,
                                        15 => break :blk Key.f5,
                                        17 => break :blk Key.f6,
                                        18 => break :blk Key.f7,
                                        19 => break :blk Key.f8,
                                        20 => break :blk Key.f9,
                                        21 => break :blk Key.f10,
                                        23 => break :blk Key.f11,
                                        24 => break :blk Key.f12,
                                        200 => {
                                            // TODO: bracketed paste
                                            continue;
                                        },
                                        201 => {
                                            // TODO: bracketed paste
                                            continue;
                                        },
                                        57427 => break :blk Key.kp_begin,
                                        else => {
                                            log.warn("unhandled csi: CSI {s}", .{buf[start + 1 .. i + 1]});
                                            continue;
                                        },
                                    }
                                },
                                'u' => blk: {
                                    if (seq.private_indicator) |_| {
                                        // response to our kitty query
                                        // TODO: kitty query handling
                                        log.warn("unhandled csi: CSI {s}", .{buf[start + 1 .. i + 1]});
                                        continue;
                                    }
                                    if (seq.param_idx == 0) {
                                        log.warn("unhandled csi: CSI {s}", .{buf[start + 1 .. i + 1]});
                                        continue;
                                    }
                                    // In any csi u encoding, the codepoint
                                    // directly maps to our keypoint definitions
                                    break :blk seq.params[0];
                                },

                                'I' => { // focus in
                                    if (@hasField(EventType, "focus_in")) {
                                        vx.postEvent(.focus_in);
                                    }
                                    continue;
                                },
                                'O' => { // focus out
                                    if (@hasField(EventType, "focus_out")) {
                                        vx.postEvent(.focus_out);
                                    }
                                    continue;
                                },
                                else => {
                                    log.warn("unhandled csi: CSI {s}", .{buf[start + 1 .. i + 1]});
                                    continue;
                                },
                            };

                            const key: Key = .{ .codepoint = codepoint };
                            if (@hasField(EventType, "key_press")) {
                                vx.postEvent(.{ .key_press = key });
                            }
                        },
                    }
                },
                else => {},
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
