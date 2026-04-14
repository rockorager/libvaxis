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
            var grapheme_iter = uucode.grapheme.Iterator(uucode.utf8.Iterator).init(.init(str));

            var grapheme_start: usize = 0;
            var prev_break: bool = true;

            while (grapheme_iter.nextCodePoint()) |result| {
                if (prev_break and !result.is_break) {
                    // Start of a new grapheme
                    const cp_len: usize = std.unicode.utf8CodepointSequenceLength(result.code_point) catch 1;
                    grapheme_start = grapheme_iter.i - cp_len;
                }

                if (result.is_break) {
                    // End of a grapheme - calculate its width
                    const grapheme_end = grapheme_iter.i;
                    const grapheme_bytes = str[grapheme_start..grapheme_end];

                    // Calculate grapheme width
                    var g_iter = uucode.utf8.Iterator.init(grapheme_bytes);
                    var width: i16 = 0;
                    var has_emoji_vs: bool = false;
                    var has_text_vs: bool = false;
                    var has_emoji_presentation: bool = false;
                    var ri_count: u8 = 0;

                    while (g_iter.next()) |cp| {
                        // Check for emoji variation selector (U+FE0F)
                        if (cp == 0xfe0f) {
                            has_emoji_vs = true;
                            continue;
                        }

                        // Check for text variation selector (U+FE0E)
                        if (cp == 0xfe0e) {
                            has_text_vs = true;
                            continue;
                        }

                        // Check if this codepoint has emoji presentation
                        if (uucode.get(.is_emoji_presentation, cp)) {
                            has_emoji_presentation = true;
                        }

                        // Count regional indicators (for flag emojis)
                        if (cp >= 0x1F1E6 and cp <= 0x1F1FF) {
                            ri_count += 1;
                        }

                        const eaw = uucode.get(.east_asian_width, cp);
                        const w = eawToWidth(cp, eaw);
                        // Take max of non-zero widths
                        if (w > 0 and w > width) width = w;
                    }

                    // Handle variation selectors and emoji presentation
                    if (has_text_vs) {
                        // Text presentation explicit - keep width as-is (usually 1)
                        width = @max(1, width);
                    } else if (has_emoji_vs or has_emoji_presentation or ri_count == 2) {
                        // Emoji presentation or flag pair - force width 2
                        width = @max(2, width);
                    }

                    total += @max(0, width);

                    grapheme_start = grapheme_end;
                }
                prev_break = result.is_break;
            }

            return total;
        },
        .wcwidth => {
            var total: u16 = 0;
            var iter = uucode.utf8.Iterator.init(str);
            while (iter.next()) |cp| {
                const w: i16 = switch (cp) {
                    // undo an override in zg for emoji skintone selectors
                    0x1f3fb...0x1f3ff => 2,
                    else => blk: {
                        const eaw = uucode.get(.east_asian_width, cp);
                        break :blk eawToWidth(cp, eaw);
                    },
                };
                total += @intCast(@max(0, w));
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
