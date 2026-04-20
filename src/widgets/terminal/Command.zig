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
    const arena = arena_allocator.allocator();

    // Keep fork->exec child path allocation-free, following std/Io/Threaded.zig:posixExecv
    const argv_block = try arena.allocSentinel(?[*:0]const u8, self.argv.len, null);
    for (self.argv, 0..) |arg, i| argv_block[i] = (try arena.dupeZ(u8, arg)).ptr;
    const env_block = try self.env_map.createPosixBlock(arena, .{});
    const path = self.env_map.get("PATH") orelse std.Io.Threaded.default_PATH;

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

        if (self.working_directory) |wd| {
            const wd_z = try posix.toPosixPath(wd);
            if (linux.errno(linux.chdir(&wd_z)) != .SUCCESS) return error.ChdirFailed;
        }

        // exec
        execvpeLinux(argv_block.ptr, env_block, self.argv[0], path) catch {};
        linux.exit(127);
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
        posix.kill(pid, posix.SIG.TERM) catch {};
        self.pid = null;
    }
}

// Keep fork->exec child path allocation-free, following std/Io/Threaded.zig:posixExecv
fn execvpeLinux(
    argv: [*:null]const ?[*:0]const u8,
    env_block: std.process.Environ.PosixBlock,
    arg0: []const u8,
    path: []const u8,
) !noreturn {
    // This implementation is largely copied from std/Io/Threaded.zig
    // (`spawnPosix` + `posixExecv`/`posixExecvPath`) and adapted for this PTY fork path.
    if (std.mem.indexOfScalar(u8, arg0, '/') != null) {
        const path_z = try posix.toPosixPath(arg0);
        return std.Io.Threaded.posixExecvPath(&path_z, argv, env_block);
    }

    var it = std.mem.tokenizeScalar(u8, path, std.fs.path.delimiter);
    var path_buf: [posix.PATH_MAX]u8 = undefined;
    var err: std.process.ReplaceError = error.FileNotFound;
    var seen_eacces = false;

    while (it.next()) |dir| {
        const path_len = dir.len + arg0.len + 1;
        if (path_buf.len < path_len + 1) return error.NameTooLong;
        @memcpy(path_buf[0..dir.len], dir);
        path_buf[dir.len] = '/';
        @memcpy(path_buf[dir.len + 1 ..][0..arg0.len], arg0);
        path_buf[path_len] = 0;
        const full_path = path_buf[0..path_len :0].ptr;
        err = std.Io.Threaded.posixExecvPath(full_path, argv, env_block);
        switch (err) {
            error.AccessDenied => seen_eacces = true,
            error.FileNotFound, error.NotDir => {},
            else => |e| return e,
        }
    }

    if (seen_eacces) return error.AccessDenied;
    return err;
}
