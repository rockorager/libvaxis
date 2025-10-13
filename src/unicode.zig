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
        if (self.inner.nextGrapheme()) |g| {
            return .{
                .start = g.start,
                .len = g.end - g.start,
            };
        } else {
            return null;
        }
    }
};

/// creates a grapheme iterator based on str
pub fn graphemeIterator(str: []const u8) GraphemeIterator {
    return GraphemeIterator.init(str);
}
