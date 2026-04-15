const Command = @This();

const std = @import("std");
const builtin = @import("builtin");
const Pty = @import("Pty.zig");
const Terminal = @import("Terminal.zig");

const linux = std.os.linux;
const posix = std.posix;

argv: []const []const u8,

working_directory: ?[]const u8,

// Set after spawn()
pid: ?std.posix.pid_t = null,

env_map: *const std.process.Environ.Map,

pty: Pty,

pub fn spawn(self: *Command, io: std.Io, allocator: std.mem.Allocator) !void {
    var arena_allocator = std.heap.ArenaAllocator.init(allocator);
    defer arena_allocator.deinit();

    const pid = pid: {
        const rc = linux.fork();
        break :pid switch (linux.errno(rc)) {
            .SUCCESS => rc,
            else => return error.ForkError,
        };
    };
    if (pid == 0) {
        // we are the child
        _ = std.os.linux.setsid();

        // set the controlling terminal
        var u: c_uint = std.posix.STDIN_FILENO;
        if (posix.system.ioctl(self.pty.tty.handle, posix.T.IOCSCTTY, @intFromPtr(&u)) != 0) return error.IoctlError;

        // set up io
        {
            const rc = linux.dup2(self.pty.tty.handle, std.posix.STDIN_FILENO);
            switch (linux.errno(rc)) {
                .SUCCESS => {},
                else => return error.Dup2Failed,
            }
        }
        {
            const rc = linux.dup2(self.pty.tty.handle, std.posix.STDOUT_FILENO);
            switch (linux.errno(rc)) {
                .SUCCESS => {},
                else => return error.Dup2Failed,
            }
        }
        {
            const rc = linux.dup2(self.pty.tty.handle, std.posix.STDERR_FILENO);
            switch (linux.errno(rc)) {
                .SUCCESS => {},
                else => return error.Dup2Failed,
            }
        }
        self.pty.tty.close(io);
        if (self.pty.pty.handle > 2) self.pty.pty.close(io);

        // if (self.working_directory) |wd| {
        //     try std.posix.chdir(wd);
        // }

        // exec
        std.process.replace(io, .{
            .argv = self.argv,
            .environ_map = self.env_map,
        }) catch {};
    }

    // we are the parent
    self.pid = @intCast(pid);

    if (!Terminal.global_sigchild_installed) {
        Terminal.global_sigchild_installed = true;
        var act = posix.Sigaction{
            .handler = .{ .handler = handleSigChild },
            .mask = switch (builtin.os.tag) {
                .macos => 0,
                .linux => posix.sigemptyset(),
                else => @compileError("os not supported"),
            },
            .flags = 0,
        };
        posix.sigaction(posix.SIG.CHLD, &act, null);
    }

    return;
}

fn handleSigChild(_: posix.SIG) callconv(.c) void {
    var status: u32 = undefined;
    const rc = linux.waitpid(-1, &status, 0);
    const pid: i32 = switch (linux.errno(rc)) {
        .SUCCESS => @intCast(rc),
        else => return,
    };

    Terminal.global_vt_mutex.lock(Terminal.global_io) catch return;
    defer Terminal.global_vt_mutex.unlock(Terminal.global_io);
    var vt = Terminal.global_vts.get(pid) orelse return;
    vt.event_queue.push(.exited) catch {};
}

pub fn kill(self: *Command) void {
    if (self.pid) |pid| {
        std.posix.kill(pid, std.posix.SIG.TERM) catch {};
        self.pid = null;
    }
}

/// Creates a null-deliminated environment variable block in the format expected by POSIX, from a
/// hash map plus options.
fn createEnvironFromMap(
    arena: std.mem.Allocator,
    map: *const std.process.Environ.Map,
) ![:null]?[*:0]u8 {
    return try map.createPosixBlock(arena, .{});
}
