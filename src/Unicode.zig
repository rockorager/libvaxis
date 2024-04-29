const std = @import("std");
const grapheme = @import("grapheme");
const DisplayWidth = @import("DisplayWidth");

/// A thin wrapper around zg data
const Unicode = @This();

grapheme_data: grapheme.GraphemeData,
width_data: DisplayWidth.DisplayWidthData,

/// initialize all unicode data vaxis may possibly need
pub fn init(alloc: std.mem.Allocator) !Unicode {
    return .{
        .grapheme_data = try grapheme.GraphemeData.init(alloc),
        .width_data = try DisplayWidth.DisplayWidthData.init(alloc),
    };
}

/// free all data
pub fn deinit(self: *const Unicode) void {
    self.grapheme_data.deinit();
    self.width_data.deinit();
}

/// creates a grapheme iterator based on str
pub fn graphemeIterator(self: *const Unicode, str: []const u8) grapheme.Iterator {
    return grapheme.Iterator.init(str, &self.grapheme_data);
}
