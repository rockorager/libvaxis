//! Main file for the C API for libvaxis.
//! The interface is documented in include/vaxis.h
//! Events are opaque handles read through accessor
//! functions so payloads can grow without breaking the ABI.
//!
//! Functions are plain callconv(.c) fns so they can be called from tests;
//! the comptime block below exports each one with a vaxis_ prefix.
const std = @import("std");
const builtin = @import("builtin");
const vaxis = @import("vaxis");

const Color = vaxis.Color;
const Key = vaxis.Key;
const Mouse = vaxis.Mouse;
const Parser = vaxis.Parser;
const Winsize = vaxis.Winsize;
const Cell = vaxis.Cell;
const Screen = vaxis.Screen;
const Window = vaxis.Window;
const TextInput = vaxis.widgets.TextInput;
const Image = vaxis.Image;
const Terminal = vaxis.widgets.Terminal;
const Tty = vaxis.Tty;
const Vaxis = vaxis.Vaxis;

const default_allocator = std.heap.c_allocator;

pub const CAllocatorVTable = extern struct {
    alloc: *const fn (?*anyopaque, usize, u8, usize) callconv(.c) ?*anyopaque,
    resize: *const fn (?*anyopaque, ?*anyopaque, usize, u8, usize, usize) callconv(.c) bool,
    remap: *const fn (?*anyopaque, ?*anyopaque, usize, u8, usize, usize) callconv(.c) ?*anyopaque,
    free: *const fn (?*anyopaque, ?*anyopaque, usize, u8, usize) callconv(.c) void,
};
pub const CAllocator = extern struct { ctx: ?*anyopaque, vtable: *const CAllocatorVTable };

fn customAlloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
    const a: *const CAllocator = @ptrCast(@alignCast(ctx));
    const p = a.vtable.alloc(a.ctx, len, @intCast(alignment.toByteUnits()), ret_addr) orelse return null;
    return @ptrCast(p);
}
fn customResize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
    const a: *const CAllocator = @ptrCast(@alignCast(ctx));
    return a.vtable.resize(a.ctx, memory.ptr, memory.len, @intCast(alignment.toByteUnits()), new_len, ret_addr);
}
fn customRemap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
    const a: *const CAllocator = @ptrCast(@alignCast(ctx));
    const p = a.vtable.remap(a.ctx, memory.ptr, memory.len, @intCast(alignment.toByteUnits()), new_len, ret_addr) orelse return null;
    return @ptrCast(p);
}
fn customFree(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
    const a: *const CAllocator = @ptrCast(@alignCast(ctx));
    a.vtable.free(a.ctx, memory.ptr, memory.len, @intCast(alignment.toByteUnits()), ret_addr);
}
const custom_allocator_vtable: std.mem.Allocator.VTable = .{
    .alloc = customAlloc,
    .resize = customResize,
    .remap = customRemap,
    .free = customFree,
};

fn allocatorFrom(custom: ?*const CAllocator) std.mem.Allocator {
    return if (custom) |a| .{ .ptr = @constCast(a), .vtable = &custom_allocator_vtable } else default_allocator;
}

const AllocatorState = struct {
    custom: ?CAllocator,

    fn init(custom: ?*const CAllocator) AllocatorState {
        return .{ .custom = if (custom) |a| a.* else null };
    }
    fn get(self: *AllocatorState) std.mem.Allocator {
        return allocatorFrom(if (self.custom) |*a| a else null);
    }
};

pub fn alloc(custom: ?*const CAllocator, len: usize) callconv(.c) ?[*]u8 {
    if (len == 0) return null;
    const memory = allocatorFrom(custom).alloc(u8, len) catch return null;
    return memory.ptr;
}
pub fn free(custom: ?*const CAllocator, ptr: ?[*]u8, len: usize) callconv(.c) void {
    if (ptr == null or len == 0) return;
    allocatorFrom(custom).free(ptr.?[0..len]);
}

comptime {
    // Export every public function as vaxis_<name>, but only when building
    // the C library, not when imported as a Zig module.
    if (@import("root") == @This()) {
        for (@typeInfo(@This()).@"struct".decls) |decl| {
            const field = @field(@This(), decl.name);
            if (@typeInfo(@TypeOf(field)) == .@"fn") {
                @export(&field, .{ .name = "vaxis_" ++ decl.name });
            }
        }
    }
}

/// C: vaxis_result
pub const Result = enum(c_int) {
    ok = 0,
    err_invalid = -1,
    err_oom = -2,
    err_invalid_utf8 = -3,
    err_io = -4,
    err_unsupported = -5,
    err_range = -6,
    err_state = -7,
};

/// C: vaxis_event_type. Values are ABI: append only, never reorder.
pub const EventType = enum(c_int) {
    none = 0,
    key_press = 1,
    key_release = 2,
    mouse = 3,
    mouse_leave = 4,
    focus_in = 5,
    focus_out = 6,
    paste_start = 7,
    paste_end = 8,
    paste = 9,
    color_report = 10,
    color_scheme = 11,
    winsize = 12,
    cap_kitty_keyboard = 13,
    cap_kitty_graphics = 14,
    cap_rgb = 15,
    cap_sgr_pixels = 16,
    cap_unicode = 17,
    cap_da1 = 18,
    cap_color_scheme_updates = 19,
    cap_multi_cursor = 20,
};

comptime {
    // EventType and vaxis.Event must stay in sync in both directions
    for (@typeInfo(vaxis.Event).@"union".fields) |field| {
        if (!@hasField(EventType, field.name))
            @compileError("vaxis.Event variant missing from EventType: " ++ field.name);
    }
    for (@typeInfo(EventType).@"enum".fields) |field| {
        if (std.mem.eql(u8, field.name, "none")) continue;
        if (!@hasField(vaxis.Event, field.name))
            @compileError("EventType tag is not a vaxis.Event variant: " ++ field.name);
    }
}

/// C: vaxis_string. A borrowed byte slice
pub const CString = extern struct {
    ptr: ?[*]const u8,
    len: usize,

    const empty: CString = .{ .ptr = null, .len = 0 };

    fn init(bytes: []const u8) CString {
        if (bytes.len == 0) return .empty;
        return .{ .ptr = bytes.ptr, .len = bytes.len };
    }
};

/// C: vaxis_rgb
pub const CRgb = extern struct {
    r: u8,
    g: u8,
    b: u8,
};

pub const CWinsize = extern struct { rows: u16, cols: u16, x_pixel: u16, y_pixel: u16 };
pub const CColor = extern struct { type: c_int, index: u8, r: u8, g: u8, b: u8 };
pub const CStyle = extern struct { fg: CColor, bg: CColor, ul: CColor, underline: u8, attrs: u8 };
pub const CCell = extern struct { grapheme: CString, width: u8, style: CStyle };
pub const CSegment = extern struct { text: CString, style: CStyle };
pub const CPrintResult = extern struct { col: u16, row: u16, overflow: bool };
pub const CPrintOptions = extern struct { row_offset: u16, col_offset: u16, wrap: c_int, commit: bool };
pub const CWindowOptions = extern struct { x: i32, y: i32, width: u16, height: u16, border: u8, border_style: CStyle };
pub const CCapabilities = extern struct {
    kitty_keyboard: bool,
    kitty_graphics: bool,
    no_color: bool,
    rgb: bool,
    sgr_pixels: bool,
    color_scheme_updates: bool,
    explicit_width: bool,
    scaled_text: bool,
    multi_cursor: bool,
    unicode_width: u8,
};

const GraphemeStore = struct {
    arena: std.heap.ArenaAllocator,
    allocated_bytes: usize = 0,

    fn init(allocator: std.mem.Allocator) GraphemeStore {
        return .{ .arena = std.heap.ArenaAllocator.init(allocator) };
    }

    fn deinit(self: *GraphemeStore) void {
        self.arena.deinit();
    }

    fn reset(self: *GraphemeStore, allocator: std.mem.Allocator) void {
        self.arena.deinit();
        self.* = .init(allocator);
    }

    fn dupe(self: *GraphemeStore, text: []const u8) error{OutOfMemory}![]const u8 {
        if (text.len == 0) return "";
        const copy = try self.arena.allocator().dupe(u8, text);
        self.allocated_bytes += copy.len;
        return copy;
    }

    /// Rebuild ownership from the live screen. This is required after an
    /// upstream widget writes borrowed slices directly into cells, and is also
    /// used periodically to bound garbage from overwritten cells.
    fn compact(self: *GraphemeStore, screen: *Screen) error{OutOfMemory}!void {
        const allocator = self.arena.child_allocator;
        var next = GraphemeStore.init(allocator);
        errdefer next.deinit();
        const copies = try allocator.alloc([]const u8, screen.buf.len);
        defer allocator.free(copies);
        for (screen.buf, copies) |cell, *copy| {
            copy.* = try next.dupe(cell.char.grapheme);
        }
        for (screen.buf, copies) |*cell, copy| {
            cell.char.grapheme = copy;
        }
        self.deinit();
        self.* = next;
    }

    fn compactIfNeeded(self: *GraphemeStore, screen: *Screen) error{OutOfMemory}!void {
        const live_budget = @max(screen.buf.len * 32, 64 * 1024);
        if (self.allocated_bytes > live_budget) try self.compact(screen);
    }
};

