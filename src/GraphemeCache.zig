const std = @import("std");
const testing = std.testing;

const GraphemeCache = @This();

/// the underlying storage for graphemes
buf: [1024 * 4]u8 = undefined,

// the start index of the next grapheme
idx: usize = 0,

/// the cache of graphemes. This allows up to 1024 graphemes with 4 codepoints
/// each
grapheme_buf: [1024]Grapheme = undefined,

// index of our next grapheme
g_idx: u21 = 0,

pub const UNICODE_MAX = 1_114_112;

const Grapheme = struct {
    // codepoint is an index into the internal storage
    codepoint: u21,
    start: usize,
    end: usize,
};

/// put a slice of bytes in the cache as a grapheme
pub fn put(self: *GraphemeCache, bytes: []const u8) !u21 {
    // See if we already have these bytes. It's a likely case that if we get one
    // grapheme, we'll get it again. So this will save a lot of storage and is
    // most likely worth the cost as it's pretty rare
    for (self.grapheme_buf) |grapheme| {
        const g_bytes = self.buf[grapheme.start..grapheme.end];
        if (std.mem.eql(u8, g_bytes, bytes)) {
            return grapheme.codepoint;
        }
    }
    if (self.idx + bytes.len > self.buf.len) return error.OutOfGraphemeBufferMemory;
    if (self.g_idx + 1 > self.grapheme_buf.len) return error.OutOfGraphemeMemory;

    // copy the grapheme to our storage
    @memcpy(self.buf[self.idx .. self.idx + bytes.len], bytes);

    const g = Grapheme{
        // assign a codepoint that is always outside of valid unicode
        .codepoint = self.g_idx + UNICODE_MAX + 1,
        .start = self.idx,
        .end = self.idx + bytes.len,
    };
    self.grapheme_buf[self.g_idx] = g;
    self.g_idx += 1;
    self.idx += bytes.len;

    return g.codepoint;
}

/// get the slice of bytes for a given grapheme
pub fn get(self: *GraphemeCache, cp: u21) ![]const u8 {
    if (cp < (UNICODE_MAX + 1)) return error.InvalidGraphemeIndex;
    const idx: usize = cp - UNICODE_MAX - 1;
    if (idx > self.g_idx) return error.InvalidGraphemeIndex;
    const g = self.grapheme_buf[idx];
    return self.buf[g.start..g.end];
}

test "GraphemeCache: roundtrip" {
    var cache: GraphemeCache = .{};
    const cp = try cache.put("abc");
    const bytes = try cache.get(cp);
    try testing.expectEqualStrings("abc", bytes);

    const cp_2 = try cache.put("abc");
    try testing.expectEqual(cp, cp_2);

    const cp_3 = try cache.put("def");
    try testing.expectEqual(cp + 1, cp_3);
}
