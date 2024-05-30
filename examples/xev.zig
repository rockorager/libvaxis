const std = @import("std");
const vaxis = @import("vaxis");
const xev = @import("xev");
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
    var alloc = gpa.allocator();

    var tty = try vaxis.Tty.init();

    var vx = try vaxis.init(alloc, .{});
    defer vx.deinit(alloc, tty.anyWriter());

    var loop = try xev.Loop.init(.{});
    defer loop.deinit();

    var vx_loop: vaxis.xev.TtyWatcher(std.mem.Allocator) = undefined;
    try vx_loop.init(&tty, &vx, &loop, &alloc, callback);

    try vx.enterAltScreen(tty.anyWriter());
    // send queries asynchronously
    try vx.queryTerminalSend(tty.anyWriter());

    try loop.run(.until_done);
}

fn callback(
    ud: ?*std.mem.Allocator,
    loop: *xev.Loop,
    watcher: *vaxis.xev.TtyWatcher(std.mem.Allocator),
    event: vaxis.xev.Event,
) xev.CallbackAction {
    switch (event) {
        .key_press => |key| {
            if (key.matches('c', .{ .ctrl = true })) {
                loop.stop();
                return .disarm;
            }
        },
        .winsize => |ws| watcher.vx.resize(ud.?.*, watcher.tty.anyWriter(), ws) catch @panic("TODO"),
        else => {},
    }
    const win = watcher.vx.window();
    win.clear();
    watcher.vx.render(watcher.tty.anyWriter()) catch {
        std.log.err("couldn't render", .{});
        return .disarm;
    };
    return .rearm;
}