const CScreen = struct { allocator: AllocatorState, screen: Screen, strings: GraphemeStore };
const CWindow = struct { allocator: *AllocatorState, window: Window, strings: *GraphemeStore };
const CTextInput = struct { allocator: AllocatorState, input: TextInput, snapshot: ?[]u8 = null };
const CImage = struct { allocator: AllocatorState, image: Image };
pub const CImageDrawOptions = extern struct { scale: c_int, z_index: i32, has_z_index: bool };
pub const CEnvVar = extern struct { key: CString, value: CString };
pub const CTerminalOptions = extern struct {
    scrollback_size: u16,
    size: CWinsize,
    working_directory: CString,
    environment: ?[*]const CEnvVar,
    environment_count: usize,
};
pub const CRuntimeOptions = extern struct { environment: ?[*]const CEnvVar, environment_count: usize };
pub const CTerminalEvent = extern struct { type: c_int, text: CString };
const CTerminal = if (builtin.os.tag == .linux) struct {
    allocator: AllocatorState,
    threaded: std.Io.Threaded,
    env: std.process.Environ.Map,
    argv: [][]const u8,
    cwd: ?[]u8,
    write_buf: [4096]u8,
    terminal: ?Terminal,
} else opaque {};
const CTty = struct { allocator: AllocatorState, threaded: std.Io.Threaded, buffer: [4096]u8, tty: ?Tty };
const CRuntime = struct { allocator: AllocatorState, tty: *CTty, env: std.process.Environ.Map, strings: GraphemeStore, vx: ?Vaxis };

fn sliceFrom(ptr: ?[*]const u8, len: usize) ?[]const u8 {
    if (len == 0) return "";
    return (ptr orelse return null)[0..len];
}

fn populateEnv(map: *std.process.Environ.Map, entries: ?[*]const CEnvVar, count: usize) error{ Invalid, OutOfMemory }!void {
    if (count == 0) return;
    const vars = entries orelse return error.Invalid;
    for (vars[0..count]) |entry| {
        const key = sliceFrom(entry.key.ptr, entry.key.len) orelse return error.Invalid;
        const value = sliceFrom(entry.value.ptr, entry.value.len) orelse return error.Invalid;
        if (!std.process.Environ.Map.validateKeyForPut(key) or
            std.mem.indexOfScalar(u8, value, 0) != null)
            return error.Invalid;
        map.put(key, value) catch return error.OutOfMemory;
    }
}

fn zigWinsize(ws: CWinsize) Winsize {
    return .{ .rows = ws.rows, .cols = ws.cols, .x_pixel = ws.x_pixel, .y_pixel = ws.y_pixel };
}

fn zigColor(color: CColor) ?Color {
    return switch (color.type) {
        0 => .default,
        1 => .{ .index = color.index },
        2 => .{ .rgb = .{ color.r, color.g, color.b } },
        else => null,
    };
}

fn cColor(color: Color) CColor {
    return switch (color) {
        .default => .{ .type = 0, .index = 0, .r = 0, .g = 0, .b = 0 },
        .index => |i| .{ .type = 1, .index = i, .r = 0, .g = 0, .b = 0 },
        .rgb => |rgb| .{ .type = 2, .index = 0, .r = rgb[0], .g = rgb[1], .b = rgb[2] },
    };
}

fn zigStyle(style: CStyle) ?Cell.Style {
    if (style.underline > 5) return null;
    return .{
        .fg = zigColor(style.fg) orelse return null,
        .bg = zigColor(style.bg) orelse return null,
        .ul = zigColor(style.ul) orelse return null,
        .ul_style = @enumFromInt(style.underline),
        .bold = style.attrs & 1 != 0,
        .dim = style.attrs & 2 != 0,
        .italic = style.attrs & 4 != 0,
        .blink = style.attrs & 8 != 0,
        .reverse = style.attrs & 16 != 0,
        .invisible = style.attrs & 32 != 0,
        .strikethrough = style.attrs & 64 != 0,
    };
}

fn cStyle(style: Cell.Style) CStyle {
    var attrs: u8 = 0;
    if (style.bold) attrs |= 1;
    if (style.dim) attrs |= 2;
    if (style.italic) attrs |= 4;
    if (style.blink) attrs |= 8;
    if (style.reverse) attrs |= 16;
    if (style.invisible) attrs |= 32;
    if (style.strikethrough) attrs |= 64;
    return .{ .fg = cColor(style.fg), .bg = cColor(style.bg), .ul = cColor(style.ul), .underline = @intFromEnum(style.ul_style), .attrs = attrs };
}

fn copyCell(strings: *GraphemeStore, cell: CCell) error{ Invalid, OutOfMemory }!Cell {
    const text = sliceFrom(cell.grapheme.ptr, cell.grapheme.len) orelse return error.Invalid;
    const grapheme = strings.dupe(text) catch return error.OutOfMemory;
    return .{ .char = .{ .grapheme = grapheme, .width = cell.width }, .style = zigStyle(cell.style) orelse return error.Invalid };
}

fn exportCell(cell: Cell) CCell {
    return .{ .grapheme = .init(cell.char.grapheme), .width = cell.char.width, .style = cStyle(cell.style) };
}

pub fn screen_new(size: CWinsize, out: ?*?*CScreen) callconv(.c) Result {
    return screen_new_with_allocator(null, size, out);
}
pub fn screen_new_with_allocator(custom: ?*const CAllocator, size: CWinsize, out: ?*?*CScreen) callconv(.c) Result {
    const result = out orelse return .err_invalid;
    result.* = null;
    const allocator = allocatorFrom(custom);
    const handle = allocator.create(CScreen) catch return .err_oom;
    handle.allocator = .init(custom);
    const owned_allocator = handle.allocator.get();
    handle.screen = Screen.init(owned_allocator, zigWinsize(size)) catch {
        allocator.destroy(handle);
        return .err_oom;
    };
    handle.strings = .init(owned_allocator);
    result.* = handle;
    return .ok;
}

pub fn screen_free(screen: ?*CScreen) callconv(.c) void {
    const s = screen orelse return;
    const allocator = s.allocator.get();
    s.screen.deinit(allocator);
    s.strings.deinit();
    allocator.destroy(s);
}

pub fn screen_resize(screen: ?*CScreen, size: CWinsize) callconv(.c) Result {
    const s = screen orelse return .err_invalid;
    const allocator = s.allocator.get();
    const replacement = Screen.init(allocator, zigWinsize(size)) catch return .err_oom;
    s.screen.deinit(allocator);
    s.screen = replacement;
    s.strings.reset(allocator);
    return .ok;
}

pub fn screen_window(screen: ?*CScreen) callconv(.c) ?*CWindow {
    const s = screen orelse return null;
    const allocator = s.allocator.get();
    const out = allocator.create(CWindow) catch return null;
    out.* = .{ .allocator = &s.allocator, .window = .{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = s.screen.width, .height = s.screen.height, .screen = &s.screen }, .strings = &s.strings };
    return out;
}
pub fn window_free(window: ?*CWindow) callconv(.c) void {
    if (window) |w| w.allocator.get().destroy(w);
}
pub fn window_width(window: ?*const CWindow) callconv(.c) u16 {
    return if (window) |w| w.window.width else 0;
}
pub fn window_height(window: ?*const CWindow) callconv(.c) u16 {
    return if (window) |w| w.window.height else 0;
}
pub fn window_clear(window: ?*CWindow) callconv(.c) void {
    if (window) |w| w.window.clear();
}
pub fn window_child(parent: ?*const CWindow, opts: CWindowOptions) callconv(.c) ?*CWindow {
    const p = parent orelse return null;
    if (opts.x < -65536 or opts.x > 65535 or opts.y < -65536 or opts.y > 65535) return null;
    const style = zigStyle(opts.border_style) orelse return null;
    const child = p.window.child(.{ .x_off = @intCast(opts.x), .y_off = @intCast(opts.y), .width = if (opts.width == 0) null else opts.width, .height = if (opts.height == 0) null else opts.height, .border = .{ .style = style, .where = .{ .other = .{ .top = opts.border & 1 != 0, .right = opts.border & 2 != 0, .bottom = opts.border & 4 != 0, .left = opts.border & 8 != 0 } } } });
    const out = p.allocator.get().create(CWindow) catch return null;
    out.* = .{ .allocator = p.allocator, .window = child, .strings = p.strings };
    return out;
}
pub fn window_fill(window: ?*CWindow, cell: ?*const CCell) callconv(.c) Result {
    const w = window orelse return .err_invalid;
    const c = cell orelse return .err_invalid;
    w.window.fill(copyCell(w.strings, c.*) catch |e| return if (e == error.OutOfMemory) .err_oom else .err_invalid);
    w.strings.compactIfNeeded(w.window.screen) catch return .err_oom;
    return .ok;
}
pub fn window_write_cell(window: ?*CWindow, col: u16, row: u16, cell: ?*const CCell) callconv(.c) Result {
    const w = window orelse return .err_invalid;
    const c = cell orelse return .err_invalid;
    w.window.writeCell(col, row, copyCell(w.strings, c.*) catch |e| return if (e == error.OutOfMemory) .err_oom else .err_invalid);
    w.strings.compactIfNeeded(w.window.screen) catch return .err_oom;
    return .ok;
}
pub fn window_read_cell(window: ?*const CWindow, col: u16, row: u16, out: ?*CCell) callconv(.c) Result {
    const w = window orelse return .err_invalid;
    const o = out orelse return .err_invalid;
    const c = w.window.readCell(col, row) orelse return .err_range;
    o.* = exportCell(c);
    return .ok;
}
pub fn screen_read_cell(screen: ?*const CScreen, col: u16, row: u16, out: ?*CCell) callconv(.c) Result {
    const s = screen orelse return .err_invalid;
    const o = out orelse return .err_invalid;
    const c = s.screen.readCell(col, row) orelse return .err_range;
    o.* = exportCell(c);
    return .ok;
}
pub fn window_grapheme_width(window: ?*const CWindow, text: ?[*]const u8, len: usize) callconv(.c) u16 {
    const w = window orelse return 0;
    return w.window.gwidth(sliceFrom(text, len) orelse return 0);
}
pub fn window_hide_cursor(window: ?*CWindow) callconv(.c) void {
    if (window) |w| w.window.hideCursor();
}
pub fn window_show_cursor(window: ?*CWindow, col: u16, row: u16) callconv(.c) void {
    if (window) |w| w.window.showCursor(col, row);
}
pub fn window_set_cursor_shape(window: ?*CWindow, shape: u8) callconv(.c) void {
    if (window) |w| if (shape <= 6) w.window.setCursorShape(@enumFromInt(shape));
}
pub fn window_scroll(window: ?*CWindow, rows: u16) callconv(.c) void {
    if (window) |w| w.window.scroll(rows);
}

