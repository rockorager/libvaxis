const std = @import("std");
const vaxis = @import("vaxis");
const Cell = vaxis.Cell;

const Event = union(enum) {
    key_press: vaxis.Key,
    winsize: vaxis.Winsize,
};

pub const panic = vaxis.panic_handler;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const deinit_status = gpa.deinit();
        //fail test; can't try in defer as defer is executed after we return
        if (deinit_status == .leak) {
            std.log.err("memory leak", .{});
        }
    }
    const alloc = gpa.allocator();

    var tty = try vaxis.Tty.init();
    var vx = try vaxis.init(alloc, .{});
    defer vx.deinit(alloc, tty.anyWriter());

    var loop: vaxis.Loop(Event) = .{ .tty = &tty, .vaxis = &vx };
    try loop.init();

    try loop.start();
    defer loop.stop();

    try vx.enterAltScreen(tty.anyWriter());
    try vx.queryTerminal(tty.anyWriter(), 1 * std.time.ns_per_s);
    var env = try std.process.getEnvMap(alloc);
    defer env.deinit();

    const vt_opts: vaxis.widgets.Terminal.Options = .{
        .winsize = .{
            .rows = 24,
            .cols = 100,
            .x_pixel = 0,
            .y_pixel = 0,
        },
        .scrollback_size = 0,
    };
    const argv1 = [_][]const u8{"senpai"};
    const argv2 = [_][]const u8{"nvim"};
    const argv3 = [_][]const u8{"senpai"};
    // const argv = [_][]const u8{"senpai"};
    // const argv = [_][]const u8{"comlink"};
    var vt1 = try vaxis.widgets.Terminal.init(
        alloc,
        &argv1,
        &env,
        &vx.unicode,
        vt_opts,
    );
    defer vt1.deinit();
    try vt1.spawn();
    var vt2 = try vaxis.widgets.Terminal.init(
        alloc,
        &argv2,
        &env,
        &vx.unicode,
        vt_opts,
    );
    defer vt2.deinit();
    try vt2.spawn();
    var vt3 = try vaxis.widgets.Terminal.init(
        alloc,
        &argv3,
        &env,
        &vx.unicode,
        vt_opts,
    );
    defer vt3.deinit();
    try vt3.spawn();

    while (true) {
        std.time.sleep(8 * std.time.ns_per_ms);
        while (loop.tryEvent()) |event| {
            switch (event) {
                .key_press => |key| if (key.matches('c', .{ .ctrl = true })) return,
                .winsize => |ws| {
                    try vx.resize(alloc, tty.anyWriter(), ws);
                },
            }
        }

        const win = vx.window();
        win.clear();
        const left = win.child(.{
            .width = .{ .limit = win.width / 2 },
            .border = .{
                .where = .right,
            },
        });

        const right_top = win.child(.{
            .x_off = left.width + 1,
            .height = .{ .limit = win.height / 2 },
            .border = .{
                .where = .bottom,
            },
        });
        const right_bot = win.child(.{
            .x_off = left.width + 1,
            .y_off = right_top.height + 1,
        });

        try vt1.resize(.{
            .rows = left.height,
            .cols = left.width,
            .x_pixel = 0,
            .y_pixel = 0,
        });
        try vt2.resize(.{
            .rows = right_top.height,
            .cols = right_bot.width,
            .x_pixel = 0,
            .y_pixel = 0,
        });
        try vt3.resize(.{
            .rows = right_bot.height,
            .cols = right_bot.width,
            .x_pixel = 0,
            .y_pixel = 0,
        });
        try vt1.draw(left);
        try vt2.draw(right_top);
        try vt3.draw(right_bot);

        try vx.render(tty.anyWriter());
    }
}
