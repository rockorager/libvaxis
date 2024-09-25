const std = @import("std");
const fmt = std.fmt;
const heap = std.heap;
const mem = std.mem;
const meta = std.meta;

const vaxis = @import("vaxis");

const log = std.log.scoped(.main);

const ActiveSection = enum {
    top,
    mid,
    btm,
};

pub fn main() !void {
    var gpa = heap.GeneralPurposeAllocator(.{}){};
    defer if (gpa.detectLeaks()) log.err("Memory leak detected!", .{});
    const alloc = gpa.allocator();

    // Users set up below the main function
    const users_buf = try alloc.dupe(User, users[0..]);
    const user_list = std.ArrayList(User).fromOwnedSlice(alloc, users_buf);
    defer user_list.deinit();
    var user_mal = std.MultiArrayList(User){};
    for (users_buf[0..]) |user| try user_mal.append(alloc, user);
    defer user_mal.deinit(alloc);

    var tty = try vaxis.Tty.init();
    defer tty.deinit();
    var tty_buf_writer = tty.bufferedWriter();
    defer tty_buf_writer.flush() catch {};
    const tty_writer = tty_buf_writer.writer().any();
    var vx = try vaxis.init(alloc, .{
        .kitty_keyboard_flags = .{ .report_events = true },
    });
    defer vx.deinit(alloc, tty.anyWriter());

    var loop: vaxis.Loop(union(enum) {
        key_press: vaxis.Key,
        winsize: vaxis.Winsize,
        table_upd,
    }) = .{ .tty = &tty, .vaxis = &vx };
    try loop.init();
    try loop.start();
    defer loop.stop();
    try vx.enterAltScreen(tty.anyWriter());
    try vx.queryTerminal(tty.anyWriter(), 250 * std.time.ns_per_ms);

    const logo =
        \\░█░█░█▀█░█░█░▀█▀░█▀▀░░░▀█▀░█▀█░█▀▄░█░░░█▀▀░
        \\░▀▄▀░█▀█░▄▀▄░░█░░▀▀█░░░░█░░█▀█░█▀▄░█░░░█▀▀░
        \\░░▀░░▀░▀░▀░▀░▀▀▀░▀▀▀░░░░▀░░▀░▀░▀▀░░▀▀▀░▀▀▀░
    ;
    const title_logo = vaxis.Cell.Segment{
        .text = logo,
        .style = .{},
    };
    const title_info = vaxis.Cell.Segment{
        .text = "===A Demo of the the Vaxis Table Widget!===",
        .style = .{},
    };
    const title_disclaimer = vaxis.Cell.Segment{
        .text = "(All data is non-sensical & LLM generated.)",
        .style = .{},
    };
    var title_segs = [_]vaxis.Cell.Segment{ title_logo, title_info, title_disclaimer };

    var cmd_input = vaxis.widgets.TextInput.init(alloc, &vx.unicode);
    defer cmd_input.deinit();

    // Colors
    const active_bg: vaxis.Cell.Color = .{ .rgb = .{ 64, 128, 255 } };
    const selected_bg: vaxis.Cell.Color = .{ .rgb = .{ 32, 64, 255 } };
    const other_bg: vaxis.Cell.Color = .{ .rgb = .{ 32, 32, 48 } };

    // Table Context
    var demo_tbl: vaxis.widgets.Table.TableContext = .{
        .active_bg = active_bg,
        .active_fg = .{ .rgb = .{ 0, 0, 0 } },
        .row_bg_1 = .{ .rgb = .{ 8, 8, 8 } },
        .selected_bg = selected_bg,
        .header_names = .{ .custom = &.{ "First", "Last", "Username", "Phone#", "Email" } },
        //.header_align = .left,
        .col_indexes = .{ .by_idx = &.{ 0, 1, 2, 4, 3 } },
        //.col_align = .{ .by_idx = &.{ .left, .left, .center, .center, .left } },
        //.col_align = .{ .all = .center },
        //.header_borders = true,
        //.col_borders = true,
        //.col_width = .{ .static_all = 15 },
        //.col_width = .{ .dynamic_header_len = 3 },
        //.col_width = .{ .static_individual = &.{ 10, 20, 15, 25, 15 } },
        //.col_width = .dynamic_fill,
        //.y_off = 10,
    };
    defer if (demo_tbl.sel_rows) |rows| alloc.free(rows);

    // TUI State
    var active: ActiveSection = .mid;
    var moving = false;
    var see_content = false;

    // Create an Arena Allocator for easy allocations on each Event.
    var event_arena = heap.ArenaAllocator.init(alloc);
    defer event_arena.deinit();
    while (true) {
        defer _ = event_arena.reset(.retain_capacity);
        defer tty_buf_writer.flush() catch {};
        const event_alloc = event_arena.allocator();
        const event = loop.nextEvent();

        switch (event) {
            .key_press => |key| keyEvt: {
                // Close the Program
                if (key.matches('c', .{ .ctrl = true })) {
                    break;
                }
                // Refresh the Screen
                if (key.matches('l', .{ .ctrl = true })) {
                    vx.queueRefresh();
                    break :keyEvt;
                }
                // Enter Moving State
                if (key.matches('w', .{ .ctrl = true })) {
                    moving = !moving;
                    break :keyEvt;
                }
                // Command State
                if (active != .btm and
                    key.matchesAny(&.{ ':', '/', 'g', 'G' }, .{}))
                {
                    active = .btm;
                    cmd_input.clearAndFree();
                    try cmd_input.update(.{ .key_press = key });
                    break :keyEvt;
                }

                switch (active) {
                    .top => {
                        if (key.matchesAny(&.{ vaxis.Key.down, 'j' }, .{}) and moving) active = .mid;
                    },
                    .mid => midEvt: {
                        if (moving) {
                            if (key.matchesAny(&.{ vaxis.Key.up, 'k' }, .{})) active = .top;
                            if (key.matchesAny(&.{ vaxis.Key.down, 'j' }, .{})) active = .btm;
                            break :midEvt;
                        }
                        // Change Row
                        if (key.matchesAny(&.{ vaxis.Key.up, 'k' }, .{})) demo_tbl.row -|= 1;
                        if (key.matchesAny(&.{ vaxis.Key.down, 'j' }, .{})) demo_tbl.row +|= 1;
                        // Change Column
                        if (key.matchesAny(&.{ vaxis.Key.left, 'h' }, .{})) demo_tbl.col -|= 1;
                        if (key.matchesAny(&.{ vaxis.Key.right, 'l' }, .{})) demo_tbl.col +|= 1;
                        // Select/Unselect Row
                        if (key.matches(vaxis.Key.space, .{})) {
                            const rows = demo_tbl.sel_rows orelse createRows: {
                                demo_tbl.sel_rows = try alloc.alloc(usize, 1);
                                break :createRows demo_tbl.sel_rows.?;
                            };
                            var rows_list = std.ArrayList(usize).fromOwnedSlice(alloc, rows);
                            for (rows_list.items, 0..) |row, idx| {
                                if (row != demo_tbl.row) continue;
                                _ = rows_list.orderedRemove(idx);
                                break;
                            } else try rows_list.append(demo_tbl.row);
                            demo_tbl.sel_rows = try rows_list.toOwnedSlice();
                        }
                        // See Row Content
                        if (key.matches(vaxis.Key.enter, .{})) see_content = !see_content;
                    },
                    .btm => {
                        if (key.matchesAny(&.{ vaxis.Key.up, 'k' }, .{}) and moving) active = .mid
                        // Run Command and Clear Command Bar
                        else if (key.matchExact(vaxis.Key.enter, .{})) {
                            const cmd = try cmd_input.toOwnedSlice();
                            defer alloc.free(cmd);
                            if (mem.eql(u8, ":q", cmd) or
                                mem.eql(u8, ":quit", cmd) or
                                mem.eql(u8, ":exit", cmd)) return;
                            if (mem.eql(u8, "G", cmd)) {
                                demo_tbl.row = user_list.items.len - 1;
                                active = .mid;
                            }
                            if (cmd.len >= 2 and mem.eql(u8, "gg", cmd[0..2])) {
                                const goto_row = fmt.parseInt(usize, cmd[2..], 0) catch 0;
                                demo_tbl.row = goto_row;
                                active = .mid;
                            }
                        } else try cmd_input.update(.{ .key_press = key });
                    },
                }
                moving = false;
            },
            .winsize => |ws| try vx.resize(alloc, tty.anyWriter(), ws),
            else => {},
        }

        // Content
        seeRow: {
            if (!see_content) {
                demo_tbl.active_content_fn = null;
                demo_tbl.active_ctx = &{};
                break :seeRow;
            }
            const RowContext = struct {
                row: []const u8,
                bg: vaxis.Color,
            };
            const row_ctx = RowContext{
                .row = try fmt.allocPrint(event_alloc, "Row #: {d}", .{demo_tbl.row}),
                .bg = demo_tbl.active_bg,
            };
            demo_tbl.active_ctx = &row_ctx;
            demo_tbl.active_content_fn = struct {
                fn see(win: *vaxis.Window, ctx_raw: *const anyopaque) !usize {
                    const ctx: *const RowContext = @alignCast(@ptrCast(ctx_raw));
                    win.height = 5;
                    const see_win = win.child(.{
                        .x_off = 0,
                        .y_off = 1,
                        .width = .{ .limit = win.width },
                        .height = .{ .limit = 4 },
                    });
                    see_win.fill(.{ .style = .{ .bg = ctx.bg } });
                    const content_logo =
                        \\
                        \\░█▀▄░█▀█░█░█░░░█▀▀░█▀█░█▀█░▀█▀░█▀▀░█▀█░▀█▀
                        \\░█▀▄░█░█░█▄█░░░█░░░█░█░█░█░░█░░█▀▀░█░█░░█░
                        \\░▀░▀░▀▀▀░▀░▀░░░▀▀▀░▀▀▀░▀░▀░░▀░░▀▀▀░▀░▀░░▀░
                    ;
                    const content_segs: []const vaxis.Cell.Segment = &.{
                        .{
                            .text = ctx.row,
                            .style = .{ .bg = ctx.bg },
                        },
                        .{
                            .text = content_logo,
                            .style = .{ .bg = ctx.bg },
                        },
                    };
                    _ = try see_win.print(content_segs, .{});
                    return see_win.height;
                }
            }.see;
            loop.postEvent(.table_upd);
        }

        // Sections
        // - Window
        const win = vx.window();
        win.clear();

        // - Top
        const top_div = 6;
        const top_bar = win.child(.{
            .x_off = 0,
            .y_off = 0,
            .width = .{ .limit = win.width },
            .height = .{ .limit = win.height / top_div },
        });
        for (title_segs[0..]) |*title_seg|
            title_seg.style.bg = if (active == .top) selected_bg else other_bg;
        top_bar.fill(.{ .style = .{
            .bg = if (active == .top) selected_bg else other_bg,
        } });
        const logo_bar = vaxis.widgets.alignment.center(
            top_bar,
            44,
            top_bar.height - (top_bar.height / 3),
        );
        _ = try logo_bar.print(title_segs[0..], .{ .wrap = .word });

        // - Middle
        const middle_bar = win.child(.{
            .x_off = 0,
            .y_off = win.height / top_div,
            .width = .{ .limit = win.width },
            .height = .{ .limit = win.height - (top_bar.height + 1) },
        });
        if (user_list.items.len > 0) {
            demo_tbl.active = active == .mid;
            try vaxis.widgets.Table.drawTable(
                event_alloc,
                middle_bar,
                //users_buf[0..],
                //user_list,
                user_mal,
                &demo_tbl,
            );
        }

        // - Bottom
        const bottom_bar = win.child(.{
            .x_off = 0,
            .y_off = win.height - 1,
            .width = .{ .limit = win.width },
            .height = .{ .limit = 1 },
        });
        if (active == .btm) bottom_bar.fill(.{ .style = .{ .bg = active_bg } });
        cmd_input.draw(bottom_bar);

        // Render the screen
        try vx.render(tty_writer);
    }
}