pub fn capabilities_default() callconv(.c) CCapabilities {
    return .{ .kitty_keyboard = false, .kitty_graphics = false, .no_color = false, .rgb = false, .sgr_pixels = false, .color_scheme_updates = false, .explicit_width = false, .scaled_text = false, .multi_cursor = false, .unicode_width = 0 };
}

pub fn window_print(window: ?*CWindow, segments: ?[*]const CSegment, count: usize, opts: CPrintOptions, out: ?*CPrintResult) callconv(.c) Result {
    const w = window orelse return .err_invalid;
    const result = out orelse return .err_invalid;
    if (count > 0 and segments == null) return .err_invalid;
    if (opts.wrap < 0 or opts.wrap > 2) return .err_invalid;
    const allocator = w.allocator.get();
    const zs = allocator.alloc(Cell.Segment, count) catch return .err_oom;
    defer allocator.free(zs);
    for (0..count) |i| {
        const cs = segments.?[i];
        const text = sliceFrom(cs.text.ptr, cs.text.len) orelse return .err_invalid;
        const owned = w.strings.dupe(text) catch return .err_oom;
        zs[i] = .{ .text = owned, .style = zigStyle(cs.style) orelse return .err_invalid };
    }
    const r = w.window.print(zs, .{ .row_offset = opts.row_offset, .col_offset = opts.col_offset, .wrap = @enumFromInt(opts.wrap), .commit = opts.commit });
    w.strings.compactIfNeeded(w.window.screen) catch return .err_oom;
    result.* = .{ .col = r.col, .row = r.row, .overflow = r.overflow };
    return .ok;
}

pub fn text_input_new(out: ?*?*CTextInput) callconv(.c) Result {
    return text_input_new_with_allocator(null, out);
}
pub fn text_input_new_with_allocator(custom: ?*const CAllocator, out: ?*?*CTextInput) callconv(.c) Result {
    const result = out orelse return .err_invalid;
    result.* = null;
    const allocator = allocatorFrom(custom);
    const handle = allocator.create(CTextInput) catch return .err_oom;
    handle.allocator = .init(custom);
    handle.input = TextInput.init(handle.allocator.get());
    handle.snapshot = null;
    result.* = handle;
    return .ok;
}
pub fn text_input_free(input: ?*CTextInput) callconv(.c) void {
    const i = input orelse return;
    const allocator = i.allocator.get();
    if (i.snapshot) |s| allocator.free(s);
    i.input.deinit();
    allocator.destroy(i);
}
fn invalidateInput(i: *CTextInput) void {
    if (i.snapshot) |s| i.allocator.get().free(s);
    i.snapshot = null;
}
pub fn text_input_insert(input: ?*CTextInput, text: ?[*]const u8, len: usize) callconv(.c) Result {
    const i = input orelse return .err_invalid;
    const b = sliceFrom(text, len) orelse return .err_invalid;
    invalidateInput(i);
    i.input.insertSliceAtCursor(b) catch return .err_oom;
    return .ok;
}
pub fn text_input_update_key(input: ?*CTextInput, event: ?*const CEvent) callconv(.c) Result {
    const i = input orelse return .err_invalid;
    const key = keyOf(event) orelse return .err_invalid;
    invalidateInput(i);
    i.input.update(.{ .key_press = key.* }) catch return .err_oom;
    return .ok;
}
pub fn text_input_get_text(input: ?*CTextInput, out: ?*CString) callconv(.c) Result {
    const i = input orelse return .err_invalid;
    const result = out orelse return .err_invalid;
    result.* = .empty;
    invalidateInput(i);
    i.snapshot = i.input.toOwnedContents(i.allocator.get()) catch return .err_oom;
    result.* = .init(i.snapshot.?);
    return .ok;
}
pub fn text_input_reset(input: ?*CTextInput) callconv(.c) void {
    if (input) |i| {
        invalidateInput(i);
        i.input.reset();
    }
}
pub fn text_input_cursor_left(input: ?*CTextInput) callconv(.c) void {
    if (input) |i| {
        invalidateInput(i);
        i.input.cursorLeft();
    }
}
pub fn text_input_cursor_right(input: ?*CTextInput) callconv(.c) void {
    if (input) |i| {
        invalidateInput(i);
        i.input.cursorRight();
    }
}
pub fn text_input_draw(input: ?*CTextInput, window: ?*CWindow, style: ?*const CStyle) callconv(.c) Result {
    const i = input orelse return .err_invalid;
    const w = window orelse return .err_invalid;
    const s = if (style) |x| zigStyle(x.*) orelse return .err_invalid else Cell.Style{};
    i.input.drawWithStyle(w.window, s);
    w.strings.compact(w.window.screen) catch {
        w.window.clear();
        return .err_oom;
    };
    return .ok;
}

pub fn image_new(id: u32, width: u16, height: u16, out: ?*?*CImage) callconv(.c) Result {
    return image_new_with_allocator(null, id, width, height, out);
}
pub fn image_new_with_allocator(custom: ?*const CAllocator, id: u32, width: u16, height: u16, out: ?*?*CImage) callconv(.c) Result {
    const result = out orelse return .err_invalid;
    result.* = null;
    if (id == 0 or width == 0 or height == 0) return .err_invalid;
    const allocator = allocatorFrom(custom);
    const handle = allocator.create(CImage) catch return .err_oom;
    handle.* = .{ .allocator = .init(custom), .image = Image.init(id, width, height) };
    result.* = handle;
    return .ok;
}
pub fn image_free(image: ?*CImage) callconv(.c) void {
    if (image) |i| i.allocator.get().destroy(i);
}
pub fn image_id(image: ?*const CImage) callconv(.c) u32 {
    return if (image) |i| i.image.imageId() else 0;
}
pub fn image_draw(image: ?*const CImage, window: ?*CWindow, opts: CImageDrawOptions) callconv(.c) Result {
    const i = image orelse return .err_invalid;
    const w = window orelse return .err_invalid;
    if (opts.scale < 0 or opts.scale > 3) return .err_invalid;
    i.image.draw(w.window, .{ .scale = @enumFromInt(opts.scale), .z_index = if (opts.has_z_index) opts.z_index else null }) catch return .err_range;
    return .ok;
}
pub fn image_cell_size(image: ?*const CImage, window: ?*const CWindow, cols: ?*u16, rows: ?*u16) callconv(.c) Result {
    const i = image orelse return .err_invalid;
    const w = window orelse return .err_invalid;
    const c = cols orelse return .err_invalid;
    const r = rows orelse return .err_invalid;
    const size = i.image.cellSize(w.window) catch return .err_range;
    c.* = size.cols;
    r.* = size.rows;
    return .ok;
}

