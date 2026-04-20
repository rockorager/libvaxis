const Command = @This();

const std = @import("std");
const builtin = @import("builtin");
const Pty = @import("Pty.zig");
const Terminal = @import("Terminal.zig");

const posix = std.posix;

argv: []const []const u8,

working_directory: ?[]const u8,

// Set after spawn()
pid: ?std.posix.pid_t = null,

env_map: *const std.process.Environ.Map,

pty: Pty,

pub fn spawn(self: *Command, allocator: std.mem.Allocator) !void {
    var arena_allocator = std.heap.ArenaAllocator.init(allocator);
    defer arena_allocator.deinit();

    const arena = arena_allocator.allocator();

    const argv_buf = try arena.allocSentinel(?[*:0]const u8, self.argv.len, null);
    for (self.argv, 0..) |arg, i| argv_buf[i] = (try arena.dupeZ(u8, arg)).ptr;

    const envp = try createEnvironFromMap(arena, self.env_map);

    // Pre-compute null-terminated working directory before fork (no alloc in child).
    const wd_z: ?[*:0]const u8 = if (self.working_directory) |wd|
        (try arena.dupeZ(u8, wd)).ptr
    else
        null;

    // Extract PATH before fork so child can find executables without libc getenv.
    const path_str = self.env_map.get("PATH") orelse "";
    const path_env_z = try arena.dupeZ(u8, path_str);

    const fork_result = posix.system.fork();
    switch (posix.errno(fork_result)) {
        .SUCCESS => {},
        .AGAIN => return error.SystemResources,
        .NOMEM => return error.SystemResources,
        else => return error.ForkFailed,
    }
    const pid: posix.pid_t = @intCast(fork_result);

    if (pid == 0) {
        // we are the child
        _ = std.os.linux.setsid();

        // set the controlling terminal
        var u: c_uint = std.posix.STDIN_FILENO;
        if (posix.system.ioctl(self.pty.tty.handle, posix.T.IOCSCTTY, @intFromPtr(&u)) != 0) std.os.linux.exit_group(1);

        // set up io
        _ = posix.system.dup2(self.pty.tty.handle, std.posix.STDIN_FILENO);
        _ = posix.system.dup2(self.pty.tty.handle, std.posix.STDOUT_FILENO);
        _ = posix.system.dup2(self.pty.tty.handle, std.posix.STDERR_FILENO);

        std.Io.Threaded.closeFd(self.pty.tty.handle);
        if (self.pty.pty.handle > 2) std.Io.Threaded.closeFd(self.pty.pty.handle);

        if (wd_z) |wd| {
            if (posix.system.chdir(wd) != 0) std.os.linux.exit_group(1);
        }

        // exec with PATH resolution
        execWithPath(argv_buf.ptr[0].?, argv_buf.ptr, @ptrCast(envp.ptr), path_env_z);
        std.os.linux.exit_group(1);
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

/// Exec file with PATH resolution. Does not return on success.
fn execWithPath(
    file_z: [*:0]const u8,
    argv: [*:null]const ?[*:0]const u8,
    envp: [*:null]const ?[*:0]const u8,
    path_z: [*:0]const u8,
) void {
    const file = std.mem.sliceTo(file_z, 0);
    if (std.mem.findScalar(u8, file, '/') != null) {
        _ = posix.system.execve(file_z, argv, envp);
        return;
    }
    const path = std.mem.sliceTo(path_z, 0);
    var it = std.mem.tokenizeScalar(u8, path, ':');
    var buf: [posix.PATH_MAX]u8 = undefined;
    while (it.next()) |dir| {
        const full = std.fmt.bufPrintZ(&buf, "{s}/{s}", .{ dir, file }) catch continue;
        _ = posix.system.execve(full.ptr, argv, envp);
    }
}

fn handleSigChild(_: std.posix.SIG) callconv(.c) void {
    // Reap zombie children; Terminal.run pushes .exited when the PTY closes.
    var status: u32 = 0;
    _ = posix.system.waitpid(-1, &status, 0);
}

pub fn kill(self: *Command) void {
    if (self.pid) |pid| {
        std.posix.kill(pid, std.posix.SIG.TERM) catch {};
        var status: u32 = 0;
        _ = posix.system.waitpid(pid, &status, 0);
        self.pid = null;
    }
}

/// Creates a null-deliminated environment variable block in the format expected by POSIX, from a
/// hash map plus options.
fn createEnvironFromMap(
    arena: std.mem.Allocator,
    map: *const std.process.Environ.Map,
) ![:null]?[*:0]u8 {
    const envp_count: usize = map.count();

    const envp_buf = try arena.allocSentinel(?[*:0]u8, envp_count, null);
    var i: usize = 0;

    {
        var it = map.iterator();
        while (it.next()) |pair| {
            envp_buf[i] = try std.fmt.allocPrintSentinel(arena, "{s}={s}", .{ pair.key_ptr.*, pair.value_ptr.* }, 0);
            i += 1;
        }
    }

    std.debug.assert(i == envp_count);
    return envp_buf;
}
