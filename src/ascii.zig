const std = @import("std");

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
