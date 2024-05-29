const std = @import("std");

const GraphemeCache = @This();

/// the underlying storage for graphemes. Right now 8kb
buf: [1024 * 8]u8 = undefined,

// the start index of the next grapheme
idx: usize = 0,

/// put a slice of bytes in the cache as a grapheme
pub fn put(self: *GraphemeCache, bytes: []const u8) []u8 {
    // reset the idx to 0 if we would overflow
    if (self.idx + bytes.len > self.buf.len) self.idx = 0;
    defer self.idx += bytes.len;
    // copy the grapheme to our storage
    @memcpy(self.buf[self.idx .. self.idx + bytes.len], bytes);
    // return the slice
    return self.buf[self.idx .. self.idx + bytes.len];
}
