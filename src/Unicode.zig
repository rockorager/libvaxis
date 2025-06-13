const std = @import("std");
const Graphemes = @import("Graphemes");
const DisplayWidth = @import("DisplayWidth");

/// A thin wrapper around zg data
const Unicode = @This();

graphemes: Graphemes,
display_width: DisplayWidth,

/// initialize all unicode data vaxis may possibly need
pub fn init(alloc: std.mem.Allocator) !Unicode {
    const graphemes = try Graphemes.init(alloc);
    return .{
        .graphemes = graphemes,
        .display_width = try DisplayWidth.initWithGraphemes(alloc, graphemes),
    };
}

/// free all data
pub fn deinit(self: *const Unicode, alloc: std.mem.Allocator) void {
    self.display_width.deinit(alloc);
}

/// creates a grapheme iterator based on str
pub fn graphemeIterator(self: *const Unicode, str: []const u8) Graphemes.Iterator {
    return Graphemes.Iterator.init(str, &self.graphemes);
}
