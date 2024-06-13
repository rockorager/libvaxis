const std = @import("std");
const vaxis = @import("vaxis");
const xev = @import("xev");
const Cell = vaxis.Cell;

pub const panic = vaxis.panic_handler;

const App = struct {
    const lower_limit: u8 = 30;
    const next_ms: u64 = 8;

    allocator: std.mem.Allocator,
    vx: *vaxis.Vaxis,
    buffered_writer: std.io.BufferedWriter(4096, std.io.AnyWriter),
    color_idx: u8,
    dir: enum {
        up,
        down,
    },

    fn draw(self: *App) !void {
        const style: vaxis.Style = .{ .fg = .{ .rgb = [_]u8{ self.color_idx, self.color_idx, self.color_idx } } };

        const segment: vaxis.Segment = .{
            .text = vaxis.logo,
            .style = style,
        };
        const win = self.vx.window();
        win.clear();
        const center = vaxis.widgets.alignment.center(win, 28, 4);
        _ = try center.printSegment(segment, .{ .wrap = .grapheme });
        switch (self.dir) {
            .up => {
                self.color_idx += 1;
                if (self.color_idx == 255) self.dir = .down;
            },
            .down => {
                self.color_idx -= 1;
                if (self.color_idx == lower_limit) self.dir = .up;
            },
        }
        try self.vx.render(self.buffered_writer.writer().any());
        try self.buffered_writer.flush();
    }
};

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
    defer tty.deinit();

    var vx = try vaxis.init(alloc, .{});
    defer vx.deinit(alloc, tty.anyWriter());

    var pool = xev.ThreadPool.init(.{});
    var loop = try xev.Loop.init(.{
        .thread_pool = &pool,
    });
    defer loop.deinit();

    var app: App = .{
        .allocator = alloc,
        .buffered_writer = tty.bufferedWriter(),
        .color_idx = App.lower_limit,
        .dir = .up,
        .vx = &vx,
    };

    var vx_loop: vaxis.xev.TtyWatcher(App) = undefined;
    try vx_loop.init(&tty, &vx, &loop, &app, eventCallback);

    try vx.enterAltScreen(tty.anyWriter());
    // send queries asynchronously
    try vx.queryTerminalSend(tty.anyWriter());

    const timer = try xev.Timer.init();
    var timer_cmp: xev.Completion = .{};
    timer.run(&loop, &timer_cmp, App.next_ms, App, &app, timerCallback);

    try loop.run(.until_done);
}

fn eventCallback(
    ud: ?*App,
    loop: *xev.Loop,
    watcher: *vaxis.xev.TtyWatcher(App),
    event: vaxis.xev.Event,
) xev.CallbackAction {
    const app = ud orelse unreachable;
    switch (event) {
        .key_press => |key| {
            if (key.matches('c', .{ .ctrl = true })) {
                loop.stop();
                return .disarm;
            }
        },
        .winsize => |ws| watcher.vx.resize(app.allocator, watcher.tty.anyWriter(), ws) catch @panic("TODO"),
        else => {},
    }
    return .rearm;
}

fn timerCallback(
    ud: ?*App,
    l: *xev.Loop,
    c: *xev.Completion,
    r: xev.Timer.RunError!void,
) xev.CallbackAction {
    _ = r catch @panic("timer error");

    var app = ud orelse return .disarm;
    app.draw() catch @panic("couldn't draw");

    const timer = try xev.Timer.init();
    timer.run(l, c, App.next_ms, App, ud, timerCallback);

    return .disarm;
}
