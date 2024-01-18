const std = @import("std");
const Tty = @import("tty/Tty.zig");

pub fn main() !void {
    // Prints to stderr (it's a shortcut based on `std.io.getStdErr()`)
    std.debug.print("All your {s} are belong to us.\n", .{"codebase"});

    // stdout is for the actual output of your application, for example if you
    // are implementing gzip, then only the compressed bytes should be sent to
    // stdout, not any debugging messages.
    const stdout_file = std.io.getStdOut().writer();
    var bw = std.io.bufferedWriter(stdout_file);
    const stdout = bw.writer();

    var tty = try Tty.init();
    defer tty.deinit();

    const pipe = try std.os.pipe();
    // run our tty read loop in it's own thread
    const read_thread = try std.Thread.spawn(.{}, Tty.run, .{ &tty, pipe[0] });
    try read_thread.setName("tty");

    std.time.sleep(100_000_000_0);
    _ = try std.os.write(pipe[1], "q");
    read_thread.join();

    try stdout.print("Run `zig build test` to run the tests.\n", .{});

    try bw.flush(); // don't forget to flush!
}

test "simple test" {
    var list = std.ArrayList(i32).init(std.testing.allocator);
    defer list.deinit(); // try commenting this out and see if zig detects the memory leak!
    try list.append(42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}