fn terminalCleanup(t: *CTerminal, initialized: bool) void {
    const allocator = t.allocator.get();
    if (initialized) t.terminal.?.deinit();
    for (t.argv) |arg| allocator.free(arg);
    allocator.free(t.argv);
    if (t.cwd) |cwd| allocator.free(cwd);
    t.env.deinit();
    t.threaded.deinit();
    allocator.destroy(t);
}
fn terminalCreate(custom: ?*const CAllocator, cargv: [*]const CString, argc: usize, opts: CTerminalOptions) !*CTerminal {
    const cwd_src = sliceFrom(opts.working_directory.ptr, opts.working_directory.len) orelse
        return error.InvalidArgument;
    const initial_allocator = allocatorFrom(custom);
    const t = try initial_allocator.create(CTerminal);
    errdefer initial_allocator.destroy(t);
    t.allocator = .init(custom);
    const allocator = t.allocator.get();

    t.threaded = std.Io.Threaded.init(allocator, .{});
    errdefer t.threaded.deinit();
    t.env = .init(allocator);
    errdefer t.env.deinit();
    try populateEnv(&t.env, opts.environment, opts.environment_count);
    t.cwd = null;
    t.terminal = null;

    t.argv = try allocator.alloc([]const u8, argc);
    var made: usize = 0;
    errdefer {
        for (t.argv[0..made]) |arg| allocator.free(arg);
        allocator.free(t.argv);
    }
    for (0..argc) |i| {
        const arg = sliceFrom(cargv[i].ptr, cargv[i].len) orelse
            return error.InvalidArgument;
        t.argv[i] = try allocator.dupe(u8, arg);
        made += 1;
    }
    if (cwd_src.len > 0) t.cwd = try allocator.dupe(u8, cwd_src);
    errdefer if (t.cwd) |cwd| allocator.free(cwd);

    t.terminal = try Terminal.init(
        t.threaded.io(),
        allocator,
        t.argv,
        &t.env,
        .{
            .scrollback_size = opts.scrollback_size,
            .winsize = zigWinsize(opts.size),
            .initial_working_directory = t.cwd,
        },
        &t.write_buf,
    );
    return t;
}

fn validTerminalSize(size: CWinsize, scrollback_size: u16) bool {
    return size.rows > 0 and size.cols > 0 and
        scrollback_size <= std.math.maxInt(u16) - size.rows;
}

pub fn terminal_new(cargv: ?[*]const CString, argc: usize, opts: ?*const CTerminalOptions, out: ?*?*CTerminal) callconv(.c) Result {
    return terminal_new_with_allocator(null, cargv, argc, opts, out);
}
pub fn terminal_new_with_allocator(custom: ?*const CAllocator, cargv: ?[*]const CString, argc: usize, opts: ?*const CTerminalOptions, out: ?*?*CTerminal) callconv(.c) Result {
    const result = out orelse return .err_invalid;
    result.* = null;
    if (builtin.os.tag != .linux) return .err_unsupported;
    if (argc == 0) return .err_invalid;
    const options = opts orelse return .err_invalid;
    if (!validTerminalSize(options.size, options.scrollback_size)) return .err_range;
    const handle = terminalCreate(custom, cargv orelse return .err_invalid, argc, options.*) catch |err| return switch (err) {
        error.InvalidArgument, error.Invalid => .err_invalid,
        error.OutOfMemory => .err_oom,
        else => .err_io,
    };
    result.* = handle;
    return .ok;
}
pub fn terminal_free(terminal: ?*CTerminal) callconv(.c) void {
    if (comptime builtin.os.tag != .linux) {
        return;
    }
    if (terminal) |t| terminalCleanup(t, t.terminal != null);
}
pub fn terminal_spawn(terminal: ?*CTerminal) callconv(.c) Result {
    if (comptime builtin.os.tag != .linux) {
        return .err_unsupported;
    }
    const t = terminal orelse return .err_invalid;
    t.terminal.?.spawn() catch return .err_io;
    return .ok;
}
pub fn terminal_resize(terminal: ?*CTerminal, size: CWinsize) callconv(.c) Result {
    if (comptime builtin.os.tag != .linux) {
        return .err_unsupported;
    }
    const t = terminal orelse return .err_invalid;
    if (!validTerminalSize(size, t.terminal.?.scrollback_size)) return .err_range;
    t.terminal.?.resize(zigWinsize(size)) catch return .err_io;
    return .ok;
}
pub fn terminal_draw(terminal: ?*CTerminal, window: ?*CWindow) callconv(.c) Result {
    if (comptime builtin.os.tag != .linux) {
        return .err_unsupported;
    }
    const t = terminal orelse return .err_invalid;
    const w = window orelse return .err_invalid;
    t.terminal.?.draw(t.allocator.get(), w.window) catch return .err_oom;
    w.strings.compact(w.window.screen) catch {
        w.window.clear();
        return .err_oom;
    };
    return .ok;
}
pub fn terminal_update_key(terminal: ?*CTerminal, event: ?*const CEvent) callconv(.c) Result {
    if (comptime builtin.os.tag != .linux) {
        return .err_unsupported;
    }
    const t = terminal orelse return .err_invalid;
    const key = keyOf(event) orelse return .err_invalid;
    t.terminal.?.update(.{ .key_press = key.* }) catch return .err_io;
    return .ok;
}
pub fn terminal_try_event(terminal: ?*CTerminal, out: ?*CTerminalEvent, available: ?*bool) callconv(.c) Result {
    if (comptime builtin.os.tag != .linux) {
        return .err_unsupported;
    }
    const t = terminal orelse return .err_invalid;
    const o = out orelse return .err_invalid;
    const a = available orelse return .err_invalid;
    a.* = false;
    o.* = .{ .type = 0, .text = .empty };
    const maybe_ev = (t.terminal.?.tryEvent() catch return .err_io);
    const ev = maybe_ev orelse return .ok;
    a.* = true;
    switch (ev) {
        .exited => o.type = 1,
        .redraw => o.type = 2,
        .bell => o.type = 3,
        .title_change => |s| {
            o.type = 4;
            o.text = .init(s);
        },
        .pwd_change => |s| {
            o.type = 5;
            o.text = .init(s);
        },
    }
    return .ok;
}

