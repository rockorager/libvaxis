const std = @import("std");
const fmt = std.fmt;
const heap = std.heap;
const mem = std.mem;
const meta = std.meta;

const vaxis = @import("../main.zig");

/// Table Context for maintaining state and drawing Tables with `drawTable()`.
pub const TableContext = struct {
    /// Current active Row of the Table.
    row: u16 = 0,
    /// Current active Column of the Table.
    col: u16 = 0,
    /// Starting point within the Data List.
    start: u16 = 0,
    /// Selected Rows.
    sel_rows: ?[]u16 = null,

    /// Active status of the Table.
    active: bool = false,
    /// Active Content Callback Function.
    /// If available, this will be called to vertically expand the active row with additional info.
    active_content_fn: ?*const fn (*vaxis.Window, *const anyopaque) anyerror!u16 = null,
    /// Active Content Context
    /// This will be provided to the `active_content` callback when called.
    active_ctx: *const anyopaque = &{},
    /// Y Offset for rows beyond the Active Content.
    /// (This will be calculated automatically)
    active_y_off: u16 = 0,

    /// The Background Color for Selected Rows.
    selected_bg: vaxis.Cell.Color,
    /// The Foreground Color for Selected Rows.
    selected_fg: vaxis.Cell.Color = .default,
    /// The Background Color for the Active Row and Column Header.
    active_bg: vaxis.Cell.Color,
    /// The Foreground Color for the Active Row and Column Header.
    active_fg: vaxis.Cell.Color = .default,
    /// First Column Header Background Color
    hdr_bg_1: vaxis.Cell.Color = .{ .rgb = [_]u8{ 64, 64, 64 } },
    /// Second Column Header Background Color
    hdr_bg_2: vaxis.Cell.Color = .{ .rgb = [_]u8{ 8, 8, 24 } },
    /// First Row Background Color
    row_bg_1: vaxis.Cell.Color = .{ .rgb = [_]u8{ 32, 32, 32 } },
    /// Second Row Background Color
    row_bg_2: vaxis.Cell.Color = .{ .rgb = [_]u8{ 8, 8, 8 } },

    /// Y Offset for drawing to the parent Window.
    y_off: u16 = 0,
    /// X Offset for printing each Cell/Item.
    cell_x_off: u16 = 1,

    /// Column Width
    /// Note, if this is left `null` the Column Width will be dynamically calculated during `drawTable()`.
    //col_width: ?usize = null,
    col_width: WidthStyle = .dynamic_fill,

    // Header Names
    header_names: HeaderNames = .field_names,
    // Column Indexes
    col_indexes: ColumnIndexes = .all,
    // Header Alignment
    header_align: HorizontalAlignment = .center,
    // Column Alignment
    col_align: ColumnAlignment = .{ .all = .left },

    // Header Borders
    header_borders: bool = false,
    // Row Borders
    //row_borders: bool = false,
    // Col Borders
    col_borders: bool = false,
};

/// Width Styles for `col_width`.
pub const WidthStyle = union(enum) {
    /// Dynamically calculate Column Widths such that the entire (or most) of the screen is filled horizontally.
    dynamic_fill,
    /// Dynamically calculate the Column Width for each Column based on its Header Length and the provided Padding length.
    dynamic_header_len: u16,
    /// Statically set all Column Widths to the same value.
    static_all: u16,
    /// Statically set individual Column Widths to specific values.
    static_individual: []const u16,
};

/// Column Indexes
pub const ColumnIndexes = union(enum) {
    /// Use all of the Columns.
    all,
    /// Use Columns from the specified indexes.
    by_idx: []const usize,
};

/// Header Names
pub const HeaderNames = union(enum) {
    /// Use Field Names as Headers
    field_names,
    /// Custom
    custom: []const []const u8,
};

/// Horizontal Alignment
pub const HorizontalAlignment = enum {
    left,
    center,
};
/// Column Alignment
pub const ColumnAlignment = union(enum) {
    all: HorizontalAlignment,
    by_idx: []const HorizontalAlignment,
};

