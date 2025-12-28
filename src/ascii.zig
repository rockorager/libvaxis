const std = @import("std");
const uucode = @import("uucode");

pub fn printableRunLen(input: []const u8) usize {
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

pub fn fastPathLen(input: []const u8) usize {
    const run = printableRunLen(input);
    if (run == 0) return 0;
    if (run < input.len) {
        const next = input[run..];
        const first = next[0];
        if (first >= 0x80) {
            const seq_len = std.unicode.utf8ByteSequenceLength(first) catch return run;
            if (next.len < seq_len) return run - 1;
            const cp = std.unicode.utf8Decode(next[0..seq_len]) catch return run;
            const gc = uucode.get(.general_category, cp);
            switch (gc) {
                .mark_nonspacing,
                .mark_spacing_combining,
                .mark_enclosing,
                => return run - 1,
                else => {},
            }
        }
    }
    return run;
}

test "printableRunLen: empty" {
    try std.testing.expectEqual(@as(usize, 0), printableRunLen(""));
}

test "printableRunLen: ascii run" {
    try std.testing.expectEqual(@as(usize, 4), printableRunLen("abcd"));
}

test "printableRunLen: stops at control" {
    try std.testing.expectEqual(@as(usize, 1), printableRunLen("a\nb"));
}

test "printableRunLen: stops at utf8" {
    try std.testing.expectEqual(@as(usize, 5), printableRunLen("hello世界"));
}

test "fastPathLen: keeps ascii before utf8" {
    try std.testing.expectEqual(@as(usize, 5), fastPathLen("hello世界"));
}

test "fastPathLen: holds for combining mark" {
    try std.testing.expectEqual(@as(usize, 0), fastPathLen("a\u{0301}"));
}

test "fastPathLen: holds for keycap" {
    try std.testing.expectEqual(@as(usize, 0), fastPathLen("1\u{20E3}"));
}

test "fastPathLen: holds for incomplete utf8" {
    try std.testing.expectEqual(@as(usize, 0), fastPathLen("a\xE2"));
}