pub fn tty_new(out: ?*?*CTty) callconv(.c) Result {
    return tty_new_with_allocator(null, out);
}
pub fn tty_new_with_allocator(custom: ?*const CAllocator, out: ?*?*CTty) callconv(.c) Result {
    const result = out orelse return .err_invalid;
    result.* = null;
    const initial_allocator = allocatorFrom(custom);
    const t = initial_allocator.create(CTty) catch return .err_oom;
    t.allocator = .init(custom);
    const allocator = t.allocator.get();
    t.threaded = std.Io.Threaded.init(allocator, .{});
    t.tty = null;
    t.tty = Tty.init(t.threaded.io(), &t.buffer) catch {
        t.threaded.deinit();
        allocator.destroy(t);
        return .err_io;
    };
    result.* = t;
    return .ok;
}
pub fn tty_free(tty: ?*CTty) callconv(.c) void {
    const t = tty orelse return;
    const allocator = t.allocator.get();
    if (t.tty) |x| x.deinit();
    t.threaded.deinit();
    allocator.destroy(t);
}
pub fn tty_winsize(tty: ?*CTty, out: ?*CWinsize) callconv(.c) Result {
    const t = tty orelse return .err_invalid;
    const o = out orelse return .err_invalid;
    const ws = t.tty.?.getWinsize() catch return .err_io;
    o.* = .{ .rows = ws.rows, .cols = ws.cols, .x_pixel = ws.x_pixel, .y_pixel = ws.y_pixel };
    return .ok;
}
pub fn tty_read(tty: ?*CTty, buf: ?[*]u8, capacity: usize, length: ?*usize) callconv(.c) Result {
    if (comptime builtin.os.tag == .windows) return .err_unsupported;
    const t = tty orelse return .err_invalid;
    const l = length orelse return .err_invalid;
    l.* = 0;
    if (capacity == 0) return .ok;
    const b = buf orelse return .err_invalid;
    l.* = t.tty.?.read(b[0..capacity]) catch return .err_io;
    return .ok;
}
pub fn tty_next_event(tty: ?*CTty, parser: ?*CParser, event: ?*?*const CEvent) callconv(.c) Result {
    if (comptime builtin.os.tag != .windows) return .err_unsupported;
    const t = tty orelse return .err_invalid;
    const p = parser orelse return .err_invalid;
    const out = event orelse return .err_invalid;
    out.* = null;
    clearParserEvent(p);
    const parsed = t.tty.?.nextEvent(&p.parser, p.allocator.get()) catch return .err_io;
    convertEvent(p, parsed);
    out.* = &p.event;
    return .ok;
}
pub fn runtime_new(tty: ?*CTty, opts: ?*const CRuntimeOptions, out: ?*?*CRuntime) callconv(.c) Result {
    return runtime_new_with_allocator(null, tty, opts, out);
}
pub fn runtime_new_with_allocator(custom: ?*const CAllocator, tty: ?*CTty, opts: ?*const CRuntimeOptions, out: ?*?*CRuntime) callconv(.c) Result {
    const result = out orelse return .err_invalid;
    result.* = null;
    const t = tty orelse return .err_invalid;
    const options = opts orelse return .err_invalid;
    const initial_allocator = allocatorFrom(custom);
    const r = initial_allocator.create(CRuntime) catch return .err_oom;
    r.allocator = .init(custom);
    const allocator = r.allocator.get();
    r.tty = t;
    r.env = .init(allocator);
    populateEnv(&r.env, options.environment, options.environment_count) catch |err| {
        r.env.deinit();
        allocator.destroy(r);
        return if (err == error.OutOfMemory) .err_oom else .err_invalid;
    };
    r.strings = .init(allocator);
    r.vx = Vaxis.init(t.threaded.io(), allocator, &r.env, .{}) catch {
        r.strings.deinit();
        r.env.deinit();
        allocator.destroy(r);
        return .err_oom;
    };
    result.* = r;
    return .ok;
}
pub fn runtime_free(runtime: ?*CRuntime) callconv(.c) void {
    const r = runtime orelse return;
    const allocator = r.allocator.get();
    if (r.vx) |*vx| vx.deinit(allocator, r.tty.tty.?.writer());
    r.strings.deinit();
    r.env.deinit();
    allocator.destroy(r);
}
pub fn runtime_resize(runtime: ?*CRuntime, size: CWinsize) callconv(.c) Result {
    const r = runtime orelse return .err_invalid;
    const allocator = r.allocator.get();
    r.vx.?.resize(allocator, r.tty.tty.?.writer(), zigWinsize(size)) catch |err| return if (err == error.OutOfMemory) .err_oom else .err_io;
    r.strings.reset(allocator);
    return .ok;
}
pub fn runtime_window(runtime: ?*CRuntime) callconv(.c) ?*CWindow {
    const r = runtime orelse return null;
    const allocator = r.allocator.get();
    const out = allocator.create(CWindow) catch return null;
    out.* = .{ .allocator = &r.allocator, .window = r.vx.?.window(), .strings = &r.strings };
    return out;
}
pub fn runtime_render(runtime: ?*CRuntime) callconv(.c) Result {
    const r = runtime orelse return .err_invalid;
    r.vx.?.render(r.tty.tty.?.writer()) catch return .err_io;
    return .ok;
}
pub fn runtime_enter_alt_screen(runtime: ?*CRuntime) callconv(.c) Result {
    const r = runtime orelse return .err_invalid;
    r.vx.?.enterAltScreen(r.tty.tty.?.writer()) catch return .err_io;
    return .ok;
}
pub fn runtime_exit_alt_screen(runtime: ?*CRuntime) callconv(.c) Result {
    const r = runtime orelse return .err_invalid;
    r.vx.?.exitAltScreen(r.tty.tty.?.writer()) catch return .err_io;
    return .ok;
}
pub fn runtime_query_terminal(runtime: ?*CRuntime, timeout_ns: u64) callconv(.c) Result {
    const r = runtime orelse return .err_invalid;
    r.vx.?.queryTerminal(r.tty.tty.?.writer(), .fromNanoseconds(timeout_ns)) catch return .err_io;
    return .ok;
}
pub fn runtime_query_terminal_send(runtime: ?*CRuntime) callconv(.c) Result {
    const r = runtime orelse return .err_invalid;
    r.vx.?.queryTerminalSend(r.tty.tty.?.writer()) catch return .err_io;
    return .ok;
}
pub fn runtime_query_terminal_finish(runtime: ?*CRuntime) callconv(.c) Result {
    const r = runtime orelse return .err_invalid;
    r.vx.?.queries_done.store(true, .unordered);
    r.vx.?.enableDetectedFeatures(r.tty.tty.?.writer()) catch return .err_io;
    return .ok;
}
fn applyRuntimeEvent(vx: *Vaxis, e: *const CEvent) void {
    switch (e.type) {
        .key_press => {
            if (e.key.codepoint == Key.f3 and !vx.queries_done.load(.unordered)) {
                if (e.key.mods.shift) {
                    vx.caps.explicit_width = true;
                    vx.caps.unicode = .unicode;
                    vx.screen.width_method = .unicode;
                }
                if (e.key.mods.alt) vx.caps.scaled_text = true;
            }
        },
        .cap_kitty_keyboard => vx.caps.kitty_keyboard = true,
        .cap_kitty_graphics => vx.caps.kitty_graphics = true,
        .cap_rgb => vx.caps.rgb = true,
        .cap_sgr_pixels => vx.caps.sgr_pixels = true,
        .cap_unicode => {
            vx.caps.unicode = .unicode;
            vx.screen.width_method = .unicode;
        },
        .cap_color_scheme_updates => vx.caps.color_scheme_updates = true,
        .cap_multi_cursor => vx.caps.multi_cursor = true,
        .cap_da1 => {
            std.Io.futexWake(vx.io, std.atomic.Value(u32), &vx.query_futex, 10);
            vx.queries_done.store(true, .unordered);
        },
        .winsize => {
            vx.state.in_band_resize = true;
            if (comptime builtin.os.tag != .windows) Tty.resetSignalHandler();
        },
        else => {},
    }
}

pub fn runtime_handle_event(runtime: ?*CRuntime, event: ?*const CEvent) callconv(.c) Result {
    const r = runtime orelse return .err_invalid;
    const e = event orelse return .err_invalid;
    if (r.vx) |*vx| {
        applyRuntimeEvent(vx, e);
    } else return .err_state;
    return .ok;
}
pub fn runtime_queue_refresh(runtime: ?*CRuntime) callconv(.c) void {
    if (runtime) |r| r.vx.?.queueRefresh();
}
fn caps(c: Vaxis.Capabilities) CCapabilities {
    return .{ .kitty_keyboard = c.kitty_keyboard, .kitty_graphics = c.kitty_graphics, .no_color = c.no_color, .rgb = c.rgb, .sgr_pixels = c.sgr_pixels, .color_scheme_updates = c.color_scheme_updates, .explicit_width = c.explicit_width, .scaled_text = c.scaled_text, .multi_cursor = c.multi_cursor, .unicode_width = switch (c.unicode) {
        .wcwidth => 0,
        .unicode => 1,
        .no_zwj => 2,
    } };
}
pub fn runtime_capabilities(runtime: ?*const CRuntime) callconv(.c) CCapabilities {
    return if (runtime) |r| caps(r.vx.?.caps) else capabilities_default();
}
pub fn runtime_set_mouse_mode(runtime: ?*CRuntime, enabled: bool) callconv(.c) Result {
    const r = runtime orelse return .err_invalid;
    r.vx.?.setMouseMode(r.tty.tty.?.writer(), enabled) catch return .err_io;
    return .ok;
}
pub fn runtime_set_bracketed_paste(runtime: ?*CRuntime, enabled: bool) callconv(.c) Result {
    const r = runtime orelse return .err_invalid;
    r.vx.?.setBracketedPaste(r.tty.tty.?.writer(), enabled) catch return .err_io;
    return .ok;
}
pub fn runtime_set_title(runtime: ?*CRuntime, title: ?[*]const u8, len: usize) callconv(.c) Result {
    const r = runtime orelse return .err_invalid;
    const s = sliceFrom(title, len) orelse return .err_invalid;
    r.vx.?.setTitle(r.tty.tty.?.writer(), s) catch return .err_io;
    return .ok;
}
fn prepareImage(r: *CRuntime, out: ?*?*CImage) error{ Invalid, OutOfMemory }!*CImage {
    const o = out orelse return error.Invalid;
    o.* = null;
    return r.allocator.get().create(CImage) catch error.OutOfMemory;
}
pub fn runtime_load_image_memory(runtime: ?*CRuntime, data: ?[*]const u8, len: usize, out: ?*?*CImage) callconv(.c) Result {
    const r = runtime orelse return .err_invalid;
    const b = sliceFrom(data, len) orelse return .err_invalid;
    const allocator = r.allocator.get();
    const handle = prepareImage(r, out) catch |err| return if (err == error.OutOfMemory) .err_oom else .err_invalid;
    const img = r.vx.?.loadImage(allocator, r.tty.tty.?.writer(), .{ .mem = b }) catch |e| {
        allocator.destroy(handle);
        return if (e == error.OutOfMemory) .err_oom else .err_io;
    };
    handle.* = .{ .allocator = r.allocator, .image = img };
    out.?.* = handle;
    return .ok;
}
pub fn runtime_transmit_image_path(runtime: ?*CRuntime, path: ?[*]const u8, len: usize, width: u16, height: u16, medium: c_int, format: c_int, out: ?*?*CImage) callconv(.c) Result {
    const r = runtime orelse return .err_invalid;
    const p = sliceFrom(path, len) orelse return .err_invalid;
    if (medium < 0 or medium > 2 or format < 0 or format > 2) return .err_invalid;
    const allocator = r.allocator.get();
    const handle = prepareImage(r, out) catch |err| return if (err == error.OutOfMemory) .err_oom else .err_invalid;
    const img = r.vx.?.transmitLocalImagePath(allocator, r.tty.tty.?.writer(), p, width, height, @enumFromInt(medium), @enumFromInt(format)) catch {
        allocator.destroy(handle);
        return .err_io;
    };
    handle.* = .{ .allocator = r.allocator, .image = img };
    out.?.* = handle;
    return .ok;
}
pub fn runtime_transmit_image_base64(runtime: ?*CRuntime, data: ?[*]const u8, len: usize, width: u16, height: u16, format: c_int, out: ?*?*CImage) callconv(.c) Result {
    const r = runtime orelse return .err_invalid;
    const b = sliceFrom(data, len) orelse return .err_invalid;
    if (format < 0 or format > 2) return .err_invalid;
    const allocator = r.allocator.get();
    const handle = prepareImage(r, out) catch |err| return if (err == error.OutOfMemory) .err_oom else .err_invalid;
    const img = r.vx.?.transmitPreEncodedImage(r.tty.tty.?.writer(), b, width, height, @enumFromInt(format)) catch {
        allocator.destroy(handle);
        return .err_io;
    };
    handle.* = .{ .allocator = r.allocator, .image = img };
    out.?.* = handle;
    return .ok;
}
pub fn runtime_free_transmitted_image(runtime: ?*CRuntime, id: u32) callconv(.c) void {
    if (runtime) |r| r.vx.?.freeImage(r.tty.tty.?.writer(), id);
}

