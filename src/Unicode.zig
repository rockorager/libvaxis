const std = @import("std");
const Graphemes = @import("Graphemes");
const DisplayWidth = @import("DisplayWidth");

/// A thin wrapper around zg data
const Unicode = @This();

width_data: DisplayWidth,

/// initialize all unicode data vaxis may possibly need
pub fn init(alloc: std.mem.Allocator) !Unicode {
    return .{
        .width_data = try DisplayWidth.init(alloc),
    };
}

/// free all data
pub fn deinit(self: *const Unicode, alloc: std.mem.Allocator) void {
    self.width_data.deinit(alloc);
}

/// creates a grapheme iterator based on str
pub fn graphemeIterator(self: *const Unicode, str: []const u8) Graphemes.Iterator {
    return self.width_data.graphemes.iterator(str);
}
