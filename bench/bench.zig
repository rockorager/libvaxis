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

fn asciiPrintableRunLen(input: []const u8) usize {
    const VecLenOpt = std.simd.suggestVectorLength(u8);
    if (VecLenOpt) |VecLen| {
        const Vec = @Vector(VecLen, u8);
        const lo: Vec = @splat(0x20);
        const hi: Vec = @splat(0x7E);
        var i: usize = 0;
        while (i + VecLen <= input.len) : (i += VecLen) {
            const chunk = @as(*const [VecLen]u8, @ptrCast(input[i..].ptr)).*;
            const vec: Vec = chunk;
            const ok = (vec >= lo) & (vec <= hi);
            if (!@reduce(.And, ok)) {
                var j: usize = 0;
                while (j < VecLen) : (j += 1) {
                    const b = input[i + j];
                    if (b < 0x20 or b > 0x7E) return i + j;
                }
            }
        }
        while (i < input.len) : (i += 1) {
            const b = input[i];
            if (b < 0x20 or b > 0x7E) return i;
        }
        return input.len;
    }

    var i: usize = 0;
    while (i < input.len) : (i += 1) {
        const b = input[i];
        if (b < 0x20 or b > 0x7E) return i;
    }
    return input.len;
}

fn benchParseStreamBaseline(writer: anytype, label: []const u8, parser: *vaxis.Parser, input: []const u8, iterations: usize) !void {
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

fn benchParseStreamSimd(writer: anytype, label: []const u8, parser: *vaxis.Parser, input: []const u8, iterations: usize) !void {
    var timer = try std.time.Timer.start();
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        var idx: usize = 0;
        while (idx < input.len) {
            const slice = input[idx..];
            var ascii_len = asciiPrintableRunLen(slice);
            if (ascii_len > 0 and ascii_len < slice.len and slice[ascii_len] >= 0x80) {
                ascii_len -= 1;
            }
            if (ascii_len > 0) {
                var j: usize = 0;
                while (j < ascii_len) : (j += 1) {
                    const key: vaxis.Key = .{
                        .codepoint = slice[j],
                        .text = slice[j .. j + 1],
                    };
                    const event: vaxis.Event = .{ .key_press = key };
                    std.mem.doNotOptimizeAway(event);
                }
                idx += ascii_len;
                continue;
            }

            const result = try parser.parse(slice, null);
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
    const mixed_stream = "The quick brown fox jumps over the lazy dog " ++
        "1234567890 !@#$%^&*() " ++
        "\x1b[A" ++
        "世界 1️⃣ 👩‍🚀!" ++
        "\r";
    try benchParseStreamBaseline(stdout, "parse_stream_loop_baseline", &parser, mixed_stream, iterations);
    try benchParseStreamSimd(stdout, "parse_stream_loop_simd", &parser, mixed_stream, iterations);
}
