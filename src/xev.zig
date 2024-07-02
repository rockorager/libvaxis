const std = @import("std");
const xev = @import("xev");

const Tty = @import("main.zig").Tty;
const Winsize = @import("main.zig").Winsize;
const Vaxis = @import("Vaxis.zig");
const Parser = @import("Parser.zig");
const Key = @import("Key.zig");
const Mouse = @import("Mouse.zig");
const Color = @import("Cell.zig").Color;

const log = std.log.scoped(.vaxis_xev);

pub const Event = union(enum) {
    key_press: Key,
    key_release: Key,
    mouse: Mouse,
    focus_in,
    focus_out,
    paste_start, // bracketed paste start
    paste_end, // bracketed paste end
    paste: []const u8, // osc 52 paste, caller must free
    color_report: Color.Report, // osc 4, 10, 11, 12 response
    color_scheme: Color.Scheme,
    winsize: Winsize,
};

pub fn TtyWatcher(comptime Userdata: type) type {
    return struct {
        const Self = @This();

        file: xev.File,
        tty: *Tty,

        read_buf: [4096]u8,
        read_buf_start: usize,
        read_cmp: xev.Completion,

        winsize_wakeup: xev.Async,
        winsize_cmp: xev.Completion,

        callback: *const fn (
            ud: ?*Userdata,
            loop: *xev.Loop,
            watcher: *Self,
            event: Event,
        ) xev.CallbackAction,

        ud: ?*Userdata,
        vx: *Vaxis,
        parser: Parser,

        pub fn init(
            self: *Self,
            tty: *Tty,
            vaxis: *Vaxis,
            loop: *xev.Loop,
            userdata: ?*Userdata,
            callback: *const fn (
                ud: ?*Userdata,
                loop: *xev.Loop,
                watcher: *Self,
                event: Event,
            ) xev.CallbackAction,
        ) !void {
            self.* = .{
                .tty = tty,
                .file = xev.File.initFd(tty.fd),
                .read_buf = undefined,
                .read_buf_start = 0,
                .read_cmp = .{},

                .winsize_wakeup = try xev.Async.init(),
                .winsize_cmp = .{},

                .callback = callback,
                .ud = userdata,
                .vx = vaxis,
                .parser = .{ .grapheme_data = &vaxis.unicode.grapheme_data },
            };

            self.file.read(
                loop,
                &self.read_cmp,
                .{ .slice = &self.read_buf },
                Self,
                self,
                Self.ttyReadCallback,
            );
            self.winsize_wakeup.wait(
                loop,
                &self.winsize_cmp,
                Self,
                self,
                winsizeCallback,
            );
            const handler: Tty.SignalHandler = .{
                .context = self,
                .callback = Self.signalCallback,
            };
            try Tty.notifyWinsize(handler);
        }

        fn signalCallback(ptr: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            self.winsize_wakeup.notify() catch |err| {
                log.warn("couldn't wake up winsize callback: {}", .{err});
            };
        }

        fn ttyReadCallback(
            ud: ?*Self,
            loop: *xev.Loop,
            c: *xev.Completion,
            _: xev.File,
            buf: xev.ReadBuffer,
            r: xev.ReadError!usize,
        ) xev.CallbackAction {
            const n = r catch |err| {
                log.err("read error: {}", .{err});
                return .disarm;
            };
            const self = ud orelse unreachable;

            // reset read start state
            self.read_buf_start = 0;

            var seq_start: usize = 0;
            parse_loop: while (seq_start < n) {
                const result = self.parser.parse(buf.slice[seq_start..n], null) catch |err| {
                    log.err("couldn't parse input: {}", .{err});
                    return .disarm;
                };
                if (result.n == 0) {
                    // copy the read to the beginning. We don't use memcpy because
                    // this could be overlapping, and it's also rare
                    const initial_start = seq_start;
                    while (seq_start < n) : (seq_start += 1) {
                        self.read_buf[seq_start - initial_start] = self.read_buf[seq_start];
                    }
                    self.read_buf_start = seq_start - initial_start + 1;
                    return .rearm;
                }
                seq_start += n;
                const event_inner = result.event orelse {
                    log.debug("unknown event: {s}", .{self.read_buf[seq_start - n + 1 .. seq_start]});
                    continue :parse_loop;
                };

                // Capture events we want to bubble up
                const event: ?Event = switch (event_inner) {
                    .key_press => |key| .{ .key_press = key },
                    .key_release => |key| .{ .key_release = key },
                    .mouse => |mouse| .{ .mouse = mouse },
                    .focus_in => .focus_in,
                    .focus_out => .focus_out,
                    .paste_start => .paste_start,
                    .paste_end => .paste_end,
                    .paste => |paste| .{ .paste = paste },
                    .color_report => |report| .{ .color_report = report },
                    .color_scheme => |scheme| .{ .color_scheme = scheme },
                    .winsize => |ws| .{ .winsize = ws },

                    // capability events which we handle below
                    .cap_kitty_keyboard,
                    .cap_kitty_graphics,
                    .cap_rgb,
                    .cap_unicode,
                    .cap_sgr_pixels,
                    .cap_color_scheme_updates,
                    .cap_da1,
                    => null, // handled below
                };

                if (event) |ev| {
                    const action = self.callback(self.ud, loop, self, ev);
                    switch (action) {
                        .disarm => return .disarm,
                        else => continue :parse_loop,
                    }
                }

                switch (event_inner) {
                    .key_press,
                    .key_release,
                    .mouse,
                    .focus_in,
                    .focus_out,
                    .paste_start,
                    .paste_end,
                    .paste,
                    .color_report,
                    .color_scheme,
                    .winsize,
                    => unreachable, // handled above

                    .cap_kitty_keyboard => {
                        log.info("kitty keyboard capability detected", .{});
                        self.vx.caps.kitty_keyboard = true;
                    },
                    .cap_kitty_graphics => {
                        if (!self.vx.caps.kitty_graphics) {
                            log.info("kitty graphics capability detected", .{});
                            self.vx.caps.kitty_graphics = true;
                        }
                    },
                    .cap_rgb => {
                        log.info("rgb capability detected", .{});
                        self.vx.caps.rgb = true;
                    },
                    .cap_unicode => {
                        log.info("unicode capability detected", .{});
                        self.vx.caps.unicode = .unicode;
                        self.vx.screen.width_method = .unicode;
                    },
                    .cap_sgr_pixels => {
                        log.info("pixel mouse capability detected", .{});
                        self.vx.caps.sgr_pixels = true;
                    },
                    .cap_color_scheme_updates => {
                        log.info("color_scheme_updates capability detected", .{});
                        self.vx.caps.color_scheme_updates = true;
                    },
                    .cap_da1 => {
                        self.vx.enableDetectedFeatures(self.tty.anyWriter()) catch |err| {
                            log.err("couldn't enable features: {}", .{err});
                        };
                    },
                }
            }

            self.file.read(
                loop,
                c,
                .{ .slice = &self.read_buf },
                Self,
                self,
                Self.ttyReadCallback,
            );
            return .disarm;
        }

        fn winsizeCallback(
            ud: ?*Self,
            l: *xev.Loop,
            c: *xev.Completion,
            r: xev.Async.WaitError!void,
        ) xev.CallbackAction {
            _ = r catch |err| {
                log.err("async error: {}", .{err});
                return .disarm;
            };
            const self = ud orelse unreachable; // no userdata
            const winsize = Tty.getWinsize(self.tty.fd) catch |err| {
                log.err("couldn't get winsize: {}", .{err});
                return .disarm;
            };
            const ret = self.callback(self.ud, l, self, .{ .winsize = winsize });
            if (ret == .disarm) return .disarm;

            self.winsize_wakeup.wait(
                l,
                c,
                Self,
                self,
                winsizeCallback,
            );
            return .disarm;
        }
    };
}
