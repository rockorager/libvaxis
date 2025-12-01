const std = @import("std");
const vaxis = @import("../main.zig");
const uucode = @import("uucode");
const ScrollView = vaxis.widgets.ScrollView;

/// Simple grapheme representation to replace Graphemes.Grapheme
const Grapheme = struct {
    len: u16,
    offset: u32,
};

pub const BufferWriter = struct {
    pub const Error = error{OutOfMemory};
    pub const Writer = std.io.GenericWriter(@This(), Error, write);

    allocator: std.mem.Allocator,
    buffer: *Buffer,

    pub fn write(self: @This(), bytes: []const u8) Error!usize {
        try self.buffer.append(self.allocator, .{
            .bytes = bytes,
        });
        return bytes.len;
    }

    pub fn writer(self: @This()) Writer {
        return .{ .context = self };
    }
};

pub const Buffer = struct {
    const StyleList = std.ArrayListUnmanaged(vaxis.Style);
    const StyleMap = std.HashMapUnmanaged(usize, usize, std.hash_map.AutoContext(usize), std.hash_map.default_max_load_percentage);

    pub const Content = struct {
        bytes: []const u8,
    };

    pub const Style = struct {
        begin: usize,
        end: usize,
        style: vaxis.Style,
    };

    pub const Error = error{OutOfMemory};

    grapheme: std.MultiArrayList(Grapheme) = .{},
    content: std.ArrayListUnmanaged(u8) = .{},
    style_list: StyleList = .{},
    style_map: StyleMap = .{},
    rows: usize = 0,
    cols: usize = 0,
    // used when appending to a buffer
    last_cols: usize = 0,

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        self.style_map.deinit(allocator);
        self.style_list.deinit(allocator);
        self.grapheme.deinit(allocator);
        self.content.deinit(allocator);
        self.* = undefined;
    }

    /// Clears all buffer data.
    pub fn clear(self: *@This(), allocator: std.mem.Allocator) void {
        self.deinit(allocator);
        self.* = .{};
    }

    /// Replaces contents of the buffer, all previous buffer data is lost.
    pub fn update(self: *@This(), allocator: std.mem.Allocator, content: Content) Error!void {
        self.clear(allocator);
        errdefer self.clear(allocator);
        try self.append(allocator, content);
    }

    /// Appends content to the buffer.
    pub fn append(self: *@This(), allocator: std.mem.Allocator, content: Content) Error!void {
        var cols: usize = self.last_cols;
        var iter = uucode.grapheme.Iterator(uucode.utf8.Iterator).init(.init(content.bytes));

        var grapheme_start: usize = 0;
        var prev_break: bool = true;

        while (iter.next()) |result| {
            if (prev_break and !result.is_break) {
                // Start of a new grapheme
                const cp_len: usize = std.unicode.utf8CodepointSequenceLength(result.cp) catch 1;
                grapheme_start = iter.i - cp_len;
            }

            if (result.is_break) {
                // End of a grapheme
                const grapheme_end = iter.i;
                const grapheme_len = grapheme_end - grapheme_start;

                try self.grapheme.append(allocator, .{
                    .len = @intCast(grapheme_len),
                    .offset = @intCast(self.content.items.len + grapheme_start),
                });

                const cluster = content.bytes[grapheme_start..grapheme_end];
                if (std.mem.eql(u8, cluster, "\n")) {
                    self.cols = @max(self.cols, cols);
                    cols = 0;
                } else {
                    // Calculate width using gwidth
                    const w = vaxis.gwidth.gwidth(cluster, .unicode);
                    cols +|= w;
                }

                grapheme_start = grapheme_end;
            }
            prev_break = result.is_break;
        }

        // Flush the last grapheme if we ended mid-cluster
        if (!prev_break and grapheme_start < content.bytes.len) {
            const grapheme_len = content.bytes.len - grapheme_start;

            try self.grapheme.append(allocator, .{
                .len = @intCast(grapheme_len),
                .offset = @intCast(self.content.items.len + grapheme_start),
            });

            const cluster = content.bytes[grapheme_start..];
            if (!std.mem.eql(u8, cluster, "\n")) {
                const w = vaxis.gwidth.gwidth(cluster, .unicode);
                cols +|= w;
            }
        }

        try self.content.appendSlice(allocator, content.bytes);
        self.last_cols = cols;
        self.cols = @max(self.cols, cols);
        self.rows +|= std.mem.count(u8, content.bytes, "\n");
    }

    /// Clears all styling data.
    pub fn clearStyle(self: *@This(), allocator: std.mem.Allocator) void {
        self.style_list.deinit(allocator);
        self.style_map.deinit(allocator);
    }

    /// Update style for range of the buffer contents.
    pub fn updateStyle(self: *@This(), allocator: std.mem.Allocator, style: Style) Error!void {
        const style_index = blk: {
            for (self.style_list.items, 0..) |s, i| {
                if (std.meta.eql(s, style.style)) {
                    break :blk i;
                }
            }
            try self.style_list.append(allocator, style.style);
            break :blk self.style_list.items.len - 1;
        };
        for (style.begin..style.end) |i| {
            try self.style_map.put(allocator, i, style_index);
        }
    }

    pub fn writer(
        self: *@This(),
        allocator: std.mem.Allocator,
    ) BufferWriter.Writer {
        return .{
            .context = .{
                .allocator = allocator,
                .buffer = self,
            },
        };
    }
};

scroll_view: ScrollView = .{},

pub fn input(self: *@This(), key: vaxis.Key) void {
    self.scroll_view.input(key);
}

pub fn draw(self: *@This(), win: vaxis.Window, buffer: Buffer) void {
    self.scroll_view.draw(win, .{ .cols = buffer.cols, .rows = buffer.rows });
    const Pos = struct { x: usize = 0, y: usize = 0 };
    var pos: Pos = .{};
    var byte_index: usize = 0;
    const bounds = self.scroll_view.bounds(win);
    for (buffer.grapheme.items(.len), buffer.grapheme.items(.offset), 0..) |g_len, g_offset, index| {
        if (bounds.above(pos.y)) {
            break;
        }

        const cluster = buffer.content.items[g_offset..][0..g_len];
        defer byte_index += cluster.len;

        if (std.mem.eql(u8, cluster, "\n")) {
            if (index == buffer.grapheme.len - 1) {
                break;
            }
            pos.y +|= 1;
            pos.x = 0;
            continue;
        } else if (bounds.below(pos.y)) {
            continue;
        }

        const width = win.gwidth(cluster);
        defer pos.x +|= width;

        if (!bounds.colInside(pos.x)) {
            continue;
        }

        const style: vaxis.Style = blk: {
            if (buffer.style_map.get(byte_index)) |style_index| {
                break :blk buffer.style_list.items[style_index];
            }
            break :blk .{};
        };

        self.scroll_view.writeCell(win, pos.x, pos.y, .{
            .char = .{ .grapheme = cluster, .width = @intCast(width) },
            .style = style,
        });
    }
}
