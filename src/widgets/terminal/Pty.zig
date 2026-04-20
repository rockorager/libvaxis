//! A PTY pair
const Pty = @This();

const std = @import("std");
const builtin = @import("builtin");
const Winsize = @import("../../main.zig").Winsize;

const posix = std.posix;

pty: std.Io.File,
tty: std.Io.File,

/// opens a new tty/pty pair
pub fn init() !Pty {
    switch (builtin.os.tag) {
        .linux => return openPtyLinux(),
        else => @compileError("unsupported os"),
    }
}

/// closes the tty and pty
pub fn deinit(self: Pty) void {
    std.Io.Threaded.closeFd(self.pty.handle);
    std.Io.Threaded.closeFd(self.tty.handle);
}

/// sets the size of the pty
pub fn setSize(self: Pty, ws: Winsize) !void {
    const _ws: posix.winsize = .{
        .row = @truncate(ws.rows),
        .col = @truncate(ws.cols),
        .xpixel = @truncate(ws.x_pixel),
        .ypixel = @truncate(ws.y_pixel),
    };
    if (posix.system.ioctl(self.pty.handle, posix.T.IOCSWINSZ, @intFromPtr(&_ws)) != 0)
        return error.SetWinsizeError;
}

fn openPtyLinux() !Pty {
    const path_z = std.posix.toPosixPath("/dev/ptmx") catch return error.WatchFailed;
    const p: std.posix.fd_t = blk: {
        const raw = std.posix.system.open(&path_z, .{}, @as(c_uint, 0));
        if (raw < 0) return error.WatchFailed;
        break :blk @intCast(raw);
    };

    // const p = try posix.open("/dev/ptmx", .{ .ACCMODE = .RDWR, .NOCTTY = true }, 0);
    errdefer std.Io.Threaded.closeFd(p);

    // unlockpt
    var n: c_uint = 0;
    if (posix.system.ioctl(p, posix.T.IOCSPTLCK, @intFromPtr(&n)) != 0) return error.IoctlError;

    // ptsname
    if (posix.system.ioctl(p, posix.T.IOCGPTN, @intFromPtr(&n)) != 0) return error.IoctlError;
    var buf: [16]u8 = undefined;
    const sname = try std.fmt.bufPrintZ(&buf, "/dev/pts/{d}", .{n});
    std.log.debug("pts: {s}", .{sname});

    const t: std.posix.fd_t = blk: {
        const raw = std.posix.system.open(sname, .{}, @as(c_uint, 0));
        if (raw < 0) return error.WatchFailed;
        break :blk @intCast(raw);
    };
    // const t = try posix.open(sname, .{ .ACCMODE = .RDWR, .NOCTTY = true }, 0);

    return .{
        .pty = .{ .handle = p, .flags = .{ .nonblocking = false } },
        .tty = .{ .handle = t, .flags = .{ .nonblocking = false } },
    };
}