/// User Struct
pub const User = struct {
    first: []const u8,
    last: []const u8,
    user: []const u8,
    email: ?[]const u8 = null,
    phone: ?[]const u8 = null,
};

// Users Array
const users = [_]User{
    .{ .first = "Nancy", .last = "Dudley", .user = "angela73", .email = "brian47@rodriguez.biz", .phone = null },
    .{ .first = "Emily", .last = "Thornton", .user = "mrogers", .email = null, .phone = "(558)888-8604x094" },
    .{ .first = "Kyle", .last = "Huff", .user = "xsmith", .email = null, .phone = "301.127.0801x12398" },
    .{ .first = "Christine", .last = "Dodson", .user = "amandabradley", .email = "cheryl21@sullivan.com", .phone = null },
    .{ .first = "Nathaniel", .last = "Kennedy", .user = "nrobinson", .email = null, .phone = null },
    .{ .first = "Laura", .last = "Leon", .user = "dawnjones", .email = "fjenkins@patel.com", .phone = "1833013180" },
    .{ .first = "Patrick", .last = "Landry", .user = "michaelhutchinson", .email = "daniel17@medina-wallace.net", .phone = "+1-634-486-6444x964" },
    .{ .first = "Tammy", .last = "Hall", .user = "jamessmith", .email = null, .phone = "(926)810-3385x22059" },
    .{ .first = "Stephanie", .last = "Anderson", .user = "wgillespie", .email = "campbelljaime@yahoo.com", .phone = null },
    .{ .first = "Jennifer", .last = "Williams", .user = "shawn60", .email = null, .phone = "611-385-4771x97523" },
    .{ .first = "Elizabeth", .last = "Ortiz", .user = "jennifer76", .email = "johnbradley@delgado.info", .phone = null },
    .{ .first = "Stacy", .last = "Mays", .user = "scottgonzalez", .email = "kramermatthew@gmail.com", .phone = null },
    .{ .first = "Jennifer", .last = "Smith", .user = "joseph75", .email = "masseyalexander@hill-moore.net", .phone = null },
    .{ .first = "Gary", .last = "Hammond", .user = "brittany26", .email = null, .phone = null },
    .{ .first = "Lisa", .last = "Johnson", .user = "tina28", .email = null, .phone = "850-606-2978x1081" },
    .{ .first = "Zachary", .last = "Hopkins", .user = "vargasmichael", .email = null, .phone = null },
    .{ .first = "Joshua", .last = "Kidd", .user = "ghanna", .email = "jbrown@yahoo.com", .phone = null },
    .{ .first = "Dawn", .last = "Jones", .user = "alisonlindsey", .email = null, .phone = null },
    .{ .first = "Monica", .last = "Berry", .user = "barbara40", .email = "michael00@hotmail.com", .phone = "(295)346-6453x343" },
    .{ .first = "Shannon", .last = "Roberts", .user = "krystal37", .email = null, .phone = "980-920-9386x454" },
    .{ .first = "Thomas", .last = "Mitchell", .user = "williamscorey", .email = "richardduncan@roberts.com", .phone = null },
    .{ .first = "Nicole", .last = "Shaffer", .user = "rogerstroy", .email = null, .phone = "(570)128-5662" },
    .{ .first = "Edward", .last = "Bennett", .user = "andersonchristina", .email = null, .phone = null },
    .{ .first = "Duane", .last = "Howard", .user = "pcarpenter", .email = "griffithwayne@parker.net", .phone = null },
    .{ .first = "Mary", .last = "Brown", .user = "kimberlyfrost", .email = "perezsara@anderson-andrews.net", .phone = null },
    .{ .first = "Pamela", .last = "Sloan", .user = "kvelez", .email = "huynhlacey@moore-bell.biz", .phone = "001-359-125-1393x8716" },
    .{ .first = "Timothy", .last = "Charles", .user = "anthony04", .email = "morrissara@hawkins.info", .phone = "+1-619-369-9572" },
    .{ .first = "Sydney", .last = "Torres", .user = "scott42", .email = "asnyder@mitchell.net", .phone = null },
    .{ .first = "John", .last = "Jones", .user = "anthonymoore", .email = null, .phone = "701.236.0571x99622" },
    .{ .first = "Erik", .last = "Johnson", .user = "allisonsanders", .email = null, .phone = null },
    .{ .first = "Donna", .last = "Kirk", .user = "laurie81", .email = null, .phone = null },
    .{ .first = "Karina", .last = "White", .user = "uperez", .email = null, .phone = null },
    .{ .first = "Jesse", .last = "Schwartz", .user = "ryan60", .email = "latoyawilliams@gmail.com", .phone = null },
    .{ .first = "Cindy", .last = "Romero", .user = "christopher78", .email = "faulknerchristina@gmail.com", .phone = "780.288.2319x583" },
    .{ .first = "Tyler", .last = "Sanders", .user = "bennettjessica", .email = null, .phone = "1966269423" },
    .{ .first = "Pamela", .last = "Carter", .user = "zsnyder", .email = null, .phone = "125-062-9130x58413" },
};
