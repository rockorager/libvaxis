const std = @import("std");
const vaxis = @import("../main.zig");

const vxfw = @import("vxfw.zig");

const Allocator = std.mem.Allocator;

const Spinner = @This();

const frames: []const []const u8 = &.{ "⣶", "⣧", "⣏", "⡟", "⠿", "⢻", "⣹", "⣼" };
const time_lapse: u32 = std.time.ms_per_s / 12; // 12 fps

count: std.atomic.Value(u16) = .{ .raw = 0 },
style: vaxis.Style = .{},
/// The frame index
frame: u4 = 0,

/// Turns true when we start the spinner. Only turns false during a draw if the count == 0. This
/// ensures we draw one more time past the spinner stopping to clear the state
was_spinning: std.atomic.Value(bool) = .{ .raw = false },

/// Start, or add one, to the spinner counter. Thread safe.
pub fn start(self: *Spinner) ?vxfw.Command {
    self.was_spinning.store(true, .unordered);
    const count = self.count.fetchAdd(1, .monotonic);
    if (count == 0) {
        return vxfw.Tick.in(time_lapse, self.widget());
    }
    return null;
}

/// Reduce one from the spinner counter. The spinner will stop when it reaches 0. Thread safe
pub fn stop(self: *Spinner) void {
    self.count.store(self.count.load(.unordered) -| 1, .unordered);
}

pub fn wasSpinning(self: *Spinner) bool {
    return self.was_spinning.load(.unordered);
}

pub fn widget(self: *Spinner) vxfw.Widget {
    return .{
        .userdata = self,
        .eventHandler = typeErasedEventHandler,
        .drawFn = typeErasedDrawFn,
    };
}

fn typeErasedEventHandler(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
    const self: *Spinner = @ptrCast(@alignCast(ptr));
    return self.handleEvent(ctx, event);
}

pub fn handleEvent(self: *Spinner, ctx: *vxfw.EventContext, event: vxfw.Event) Allocator.Error!void {
    switch (event) {
        .tick => {
            const count = self.count.load(.unordered);

            if (count == 0) {
                if (self.wasSpinning()) {
                    ctx.redraw = true;
                    self.was_spinning.store(false, .unordered);
                }
                return;
            }
            // Update frame
            self.frame += 1;
            if (self.frame >= frames.len) self.frame = 0;

            // Update rearm
            try ctx.tick(time_lapse, self.widget());
        },
        else => {},
    }
}

fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
    const self: *Spinner = @ptrCast(@alignCast(ptr));
    return self.draw(ctx);
}

pub fn draw(self: *Spinner, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
    const size: vxfw.Size = .{
        .width = @max(1, ctx.min.width),
        .height = @max(1, ctx.min.height),
    };

    const surface = try vxfw.Surface.init(ctx.arena, self.widget(), size);
    @memset(surface.buffer, .{ .style = self.style });

    if (self.count.load(.unordered) == 0) return surface;

    surface.writeCell(0, 0, .{
        .char = .{
            .grapheme = frames[self.frame],
            .width = 1,
        },
        .style = self.style,
    });
    return surface;
}

test Spinner {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // Create a spinner
    var spinner: Spinner = .{};
    // Get our widget interface
    const spinner_widget = spinner.widget();

    // Start the spinner. This (maybe) returns a Tick command to schedule the next frame. If the
    // spinner is already running, no command is returned. Calling start is thread safe. The
    // returned command can be added to an EventContext to schedule the frame
    const maybe_cmd = spinner.start();
    try std.testing.expect(maybe_cmd != null);
    try std.testing.expect(maybe_cmd.? == .tick);
    try std.testing.expectEqual(1, spinner.count.load(.unordered));

    // If we call start again, we won't get another command but our counter will go up
    const maybe_cmd2 = spinner.start();
    try std.testing.expect(maybe_cmd2 == null);
    try std.testing.expectEqual(2, spinner.count.load(.unordered));

    // We are about to deliver the tick to the widget. We need an EventContext (the engine will
    // provide this)
    var ctx: vxfw.EventContext = .{ .cmds = vxfw.CommandList.init(arena.allocator()) };

    // The event loop handles the tick event and calls us back with a .tick event. If we should keep
    // running, we will add a new tick event
    try spinner_widget.handleEvent(&ctx, .tick);

    // Receiving a .tick advances the frame
    try std.testing.expectEqual(1, spinner.frame);

    // Simulate a draw
    const surface = try spinner_widget.draw(.{
        .arena = arena.allocator(),
        .min = .{},
        .max = .{},
        .cell_size = .{ .width = 10, .height = 20 },
    });

    // Spinner will try to be 1x1
    try std.testing.expectEqual(1, surface.size.width);
    try std.testing.expectEqual(1, surface.size.height);

    // Stopping the spinner decrements our counter
    spinner.stop();
    try std.testing.expectEqual(1, spinner.count.load(.unordered));
    spinner.stop();
    try std.testing.expectEqual(0, spinner.count.load(.unordered));
}

test "refAllDecls" {
    std.testing.refAllDecls(@This());
}