/// Draw a Table for the TUI.
pub fn drawTable(
    /// This should be an ArenaAllocator that can be deinitialized after each event call.
    /// The Allocator is only used in three cases:
    /// 1. If a cell is a non-String. (If the Allocator is not provided, those cells will show "[unsupported (TypeName)]".)
    /// 2. To show that a value is too large to fit into a cell using '...'. (If the Allocator is not provided, they'll just be cutoff.)
    /// 3. To copy a MultiArrayList into a normal slice. (Note, this is an expensive operation. Prefer to pass a Slice or ArrayList if possible.)
    alloc: ?mem.Allocator,
    /// The parent Window to draw to.
    win: vaxis.Window,
    /// This must be a Slice, ArrayList, or MultiArrayList.
    /// Note, MultiArrayList support currently requires allocation.
    data_list: anytype,
    // The Table Context for this Table.
    table_ctx: *TableContext,
) !void {
    var di_is_mal = false;
    const data_items = getData: {
        const DataListT = @TypeOf(data_list);
        const data_ti = @typeInfo(DataListT);
        switch (data_ti) {
            .pointer => |ptr| {
                if (ptr.size != .Slice) return error.UnsupportedTableDataType;
                break :getData data_list;
            },
            .@"struct" => {
                const di_fields = meta.fields(DataListT);
                const al_fields = meta.fields(std.ArrayList([]const u8));
                const mal_fields = meta.fields(std.MultiArrayList(struct { a: u8 = 0, b: u32 = 0 }));
                // Probably an ArrayList
                const is_al = comptime if (mem.indexOf(u8, @typeName(DataListT), "MultiArrayList") == null and
                    mem.indexOf(u8, @typeName(DataListT), "ArrayList") != null and
                    al_fields.len == di_fields.len)
                isAL: {
                    var is = true;
                    for (al_fields, di_fields) |al_field, di_field|
                        is = is and mem.eql(u8, al_field.name, di_field.name);
                    break :isAL is;
                } else false;
                if (is_al) break :getData data_list.items;

                // Probably a MultiArrayList
                const is_mal = if (mem.indexOf(u8, @typeName(DataListT), "MultiArrayList") != null and
                    mal_fields.len == di_fields.len)
                isMAL: {
                    var is = true;
                    inline for (mal_fields, di_fields) |mal_field, di_field|
                        is = is and mem.eql(u8, mal_field.name, di_field.name);
                    break :isMAL is;
                } else false;
                if (!is_mal) return error.UnsupportedTableDataType;
                if (alloc) |_alloc| {
                    di_is_mal = true;
                    const mal_slice = data_list.slice();
                    const DataT = dataType: {
                        const fn_info = @typeInfo(@TypeOf(@field(@TypeOf(mal_slice), "get")));
                        break :dataType fn_info.@"fn".return_type orelse @panic("No Child Type");
                    };
                    var data_out_list = std.ArrayList(DataT).init(_alloc);
                    for (0..mal_slice.len) |idx| try data_out_list.append(mal_slice.get(idx));
                    break :getData try data_out_list.toOwnedSlice();
                }
                return error.UnsupportedTableDataType;
            },
            else => return error.UnsupportedTableDataType,
        }
    };
    defer if (di_is_mal) alloc.?.free(data_items);
    const DataT = @TypeOf(data_items[0]);
    const fields = meta.fields(DataT);
    const field_indexes = switch (table_ctx.col_indexes) {
        .all => comptime allIdx: {
            var indexes_buf: [fields.len]usize = undefined;
            for (0..fields.len) |idx| indexes_buf[idx] = idx;
            const indexes = indexes_buf;
            break :allIdx indexes[0..];
        },
        .by_idx => |by_idx| by_idx,
    };

    // Headers for the Table
    var hdrs_buf: [fields.len][]const u8 = undefined;
    const headers = hdrs: {
        switch (table_ctx.header_names) {
            .field_names => {
                for (field_indexes) |f_idx| {
                    inline for (fields, 0..) |field, idx| {
                        if (f_idx == idx)
                            hdrs_buf[idx] = field.name;
                    }
                }
                break :hdrs hdrs_buf[0..];
            },
            .custom => |hdrs| break :hdrs hdrs,
        }
    };

    const table_win = win.child(.{
        .y_off = table_ctx.y_off,
        .width = win.width,
        .height = win.height,
    });

    // Headers
    if (table_ctx.col > headers.len - 1) table_ctx.col = @intCast(headers.len - 1);
    var col_start: u16 = 0;
    for (headers[0..], 0..) |hdr_txt, idx| {
        const col_width = try calcColWidth(
            @intCast(idx),
            headers,
            table_ctx.col_width,
            table_win,
        );
        defer col_start += col_width;
        const hdr_fg, const hdr_bg = hdrColors: {
            if (table_ctx.active and idx == table_ctx.col)
                break :hdrColors .{ table_ctx.active_fg, table_ctx.active_bg }
            else if (idx % 2 == 0)
                break :hdrColors .{ .default, table_ctx.hdr_bg_1 }
            else
                break :hdrColors .{ .default, table_ctx.hdr_bg_2 };
        };
        const hdr_win = table_win.child(.{
            .x_off = col_start,
            .y_off = 0,
            .width = col_width,
            .height = 1,
            .border = .{ .where = if (table_ctx.header_borders and idx > 0) .left else .none },
        });
        var hdr = switch (table_ctx.header_align) {
            .left => hdr_win,
            .center => vaxis.widgets.alignment.center(hdr_win, @min(col_width -| 1, hdr_txt.len +| 1), 1),
        };
        hdr_win.fill(.{ .style = .{ .bg = hdr_bg } });
        var seg = [_]vaxis.Cell.Segment{.{
            .text = if (hdr_txt.len > col_width and alloc != null) try fmt.allocPrint(alloc.?, "{s}...", .{hdr_txt[0..(col_width -| 4)]}) else hdr_txt,
            .style = .{
                .fg = hdr_fg,
                .bg = hdr_bg,
                .bold = true,
                .ul_style = if (idx == table_ctx.col) .single else .dotted,
            },
        }};
        _ = hdr.print(seg[0..], .{ .wrap = .word });
    }

    // Rows
    if (table_ctx.active_content_fn == null) table_ctx.active_y_off = 0;
    const max_items: u16 =
        if (data_items.len > table_win.height -| 1) table_win.height -| 1 else @intCast(data_items.len);
    var end = table_ctx.start + max_items;
    if (table_ctx.row + table_ctx.active_y_off >= win.height -| 2)
        end -|= table_ctx.active_y_off;
    if (end > data_items.len) end = @intCast(data_items.len);
    table_ctx.start = tableStart: {
        if (table_ctx.row == 0)
            break :tableStart 0;
        if (table_ctx.row < table_ctx.start)
            break :tableStart table_ctx.start - (table_ctx.start - table_ctx.row);
        if (table_ctx.row >= data_items.len - 1)
            table_ctx.row = @intCast(data_items.len - 1);
        if (table_ctx.row >= end)
            break :tableStart table_ctx.start + (table_ctx.row - end + 1);
        break :tableStart table_ctx.start;
    };
    end = table_ctx.start + max_items;
    if (table_ctx.row + table_ctx.active_y_off >= win.height -| 2)
        end -|= table_ctx.active_y_off;
    if (end > data_items.len) end = @intCast(data_items.len);
    table_ctx.start = @min(table_ctx.start, end);
    table_ctx.active_y_off = 0;
    for (data_items[table_ctx.start..end], 0..) |data, row| {
        const row_fg, const row_bg = rowColors: {
            if (table_ctx.active and table_ctx.start + row == table_ctx.row)
                break :rowColors .{ table_ctx.active_fg, table_ctx.active_bg };
            if (table_ctx.sel_rows) |rows| {
                if (mem.indexOfScalar(u16, rows, @intCast(table_ctx.start + row)) != null)
                    break :rowColors .{ table_ctx.selected_fg, table_ctx.selected_bg };
            }
            if (row % 2 == 0) break :rowColors .{ .default, table_ctx.row_bg_1 };
            break :rowColors .{ .default, table_ctx.row_bg_2 };
        };
        var row_win = table_win.child(.{
            .x_off = 0,
            .y_off = @intCast(1 + row + table_ctx.active_y_off),
            .width = table_win.width,
            .height = 1,
            //.border = .{ .where = if (table_ctx.row_borders) .top else .none },
        });
        if (table_ctx.start + row == table_ctx.row) {
            table_ctx.active_y_off = if (table_ctx.active_content_fn) |content| try content(&row_win, table_ctx.active_ctx) else 0;
        }
        col_start = 0;
        const item_fields = meta.fields(DataT);
        var col_idx: usize = 0;
        for (field_indexes) |f_idx| {
            inline for (item_fields[0..], 0..) |item_field, item_idx| contFields: {
                switch (table_ctx.col_indexes) {
                    .all => {},
                    .by_idx => {
                        if (item_idx != f_idx) break :contFields;
                    },
                }
                defer col_idx += 1;
                const col_width = try calcColWidth(
                    item_idx,
                    headers,
                    table_ctx.col_width,
                    table_win,
                );
                defer col_start += col_width;
                const item = @field(data, item_field.name);
                const ItemT = @TypeOf(item);
                const item_win = row_win.child(.{
                    .x_off = col_start,
                    .y_off = 0,
                    .width = col_width,
                    .height = 1,
                    .border = .{ .where = if (table_ctx.col_borders and col_idx > 0) .left else .none },
                });
                const item_txt = switch (ItemT) {
                    []const u8 => item,
                    [][]const u8, []const []const u8 => strSlice: {
                        if (alloc) |_alloc| break :strSlice try fmt.allocPrint(_alloc, "{s}", .{item});
                        break :strSlice item;
                    },
                    else => nonStr: {
                        switch (@typeInfo(ItemT)) {
                            .@"enum" => break :nonStr @tagName(item),
                            .optional => {
                                const opt_item = item orelse break :nonStr "-";
                                switch (@typeInfo(ItemT).optional.child) {
                                    []const u8 => break :nonStr opt_item,
                                    [][]const u8, []const []const u8 => {
                                        break :nonStr if (alloc) |_alloc| try fmt.allocPrint(_alloc, "{s}", .{opt_item}) else fmt.comptimePrint("[unsupported ({s})]", .{@typeName(DataT)});
                                    },
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
                const item_align_win = itemAlignWin: {
                    const col_align = switch (table_ctx.col_align) {
                        .all => |all| all,
                        .by_idx => |aligns| aligns[col_idx],
                    };
                    break :itemAlignWin switch (col_align) {
                        .left => item_win,
                        .center => center: {
                            const center = vaxis.widgets.alignment.center(item_win, @min(col_width -| 1, item_txt.len +| 1), 1);
                            center.fill(.{ .style = .{ .bg = row_bg } });
                            break :center center;
                        },
                    };
                };
                var seg = [_]vaxis.Cell.Segment{.{
                    .text = if (item_txt.len > col_width and alloc != null) try fmt.allocPrint(alloc.?, "{s}...", .{item_txt[0..(col_width -| 4)]}) else item_txt,
                    .style = .{ .fg = row_fg, .bg = row_bg },
                }};
                _ = item_align_win.print(seg[0..], .{ .wrap = .word, .col_offset = table_ctx.cell_x_off });
            }
        }
    }
}

/// Calculate the Column Width of `col` using the provided Number of Headers (`num_hdrs`), Width Style (`style`), and Table Window (`table_win`).
pub fn calcColWidth(
    col: u16,
    headers: []const []const u8,
    style: WidthStyle,
    table_win: vaxis.Window,
) !u16 {
    return switch (style) {
        .dynamic_fill => dynFill: {
            var cw: u16 = table_win.width / @as(u16, @intCast(headers.len));
            if (cw % 2 != 0) cw +|= 1;
            while (cw * headers.len < table_win.width - 1) cw +|= 1;
            break :dynFill cw;
        },
        .dynamic_header_len => dynHdrs: {
            if (col >= headers.len) break :dynHdrs error.NotEnoughStaticWidthsProvided;
            break :dynHdrs @as(u16, @intCast(headers[col].len)) + (style.dynamic_header_len * 2);
        },
        .static_all => style.static_all,
        .static_individual => statInd: {
            if (col >= headers.len) break :statInd error.NotEnoughStaticWidthsProvided;
            break :statInd style.static_individual[col];
        },
    };
}
