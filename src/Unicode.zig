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
    start: usize = 0,
    prev_break: bool = true,

    pub fn init(str: []const u8) GraphemeIterator {
        return .{
            .str = str,
            .inner = uucode.grapheme.Iterator(uucode.utf8.Iterator).init(.init(str)),
        };
    }

    pub fn next(self: *GraphemeIterator) ?Grapheme {
        while (self.inner.next()) |res| {
            // When leaving a break and entering a non-break, set the start of a cluster
            if (self.prev_break and !res.is_break) {
                const cp_len: usize = std.unicode.utf8CodepointSequenceLength(res.cp) catch 1;
                self.start = self.inner.i - cp_len;
            }

            // A break marks the end of the current grapheme
            if (res.is_break) {
                const end = self.inner.i;
                const s = self.start;
                self.start = end;
                self.prev_break = true;
                return .{ .start = s, .len = end - s };
            }

            self.prev_break = false;
        }

        // Flush the last grapheme if we ended mid-cluster
        if (!self.prev_break and self.start < self.str.len) {
            const s = self.start;
            const len = self.str.len - s;
            self.start = self.str.len;
            self.prev_break = true;
            return .{ .start = s, .len = len };
        }

        return null;
    }
};

/// creates a grapheme iterator based on str
pub fn graphemeIterator(str: []const u8) GraphemeIterator {
    return GraphemeIterator.init(str);
}
