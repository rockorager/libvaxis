const std = @import("std");
const uucode = @import("uucode");

// Old API-compatible Grapheme value
pub const Grapheme = struct {
    start: usize,
    len: usize,

    pub fn bytes(self: Grapheme, str: []const u8) []const u8 {
        return str[self.start .. self.start + self.len];
    }
};

// Old API-compatible iterator that yields Grapheme with .len and .bytes()
pub const GraphemeIterator = struct {
    str: []const u8,
    inner: uucode.grapheme.Iterator(uucode.utf8.Iterator),

    pub fn init(str: []const u8) GraphemeIterator {
        return .{
            .str = str,
            .inner = uucode.grapheme.utf8Iterator(str),
        };
    }

    pub fn next(self: *GraphemeIterator) ?Grapheme {
        const g = self.inner.nextGrapheme() orelse return null;
        return .{ .start = g.start, .len = g.end - g.start };
    }
};

/// creates a grapheme iterator based on str
pub fn graphemeIterator(str: []const u8) GraphemeIterator {
    return GraphemeIterator.init(str);
}

test {
    std.testing.refAllDecls(@This());
}

test "grapheme iterator: invalid utf8 + combining mark" {
    // An invalid byte decodes to U+FFFD but consumes only one byte
    var it = graphemeIterator("ab\xff\xcc\x81");
    try std.testing.expectEqual(Grapheme{ .start = 0, .len = 1 }, it.next().?);
    try std.testing.expectEqual(Grapheme{ .start = 1, .len = 1 }, it.next().?);
    try std.testing.expectEqual(Grapheme{ .start = 2, .len = 3 }, it.next().?);
    try std.testing.expectEqual(null, it.next());

    it = graphemeIterator("\xff\xcc\x81");
    try std.testing.expectEqual(Grapheme{ .start = 0, .len = 3 }, it.next().?);
    try std.testing.expectEqual(null, it.next());
}
