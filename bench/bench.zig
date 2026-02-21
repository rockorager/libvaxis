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

fn buildRepeated(allocator: std.mem.Allocator, pattern: []const u8, repeat: usize) ![]u8 {
    const total_len = pattern.len * repeat;
    var buf = try allocator.alloc(u8, total_len);
    for (0..repeat) |i| {
        const start = i * pattern.len;
        const end = start + pattern.len;
        @memcpy(buf[start..end], pattern);
    }
    return buf;
}

fn totalBytes(segments: []const vaxis.Segment) usize {
    var total: usize = 0;
    for (segments) |segment| {
        total += segment.text.len;
    }
    return total;
}

fn benchPrintWord(writer: anytype, label: []const u8, win: vaxis.Window, segments: []const vaxis.Segment, opts: vaxis.PrintOptions, iterations: usize) !void {
    const bytes_per_iter = totalBytes(segments);
    var timer = try std.time.Timer.start();
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        const result = win.print(segments, opts);
        std.mem.doNotOptimizeAway(result);
    }
    const elapsed_ns = timer.read();
    try printResults(writer, label, iterations, elapsed_ns, bytes_per_iter * iterations);
}

/// Iterate word tokens and compute gwidth(word) for each. This simulates the
/// extra pass that existed before caching grapheme widths in Window.print.
fn benchWordWidthPass(win: vaxis.Window, segments: []const vaxis.Segment) void {
    var total: u32 = 0;
    for (segments) |segment| {
        var line_iter: BenchLineIterator = .{ .buf = segment.text };
        while (line_iter.next()) |line| {
            var iter: BenchWhitespaceTokenizer = .{ .buf = line };
            while (iter.next()) |token| {
                switch (token) {
                    .whitespace => {},
                    .word => |word| {
                        total +|= win.gwidth(word);
                    },
                }
            }
        }
    }
    std.mem.doNotOptimizeAway(total);
}

fn benchPrintWordBaseline(writer: anytype, label: []const u8, win: vaxis.Window, segments: []const vaxis.Segment, opts: vaxis.PrintOptions, iterations: usize) !void {
    const bytes_per_iter = totalBytes(segments);
    var timer = try std.time.Timer.start();
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        const result = win.print(segments, opts);
        std.mem.doNotOptimizeAway(result);
        benchWordWidthPass(win, segments);
    }
    const elapsed_ns = timer.read();
    try printResults(writer, label, iterations, elapsed_ns, bytes_per_iter * iterations);
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

    const pattern = "hello 世界 👩‍🚀 foo bar ";
    const long_token = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const small_text = try buildRepeated(allocator, pattern, 8);
    defer allocator.free(small_text);
    const medium_text = try buildRepeated(allocator, pattern, 32);
    defer allocator.free(medium_text);
    const large_text = try buildRepeated(allocator, pattern, 64);
    defer allocator.free(large_text);
    const overflow_text = try buildRepeated(allocator, long_token, 200);
    defer allocator.free(overflow_text);

    const small_segments = [_]vaxis.Segment{.{ .text = small_text }};
    const medium_segments = [_]vaxis.Segment{.{ .text = medium_text }};
    const large_segments = [_]vaxis.Segment{.{ .text = large_text }};
    const overflow_segments = [_]vaxis.Segment{.{ .text = overflow_text }};

    const print_opts: vaxis.PrintOptions = .{ .wrap = .word, .commit = false };
    const win = vx.window();

    try benchPrintWordBaseline(stdout, "print_word_small_baseline", win, small_segments[0..], print_opts, iterations);
    try benchPrintWord(stdout, "print_word_small_cached", win, small_segments[0..], print_opts, iterations);
    try benchPrintWordBaseline(stdout, "print_word_medium_baseline", win, medium_segments[0..], print_opts, iterations);
    try benchPrintWord(stdout, "print_word_medium_cached", win, medium_segments[0..], print_opts, iterations);
    try benchPrintWordBaseline(stdout, "print_word_large_baseline", win, large_segments[0..], print_opts, iterations);
    try benchPrintWord(stdout, "print_word_large_cached", win, large_segments[0..], print_opts, iterations);
    try benchPrintWordBaseline(stdout, "print_word_overflow_baseline", win, overflow_segments[0..], print_opts, iterations);
    try benchPrintWord(stdout, "print_word_overflow_cached", win, overflow_segments[0..], print_opts, iterations);
}

/// Iterates a slice of bytes by linebreaks. Lines are split by '\r', '\n', or '\r\n'
const BenchLineIterator = struct {
    buf: []const u8,
    index: usize = 0,
    has_break: bool = true,

    fn next(self: *BenchLineIterator) ?[]const u8 {
        if (self.index >= self.buf.len) return null;

        const start = self.index;
        const end = std.mem.indexOfAnyPos(u8, self.buf, self.index, "\r\n") orelse {
            if (start == 0) self.has_break = false;
            self.index = self.buf.len;
            return self.buf[start..];
        };

        self.index = end;
        self.consumeCR();
        self.consumeLF();
        return self.buf[start..end];
    }

    // consumes a \n byte
    fn consumeLF(self: *BenchLineIterator) void {
        if (self.index >= self.buf.len) return;
        if (self.buf[self.index] == '\n') self.index += 1;
    }

    // consumes a \r byte
    fn consumeCR(self: *BenchLineIterator) void {
        if (self.index >= self.buf.len) return;
        if (self.buf[self.index] == '\r') self.index += 1;
    }
};

/// Returns tokens of text and whitespace
const BenchWhitespaceTokenizer = struct {
    buf: []const u8,
    index: usize = 0,

    const Token = union(enum) {
        // the length of whitespace. Tab = 8
        whitespace: usize,
        word: []const u8,
    };

    fn next(self: *BenchWhitespaceTokenizer) ?Token {
        if (self.index >= self.buf.len) return null;
        const Mode = enum {
            whitespace,
            word,
        };
        const first = self.buf[self.index];
        const mode: Mode = if (first == ' ' or first == '\t') .whitespace else .word;
        switch (mode) {
            .whitespace => {
                var len: usize = 0;
                while (self.index < self.buf.len) : (self.index += 1) {
                    switch (self.buf[self.index]) {
                        ' ' => len += 1,
                        '\t' => len += 8,
                        else => break,
                    }
                }
                return .{ .whitespace = len };
            },
            .word => {
                const start = self.index;
                while (self.index < self.buf.len) : (self.index += 1) {
                    switch (self.buf[self.index]) {
                        ' ', '\t' => break,
                        else => {},
                    }
                }
                return .{ .word = self.buf[start..self.index] };
            },
        }
    }
};
