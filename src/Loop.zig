const std = @import("std");
const builtin = @import("builtin");

const grapheme = @import("grapheme");

const GraphemeCache = @import("GraphemeCache.zig");
const Parser = @import("Parser.zig");
const Queue = @import("queue.zig").Queue;
const Tty = @import("main.zig").Tty;
const Vaxis = @import("Vaxis.zig");

pub fn Loop(comptime T: type) type {
    return struct {
        const Self = @This();

        const Event = T;

        const log = std.log.scoped(.loop);

        tty: *Tty,
        vaxis: *Vaxis,

        queue: Queue(T, 512) = .{},
        thread: ?std.Thread = null,
        should_quit: bool = false,

        /// Initialize the event loop. This is an intrusive init so that we have
        /// a stable pointer to register signal callbacks with posix TTYs
        pub fn init(self: *Self) !void {
            switch (builtin.os.tag) {
                .windows => {},
                else => {
                    const handler: Tty.SignalHandler = .{
                        .context = self,
                        .callback = Self.winsizeCallback,
                    };
                    try Tty.notifyWinsize(handler);
                },
            }
        }

        /// spawns the input thread to read input from the tty
        pub fn start(self: *Self) !void {
            if (self.thread) |_| return;
            self.thread = try std.Thread.spawn(.{}, Self.ttyRun, .{
                self,
                &self.vaxis.unicode.grapheme_data,
                self.vaxis.opts.system_clipboard_allocator,
            });
        }

        /// stops reading from the tty.
        pub fn stop(self: *Self) void {
            self.should_quit = true;
            // trigger a read
            self.vaxis.deviceStatusReport(self.tty.anyWriter()) catch {};

            if (self.thread) |thread| {
                thread.join();
                self.thread = null;
                self.should_quit = false;
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

        pub fn winsizeCallback(ptr: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ptr));

            const winsize = Tty.getWinsize(self.tty.fd) catch return;
            if (@hasField(Event, "winsize")) {
                self.postEvent(.{ .winsize = winsize });
            }
        }

        /// read input from the tty. This is run in a separate thread
        fn ttyRun(
            self: *Self,
            grapheme_data: *const grapheme.GraphemeData,
            paste_allocator: ?std.mem.Allocator,
        ) !void {
            // initialize a grapheme cache
            var cache: GraphemeCache = .{};

            switch (builtin.os.tag) {
                .windows => {
                    while (!self.should_quit) {
                        const event = try self.tty.nextEvent();
                        switch (event) {
                            .winsize => |ws| {
                                if (@hasField(Event, "winsize")) {
                                    self.postEvent(.{ .winsize = ws });
                                }
                            },
                            .key_press => |key| {
                                if (@hasField(Event, "key_press")) {
                                    // HACK: yuck. there has to be a better way
                                    var mut_key = key;
                                    if (key.text) |text| {
                                        mut_key.text = cache.put(text);
                                    }
                                    self.postEvent(.{ .key_press = mut_key });
                                }
                            },
                            .key_release => |*key| {
                                if (@hasField(Event, "key_release")) {
                                    // HACK: yuck. there has to be a better way
                                    var mut_key = key;
                                    if (key.text) |text| {
                                        mut_key.text = cache.put(text);
                                    }
                                    self.postEvent(.{ .key_release = mut_key });
                                }
                            },
                            .cap_da1 => {
                                std.Thread.Futex.wake(&self.vaxis.query_futex, 10);
                            },
                            .mouse => {}, // Unsupported currently
                            else => {},
                        }
                    }
                },
                else => {
                    // get our initial winsize
                    const winsize = try Tty.getWinsize(self.tty.fd);
                    if (@hasField(Event, "winsize")) {
                        self.postEvent(.{ .winsize = winsize });
                    }

                    var parser: Parser = .{
                        .grapheme_data = grapheme_data,
                    };

                    // initialize the read buffer
                    var buf: [1024]u8 = undefined;
                    var read_start: usize = 0;
                    // read loop
                    while (!self.should_quit) {
                        const n = try self.tty.read(buf[read_start..]);
                        var seq_start: usize = 0;
                        while (seq_start < n) {
                            const result = try parser.parse(buf[seq_start..n], paste_allocator);
                            if (result.n == 0) {
                                // copy the read to the beginning. We don't use memcpy because
                                // this could be overlapping, and it's also rare
                                const initial_start = seq_start;
                                while (seq_start < n) : (seq_start += 1) {
                                    buf[seq_start - initial_start] = buf[seq_start];
                                }
                                read_start = seq_start - initial_start + 1;
                                continue;
                            }
                            read_start = 0;
                            seq_start += result.n;

                            const event = result.event orelse continue;
                            switch (event) {
                                .key_press => |key| {
                                    if (@hasField(Event, "key_press")) {
                                        // HACK: yuck. there has to be a better way
                                        var mut_key = key;
                                        if (key.text) |text| {
                                            mut_key.text = cache.put(text);
                                        }
                                        self.postEvent(.{ .key_press = mut_key });
                                    }
                                },
                                .key_release => |*key| {
                                    if (@hasField(Event, "key_release")) {
                                        // HACK: yuck. there has to be a better way
                                        var mut_key = key;
                                        if (key.text) |text| {
                                            mut_key.text = cache.put(text);
                                        }
                                        self.postEvent(.{ .key_release = mut_key });
                                    }
                                },
                                .mouse => |mouse| {
                                    if (@hasField(Event, "mouse")) {
                                        self.postEvent(.{ .mouse = self.vaxis.translateMouse(mouse) });
                                    }
                                },
                                .focus_in => {
                                    if (@hasField(Event, "focus_in")) {
                                        self.postEvent(.focus_in);
                                    }
                                },
                                .focus_out => {
                                    if (@hasField(Event, "focus_out")) {
                                        self.postEvent(.focus_out);
                                    }
                                },
                                .paste_start => {
                                    if (@hasField(Event, "paste_start")) {
                                        self.postEvent(.paste_start);
                                    }
                                },
                                .paste_end => {
                                    if (@hasField(Event, "paste_end")) {
                                        self.postEvent(.paste_end);
                                    }
                                },
                                .paste => |text| {
                                    if (@hasField(Event, "paste")) {
                                        self.postEvent(.{ .paste = text });
                                    } else {
                                        if (paste_allocator) |_|
                                            paste_allocator.?.free(text);
                                    }
                                },
                                .color_report => |report| {
                                    if (@hasField(Event, "color_report")) {
                                        self.postEvent(.{ .color_report = report });
                                    }
                                },
                                .color_scheme => |scheme| {
                                    if (@hasField(Event, "color_scheme")) {
                                        self.postEvent(.{ .color_scheme = scheme });
                                    }
                                },
                                .cap_kitty_keyboard => {
                                    log.info("kitty keyboard capability detected", .{});
                                    self.vaxis.caps.kitty_keyboard = true;
                                },
                                .cap_kitty_graphics => {
                                    if (!self.vaxis.caps.kitty_graphics) {
                                        log.info("kitty graphics capability detected", .{});
                                        self.vaxis.caps.kitty_graphics = true;
                                    }
                                },
                                .cap_rgb => {
                                    log.info("rgb capability detected", .{});
                                    self.vaxis.caps.rgb = true;
                                },
                                .cap_unicode => {
                                    log.info("unicode capability detected", .{});
                                    self.vaxis.caps.unicode = .unicode;
                                    self.vaxis.screen.width_method = .unicode;
                                },
                                .cap_sgr_pixels => {
                                    log.info("pixel mouse capability detected", .{});
                                    self.vaxis.caps.sgr_pixels = true;
                                },
                                .cap_color_scheme_updates => {
                                    log.info("color_scheme_updates capability detected", .{});
                                    self.vaxis.caps.color_scheme_updates = true;
                                },
                                .cap_da1 => {
                                    std.Thread.Futex.wake(&self.vaxis.query_futex, 10);
                                },
                                .winsize => unreachable, // handled elsewhere for posix
                            }
                        }
                    }
                },
            }
        }
    };
}