/// The storage behind the opaque vaxis_event handle. Payloads are the
/// native vaxis types; accessors convert at the boundary
const CEvent = struct {
    type: EventType = .none,
    key: Key = .{ .codepoint = 0 },
    mouse: Mouse = .{ .col = 0, .row = 0, .button = .none, .mods = .{}, .type = .press },
    paste: []const u8 = "",
    color_report: Color.Report = .{ .kind = .fg, .value = .{ 0, 0, 0 } },
    color_scheme: Color.Scheme = .dark,
    winsize: Winsize = .{ .rows = 0, .cols = 0, .x_pixel = 0, .y_pixel = 0 },
};

/// vaxis_parser. Owns the current event and everything it points at
const CParser = struct {
    allocator: AllocatorState,
    parser: Parser,
    event: CEvent,
    text_buf: [256]u8,
    paste: ?[]const u8,
};

pub fn parser_new() callconv(.c) ?*CParser {
    return parser_new_with_allocator(null);
}
pub fn parser_new_with_allocator(custom: ?*const CAllocator) callconv(.c) ?*CParser {
    const allocator = allocatorFrom(custom);
    const parser = allocator.create(CParser) catch return null;
    parser.* = .{
        .allocator = .init(custom),
        .parser = .{},
        .event = .{},
        .text_buf = undefined,
        .paste = null,
    };
    return parser;
}

pub fn parser_free(parser: ?*CParser) callconv(.c) void {
    const p = parser orelse return;
    const allocator = p.allocator.get();
    if (p.paste) |paste| allocator.free(paste);
    allocator.destroy(p);
}

fn clearParserEvent(p: *CParser) void {
    p.event = .{};
    if (p.paste) |paste| {
        p.allocator.get().free(paste);
        p.paste = null;
    }
}

pub fn parser_parse(
    parser: ?*CParser,
    input: ?[*]const u8,
    input_len: usize,
    event: ?*?*const CEvent,
    consumed: ?*usize,
) callconv(.c) Result {
    const p = parser orelse return .err_invalid;
    const out_event = event orelse return .err_invalid;
    const out_consumed = consumed orelse return .err_invalid;

    out_event.* = null;
    out_consumed.* = 0;

    // the previous event is only valid until this call
    clearParserEvent(p);

    if (input_len == 0) return .ok;
    const in = input orelse return .err_invalid;

    const result = p.parser.parse(in[0..input_len], p.allocator.get()) catch |err| {
        return switch (err) {
            error.OutOfMemory => .err_oom,
            error.InvalidUTF8 => .err_invalid_utf8,
        };
    };
    out_consumed.* = result.n;
    if (result.event) |ev| {
        convertEvent(p, ev);
        out_event.* = &p.event;
    }
    return .ok;
}

// Event accessors are NULL-safe and return zero values when the event is
// not of the matching type

pub fn event_get_type(event: ?*const CEvent) callconv(.c) EventType {
    const e = event orelse return .none;
    return e.type;
}

fn keyOf(event: ?*const CEvent) ?*const Key {
    const e = event orelse return null;
    return switch (e.type) {
        .key_press, .key_release => &e.key,
        else => null,
    };
}

pub fn event_key_codepoint(event: ?*const CEvent) callconv(.c) u32 {
    const key = keyOf(event) orelse return 0;
    return key.codepoint;
}

pub fn event_key_shifted_codepoint(event: ?*const CEvent) callconv(.c) u32 {
    const key = keyOf(event) orelse return 0;
    return key.shifted_codepoint orelse 0;
}

pub fn event_key_base_layout_codepoint(event: ?*const CEvent) callconv(.c) u32 {
    const key = keyOf(event) orelse return 0;
    return key.base_layout_codepoint orelse 0;
}

pub fn event_key_mods(event: ?*const CEvent) callconv(.c) u8 {
    const key = keyOf(event) orelse return 0;
    return @bitCast(key.mods);
}

pub fn event_key_text(event: ?*const CEvent) callconv(.c) CString {
    const key = keyOf(event) orelse return .empty;
    return .init(key.text orelse "");
}

pub fn event_key_matches(event: ?*const CEvent, codepoint: u32, mods: u8) callconv(.c) bool {
    const key = keyOf(event) orelse return false;
    if (codepoint > std.math.maxInt(u21)) return false;
    return key.matches(@intCast(codepoint), @bitCast(mods));
}

fn mouseOf(event: ?*const CEvent) ?*const Mouse {
    const e = event orelse return null;
    return if (e.type == .mouse) &e.mouse else null;
}

pub fn event_mouse_col(event: ?*const CEvent) callconv(.c) i16 {
    const mouse = mouseOf(event) orelse return 0;
    return mouse.col;
}

pub fn event_mouse_row(event: ?*const CEvent) callconv(.c) i16 {
    const mouse = mouseOf(event) orelse return 0;
    return mouse.row;
}

pub fn event_mouse_button(event: ?*const CEvent) callconv(.c) u8 {
    const mouse = mouseOf(event) orelse return 0;
    return @intFromEnum(mouse.button);
}

pub fn event_mouse_mods(event: ?*const CEvent) callconv(.c) u8 {
    const mouse = mouseOf(event) orelse return 0;
    return @as(u3, @bitCast(mouse.mods));
}

pub fn event_mouse_type(event: ?*const CEvent) callconv(.c) u8 {
    const mouse = mouseOf(event) orelse return 0;
    return @intFromEnum(mouse.type);
}

pub fn event_paste_text(event: ?*const CEvent) callconv(.c) CString {
    const e = event orelse return .empty;
    if (e.type != .paste) return .empty;
    return .init(e.paste);
}

pub fn event_color_report_kind(event: ?*const CEvent) callconv(.c) u8 {
    const e = event orelse return 0;
    if (e.type != .color_report) return 0;
    return @intFromEnum(std.meta.activeTag(e.color_report.kind));
}

pub fn event_color_report_index(event: ?*const CEvent) callconv(.c) u8 {
    const e = event orelse return 0;
    if (e.type != .color_report) return 0;
    return switch (e.color_report.kind) {
        .index => |idx| idx,
        else => 0,
    };
}

pub fn event_color_report_rgb(event: ?*const CEvent) callconv(.c) CRgb {
    const zero: CRgb = .{ .r = 0, .g = 0, .b = 0 };
    const e = event orelse return zero;
    if (e.type != .color_report) return zero;
    const value = e.color_report.value;
    return .{ .r = value[0], .g = value[1], .b = value[2] };
}

pub fn event_color_scheme(event: ?*const CEvent) callconv(.c) u8 {
    const e = event orelse return 0;
    if (e.type != .color_scheme) return 0;
    return @intFromEnum(e.color_scheme);
}

pub fn event_winsize_rows(event: ?*const CEvent) callconv(.c) u16 {
    const e = event orelse return 0;
    if (e.type != .winsize) return 0;
    return e.winsize.rows;
}

pub fn event_winsize_cols(event: ?*const CEvent) callconv(.c) u16 {
    const e = event orelse return 0;
    if (e.type != .winsize) return 0;
    return e.winsize.cols;
}

pub fn event_winsize_x_pixel(event: ?*const CEvent) callconv(.c) u16 {
    const e = event orelse return 0;
    if (e.type != .winsize) return 0;
    return e.winsize.x_pixel;
}

pub fn event_winsize_y_pixel(event: ?*const CEvent) callconv(.c) u16 {
    const e = event orelse return 0;
    if (e.type != .winsize) return 0;
    return e.winsize.y_pixel;
}

pub fn key_from_name(name: ?[*]const u8, name_len: usize) callconv(.c) u32 {
    const n = name orelse return 0;
    return Key.name_map.get(n[0..name_len]) orelse 0;
}

pub fn version() callconv(.c) [*:0]const u8 {
    // single-sourced from build.zig.zon
    return std.fmt.comptimePrint("{s}", .{@import("build_options").version});
}

