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

    // run our tty read loop in it's own thread
    const read_thread = try std.Thread.spawn(.{}, Tty.run, .{ &tty, Event, eventCallback });
    try read_thread.setName("tty");

    std.time.sleep(100_000_000_00);
    tty.stop();
    read_thread.join();

    try stdout.print("Run `zig build test` to run the tests.\n", .{});

    try bw.flush(); // don't forget to flush!
}

const Event = union(enum) {
    key: u8,
    mouse: u8,
};

fn eventCallback(_: Event) void {}

test "simple test" {
    _ = @import("odditui.zig");
    _ = @import("queue.zig");
}
