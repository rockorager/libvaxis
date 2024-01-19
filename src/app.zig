const std = @import("std");

const queue = @import("queue.zig");
const Tty = @import("Tty.zig");
const Key = @import("Key.zig");
const Screen = @import("Screen.zig");
const Window = @import("Window.zig");

/// App is the entrypoint for an odditui application. The provided type T should
/// be a tagged union which contains all of the events the application will
/// handle. Odditui will look for the following fields on the union and, if
/// found, emit them via the "nextEvent" method
///
/// The following events *must* be in your enum
/// - `key_press: Key`, for key press events
/// - `winsize: std.os.system.winsize`, for resize events. Must call app.resize
///   when receiving this event
pub fn App(comptime T: type) type {
    return struct {
        const Self = @This();

        const log = std.log.scoped(.app);

        pub const EventType = T;

        /// the event queue for this App
        //
        // TODO: is 512 ok?
        queue: queue.Queue(T, 512),

        tty: ?Tty,

        screen: Screen,

        /// Runtime options
        const Options = struct {};

        /// Initialize an App with runtime options
        pub fn init(_: Options) !Self {
            return Self{
                .queue = .{},
                .tty = null,
                .screen = Screen.init(),
            };
        }

        pub fn deinit(self: *Self, alloc: std.mem.Allocator) void {
            if (self.tty) |_| {
                var tty = &self.tty.?;
                tty.deinit();
            }
            self.screen.deinit(alloc);
        }

        /// spawns the input thread to start listening to the tty for input
        pub fn start(self: *Self) !void {
            self.tty = try Tty.init();
            // run our tty read loop in it's own thread
            const read_thread = try std.Thread.spawn(.{}, Tty.run, .{ &self.tty.?, T, self });
            try read_thread.setName("tty");
        }

        pub fn stop(self: *Self) void {
            if (self.tty) |_| {
                var tty = &self.tty.?;
                tty.stop();
            }
        }

        /// returns the next available event, blocking until one is available
        pub fn nextEvent(self: *Self) T {
            return self.queue.pop();
        }

        /// posts an event into the event queue. Will block if there is not
        /// capacity for the event
        pub fn postEvent(self: *Self, event: T) void {
            self.queue.push(event);
        }

        /// resize allocates a slice of cellsequal to the number of cells
        /// required to display the screen (ie width x height). Any previous screen is
        /// freed when resizing
        pub fn resize(self: *Self, alloc: std.mem.Allocator, w: usize, h: usize) !void {
            try self.screen.resize(alloc, w, h);
        }

        pub fn window(self: *Self) Window {
            return Window{
                .x_off = 0,
                .y_off = 0,
                .w = .{.expand},
                .h = .{.expand},
                .parent = null,
                .screen = &self.screen,
            };
        }
    };
}

test "App: event queueing" {
    const Event = union(enum) {
        key,
    };
    const alloc = std.testing.allocator;
    var app: App(Event) = try App(Event).init(.{});
    defer app.deinit(alloc);
    app.postEvent(.key);
    const event = app.nextEvent();
    try std.testing.expect(event == .key);
}