fn convertEvent(p: *CParser, event: vaxis.Event) void {
    // the tag mapping is comptime-checked: a vaxis.Event variant without a
    // matching EventType tag fails to compile
    p.event.type = switch (event) {
        inline else => |_, tag| @field(EventType, @tagName(tag)),
    };
    switch (event) {
        .key_press, .key_release => |key| p.event.key = copyKey(p, key),
        .mouse => |mouse| p.event.mouse = mouse,
        .paste => |text| {
            p.paste = text;
            p.event.paste = text;
        },
        .color_report => |report| p.event.color_report = report,
        .color_scheme => |scheme| p.event.color_scheme = scheme,
        .winsize => |winsize| p.event.winsize = winsize,
        else => {},
    }
}

fn copyKey(p: *CParser, key: Key) Key {
    var out = key;
    out.text = null;
    if (key.text) |text| {
        // Copy the text so it stays valid until the next parse call.
        // Oversized text is truncated at a codepoint boundary
        var n = @min(text.len, p.text_buf.len);
        while (n < text.len and n > 0 and text[n] & 0xC0 == 0x80) n -= 1;
        @memcpy(p.text_buf[0..n], text[0..n]);
        out.text = p.text_buf[0..n];
    }
    return out;
}

const testing = std.testing;

fn parseBytes(p: *CParser, input: []const u8, event: *?*const CEvent, n: *usize) Result {
    return parser_parse(p, input.ptr, input.len, event, n);
}

fn comptimeUpper(comptime name: []const u8) []const u8 {
    comptime {
        var out: [name.len]u8 = undefined;
        for (name, 0..) |char, i| out[i] = std.ascii.toUpper(char);
        const final = out;
        return &final;
    }
}

fn asInt(value: anytype) c_int {
    return switch (@typeInfo(@TypeOf(value))) {
        .@"enum" => @intFromEnum(value),
        else => @intCast(value),
    };
}

test "c api: conformance with vaxis.h" {
    @setEvalBranchQuota(100_000);
    const c = @cImport(@cInclude("vaxis.h"));

    // the only transparent structs in the ABI
    try testing.expectEqual(@sizeOf(c.vaxis_string), @sizeOf(CString));
    try testing.expectEqual(@alignOf(c.vaxis_string), @alignOf(CString));
    try testing.expectEqual(@offsetOf(c.vaxis_string, "ptr"), @offsetOf(CString, "ptr"));
    try testing.expectEqual(@offsetOf(c.vaxis_string, "len"), @offsetOf(CString, "len"));
    try testing.expectEqual(@sizeOf(c.vaxis_rgb), @sizeOf(CRgb));
    inline for (.{ "r", "g", "b" }) |field| {
        try testing.expectEqual(@offsetOf(c.vaxis_rgb, field), @offsetOf(CRgb, field));
    }
    inline for (.{
        .{ c.vaxis_allocator_vtable, CAllocatorVTable }, .{ c.vaxis_allocator, CAllocator },
        .{ c.vaxis_winsize, CWinsize },                  .{ c.vaxis_color, CColor },
        .{ c.vaxis_style, CStyle },                      .{ c.vaxis_cell, CCell },
        .{ c.vaxis_segment, CSegment },                  .{ c.vaxis_print_result, CPrintResult },
        .{ c.vaxis_print_options, CPrintOptions },       .{ c.vaxis_window_options, CWindowOptions },
        .{ c.vaxis_capabilities, CCapabilities },        .{ c.vaxis_image_draw_options, CImageDrawOptions },
        .{ c.vaxis_env_var, CEnvVar },                   .{ c.vaxis_runtime_options, CRuntimeOptions },
        .{ c.vaxis_terminal_options, CTerminalOptions }, .{ c.vaxis_terminal_event, CTerminalEvent },
    }) |pair| {
        try testing.expectEqual(@sizeOf(pair[0]), @sizeOf(pair[1]));
        try testing.expectEqual(@alignOf(pair[0]), @alignOf(pair[1]));
    }

    // every event type has a matching VAXIS_EVENT_* value
    inline for (@typeInfo(EventType).@"enum".fields) |field| {
        try testing.expectEqual(
            asInt(@field(c, "VAXIS_EVENT_" ++ comptimeUpper(field.name))),
            field.value,
        );
    }

    // result codes: ok is VAXIS_OK, errors are VAXIS_ERR_*
    inline for (@typeInfo(Result).@"enum".fields) |field| {
        const c_name = comptime if (std.mem.eql(u8, field.name, "ok"))
            "VAXIS_OK"
        else
            "VAXIS_" ++ comptimeUpper(field.name);
        try testing.expectEqual(asInt(@field(c, c_name)), field.value);
    }

    // every u21 key constant has a matching VAXIS_KEY_* define
    inline for (@typeInfo(Key).@"struct".decls) |decl| {
        if (@TypeOf(@field(Key, decl.name)) == u21) {
            try testing.expectEqual(
                asInt(@field(c, "VAXIS_KEY_" ++ comptimeUpper(decl.name))),
                @field(Key, decl.name),
            );
        }
    }

    // modifier bits are the packed struct bit positions
    inline for (@typeInfo(Key.Modifiers).@"struct".fields, 0..) |field, i| {
        try testing.expectEqual(
            asInt(@field(c, "VAXIS_MOD_" ++ comptimeUpper(field.name))),
            @as(u8, 1) << i,
        );
    }
    inline for (@typeInfo(Mouse.Modifiers).@"struct".fields, 0..) |field, i| {
        try testing.expectEqual(
            asInt(@field(c, "VAXIS_MOUSE_MOD_" ++ comptimeUpper(field.name))),
            @as(u8, 1) << i,
        );
    }

    // mouse buttons, mouse event types, color kinds, and color schemes
    inline for (@typeInfo(Mouse.Button).@"enum".fields) |field| {
        try testing.expectEqual(
            asInt(@field(c, "VAXIS_MOUSE_" ++ comptimeUpper(field.name))),
            field.value,
        );
    }
    inline for (@typeInfo(Mouse.Type).@"enum".fields) |field| {
        try testing.expectEqual(
            asInt(@field(c, "VAXIS_MOUSE_" ++ comptimeUpper(field.name))),
            field.value,
        );
    }
    inline for (@typeInfo(std.meta.Tag(Color.Kind)).@"enum".fields) |field| {
        try testing.expectEqual(
            asInt(@field(c, "VAXIS_COLOR_" ++ comptimeUpper(field.name))),
            field.value,
        );
    }
    inline for (@typeInfo(Color.Scheme).@"enum".fields) |field| {
        try testing.expectEqual(
            asInt(@field(c, "VAXIS_COLOR_SCHEME_" ++ comptimeUpper(field.name))),
            field.value,
        );
    }
}

test "c api: screen owns input strings and bounds overwritten storage" {
    var screen: ?*CScreen = null;
    try testing.expectEqual(.ok, screen_new(.{ .rows = 2, .cols = 8, .x_pixel = 80, .y_pixel = 160 }, &screen));
    defer screen_free(screen);
    const window = screen_window(screen) orelse return error.OutOfMemory;
    defer window_free(window);

    var input = [_]u8{'a'};
    const cell: CCell = .{
        .grapheme = .init(&input),
        .width = 1,
        .style = cStyle(.{}),
    };
    try testing.expectEqual(.ok, window_write_cell(window, 7, 1, &cell));
    input[0] = 'z';
    var actual: CCell = undefined;
    try testing.expectEqual(.ok, window_read_cell(window, 7, 1, &actual));
    try testing.expectEqualStrings("a", actual.grapheme.ptr.?[0..actual.grapheme.len]);

    for (0..70_000) |i| {
        input[0] = @intCast('a' + i % 26);
        try testing.expectEqual(.ok, window_write_cell(window, 7, 1, &cell));
    }
    try testing.expect(screen.?.strings.allocated_bytes <= 64 * 1024);
}

test "c api: environment entries are parsed and copied" {
    var map = std.process.Environ.Map.init(testing.allocator);
    defer map.deinit();
    const valid = [_]CEnvVar{.{ .key = .init("NO_COLOR"), .value = .init("1") }};
    try populateEnv(&map, &valid, valid.len);
    try testing.expectEqualStrings("1", map.get("NO_COLOR").?);

    const invalid = [_]CEnvVar{.{ .key = .init("BAD=KEY"), .value = .init("x") }};
    try testing.expectError(error.Invalid, populateEnv(&map, &invalid, invalid.len));
}

test "c api: runtime capability events update Vaxis state" {
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    var vx = try Vaxis.init(std.testing.io, testing.allocator, &env, .{});
    var writer: std.Io.Writer.Allocating = .init(testing.allocator);
    defer writer.deinit();
    defer vx.deinit(testing.allocator, &writer.writer);

    var event: CEvent = .{ .type = .cap_kitty_graphics };
    applyRuntimeEvent(&vx, &event);
    try testing.expect(vx.caps.kitty_graphics);
    event.type = .cap_unicode;
    applyRuntimeEvent(&vx, &event);
    try testing.expectEqual(vaxis.gwidth.Method.unicode, vx.caps.unicode);
    event.type = .winsize;
    applyRuntimeEvent(&vx, &event);
    try testing.expect(vx.state.in_band_resize);
}

