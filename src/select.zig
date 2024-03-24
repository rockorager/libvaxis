const std = @import("std");
const builtin = @import("builtin");

const c = struct {
    comptime {
        if (!builtin.os.tag.isDarwin())
            @compileError("this file requires linking against darwin libc!");
    }

    extern "c" fn select(c_int, ?*fd_set, ?*fd_set, ?*fd_set, ?*timeval) c_int;
    /// FIXME: pretty sure this will break if you define _DARWIN_UNLIMITED_SELECT lol
    const fd_set = extern struct {
        fds_bits: [32]i32 = .{0} ** 32,
    };
    const timeval = extern struct {
        tv_sec: i64,
        tv_usec: i32,
    };

    const DARWIN_NFDBITS = @sizeOf(i32) * 8;

    /// hand translated mostly bc I didn't understand the zig translate-c output
    /// notably, i'm skipping the check_fd_set call ... don't make me mad
    inline fn FD_SET(fd: i32, fds: ?*fd_set) void {
        const idx: usize = @intCast(@as(u64, @bitCast(@as(i64, fd))) / DARWIN_NFDBITS);
        const val: u64 = @as(u64, 1) << @intCast(@as(u64, @bitCast(@as(i64, fd))) % DARWIN_NFDBITS);
        fds.?.fds_bits[idx] |= @as(i32, @bitCast(@as(u32, @truncate(val))));
    }
    inline fn FD_CLR(fd: i32, fds: ?*fd_set) void {
        const idx: usize = @intCast(@as(u64, @bitCast(@as(i64, fd))) / DARWIN_NFDBITS);
        const val: u64 = @as(u64, 1) << @intCast(@as(u64, @bitCast(@as(i64, fd))) % DARWIN_NFDBITS);
        fds.?.fds_bits[idx] &= ~@as(i32, @bitCast(@as(u32, @truncate(val))));
    }
    inline fn FD_ISSET(fd: i32, fds: ?*const fd_set) bool {
        const idx: usize = @intCast(@as(u64, @bitCast(@as(i64, fd))) / DARWIN_NFDBITS);
        const val: u64 = @as(u64, 1) << @intCast(@as(u64, @bitCast(@as(i64, fd))) % DARWIN_NFDBITS);
        return fds.?.fds_bits[idx] & @as(i32, @bitCast(@as(u32, @truncate(val)))) > 0;
    }
};

/// minimal wrapper over select(2); watches the specified files for input
/// API chosen to (mostly) match std.io.poll
pub fn select(
    allocator: std.mem.Allocator,
    comptime StreamEnum: type,
    files: SelectFiles(StreamEnum),
) error{FdMaxExceeded}!Selector(StreamEnum) {
    const enum_fields = @typeInfo(StreamEnum).Enum.fields;
    var result: Selector(StreamEnum) = undefined;
    var fd_max: std.os.system.fd_t = 0;
    inline for (0..enum_fields.len) |i| {
        result.fifos[i] = .{
            .allocator = allocator,
            .buf = &.{},
            .head = 0,
            .count = 0,
        };
        result.select_fds[i] = @field(files, enum_fields[i].name).handle;
        fd_max = @max(fd_max, @field(files, enum_fields[i].name).handle);
    }
    result.fd_max = if (fd_max + 1 > 1024) return error.FdMaxExceeded else fd_max + 1;
    return result;
}

pub const SelectFifo = std.fifo.LinearFifo(u8, .Dynamic);

pub fn Selector(comptime StreamEnum: type) type {
    return struct {
        const enum_fields = @typeInfo(StreamEnum).Enum.fields;
        fifos: [enum_fields.len]SelectFifo,
        select_fds: [enum_fields.len]std.os.system.fd_t,
        fd_max: std.os.system.fd_t,

        const Self = @This();

        pub fn deinit(self: *Self) void {
            inline for (&self.fifos) |*q| q.deinit();
            self.* = undefined;
        }

        pub fn select(self: *Self) !void {
            return selectInner(self, null);
        }

        pub fn selectTimeout(self: *Self, nanoseconds: u64) !void {
            return selectInner(self, nanoseconds);
        }

        fn selectInner(self: *Self, nanoseconds: ?u64) !void {
            // We ask for ensureUnusedCapacity with this much extra space. This
            // has more of an effect on small reads because once the reads
            // start to get larger the amount of space an ArrayList will
            // allocate grows exponentially.
            const bump_amt = 512;

            const fds = fds: {
                while (true) {
                    var timeval: ?c.timeval =
                        if (nanoseconds) |ns|
                        .{
                            .tv_sec = std.math.cast(i64, ns / std.time.ns_per_s) orelse std.math.maxInt(i64),
                            .tv_usec = std.math.cast(i32, (ns % std.time.ns_per_s) / std.time.ns_per_us) orelse 0,
                        }
                    else
                        null;
                    const ptr: ?*c.timeval = if (timeval) |*tv| tv else null;
                    var fds: c.fd_set = .{};
                    @memset(&fds.fds_bits, 0);
                    inline for (self.select_fds) |fd| {
                        c.FD_SET(fd, &fds);
                    }
                    const err = c.select(self.fd_max, &fds, null, null, ptr);
                    switch (std.os.errno(err)) {
                        .SUCCESS => break :fds fds,
                        // TODO: these are clearly not unreachable ...
                        .BADF => break :fds fds,
                        .INVAL => unreachable,
                        .INTR => continue,
                        .NOMEM => return error.SystemResources,
                        else => |e| return std.os.unexpectedErrno(e),
                    }
                }
            };

            inline for (&self.select_fds, &self.fifos) |fd, *q| {
                if (c.FD_ISSET(fd, &fds)) {
                    const buf = try q.writableWithSize(bump_amt);
                    const amt = try std.os.read(fd, buf);
                    q.update(amt);
                }
            }
        }

        pub inline fn fifo(self: *Self, comptime which: StreamEnum) *SelectFifo {
            return &self.fifos[@intFromEnum(which)];
        }
    };
}

/// Given an enum, returns a struct with fields of that enum,
/// each field representing an I/O stream for selecting
pub fn SelectFiles(comptime StreamEnum: type) type {
    const enum_fields = @typeInfo(StreamEnum).Enum.fields;
    var struct_fields: [enum_fields.len]std.builtin.Type.StructField = undefined;
    for (&struct_fields, enum_fields) |*struct_field, enum_field| {
        struct_field.* = .{
            .name = enum_field.name ++ "",
            .type = std.fs.File,
            .default_value = null,
            .is_comptime = false,
            .alignment = @alignOf(std.fs.File),
        };
    }
    return @Type(.{ .Struct = .{
        .layout = .Auto,
        .fields = &struct_fields,
        .decls = &.{},
        .is_tuple = false,
    } });
}

test "select" {
    const read_end, const write_end = try std.os.pipe();
    defer std.os.close(read_end);
    defer std.os.close(write_end);
    const read_fd: std.fs.File = .{ .handle = read_end };
    const tty = try std.fs.cwd().openFile("/dev/tty", .{
        .mode = .read_write,
        .allow_ctty = true,
    });

    var selector = try select(std.testing.allocator, enum { tty, quit }, .{
        .tty = tty,
        .quit = read_fd,
    });
    defer selector.deinit();

    const inner = struct {
        fn f(fd: i32) !void {
            std.time.sleep(std.time.ns_per_s);
            _ = try std.os.write(fd, "q");
        }
    };

    const pid = try std.Thread.spawn(.{}, inner.f, .{write_end});
    defer pid.join();

    try selector.selectTimeout(std.time.ns_per_us * 2);
    try selector.select();
}
