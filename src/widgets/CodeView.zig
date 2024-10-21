const std = @import("std");
const vaxis = @import("../main.zig");
const ScrollView = vaxis.widgets.ScrollView;
const LineNumbers = vaxis.widgets.LineNumbers;

pub const DrawOptions = struct {
    highlighted_line: u16 = 0,
    draw_line_numbers: bool = true,
    indentation: u16 = 0,
};

pub const Buffer = vaxis.widgets.TextView.Buffer;

scroll_view: ScrollView = .{ .vertical_scrollbar = null },
highlighted_style: vaxis.Style = .{ .bg = .{ .index = 0 } },
indentation_cell: vaxis.Cell = .{
    .char = .{
        .grapheme = "┆",
        .width = 1,
    },
    .style = .{ .dim = true },
},

pub fn input(self: *@This(), key: vaxis.Key) void {
    self.scroll_view.input(key);
}

pub fn draw(self: *@This(), win: vaxis.Window, buffer: Buffer, opts: DrawOptions) void {
    const pad_left: usize = if (opts.draw_line_numbers) LineNumbers.numDigits(buffer.rows) +| 1 else 0;
    self.scroll_view.draw(win, .{
        .cols = buffer.cols + pad_left,
        .rows = buffer.rows,
    });
    if (opts.draw_line_numbers) {
        var nl: LineNumbers = .{
            .highlighted_line = opts.highlighted_line,
            .num_lines = buffer.rows +| 1,
        };
        nl.draw(win.child(.{
            .x_off = 0,
            .y_off = 0,
            .width = pad_left,
            .height = win.height,
        }), self.scroll_view.scroll.y);
    }
    self.drawCode(win.child(.{ .x_off = pad_left }), buffer, opts);
}

fn drawCode(self: *@This(), win: vaxis.Window, buffer: Buffer, opts: DrawOptions) void {
    const Pos = struct { x: usize = 0, y: usize = 0 };
    var pos: Pos = .{};
    var byte_index: usize = 0;
    var is_indentation = true;
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
            pos.y += 1;
            pos.x = 0;
            is_indentation = true;
            continue;
        } else if (bounds.below(pos.y)) {
            continue;
        }

        const highlighted_line = pos.y +| 1 == opts.highlighted_line;
        var style: vaxis.Style = if (highlighted_line) self.highlighted_style else .{};

        if (buffer.style_map.get(byte_index)) |meta| {
            const tmp = style.bg;
            style = buffer.style_list.items[meta];
            style.bg = tmp;
        }

        const width = win.gwidth(cluster);
        defer pos.x +|= width;

        if (!bounds.colInside(pos.x)) {
            continue;
        }

        if (opts.indentation > 0 and !std.mem.eql(u8, cluster, " ")) {
            is_indentation = false;
        }

        if (is_indentation and opts.indentation > 0 and pos.x % opts.indentation == 0) {
            var cell = self.indentation_cell;
            cell.style.bg = style.bg;
            self.scroll_view.writeCell(win, pos.x, pos.y, cell);
        } else {
            self.scroll_view.writeCell(win, pos.x, pos.y, .{
                .char = .{ .grapheme = cluster, .width = @intCast(width) },
                .style = style,
            });
        }

        if (highlighted_line) {
            for (pos.x +| width..bounds.x2) |x| {
                self.scroll_view.writeCell(win, x, pos.y, .{ .style = style });
            }
        }
    }
}
