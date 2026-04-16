const std = @import("std");
const vaxis = @import("vaxis");

fn parseIterations(allocator: std.mem.Allocator, args: std.process.Args) !usize {
    var it = try args.iterateAllocator(allocator);
    defer it.deinit();
    _ = it.next();
    if (it.next()) |val| {
        return std.fmt.parseUnsigned(usize, val, 10);
    }
    return 200;
}

fn printResults(writer: *std.Io.Writer, label: []const u8, iterations: usize, elapsed: std.Io.Duration, total_bytes: u64) !void {
    const ns_per_frame = @divTrunc(elapsed.toNanoseconds(), iterations);
    const bytes_per_frame = total_bytes / iterations;
    try writer.print(
        "{s}: frames={d} total_time={f} ns/frame={d} bytes={d} bytes/frame={d}\n",
        .{ label, iterations, elapsed, ns_per_frame, total_bytes, bytes_per_frame },
    );
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;

    const iterations = try parseIterations(allocator, init.minimal.args);

    var vx = try vaxis.init(io, allocator, init.environ_map, .{});
    var init_writer: std.Io.Writer.Allocating = .init(allocator);
    defer init_writer.deinit();
    defer vx.deinit(allocator, &init_writer.writer);

    const winsize = vaxis.Winsize{ .rows = 24, .cols = 80, .x_pixel = 0, .y_pixel = 0 };
    try vx.resize(allocator, &init_writer.writer, winsize);

    const stdout_file: std.Io.File = .stdout();
    var stdout_buf: [1024]u8 = undefined;
    var stdout_writer = stdout_file.writer(io, &stdout_buf);
    const stdout = &stdout_writer.interface;

    {
        var buf: [1024]u8 = undefined;
        var idle_writer: std.Io.Writer.Discarding = .init(&buf);
        var timer: std.Io.Timestamp = .now(io, .real);
        var i: usize = 0;
        while (i < iterations) : (i += 1) {
            try vx.render(&idle_writer.writer);
        }
        const idle_ns = timer.untilNow(io, .real);
        const idle_bytes = idle_writer.fullCount();
        try printResults(stdout, "idle", iterations, idle_ns, idle_bytes);
    }

    {
        var buf: [1024]u8 = undefined;
        var dirty_writer: std.Io.Writer.Discarding = .init(&buf);
        var timer: std.Io.Timestamp = .now(io, .real);
        var i: usize = 0;
        while (i < iterations) : (i += 1) {
            vx.queueRefresh();
            try vx.render(&dirty_writer.writer);
        }
        const dirty_ns = timer.untilNow(io, .real);
        const dirty_bytes = dirty_writer.fullCount();
        try printResults(stdout, "dirty", iterations, dirty_ns, dirty_bytes);
    }

    try stdout.flush();
}

test {
    std.testing.refAllDecls(@This());
}
