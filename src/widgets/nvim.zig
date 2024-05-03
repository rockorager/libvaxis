const std = @import("std");
const assert = std.debug.assert;
const vaxis = @import("../main.zig");
const znvim = @import("znvim");

pub const Event = union(enum) {
    redraw: *anyopaque,
    quit: *anyopaque,
};

pub fn Nvim(comptime T: type) type {
    if (!@hasField(T, "nvim")) {
        @compileError("Nvim widget requires an Event to have an 'nvim' event of type Nvim.Event");
    }
    return struct {
        const Self = @This();
        const Client = znvim.DefaultClient(.file);
        const EventType = T;

        const log = std.log.scoped(.nvim);

        /// vaxis events handled by Nvim
        pub const VaxisEvent = union(enum) {
            key_press: vaxis.Key,
        };

        alloc: std.mem.Allocator,

        /// true when we have spawned
        spawned: bool = false,
        /// true when we have ui attached
        attached: bool = false,

        client: ?Client = null,

        /// draw mutex. We lock access to the internal model while drawing
        mutex: std.Thread.Mutex = .{},

        /// the child process
        process: std.ChildProcess,

        thread: ?std.Thread = null,

        screen: vaxis.AllocatingScreen = undefined,
        visible_screen: vaxis.AllocatingScreen = undefined,

        hl_map: HighlightMap,

        loop: *vaxis.Loop(T),
        dirty: bool = false,
        mode_set: std.ArrayList(Mode),

        /// initialize nvim. Starts the nvim process. UI is not attached until the first
        /// call to draw
        pub fn init(alloc: std.mem.Allocator, loop: *vaxis.Loop(T)) !Self {
            const args = [_][]const u8{ "nvim", "--embed" };
            var nvim = std.ChildProcess.init(&args, alloc);

            // set to use pipe
            nvim.stdin_behavior = .Pipe;
            // set to use pipe
            nvim.stdout_behavior = .Pipe;
            // set ignore
            nvim.stderr_behavior = .Ignore;

            // try spwan
            try nvim.spawn();
            return .{
                .alloc = alloc,
                .process = nvim,
                .hl_map = HighlightMap.init(alloc),
                .loop = loop,
                .mode_set = std.ArrayList(Mode).init(alloc),
            };
        }

        /// spawns the client thread and registers callbacks
        pub fn spawn(self: *Self) !void {
            if (self.spawned) return;
            defer self.spawned = true;

            // get stdin and stdout pipe
            assert(self.process.stdin != null);
            assert(self.process.stdout != null);
            const nvim_stdin = self.process.stdin.?;
            const nvim_stdout = self.process.stdout.?;

            self.client = try Client.init(
                nvim_stdin,
                nvim_stdout,
                self.alloc,
            );

            self.thread = try std.Thread.spawn(.{}, Self.nvimLoop, .{self});
        }

        pub fn deinit(self: *Self) void {
            if (self.client) |*client| {
                client.deinit();
            }
            _ = self.process.kill() catch |err|
                log.err("couldn't kill nvim process: {}", .{err});
            if (self.thread) |thread| {
                thread.join();
            }
            self.screen.deinit(self.alloc);
            self.visible_screen.deinit(self.alloc);
            self.hl_map.map.deinit();
            self.mode_set.deinit();
        }

        pub fn draw(self: *Self, win: vaxis.Window) !void {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.dirty = false;
            win.setCursorShape(self.visible_screen.cursor_shape);
            if (!self.attached) try self.attach(win.width, win.height);
            if (win.width != self.screen.width or
                win.height != self.screen.height) try self.resize(win.width, win.height);
            var row: usize = 0;
            while (row < self.visible_screen.height) : (row += 1) {
                var col: usize = 0;
                while (col < self.visible_screen.width) : (col += 1) {
                    win.writeCell(col, row, self.visible_screen.readCell(col, row).?);
                }
            }
            if (self.visible_screen.cursor_vis)
                win.showCursor(self.visible_screen.cursor_col, self.visible_screen.cursor_row);
        }

        pub fn update(self: *Self, event: VaxisEvent) !void {
            var client = self.client orelse return;
            switch (event) {
                .key_press => |key| {
                    const key_str = if (key.text) |text|
                        text
                    else blk: {
                        var buf: [64]u8 = undefined;
                        var alloc = std.heap.FixedBufferAllocator.init(&buf);
                        var w = std.ArrayList(u8).init(alloc.allocator());
                        try w.append('<');
                        if (key.mods.shift)
                            try w.appendSlice("S-");
                        if (key.mods.ctrl)
                            try w.appendSlice("C-");
                        if (key.mods.alt)
                            try w.appendSlice("M-");
                        if (key.mods.super)
                            try w.appendSlice("D-");

                        const key_str = switch (key.codepoint) {
                            '<' => "lt",
                            '\\' => "Bslash",
                            '|' => "Bar",
                            vaxis.Key.enter => "CR",
                            vaxis.Key.backspace => "BS",
                            vaxis.Key.tab => "Tab",
                            vaxis.Key.escape => "ESC",
                            vaxis.Key.space => "Space",
                            vaxis.Key.delete => "Del",
                            vaxis.Key.up => "Up",
                            vaxis.Key.down => "Down",
                            vaxis.Key.left => "Left",
                            vaxis.Key.right => "Right",

                            else => utf8: {
                                var utf8Buf: [4]u8 = undefined;
                                const n = try std.unicode.utf8Encode(key.codepoint, &utf8Buf);
                                break :utf8 utf8Buf[0..n];
                            },
                        };

                        try w.appendSlice(key_str);
                        try w.append('>');

                        break :blk w.items;
                    };
                    var payload = try Client.createParams(1, self.alloc);
                    defer Client.freeParams(payload, self.alloc);
                    payload.arr[0] = try znvim.Payload.strToPayload(key_str, self.alloc);
                    try client.notify("nvim_input", payload);
                },
            }
        }

        fn attach(self: *Self, width: usize, height: usize) !void {
            self.attached = true;
            try self.client.?.registerNotifyMethod(
                "redraw",
                .{
                    .userdata = self,
                    .func = &redrawCallback,
                },
            );
            self.screen = try vaxis.AllocatingScreen.init(self.alloc, width, height);
            self.visible_screen = try vaxis.AllocatingScreen.init(self.alloc, width, height);
            const params = try Client.createParams(3, self.alloc);
            defer Client.freeParams(params, self.alloc);

            var opts = znvim.Payload.mapPayload(self.alloc);
            try opts.mapPut("ext_linegrid", znvim.Payload.boolToPayload(true));

            params.arr[0] = znvim.Payload.uintToPayload(self.screen.width);
            params.arr[1] = znvim.Payload.uintToPayload(self.screen.height);
            params.arr[2] = opts;

            const result = try self.client.?.call("nvim_ui_attach", params);
            switch (result) {
                .err => |err| Client.freeParams(err, self.alloc),
                .result => |r| Client.freeParams(r, self.alloc),
            }
        }

        fn resize(self: *Self, width: usize, height: usize) !void {
            self.screen.deinit(self.alloc);
            self.visible_screen.deinit(self.alloc);
            self.screen = try vaxis.AllocatingScreen.init(self.alloc, width, height);
            self.visible_screen = try vaxis.AllocatingScreen.init(self.alloc, width, height);
            const params = try Client.createParams(2, self.alloc);
            defer Client.freeParams(params, self.alloc);

            params.arr[0] = znvim.Payload.uintToPayload(self.screen.width);
            params.arr[1] = znvim.Payload.uintToPayload(self.screen.height);

            try self.client.?.notify("nvim_ui_try_resize", params);
        }

        fn redrawCallback(
            params: znvim.Payload,
            alloc: std.mem.Allocator,
            userdata: ?*anyopaque,
        ) void {
            _ = alloc; // autofix
            assert(userdata != null);
            var self: *Self = @ptrCast(@alignCast(userdata.?));
            for (params.arr) |event| {
                assert(event == znvim.Payload.arr);
                const event_name = event.arr[0].str.value();
                log.debug("redraw callback event {s}", .{event_name});
                const event_enum = std.meta.stringToEnum(NvimEvent, event_name) orelse {
                    log.err("unhandled nvim event: {s}", .{event_name});
                    continue;
                };
                assert(event.arr[1] == znvim.Payload.arr);
                self.handleEvent(event_enum, event.arr[1..]);
            }
        }

        fn nvimLoop(self: *Self) void {
            if (self.client) |*client| {
                while (true) {
                    client.loop() catch |err| {
                        log.err("rpc loop error: {}", .{err});
                        self.loop.postEvent(.{ .nvim = .{ .quit = self } });
                        return;
                    };
                }
            }
        }

        const NvimEvent = enum {
            chdir,
            default_colors_set,
            flush,
            grid_clear,
            grid_cursor_goto,
            grid_line,
            grid_resize,
            grid_scroll,
            hl_attr_define,
            hl_group_set,
            mode_change,
            mode_info_set,
            option_set,
            set_icon,
            set_title,
        };

        const OptionSet = enum {
            ambiwidth,
            arabicshape,
            emoji,
            guifont,
            guifontwide,
            linespace,
            mousefocus,
            mousehide,
            mousemoveevent,
            pumblend,
            showtabline,
            termguicolors,
            termsync,
            ttimeout,
            ttimeoutlen,
            verbose,

            ext_cmdline,
            ext_hlstate,
            ext_linegrid,
            ext_messages,
            ext_multigrid,
            ext_popupmenu,
            ext_tabline,
            ext_termcolors,
            ext_wildmenu,
        };

        const Mode = struct {
            cursor_style_enabled: bool = false,
            cursor_shape: vaxis.Cell.CursorShape = .default,
            attr_id: usize = 0,
            mouse_shape: vaxis.Mouse.Shape = .default,
            short_name: []const u8 = "",
            name: []const u8 = "",

            fn deinit(self: Mode, alloc: std.mem.Allocator) void {
                alloc.free(self.short_name);
                alloc.free(self.name);
            }

            const Keys = enum {
                cursor_shape,
                blinkon,
                blinkoff,
                attr_id,
                short_name,
                name,
                mouse_shape,
            };
        };

        const HighlightMap = struct {
            /// the keys used in rgb_dict field in the nvim rpc event
            const Keys = enum {
                foreground,
                background,
                special,
                italic,
                bold,
                strikethrough,
                reverse,
                underline,
                undercurl,
                underdouble,
                underdotted,

                // not used:
                altfont,
                blend,
                url, // TODO: handle urls

            };

            const Highlight = struct {
                id: u64,
                attrs: struct {
                    fg: ?vaxis.Color = null,
                    bg: ?vaxis.Color = null,
                    special: ?vaxis.Color = null,
                    italic: ?bool = null,
                    bold: ?bool = null,
                    strikethrough: ?bool = null,
                    underline: ?bool = null,
                    undercurl: ?bool = null,
                    underdouble: ?bool = null,
                    underdotted: ?bool = null,
                    reverse: ?bool = null,
                    // TODO: urls
                    // url: ?[]const u8 = null,
                } = .{},
            };

            alloc: std.mem.Allocator,
            default: vaxis.Style,
            map: std.ArrayList(Highlight),

            pub fn init(alloc: std.mem.Allocator) HighlightMap {
                return .{
                    .alloc = alloc,
                    .default = .{},
                    .map = std.ArrayList(Highlight).init(alloc),
                };
            }

            /// returns the requested id, or default if not found
            pub fn get(self: *HighlightMap, id: u64) vaxis.Style {
                for (self.map.items) |h| {
                    if (h.id == id) return self.merge(h);
                } else return self.default;
            }

            pub fn put(self: *HighlightMap, hl: Highlight) !void {
                for (self.map.items, 0..) |h, i| {
                    if (h.id == hl.id) {
                        self.map.items[i] = hl;
                        return;
                    }
                } else try self.map.append(hl);
            }

            /// merges a Highlight with the default to create a vaxis.Style
            fn merge(self: HighlightMap, hl: Highlight) vaxis.Style {
                var result = self.default;
                const attrs = hl.attrs;
                if (attrs.fg) |val| result.fg = val;
                if (attrs.bg) |val| result.bg = val;
                if (attrs.special) |val| result.ul = val;
                if (attrs.italic) |val| result.italic = val;
                if (attrs.bold) |val| result.bold = val;
                if (attrs.strikethrough) |val| result.strikethrough = val;
                if (attrs.underline) |val| result.ul_style = if (val) .single else .off;
                if (attrs.undercurl) |val| result.ul_style = if (val) .single else .off;
                if (attrs.underdotted) |val| result.ul_style = if (val) .dotted else .off;
                if (attrs.reverse) |val| result.reverse = val;
                // TODO: hyperlinks
                return result;
            }
        };

        /// handles an nvim event. params will always be a .arr payload type. Each event
        /// is of the form: [ "event_name", [ param_tuple ], [param_tuple], ... ]. Each
        /// event can come with multiple params (IE multiple instances of the same event)
        fn handleEvent(self: *Self, event: NvimEvent, params: []znvim.Payload) void {
            switch (event) {
                .chdir => {
                    // param_tuple: [path]
                    for (params) |param| {
                        assert(param == znvim.Payload.arr);
                        assert(param.arr.len == 1);
                        assert(param.arr[0] == znvim.Payload.str);
                    }
                },
                .default_colors_set => {
                    // param_tuple: [rgb_fg, rgb_bg, rgb_sp, cterm_fg, cterm_bg]
                    for (params) |param| {
                        assert(param == znvim.Payload.arr);
                        assert(param.arr.len == 5);
                        self.hl_map.default.fg = vaxis.Color.rgbFromUint(@truncate(param.arr[0].uint));
                        self.hl_map.default.bg = vaxis.Color.rgbFromUint(@truncate(param.arr[1].uint));
                        self.hl_map.default.ul = vaxis.Color.rgbFromUint(@truncate(param.arr[2].uint));
                    }
                },
                .flush => {
                    self.mutex.lock();
                    defer self.mutex.unlock();
                    var row: usize = 0;
                    while (row < self.visible_screen.height) : (row += 1) {
                        var col: usize = 0;
                        while (col < self.visible_screen.width) : (col += 1) {
                            self.visible_screen.writeCell(col, row, self.screen.readCell(col, row).?);
                        }
                    }
                    self.visible_screen.cursor_row = self.screen.cursor_row;
                    self.visible_screen.cursor_col = self.screen.cursor_col;
                    self.visible_screen.cursor_vis = self.screen.cursor_vis;
                    self.visible_screen.cursor_shape = self.screen.cursor_shape;
                    if (!self.dirty) {
                        self.dirty = true;
                        self.loop.postEvent(.{ .nvim = .{ .redraw = self } });
                    }
                },
                .grid_clear => {
                    var row: usize = 0;
                    var col: usize = 0;
                    while (row < self.screen.height) : (row += 1) {
                        while (col < self.screen.width) : (col += 1) {
                            self.screen.writeCell(col, row, .{ .style = self.hl_map.default });
                        }
                    }
                },
                .grid_cursor_goto => {
                    // param_tuple: [grid, row, col]
                    for (params) |param| {
                        assert(param == znvim.Payload.arr);
                        assert(param.arr.len == 3);
                        self.screen.cursor_row = @truncate(param.arr[1].uint);
                        self.screen.cursor_col = @truncate(param.arr[2].uint);
                        self.screen.cursor_vis = true;
                    }
                },
                .grid_line => {
                    // param_tuple: [grid, row, col_start, cells, wrap]
                    var style: vaxis.Style = self.hl_map.default;
                    for (params) |param| {
                        assert(param == znvim.Payload.arr);
                        assert(param.arr.len == 5);
                        assert(param.arr[1] == znvim.Payload.uint);
                        assert(param.arr[2] == znvim.Payload.uint);
                        assert(param.arr[3] == znvim.Payload.arr);
                        const row: usize = param.arr[1].uint;
                        var col: usize = param.arr[2].uint;
                        const cells = param.arr[3].arr;
                        for (cells) |cell| {
                            assert(cell == znvim.Payload.arr);
                            switch (cell.arr.len) {
                                1 => {
                                    assert(cell.arr[0] == znvim.Payload.str);
                                    self.screen.writeCell(col, row, .{
                                        .char = .{
                                            .grapheme = cell.arr[0].str.value(),
                                        },
                                        .style = style,
                                    });
                                    col += 1;
                                },
                                2 => {
                                    assert(cell.arr[0] == znvim.Payload.str);
                                    assert(cell.arr[1] == znvim.Payload.uint);
                                    style = self.hl_map.get(cell.arr[1].uint);
                                    self.screen.writeCell(col, row, .{
                                        .char = .{
                                            .grapheme = cell.arr[0].str.value(),
                                        },
                                        .style = style,
                                    });
                                    col += 1;
                                },
                                3 => {
                                    assert(cell.arr[0] == znvim.Payload.str);
                                    assert(cell.arr[1] == znvim.Payload.uint);
                                    assert(cell.arr[2] == znvim.Payload.uint);
                                    style = self.hl_map.get(cell.arr[1].uint);
                                    var i: usize = 0;
                                    while (i < cell.arr[2].uint) : (i += 1) {
                                        self.screen.writeCell(col, row, .{
                                            .char = .{
                                                .grapheme = cell.arr[0].str.value(),
                                            },
                                            .style = style,
                                        });
                                        col += 1;
                                    }
                                },
                                else => unreachable,
                            }
                        }
                    }
                },
                .grid_resize => {
                    // param_tuple: [grid, width, height]
                    // We don't need to handle this since we aren't activating
                    // ui_multigrid. Grid ID 1 will always be our main grid
                },
                .grid_scroll => {
                    // param_tuple: [grid, top, bot, left, right, rows, cols]
                    for (params) |param| {
                        assert(param == znvim.Payload.arr);
                        assert(param.arr.len == 7);
                        // we don't care about grid
                        // assert(param.arr[0] == znvim.Payload.uint);
                        assert(param.arr[1] == znvim.Payload.uint);
                        assert(param.arr[2] == znvim.Payload.uint);
                        assert(param.arr[3] == znvim.Payload.uint);
                        assert(param.arr[4] == znvim.Payload.uint);
                        assert(param.arr[5] == znvim.Payload.uint or
                            param.arr[5] == znvim.Payload.int);
                        // we don't care about cols. This is always zero
                        // currently
                        // assert(param.arr[6] == znvim.Payload.uint);
                        const top: usize = @truncate(param.arr[1].uint);
                        const bot: usize = @truncate(param.arr[2].uint);
                        const left: usize = @truncate(param.arr[3].uint);
                        const right: usize = @truncate(param.arr[4].uint);
                        if (param.arr[5] == znvim.Payload.uint) {
                            const rows: usize = @truncate(param.arr[5].uint);
                            var row: usize = top;
                            while (row < bot) : (row += 1) {
                                if (row + rows > bot) break;
                                var col: usize = left;
                                while (col < right) : (col += 1) {
                                    if (row + rows < self.screen.height) return;
                                    const cell = self.screen.readCell(col, row + rows) orelse unreachable;
                                    self.screen.writeCell(col, row, cell);
                                }
                            }
                        } else {
                            const rows: usize = @intCast(-param.arr[5].int);
                            var row: usize = bot -| 1;
                            while (row >= top) : (row -|= 1) {
                                if (row + 1 -| rows <= top) break;
                                var col: usize = left;
                                while (col < right) : (col += 1) {
                                    const cell = self.screen.readCell(col, row -| rows) orelse unreachable;
                                    self.screen.writeCell(col, row, cell);
                                }
                            }
                        }
                    }
                },
                .hl_attr_define => {
                    // param_tuple: [id, rgb_attr, cterm_attr, info]
                    for (params) |param| {
                        assert(param == znvim.Payload.arr);
                        assert(param.arr.len == 4);
                        assert(param.arr[0] == znvim.Payload.uint);
                        assert(param.arr[1] == znvim.Payload.map);
                        // we don't care about cterm_attr
                        // assert(param.arr[2] == znvim.Payload.map);
                        assert(param.arr[3] == znvim.Payload.arr);
                        const rgb_dict = param.arr[1].map;

                        var hl: HighlightMap.Highlight = .{
                            .id = param.arr[0].uint,
                        };
                        var rgb_iter = rgb_dict.iterator();
                        while (rgb_iter.next()) |kv| {
                            const key = std.meta.stringToEnum(HighlightMap.Keys, kv.key_ptr.*) orelse {
                                log.warn("unhandled highlight key: {s}", .{kv.key_ptr.*});
                                continue;
                            };
                            switch (key) {
                                .foreground => {
                                    hl.attrs.fg = vaxis.Color.rgbFromUint(@truncate(kv.value_ptr.*.uint));
                                },
                                .background => {
                                    hl.attrs.bg = vaxis.Color.rgbFromUint(@truncate(kv.value_ptr.*.uint));
                                },
                                .special => {
                                    hl.attrs.bg = vaxis.Color.rgbFromUint(@truncate(kv.value_ptr.*.uint));
                                },
                                .italic => hl.attrs.italic = kv.value_ptr.*.bool,
                                .bold => hl.attrs.bold = kv.value_ptr.*.bool,
                                .strikethrough => hl.attrs.strikethrough = kv.value_ptr.*.bool,
                                .underline => hl.attrs.underline = kv.value_ptr.*.bool,
                                .undercurl => hl.attrs.undercurl = kv.value_ptr.*.bool,
                                .underdouble => hl.attrs.underdouble = kv.value_ptr.*.bool,
                                .underdotted => hl.attrs.underdotted = kv.value_ptr.*.bool,
                                .reverse => hl.attrs.reverse = kv.value_ptr.*.bool,
                                else => {},
                            }
                        }
                        self.hl_map.put(hl) catch |err| {
                            log.err("couldn't save highlight: {}", .{err});
                        };
                    }
                },
                .hl_group_set => {}, // not used right now
                .mode_change => {
                    // param_tuple: [mode, mode_idx]
                    for (params) |param| {
                        assert(param == znvim.Payload.arr);
                        assert(param.arr.len == 2);
                        assert(param.arr[1] == znvim.Payload.uint);
                        const mode = self.mode_set.items[param.arr[1].uint];
                        log.debug("MODE CHANGE: {}", .{mode.cursor_shape});
                        self.screen.cursor_shape = mode.cursor_shape;
                    }
                },
                .mode_info_set => {
                    // param_tuple: [cursor_style_enabled, mode_info]
                    for (params) |param| {
                        assert(param == znvim.Payload.arr);
                        assert(param.arr.len == 2);
                        assert(param.arr[0] == znvim.Payload.bool);
                        assert(param.arr[1] == znvim.Payload.arr);
                        for (param.arr[1].arr) |mode_info| {
                            assert(mode_info == znvim.Payload.map);
                            var iter = mode_info.map.iterator();
                            var mode: Mode = .{};
                            var blink: ?bool = null;
                            var shape: vaxis.Cell.CursorShape = .default;
                            while (iter.next()) |kv| {
                                const key = std.meta.stringToEnum(Mode.Keys, kv.key_ptr.*) orelse continue;
                                switch (key) {
                                    .cursor_shape => {
                                        if (std.mem.eql(u8, "block", kv.value_ptr.*.str.value()))
                                            shape = .block
                                        else if (std.mem.eql(u8, "horizontal", kv.value_ptr.*.str.value()))
                                            shape = .underline
                                        else if (std.mem.eql(u8, "vertical", kv.value_ptr.*.str.value()))
                                            shape = .beam;
                                    },
                                    .short_name => {},
                                    .name => {},
                                    .mouse_shape => {},
                                    .attr_id => {},
                                    .blinkon => {
                                        if (blink == null and kv.value_ptr.*.uint != 0)
                                            blink = true
                                        else
                                            blink = false;
                                    },
                                    .blinkoff => {
                                        if (blink == null and kv.value_ptr.*.uint != 0)
                                            blink = true
                                        else
                                            blink = false;
                                    },
                                }
                                mode.cursor_shape = if (blink == null or !blink.?)
                                    shape
                                else
                                    @enumFromInt(@intFromEnum(shape) - 1);
                                log.err("key={s}, value={}", .{ kv.key_ptr.*, kv.value_ptr.* });
                            }
                            self.mode_set.append(mode) catch |err| {
                                log.err("couldn't add mode_set: {}", .{err});
                            };
                        }
                    }
                },
                .option_set => {
                    // param_tuple: [name, value]
                    for (params) |param| {
                        assert(param == znvim.Payload.arr);
                        assert(param.arr.len == 2);
                        assert(param.arr[0] == znvim.Payload.str);
                        const opt = std.meta.stringToEnum(OptionSet, param.arr[0].str.value()) orelse {
                            log.err("unknonwn 'option_set' key: {s}", .{param.arr[0].str.value()});
                            continue;
                        };
                        switch (opt) {
                            .ambiwidth => {},
                            .arabicshape => {},
                            .emoji => {},
                            .guifont => {},
                            .guifontwide => {},
                            .linespace => {},
                            .mousefocus => {},
                            .mousehide => {},
                            .mousemoveevent => {},
                            .pumblend => {},
                            .showtabline => {},
                            .termguicolors => {},
                            .termsync => {},
                            .ttimeout => {},
                            .ttimeoutlen => {},
                            .verbose => {},
                            .ext_cmdline => {},
                            .ext_hlstate => {},
                            .ext_linegrid => {},
                            .ext_messages => {},
                            .ext_multigrid => {},
                            .ext_popupmenu => {},
                            .ext_tabline => {},
                            .ext_termcolors => {},
                            .ext_wildmenu => {},
                        }
                    }
                },
                .set_icon => {
                    // param_tuple: [title]
                    for (params) |param| {
                        assert(param == znvim.Payload.arr);
                        assert(param.arr.len == 1);
                        assert(param.arr[0] == znvim.Payload.str);
                        const icon = param.arr[0].str.value();
                        log.debug("set_icon: {s}", .{icon});
                    }
                },
                .set_title => {
                    // param_tuple: [icon]
                    for (params) |param| {
                        assert(param == znvim.Payload.arr);
                        assert(param.arr.len == 1);
                        assert(param.arr[0] == znvim.Payload.str);
                        const title = param.arr[0].str.value();
                        log.debug("set_title: {s}", .{title});
                    }
                },
            }
        }
    };
}
