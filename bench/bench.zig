const std = @import("std");
const vaxis = @import("vaxis");
const uucode = @import("uucode");

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

// Mirrors the pre-fast-path parseGround work for ASCII to provide a baseline.
fn parseAsciiSlow(input: []const u8) !vaxis.Parser.Result {
    std.debug.assert(input.len > 0);
    var iter = uucode.utf8.Iterator.init(input);
    const first_cp = iter.next() orelse return error.InvalidUTF8;

    var n: usize = std.unicode.utf8CodepointSequenceLength(first_cp) catch return error.InvalidUTF8;

    var code = first_cp;
    var grapheme_iter = uucode.grapheme.Iterator(uucode.utf8.Iterator).init(.init(input));
    var grapheme_len: usize = 0;
    var cp_count: usize = 0;

    while (grapheme_iter.next()) |result| {
        cp_count += 1;
        if (result.is_break) {
            grapheme_len = grapheme_iter.i;
            break;
        }
    }

    if (grapheme_len > 0) {
        n = grapheme_len;
        if (cp_count > 1) {
            code = vaxis.Key.multicodepoint;
        }
    }

    const key: vaxis.Key = .{ .codepoint = code, .text = input[0..n] };
    return .{ .event = .{ .key_press = key }, .n = n };
}

fn benchParseFast(writer: anytype, label: []const u8, parser: *vaxis.Parser, input: []const u8, iterations: usize) !void {
    var timer = try std.time.Timer.start();
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        const result = try parser.parse(input, null);
        std.mem.doNotOptimizeAway(result);
    }
    const elapsed_ns = timer.read();
    try printResults(writer, label, iterations, elapsed_ns, input.len * iterations);
}

fn benchParseSlow(writer: anytype, label: []const u8, input: []const u8, iterations: usize) !void {
    var timer = try std.time.Timer.start();
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        const result = try parseAsciiSlow(input);
        std.mem.doNotOptimizeAway(result);
    }
    const elapsed_ns = timer.read();
    try printResults(writer, label, iterations, elapsed_ns, input.len * iterations);
}

fn benchParseStreamSlow(writer: anytype, label: []const u8, parser: *vaxis.Parser, input: []const u8, iterations: usize) !void {
    var timer = try std.time.Timer.start();
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        var idx: usize = 0;
        while (idx < input.len) {
            const next = if (idx + 1 < input.len) input[idx + 1] else null;
            if (input[idx] >= 0x20 and input[idx] <= 0x7E and (next == null or next.? < 0x80)) {
                const result = try parseAsciiSlow(input[idx..]);
                if (result.n == 0) break;
                idx += result.n;
                std.mem.doNotOptimizeAway(result);
                continue;
            }

            const result = try parser.parse(input[idx..], null);
            if (result.n == 0) break;
            idx += result.n;
            std.mem.doNotOptimizeAway(result);
        }
        std.mem.doNotOptimizeAway(idx);
    }
    const elapsed_ns = timer.read();
    try printResults(writer, label, iterations, elapsed_ns, input.len * iterations);
}

fn benchParseStreamFast(writer: anytype, label: []const u8, parser: *vaxis.Parser, input: []const u8, iterations: usize) !void {
    var timer = try std.time.Timer.start();
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        var idx: usize = 0;
        while (idx < input.len) {
            const result = try parser.parse(input[idx..], null);
            if (result.n == 0) break;
            idx += result.n;
            std.mem.doNotOptimizeAway(result);
        }
        std.mem.doNotOptimizeAway(idx);
    }
    const elapsed_ns = timer.read();
    try printResults(writer, label, iterations, elapsed_ns, input.len * iterations);
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

    var parser: vaxis.Parser = .{};
    const ascii_input = "a";
    try benchParseSlow(stdout, "parse_ground_ascii_slow", ascii_input, iterations);
    try benchParseFast(stdout, "parse_ground_ascii_fast", &parser, ascii_input, iterations);

    const mixed_input = "hello \x1b[A世界 1️⃣ 👩‍🚀!\r";
    try benchParseStreamSlow(stdout, "parse_stream_mixed_slow", &parser, mixed_input, iterations);
    try benchParseStreamFast(stdout, "parse_stream_mixed_fast", &parser, mixed_input, iterations);
}
