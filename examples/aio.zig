const builtin = @import("builtin");
const std = @import("std");
const vaxis = @import("vaxis");
const aio = @import("aio");
const coro = @import("coro");

pub const panic = vaxis.panic_handler;

const Event = union(enum) {
    key_press: vaxis.Key,
    winsize: vaxis.Winsize,
};

const Loop = vaxis.aio.Loop(Event);

const Video = enum { no_state, ready, end };
const Audio = enum { no_state, ready, end };

fn downloadTask(allocator: std.mem.Allocator, url: []const u8) ![]const u8 {
    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();
    var body = std.ArrayList(u8).init(allocator);
    _ = try client.fetch(.{
        .location = .{ .url = url },
        .response_storage = .{ .dynamic = &body },
        .max_append_size = 1.6e+7,
    });
    return try body.toOwnedSlice();
}

fn audioTask(allocator: std.mem.Allocator) !void {
    // signals end of audio in case there's a error
    errdefer coro.yield(Audio.end) catch {};

    // var child = std.process.Child.init(&.{ "aplay", "-Dplug:default", "-q", "-f", "S16_LE", "-r", "8000" }, allocator);
    var child = std.process.Child.init(&.{ "mpv", "--audio-samplerate=16000", "--audio-channels=mono", "--audio-format=s16", "-" }, allocator);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    try child.spawn();
    defer _ = child.kill() catch {};

    const sound = blk: {
        var tpool = try coro.ThreadPool.init(allocator, .{});
        defer tpool.deinit();
        break :blk try tpool.yieldForCompletition(downloadTask, .{ allocator, "https://keroserene.net/lol/roll.s16" }, .{});
    };
    defer allocator.free(sound);

    try coro.yield(Audio.ready);

    var audio_off: usize = 0;
    while (audio_off < sound.len) {
        var written: usize = 0;
        try coro.io.single(aio.Write{ .file = child.stdin.?, .buffer = sound[audio_off..], .out_written = &written });
        audio_off += written;
    }

    // the audio is already fed to the player and the defer
    // would kill the child, so stay here chilling
    coro.yield(Audio.end) catch {};
}

fn videoTask(writer: std.io.AnyWriter) !void {
    // signals end of video
    defer coro.yield(Video.end) catch {};

    var socket: std.posix.socket_t = undefined;
    try coro.io.single(aio.Socket{
        .domain = std.posix.AF.INET,
        .flags = std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC,
        .protocol = std.posix.IPPROTO.TCP,
        .out_socket = &socket,
    });
    defer std.posix.close(socket);

    const address = std.net.Address.initIp4(.{ 44, 224, 41, 160 }, 1987);
    try coro.io.single(aio.Connect{
        .socket = socket,
        .addr = &address.any,
        .addrlen = address.getOsSockLen(),
    });

    try coro.yield(Video.ready);

    var buf: [1024]u8 = undefined;
    while (true) {
        var read: usize = 0;
        try coro.io.single(aio.Recv{ .socket = socket, .buffer = &buf, .out_read = &read });
        if (read == 0) break;
        _ = try writer.write(buf[0..read]);
    }
}

fn loadingTask(vx: *vaxis.Vaxis, writer: std.io.AnyWriter) !void {
    var color_idx: u8 = 30;
    var dir: enum { up, down } = .up;

    while (true) {
        try coro.io.single(aio.Timeout{ .ns = 8 * std.time.ns_per_ms });

        const style: vaxis.Style = .{ .fg = .{ .rgb = [_]u8{ color_idx, color_idx, color_idx } } };
        const segment: vaxis.Segment = .{ .text = vaxis.logo, .style = style };

        const win = vx.window();
        win.clear();

        var loc = vaxis.widgets.alignment.center(win, 28, 4);
        _ = try loc.printSegment(segment, .{ .wrap = .grapheme });

        switch (dir) {
            .up => {
                color_idx += 1;
                if (color_idx == 255) dir = .down;
            },
            .down => {
                color_idx -= 1;
                if (color_idx == 30) dir = .up;
            },
        }

        try vx.render(writer);
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var tty = try vaxis.Tty.init();
    defer tty.deinit();

    var vx = try vaxis.init(allocator, .{});
    defer vx.deinit(allocator, tty.anyWriter());

    var scheduler = try coro.Scheduler.init(allocator, .{});
    defer scheduler.deinit();

    var loop = try Loop.init();
    try loop.spawn(&scheduler, &vx, &tty, null, .{});
    defer loop.deinit(&vx, &tty);

    try vx.enterAltScreen(tty.anyWriter());
    try vx.queryTerminalSend(tty.anyWriter());

    var buffered_tty_writer = tty.bufferedWriter();
    const loading = try scheduler.spawn(loadingTask, .{ &vx, buffered_tty_writer.writer().any() }, .{});
    const audio = try scheduler.spawn(audioTask, .{allocator}, .{});
    const video = try scheduler.spawn(videoTask, .{buffered_tty_writer.writer().any()}, .{});

    main: while (try scheduler.tick(.blocking) > 0) {
        while (try loop.popEvent()) |event| switch (event) {
            .key_press => |key| {
                if (key.matches('c', .{ .ctrl = true })) {
                    break :main;
                }
            },
            .winsize => |ws| try vx.resize(allocator, buffered_tty_writer.writer().any(), ws),
        };

        if (audio.state(Video) == .ready and video.state(Audio) == .ready) {
            loading.cancel();
            audio.wakeup();
            video.wakeup();
        } else if (audio.state(Audio) == .end and video.state(Video) == .end) {
            break :main;
        }

        try buffered_tty_writer.flush();
    }
}
