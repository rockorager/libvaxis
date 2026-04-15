//! A PTY pair
const Pty = @This();

const std = @import("std");
const builtin = @import("builtin");
const Winsize = @import("../../main.zig").Winsize;

const linux = std.os.linux;
const posix = std.posix;

pty: std.Io.File,
tty: std.Io.File,

/// opens a new tty/pty pair
pub fn init(io: std.Io) !Pty {
    switch (builtin.os.tag) {
        .linux => return openPtyLinux(io),
        else => @compileError("unsupported os"),
    }
}

/// closes the tty and pty
pub fn deinit(self: Pty, io: std.Io) void {
    self.pty.close(io);
    self.tty.close(io);
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

fn openPtyLinux(io: std.Io) !Pty {
    const pty = try std.Io.Dir.openFileAbsolute(io, "/dev/ptmx", .{
        .mode = .read_write,
        .allow_ctty = false,
    });
    errdefer pty.close(io);

    // unlockpt
    var n: c_uint = 0;
    if (posix.system.ioctl(pty.handle, posix.T.IOCSPTLCK, @intFromPtr(&n)) != 0) return error.IoctlError;

    // ptsname
    if (posix.system.ioctl(pty.handle, posix.T.IOCGPTN, @intFromPtr(&n)) != 0) return error.IoctlError;
    var buf: [16]u8 = undefined;
    const sname = try std.fmt.bufPrint(&buf, "/dev/pts/{d}", .{n});
    std.log.debug("pts: {s}", .{sname});

    const tty = try std.Io.Dir.openFileAbsolute(io, sname, .{
        .mode = .read_write,
        .allow_ctty = false,
    });

    return .{
        .pty = pty,
        .tty = tty,
    };
}
