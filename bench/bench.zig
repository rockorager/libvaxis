const std = @import("std");
const vaxis = @import("vaxis");

fn parseIterations(allocator: std.mem.Allocator) !usize {
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.next();
    if (args.next()) |val| {
        return std.fmt.parseUnsigned(usize, val, 10);
    }
    return 200;
}

fn printResults(writer: anytype, label: []const u8, iterations: usize, elapsed_ns: u64, total_bytes: usize) !void {
    const ns_per_frame = elapsed_ns / @as(u64, @intCast(iterations));
    const bytes_per_frame = total_bytes / iterations;
    try writer.print(
        "{s}: frames={d} total_ns={d} ns/frame={d} bytes={d} bytes/frame={d}\n",
        .{ label, iterations, elapsed_ns, ns_per_frame, total_bytes, bytes_per_frame },
    );
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const iterations = try parseIterations(allocator);

    var vx = try vaxis.init(allocator, .{});
    var init_writer = std.io.Writer.Allocating.init(allocator);
    defer init_writer.deinit();
    defer vx.deinit(allocator, &init_writer.writer);

    const winsize = vaxis.Winsize{ .rows = 24, .cols = 80, .x_pixel = 0, .y_pixel = 0 };
    try vx.resize(allocator, &init_writer.writer, winsize);

    const stdout = std.fs.File.stdout().deprecatedWriter();

    var idle_writer = std.io.Writer.Allocating.init(allocator);
    defer idle_writer.deinit();
    var timer = try std.time.Timer.start();
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        try vx.render(&idle_writer.writer);
    }
    const idle_ns = timer.read();
    const idle_bytes: usize = idle_writer.writer.end;
    try printResults(stdout, "idle", iterations, idle_ns, idle_bytes);

    var dirty_writer = std.io.Writer.Allocating.init(allocator);
    defer dirty_writer.deinit();
    timer.reset();
    i = 0;
    while (i < iterations) : (i += 1) {
        vx.queueRefresh();
        try vx.render(&dirty_writer.writer);
    }
    const dirty_ns = timer.read();
    const dirty_bytes: usize = dirty_writer.writer.end;
    try printResults(stdout, "dirty", iterations, dirty_ns, dirty_bytes);
}
