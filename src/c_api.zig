//! Main file for the C API for libvaxis.
//! The interface is documented in include/vaxis.h
//! Events are opaque handles read through accessor
//! functions so payloads can grow without breaking the ABI.
//!
//! Functions are plain callconv(.c) fns so they can be called from tests;
//! the comptime block below exports each one with a vaxis_ prefix.
const std = @import("std");
const vaxis = @import("vaxis");

const Color = vaxis.Color;
const Key = vaxis.Key;
const Mouse = vaxis.Mouse;
const Parser = vaxis.Parser;
const Winsize = vaxis.Winsize;

const allocator = std.heap.c_allocator;

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
    parser: Parser,
    event: CEvent,
    text_buf: [256]u8,
    paste: ?[]const u8,
};

pub fn parser_new() callconv(.c) ?*CParser {
    const parser = allocator.create(CParser) catch return null;
    parser.* = .{
        .parser = .{},
        .event = .{},
        .text_buf = undefined,
        .paste = null,
    };
    return parser;
}

pub fn parser_free(parser: ?*CParser) callconv(.c) void {
    const p = parser orelse return;
    if (p.paste) |paste| allocator.free(paste);
    allocator.destroy(p);
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
    p.event = .{};
    if (p.paste) |paste| {
        allocator.free(paste);
        p.paste = null;
    }

    if (input_len == 0) return .ok;
    const in = input orelse return .err_invalid;

    const result = p.parser.parse(in[0..input_len], allocator) catch |err| {
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
