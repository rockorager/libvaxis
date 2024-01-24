const std = @import("std");
const unicode = std.unicode;
const testing = std.testing;
const ziglyph = @import("ziglyph");

/// the method to use when calculating the width of a grapheme
pub const Method = enum {
    unicode,
    wcwidth,
};

/// returns the width of the provided string, as measured by the method chosen
pub fn gwidth(str: []const u8, method: Method) !usize {
    switch (method) {
        .unicode => {
            return try ziglyph.display_width.strWidth(str, .half);
        },
        .wcwidth => {
            var total: usize = 0;
            const utf8 = try unicode.Utf8View.init(str);
            var iter = utf8.iterator();

            while (iter.nextCodepoint()) |cp| {
                const w = ziglyph.display_width.codePointWidth(cp, .half);
                if (w < 0) continue;
                total += @intCast(w);
            }
            return total;
        },
    }
}

test "gwidth: a" {
    try testing.expectEqual(1, try gwidth("a", .unicode));
    try testing.expectEqual(1, try gwidth("a", .wcwidth));
}

test "gwidth: emoji with ZWJ" {
    try testing.expectEqual(2, try gwidth("👩‍🚀", .unicode));
    try testing.expectEqual(4, try gwidth("👩‍🚀", .wcwidth));
}

test "gwidth: emoji with skin tone selector" {
    try testing.expectEqual(2, try gwidth("👋🏿", .unicode));
    try testing.expectEqual(4, try gwidth("👋🏿", .wcwidth));
}

test "gwidth: invalid string" {
    try testing.expectError(error.InvalidUtf8, gwidth("\xc3\x28", .unicode));
    try testing.expectError(error.InvalidUtf8, gwidth("\xc3\x28", .wcwidth));
}
