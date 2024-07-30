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

    var tty = try vaxis.Tty.init();
    defer tty.deinit();

    var vx = try vaxis.init(alloc, .{});
    defer vx.deinit(alloc, tty.anyWriter());

    var loop: vaxis.Loop(union(enum) {
        key_press: vaxis.Key,
        winsize: vaxis.Winsize,
    }) = .{ .tty = &tty, .vaxis = &vx };
    try loop.init();

    try loop.start();
    defer loop.stop();
    try vx.enterAltScreen(tty.anyWriter());
    try vx.queryTerminal(tty.anyWriter(), 1 * std.time.ns_per_s);

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
    const selected_bg: vaxis.Cell.Color = .{ .rgb = .{ 64, 128, 255 } };
    const other_bg: vaxis.Cell.Color = .{ .rgb = .{ 32, 32, 48 } };

    // Table Context
    var demo_tbl: vaxis.widgets.Table.TableContext = .{ .selected_bg = selected_bg };

    // TUI State
    var active: ActiveSection = .mid;
    var moving = false;

    while (true) {
        // Create an Arena Allocator for easy allocations on each Event.
        var event_arena = heap.ArenaAllocator.init(alloc);
        defer event_arena.deinit();
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
                    for (0..cmd_input.buf.items.len) |_| _ = cmd_input.buf.orderedRemove(0);
                    try cmd_input.update(.{ .key_press = key });
                    cmd_input.cursor_idx = 1;
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
                    },
                    .btm => {
                        if (key.matchesAny(&.{ vaxis.Key.up, 'k' }, .{}) and moving) active = .mid
                        // Run Command and Clear Command Bar
                        else if (key.matchExact(vaxis.Key.enter, .{})) {
                            const cmd = cmd_input.buf.items;
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
                            for (0..cmd_input.buf.items.len) |_| _ = cmd_input.buf.orderedRemove(0);
                            cmd_input.cursor_idx = 0;
                        } else try cmd_input.update(.{ .key_press = key });
                    },
                }
                moving = false;
            },
            .winsize => |ws| try vx.resize(alloc, tty.anyWriter(), ws),
            //else => {},
        }

        // Sections
        // - Window
        const win = vx.window();
        win.clear();

        // - Top
        const top_div = 6;
        const top_bar = win.initChild(
            0,
            0,
            .{ .limit = win.width },
            .{ .limit = win.height / top_div },
        );
        for (title_segs[0..]) |*title_seg|
            title_seg.*.style.bg = if (active == .top) selected_bg else other_bg;
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
        const middle_bar = win.initChild(
            0,
            win.height / top_div,
            .{ .limit = win.width },
            .{ .limit = win.height - (top_bar.height + 1) },
        );
        if (user_list.items.len > 0) {
            demo_tbl.active = active == .mid;
            try vaxis.widgets.Table.drawTable(
                event_alloc,
                middle_bar,
                &.{ "First", "Last", "Username", "Email", "Phone#" },
                user_list,
                &demo_tbl,
            );
        }

        // - Bottom
        const bottom_bar = win.initChild(
            0,
            win.height - 1,
            .{ .limit = win.width },
            .{ .limit = 1 },
        );
        if (active == .btm) bottom_bar.fill(.{ .style = .{ .bg = selected_bg } });
        cmd_input.draw(bottom_bar);

        // Render the screen
        try vx.render(tty.anyWriter());
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