test "c api: terminal dimensions are validated" {
    try testing.expect(!validTerminalSize(.{ .rows = 0, .cols = 80, .x_pixel = 0, .y_pixel = 0 }, 0));
    try testing.expect(!validTerminalSize(.{ .rows = 24, .cols = 0, .x_pixel = 0, .y_pixel = 0 }, 0));
    try testing.expect(!validTerminalSize(.{ .rows = 65_000, .cols = 80, .x_pixel = 0, .y_pixel = 0 }, 1_000));
    try testing.expect(validTerminalSize(.{ .rows = 24, .cols = 80, .x_pixel = 0, .y_pixel = 0 }, 500));
}

test "c api: plain keypress with text" {
    const parser = parser_new() orelse return error.OutOfMemory;
    defer parser_free(parser);

    var event: ?*const CEvent = null;
    var n: usize = 0;
    try testing.expectEqual(.ok, parseBytes(parser, "a", &event, &n));
    try testing.expectEqual(@as(usize, 1), n);
    try testing.expectEqual(EventType.key_press, event_get_type(event));
    try testing.expectEqual(@as(u32, 'a'), event_key_codepoint(event));
    const text = event_key_text(event);
    try testing.expectEqualStrings("a", text.ptr.?[0..text.len]);
    try testing.expect(event_key_matches(event, 'a', 0));
    try testing.expect(!event_key_matches(event, 'b', 0));
}

test "c api: kitty shift+a" {
    const parser = parser_new() orelse return error.OutOfMemory;
    defer parser_free(parser);

    const input = "\x1b[97:65;2u";
    var event: ?*const CEvent = null;
    var n: usize = 0;
    try testing.expectEqual(.ok, parseBytes(parser, input, &event, &n));
    try testing.expectEqual(input.len, n);
    try testing.expectEqual(EventType.key_press, event_get_type(event));
    try testing.expectEqual(@as(u32, 'a'), event_key_codepoint(event));
    try testing.expectEqual(@as(u32, 'A'), event_key_shifted_codepoint(event));
    try testing.expectEqual(@as(u8, 1), event_key_mods(event)); // VAXIS_MOD_SHIFT
    try testing.expect(event_key_matches(event, 'a', 1));
    try testing.expect(event_key_matches(event, 'A', 0));
}

test "c api: sgr mouse motion" {
    const parser = parser_new() orelse return error.OutOfMemory;
    defer parser_free(parser);

    const input = "\x1b[<35;1;1m";
    var event: ?*const CEvent = null;
    var n: usize = 0;
    try testing.expectEqual(.ok, parseBytes(parser, input, &event, &n));
    try testing.expectEqual(EventType.mouse, event_get_type(event));
    try testing.expectEqual(@as(i16, 0), event_mouse_col(event));
    try testing.expectEqual(@as(i16, 0), event_mouse_row(event));
    try testing.expectEqual(@as(u8, 3), event_mouse_button(event)); // VAXIS_MOUSE_NONE
    try testing.expectEqual(@as(u8, 2), event_mouse_type(event)); // VAXIS_MOUSE_MOTION
    // key accessors return zero values for a mouse event
    try testing.expectEqual(@as(u32, 0), event_key_codepoint(event));
    try testing.expectEqual(@as(usize, 0), event_key_text(event).len);
}

test "c api: osc 52 paste is parser-owned" {
    const parser = parser_new() orelse return error.OutOfMemory;
    defer parser_free(parser);

    const input = "\x1b]52;c;b3NjNTIgcGFzdGU=\x1b\\";
    var event: ?*const CEvent = null;
    var n: usize = 0;
    try testing.expectEqual(.ok, parseBytes(parser, input, &event, &n));
    try testing.expectEqual(EventType.paste, event_get_type(event));
    const text = event_paste_text(event);
    try testing.expectEqualStrings("osc52 paste", text.ptr.?[0..text.len]);
    // the next parse releases the paste; free must not double free
    try testing.expectEqual(.ok, parseBytes(parser, "a", &event, &n));
    try testing.expectEqual(EventType.key_press, event_get_type(event));
}

test "c api: incomplete sequence yields null event and zero consumed" {
    const parser = parser_new() orelse return error.OutOfMemory;
    defer parser_free(parser);

    const input = "\x1b[";
    var event: ?*const CEvent = null;
    var n: usize = 1;
    try testing.expectEqual(.ok, parseBytes(parser, input, &event, &n));
    try testing.expectEqual(@as(?*const CEvent, null), event);
    try testing.expectEqual(EventType.none, event_get_type(event));
    try testing.expectEqual(@as(usize, 0), n);
}

test "c api: in-band resize" {
    const parser = parser_new() orelse return error.OutOfMemory;
    defer parser_free(parser);

    const input = "\x1b[48;24;80;480;1440t";
    var event: ?*const CEvent = null;
    var n: usize = 0;
    try testing.expectEqual(.ok, parseBytes(parser, input, &event, &n));
    try testing.expectEqual(EventType.winsize, event_get_type(event));
    try testing.expectEqual(@as(u16, 24), event_winsize_rows(event));
    try testing.expectEqual(@as(u16, 80), event_winsize_cols(event));
    try testing.expectEqual(@as(u16, 1440), event_winsize_x_pixel(event));
    try testing.expectEqual(@as(u16, 480), event_winsize_y_pixel(event));
}

test "c api: color report" {
    const parser = parser_new() orelse return error.OutOfMemory;
    defer parser_free(parser);

    const input = "\x1b]11;rgb:ffff/8080/0000\x1b\\";
    var event: ?*const CEvent = null;
    var n: usize = 0;
    try testing.expectEqual(.ok, parseBytes(parser, input, &event, &n));
    try testing.expectEqual(EventType.color_report, event_get_type(event));
    try testing.expectEqual(@as(u8, 1), event_color_report_kind(event)); // VAXIS_COLOR_BG
    const rgb = event_color_report_rgb(event);
    try testing.expectEqual(@as(u8, 0xff), rgb.r);
    try testing.expectEqual(@as(u8, 0x80), rgb.g);
    try testing.expectEqual(@as(u8, 0x00), rgb.b);
}

test "c api: malformed osc payload is consumed with a null event" {
    const parser = parser_new() orelse return error.OutOfMemory;
    defer parser_free(parser);

    const input = "\x1b]4;1;rgb:zz/zz/zz\x1b\\";
    var event: ?*const CEvent = null;
    var n: usize = 0;
    try testing.expectEqual(.ok, parseBytes(parser, input, &event, &n));
    try testing.expectEqual(@as(?*const CEvent, null), event);
    try testing.expectEqual(input.len, n);
}

test "c api: oversized grapheme text is truncated at a utf8 boundary" {
    const parser = parser_new() orelse return error.OutOfMemory;
    defer parser_free(parser);

    // one grapheme cluster larger than the 256 byte text buffer
    const input = ("\xE2\x98\xBA\xE2\x80\x8D" ** 60) ++ "\xE2\x98\xBA";
    var event: ?*const CEvent = null;
    var n: usize = 0;
    try testing.expectEqual(.ok, parseBytes(parser, input, &event, &n));
    try testing.expectEqual(input.len, n);
    try testing.expectEqual(EventType.key_press, event_get_type(event));
    try testing.expectEqual(@as(u32, Key.multicodepoint), event_key_codepoint(event));

    const text = event_key_text(event);
    try testing.expect(text.len < input.len); // truncated
    try testing.expect(text.len <= 256);
    try testing.expect(std.unicode.utf8ValidateSlice(text.ptr.?[0..text.len])); // but never split
}

test "c api: key name lookup" {
    try testing.expectEqual(@as(u32, Key.enter), key_from_name("enter", 5));
    try testing.expectEqual(@as(u32, Key.f1), key_from_name("f1", 2));
    try testing.expectEqual(@as(u32, 0), key_from_name("not_a_key", 9));
}

test "c api: null arguments" {
    var event: ?*const CEvent = null;
    var n: usize = 0;
    try testing.expectEqual(.err_invalid, parser_parse(null, "a", 1, &event, &n));
    const parser = parser_new() orelse return error.OutOfMemory;
    defer parser_free(parser);
    try testing.expectEqual(.err_invalid, parser_parse(parser, null, 1, &event, &n));
    try testing.expectEqual(.err_invalid, parser_parse(parser, "a", 1, null, &n));
    try testing.expectEqual(.err_invalid, parser_parse(parser, "a", 1, &event, null));
    // accessors are NULL-safe
    try testing.expectEqual(EventType.none, event_get_type(null));
    try testing.expectEqual(@as(u32, 0), event_key_codepoint(null));
    try testing.expectEqual(@as(?[*]const u8, null), event_key_text(null).ptr);
    try testing.expect(!event_key_matches(null, 'a', 0));
}
