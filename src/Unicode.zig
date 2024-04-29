const std = @import("std");
const grapheme = @import("grapheme");

/// A thin wrapper around zg data
const Unicode = @This();

grapheme_data: grapheme.GraphemeData,

/// initialize all unicode data vaxis may possibly need
pub fn init(alloc: std.mem.Allocator) !Unicode {
    const grapheme_data = try grapheme.GraphemeData.init(alloc);

    return .{
        .grapheme_data = grapheme_data,
    };
}

/// free all data
pub fn deinit(self: *Unicode) void {
    self.grapheme_data.deinit();
}

/// creates a grapheme iterator based on str
pub fn graphemeIterator(self: *const Unicode, str: []const u8) grapheme.Iterator {
    return grapheme.Iterator.init(str, &self.grapheme_data);
}
