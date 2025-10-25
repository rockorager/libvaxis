const std = @import("std");
const unicode = std.unicode;
const testing = std.testing;
const uucode = @import("uucode");

/// the method to use when calculating the width of a grapheme
pub const Method = enum {
    unicode,
    wcwidth,
    no_zwj,
};

/// Calculate width from east asian width property and Unicode properties
fn eawToWidth(cp: u21, eaw: uucode.types.EastAsianWidth) i16 {
    // Based on wcwidth implementation
    // Control characters
    if (cp == 0) return 0;
    if (cp < 32 or (cp >= 0x7f and cp < 0xa0)) return -1;

    // Use general category for comprehensive zero-width detection
    const gc = uucode.get(.general_category, cp);
    switch (gc) {
        .mark_nonspacing, .mark_enclosing => return 0,
        else => {},
    }

    // Additional zero-width characters not covered by general category
    if (cp == 0x00ad) return 0; // soft hyphen
    if (cp == 0x200b) return 0; // zero-width space
    if (cp == 0x200c) return 0; // zero-width non-joiner
    if (cp == 0x200d) return 0; // zero-width joiner
    if (cp == 0x2060) return 0; // word joiner
    if (cp == 0x034f) return 0; // combining grapheme joiner
    if (cp == 0xfeff) return 0; // zero-width no-break space (BOM)
    if (cp >= 0x180b and cp <= 0x180d) return 0; // Mongolian variation selectors
    if (cp >= 0xfe00 and cp <= 0xfe0f) return 0; // variation selectors
    if (cp >= 0xe0100 and cp <= 0xe01ef) return 0; // Plane-14 variation selectors

    // East Asian Width: fullwidth or wide = 2
    // ambiguous in East Asian context = 2, otherwise 1
    // halfwidth, narrow, or neutral = 1
    return switch (eaw) {
        .fullwidth, .wide => 2,
        else => 1,
    };
}

/// returns the width of the provided string, as measured by the method chosen
pub fn gwidth(str: []const u8, method: Method) u16 {
    switch (method) {
        .unicode => {
            var total: u16 = 0;
            var grapheme_iter = uucode.grapheme.utf8Iterator(str);

            while (true) {
                const width = uucode.x.grapheme.unverifiedWcwidth(grapheme_iter);
                total += @intCast(@max(0, width));
                if (grapheme_iter.nextGrapheme() == null) break;
            }

            return total;
        },
        .wcwidth => {
            var total: u16 = 0;
            var iter = uucode.utf8.Iterator.init(str);
            var start: usize = 0;
            while (iter.next()) |cp| {
                // Skip zero-width joiner, and text/emoji presentation selectors
                if (cp == uucode.config.zero_width_joiner or
                    cp == 0xFE0E or
                    cp == 0xFE0F)
                {
                    continue;
                }
                if (0x1F3FB <= cp and cp <= 0x1F3FF) {
                    // Emoji modifier
                    total += 2;
                    continue;
                }
                const g_iter = uucode.grapheme.utf8Iterator(str[start..iter.i]);
                const width = uucode.x.grapheme.unverifiedWcwidth(g_iter);
                total += @intCast(@max(0, width));
                start = iter.i;
            }
            return total;
        },
        .no_zwj => {
            var iter = std.mem.splitSequence(u8, str, "\u{200D}");
            var result: u16 = 0;
            while (iter.next()) |s| {
                result += gwidth(s, .unicode);
            }
            return result;
        },
    }
}

test "gwidth: a" {
    try testing.expectEqual(1, gwidth("a", .unicode));
    try testing.expectEqual(1, gwidth("a", .wcwidth));
    try testing.expectEqual(1, gwidth("a", .no_zwj));
}

test "gwidth: emoji with ZWJ" {
    try testing.expectEqual(2, gwidth("👩‍🚀", .unicode));
    try testing.expectEqual(4, gwidth("👩‍🚀", .wcwidth));
    try testing.expectEqual(4, gwidth("👩‍🚀", .no_zwj));
}

test "gwidth: emoji with VS16 selector" {
    try testing.expectEqual(2, gwidth("\xE2\x9D\xA4\xEF\xB8\x8F", .unicode));
    try testing.expectEqual(1, gwidth("\xE2\x9D\xA4\xEF\xB8\x8F", .wcwidth));
    try testing.expectEqual(2, gwidth("\xE2\x9D\xA4\xEF\xB8\x8F", .no_zwj));
}

test "gwidth: emoji with skin tone selector" {
    try testing.expectEqual(2, gwidth("👋🏿", .unicode));
    try testing.expectEqual(4, gwidth("👋🏿", .wcwidth));
    try testing.expectEqual(2, gwidth("👋🏿", .no_zwj));
}

test "gwidth: zero-width space" {
    try testing.expectEqual(0, gwidth("\u{200B}", .unicode));
    try testing.expectEqual(0, gwidth("\u{200B}", .wcwidth));
}

test "gwidth: zero-width non-joiner" {
    try testing.expectEqual(0, gwidth("\u{200C}", .unicode));
    try testing.expectEqual(0, gwidth("\u{200C}", .wcwidth));
}

test "gwidth: combining marks" {
    // Hebrew combining mark
    try testing.expectEqual(0, gwidth("\u{05B0}", .unicode));
    // Devanagari combining mark
    try testing.expectEqual(0, gwidth("\u{093C}", .unicode));
}

test "gwidth: flag emoji (regional indicators)" {
    // US flag 🇺🇸
    try testing.expectEqual(2, gwidth("🇺🇸", .unicode));
    // UK flag 🇬🇧
    try testing.expectEqual(2, gwidth("🇬🇧", .unicode));
}

test "gwidth: text variation selector" {
    // U+2764 (heavy black heart) + U+FE0E (text variation selector)
    // Should be width 1 with text presentation
    try testing.expectEqual(1, gwidth("❤︎", .unicode));
}

test "gwidth: keycap sequence" {
    // Digit 1 + U+FE0F + U+20E3 (combining enclosing keycap)
    // Should be width 2
    try testing.expectEqual(2, gwidth("1️⃣", .unicode));
}

test "gwidth: base letter with combining mark" {
    // 'a' + combining acute accent (NFD form)
    // Should be width 1 (combining mark is zero-width)
    try testing.expectEqual(1, gwidth("á", .unicode));
}
