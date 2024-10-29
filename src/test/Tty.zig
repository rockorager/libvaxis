//! Testable TTY
const TestTTY = @This();

const std = @import("std");
const builtin = @import("builtin");

const posix = std.posix;

const Winsize = @import("../main.zig").Winsize;

const ctlseqs = @import("../ctlseqs.zig");

/// Used for API compat
fd: posix.fd_t,
pipe_read: posix.fd_t,
pipe_write: posix.fd_t,
writer: *std.ArrayList(u8),

/// Initializes a TestTTY.
pub fn init() !TestTTY {
    const list = try std.testing.allocator.create(std.ArrayList(u8));
    list.* = std.ArrayList(u8).init(std.testing.allocator);
    const r, const w = try posix.pipe();
    return .{
        .fd = r,
        .pipe_read = r,
        .pipe_write = w,
        .writer = list,
    };
}

pub fn deinit(self: TestTTY) void {
    std.posix.close(self.pipe_read);
    std.posix.close(self.pipe_write);
    self.writer.deinit();
    std.testing.allocator.destroy(self.writer);
}

/// Write bytes to the tty
pub fn write(self: *const TestTTY, bytes: []const u8) !usize {
    if (std.mem.eql(u8, bytes, ctlseqs.device_status_report)) {
        _ = posix.write(self.pipe_write, "\x1b") catch {};
    }
    return self.writer.writer().write(bytes);
}

pub fn opaqueWrite(ptr: *const anyopaque, bytes: []const u8) !usize {
    const self: *const TestTTY = @ptrCast(@alignCast(ptr));
    return self.write(bytes);
}

pub fn anyWriter(self: *const TestTTY) std.io.AnyWriter {
    return .{
        .context = self,
        .writeFn = TestTTY.opaqueWrite,
    };
}

pub fn read(self: *const TestTTY, buf: []u8) !usize {
    return posix.read(self.fd, buf);
}

pub fn opaqueRead(ptr: *const anyopaque, buf: []u8) !usize {
    const self: *const TestTTY = @ptrCast(@alignCast(ptr));
    return posix.read(self.fd, buf);
}

pub fn anyReader(self: *const TestTTY) std.io.AnyReader {
    return .{
        .context = self,
        .readFn = TestTTY.opaqueRead,
    };
}

/// Get the window size from the kernel
pub fn getWinsize(_: posix.fd_t) !Winsize {
    return .{
        .rows = 40,
        .cols = 80,
        .x_pixel = 40 * 8,
        .y_pixel = 40 * 8 * 2,
    };
}

pub fn bufferedWriter(self: *const TestTTY) std.io.BufferedWriter(4096, std.io.AnyWriter) {
    return std.io.bufferedWriter(self.anyWriter());
}
