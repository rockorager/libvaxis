const std = @import("std");

const Queue = @import("queue.zig").Queue;
const Tty = @import("Tty.zig");
const Vaxis = @import("Vaxis.zig");

pub fn Loop(comptime T: type) type {
    return struct {
        const Self = @This();

        const log = std.log.scoped(.loop);

        queue: Queue(T, 512) = .{},

        thread: ?std.Thread = null,

        vaxis: *Vaxis,

        /// spawns the input thread to read input from the tty
        pub fn run(self: *Self) !void {
            if (self.thread) |_| return;
            if (self.vaxis.tty == null) self.vaxis.tty = try Tty.init();
            self.thread = try std.Thread.spawn(.{}, Tty.run, .{
                &self.vaxis.tty.?,
                T,
                self,
                &self.vaxis.unicode.grapheme_data,
                self.vaxis.opts.system_clipboard_allocator,
            });
        }

        /// stops reading from the tty and returns it to it's initial state
        pub fn stop(self: *Self) void {
            if (self.vaxis.tty) |*tty| {
                // stop the read loop, then join the thread
                tty.stop();
                if (self.thread) |thread| {
                    thread.join();
                    self.thread = null;
                }
                // once thread is closed we can deinit the tty
                tty.deinit();
                self.vaxis.tty = null;
            }
        }

        /// returns the next available event, blocking until one is available
        pub fn nextEvent(self: *Self) T {
            return self.queue.pop();
        }

        /// blocks until an event is available. Useful when your application is
        /// operating on a poll + drain architecture (see tryEvent)
        pub fn pollEvent(self: *Self) void {
            self.queue.poll();
        }

        /// returns an event if one is available, otherwise null. Non-blocking.
        pub fn tryEvent(self: *Self) ?T {
            return self.queue.tryPop();
        }

        /// posts an event into the event queue. Will block if there is not
        /// capacity for the event
        pub fn postEvent(self: *Self, event: T) void {
            self.queue.push(event);
        }

        pub fn tryPostEvent(self: *Self, event: T) bool {
            return self.queue.tryPush(event);
        }
    };
}
