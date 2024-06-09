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
    // const shell = env.get("SHELL") orelse "bash";
    const shell = "fish";
    // const ed = env.get("EDITOR") orelse "nvim";
    // const pager = env.get("EDITOR") orelse "nvim";
    const argv = [_][]const u8{shell};
    var vt = try vaxis.widgets.Terminal.init(
        alloc,
        &argv,
        &env,
        &vx.unicode,
        vt_opts,
    );
    defer vt.deinit();
    try vt.spawn();

    while (true) {
        std.time.sleep(8 * std.time.ns_per_ms);
        // try vt events first
        while (vt.tryEvent()) |event| {
            switch (event) {
                .bell => {},
                .exited => return,
            }
        }
        while (loop.tryEvent()) |event| {
            switch (event) {
                .key_press => |key| {
                    if (key.matches('c', .{ .ctrl = true })) return;
                    try vt.update(.{ .key_press = key });
                },
                .winsize => |ws| {
                    try vx.resize(alloc, tty.anyWriter(), ws);
                },
            }
        }

        const win = vx.window();
        win.clear();
        const child = win.child(.{
            .x_off = 4,
            .y_off = 2,
            .width = .{ .limit = win.width - 8 },
            .height = .{ .limit = win.width - 6 },
            .border = .{
                .where = .all,
            },
        });

        try vt.resize(.{
            .rows = child.height,
            .cols = child.width,
            .x_pixel = 0,
            .y_pixel = 0,
        });
        try vt.draw(child);

        try vx.render(tty.anyWriter());
    }
}
