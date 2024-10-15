const std = @import("std");
const grapheme = @import("grapheme");
const DisplayWidth = @import("DisplayWidth");

/// A thin wrapper around zg data
const Unicode = @This();

width_data: DisplayWidth.DisplayWidthData,

/// initialize all unicode data vaxis may possibly need
pub fn init(alloc: std.mem.Allocator) !Unicode {
    return .{
        .width_data = try DisplayWidth.DisplayWidthData.init(alloc),
    };
}

/// free all data
pub fn deinit(self: *const Unicode) void {
    self.width_data.deinit();
}

/// creates a grapheme iterator based on str
pub fn graphemeIterator(self: *const Unicode, str: []const u8) grapheme.Iterator {
    return grapheme.Iterator.init(str, &self.width_data.g_data);
}
