const std = @import("std");
const fmt = std.fmt;
const heap = std.heap;
const mem = std.mem;
const meta = std.meta;

const vaxis = @import("../main.zig");

/// Table Context for maintaining state and drawing Tables with `drawTable()`.
pub const TableContext = struct {
    /// Current selected Row of the Table.
    row: usize = 0,
    /// Current selected Column of the Table.
    col: usize = 0,
    /// Starting point within the Data List.
    start: usize = 0,

    /// Active status of the Table.
    active: bool = false,

    /// The Background Color for Selected Rows and Column Headers.
    selected_bg: vaxis.Cell.Color,
    /// First Column Header Background Color
    hdr_bg_1: vaxis.Cell.Color = .{ .rgb = [_]u8{ 64, 64, 64 } },
    /// Second Column Header Background Color
    hdr_bg_2: vaxis.Cell.Color = .{ .rgb = [_]u8{ 8, 8, 24 } },
    /// First Row Background Color
    row_bg_1: vaxis.Cell.Color = .{ .rgb = [_]u8{ 32, 32, 32 } },
    /// Second Row Background Color
    row_bg_2: vaxis.Cell.Color = .{ .rgb = [_]u8{ 8, 8, 8 } },

    /// Y Offset for drawing to the parent Window.
    y_off: usize = 0,

    /// Column Width
    /// Note, this should be treated as Read Only. The Column Width will be calculated during `drawTable()`.
    col_width: usize = 0,
};

/// Draw a Table for the TUI.
pub fn drawTable(
    /// This should be an ArenaAllocator that can be deinitialized after each event call.
    /// The Allocator is only used in two cases:
    /// 1. If a cell is a non-String. If the Allocator is not provided, those cells will show "[unsupported (TypeName)]".
    /// 2. To show that a value is too large to fit into a cell. If the Allocator is not provided, they'll just be cutoff.
    alloc: ?mem.Allocator,
    /// The parent Window to draw to.
    win: vaxis.Window,
    /// Headers for the Table
    headers: []const []const u8,
    /// This must be an ArrayList.
    data_list: anytype,
    // The Table Context for this Table.
    table_ctx: *TableContext,
) !void {
    const table_win = win.initChild(
        0,
        table_ctx.y_off,
        .{ .limit = win.width },
        .{ .limit = win.height },
    );

    table_ctx.col_width = table_win.width / headers.len;
    if (table_ctx.col_width % 2 != 0) table_ctx.col_width +|= 1;
    while (table_ctx.col_width * headers.len < table_win.width - 1) table_ctx.col_width +|= 1;

    if (table_ctx.col > headers.len - 1) table_ctx.*.col = headers.len - 1;
    for (headers[0..], 0..) |hdr_txt, idx| {
        const hdr_bg =
            if (table_ctx.active and idx == table_ctx.col) table_ctx.selected_bg else if (idx % 2 == 0) table_ctx.hdr_bg_1 else table_ctx.hdr_bg_2;
        const hdr_win = table_win.initChild(
            idx * table_ctx.col_width,
            0,
            .{ .limit = table_ctx.col_width },
            .{ .limit = 1 },
        );
        var hdr = vaxis.widgets.alignment.center(hdr_win, @min(table_ctx.col_width -| 1, hdr_txt.len +| 1), 1);
        hdr_win.fill(.{ .style = .{ .bg = hdr_bg } });
        var seg = [_]vaxis.Cell.Segment{.{
            .text = if (hdr_txt.len > table_ctx.col_width and alloc != null) try fmt.allocPrint(alloc.?, "{s}...", .{hdr_txt[0..(table_ctx.col_width -| 4)]}) else hdr_txt,
            .style = .{
                .bg = hdr_bg,
                .bold = true,
                .ul_style = if (idx == table_ctx.col) .single else .dotted,
            },
        }};
        _ = try hdr.print(seg[0..], .{ .wrap = .word });
    }

    const max_items = if (data_list.items.len > table_win.height -| 1) table_win.height -| 1 else data_list.items.len;
    var end = table_ctx.*.start + max_items;
    if (end > data_list.items.len) end = data_list.items.len;
    table_ctx.*.start = tableStart: {
        if (table_ctx.row == 0)
            break :tableStart 0;
        if (table_ctx.row < table_ctx.start)
            break :tableStart table_ctx.start - (table_ctx.start - table_ctx.row);
        if (table_ctx.row >= data_list.items.len - 1)
            table_ctx.*.row = data_list.items.len - 1;
        if (table_ctx.row >= end)
            break :tableStart table_ctx.start + (table_ctx.row - end + 1);
        break :tableStart table_ctx.start;
    };
    end = table_ctx.*.start + max_items;
    if (end > data_list.items.len) end = data_list.items.len;
    for (data_list.items[table_ctx.start..end], 0..) |data, idx| {
        const row_bg =
            if (table_ctx.active and table_ctx.start + idx == table_ctx.row) table_ctx.selected_bg else if (idx % 2 == 0) table_ctx.row_bg_1 else table_ctx.row_bg_2;

        const row_win = table_win.initChild(
            0,
            1 + idx,
            .{ .limit = table_win.width },
            .{ .limit = 1 },
        );
        const DataT = @TypeOf(data);
        if (DataT == []const u8) {
            row_win.fill(.{ .style = .{ .bg = row_bg } });
            var seg = [_]vaxis.Cell.Segment{.{
                .text = if (data.len > table_ctx.col_width and alloc != null) try fmt.allocPrint(alloc.?, "{s}...", .{data[0..(table_ctx.col_width -| 4)]}) else data,
                .style = .{ .bg = row_bg },
            }};
            _ = try row_win.print(seg[0..], .{ .wrap = .word });
            return;
        }
        const item_fields = meta.fields(DataT);
        inline for (item_fields[0..], 0..) |item_field, item_idx| {
            const item = @field(data, item_field.name);
            const ItemT = @TypeOf(item);
            const item_win = row_win.initChild(
                item_idx * table_ctx.col_width,
                0,
                .{ .limit = table_ctx.col_width },
                .{ .limit = 1 },
            );
            const item_txt = switch (ItemT) {
                []const u8 => item,
                else => nonStr: {
                    switch (@typeInfo(ItemT)) {
                        .Optional => {
                            const opt_item = item orelse break :nonStr "-";
                            switch (@typeInfo(ItemT).Optional.child) {
                                []const u8 => break :nonStr opt_item,
                                else => {
                                    break :nonStr if (alloc) |_alloc| try fmt.allocPrint(_alloc, "{any}", .{opt_item}) else fmt.comptimePrint("[unsupported ({s})]", .{@typeName(DataT)});
                                },
                            }
                        },
                        else => {
                            break :nonStr if (alloc) |_alloc| try fmt.allocPrint(_alloc, "{any}", .{item}) else fmt.comptimePrint("[unsupported ({s})]", .{@typeName(DataT)});
                        },
                    }
                },
            };
            item_win.fill(.{ .style = .{ .bg = row_bg } });
            var seg = [_]vaxis.Cell.Segment{.{
                .text = if (item_txt.len > table_ctx.col_width and alloc != null) try fmt.allocPrint(alloc.?, "{s}...", .{item_txt[0..(table_ctx.col_width -| 4)]}) else item_txt,
                .style = .{ .bg = row_bg },
            }};
            _ = try item_win.print(seg[0..], .{ .wrap = .word });
        }
    }
}
