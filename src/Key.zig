const std = @import("std");
const testing = std.testing;

const Key = @This();

/// Modifier Keys for a Key Match Event.
pub const Modifiers = packed struct(u8) {
    shift: bool = false,
    alt: bool = false,
    ctrl: bool = false,
    super: bool = false,
    hyper: bool = false,
    meta: bool = false,
    caps_lock: bool = false,
    num_lock: bool = false,

    pub fn eql(self: Modifiers, other: Modifiers) bool {
        const a: u8 = @bitCast(self);
        const b: u8 = @bitCast(other);
        return a == b;
    }
};

/// Flags for the Kitty Protocol.
pub const KittyFlags = packed struct(u5) {
    disambiguate: bool = true,
    report_events: bool = false,
    report_alternate_keys: bool = true,
    report_all_as_ctl_seqs: bool = true,
    report_text: bool = true,
};

/// the unicode codepoint of the key event.
codepoint: u21,

/// the text generated from the key event. The underlying slice has a limited
/// lifetime. Vaxis maintains an internal ring buffer to temporarily store text.
/// If the application needs these values longer than the lifetime of the event
/// it must copy the data.
text: ?[]const u8 = null,

/// the shifted codepoint of this key event. This will only be present if the
/// Shift modifier was used to generate the event
shifted_codepoint: ?u21 = null,

/// the key that would have been pressed on a standard keyboard layout. This is
/// useful for shortcut matching
base_layout_codepoint: ?u21 = null,

mods: Modifiers = .{},

// matches follows a loose matching algorithm for key matches.
// 1. If the codepoint and modifiers are exact matches, after removing caps_lock
//    and num_lock
// 2. If the utf8 encoding of the codepoint matches the text, after removing
//    num_lock
// 3. If there is a shifted codepoint and it matches after removing the shift
//    modifier from self, after removing caps_lock and num_lock
pub fn matches(self: Key, cp: u21, mods: Modifiers) bool {
    // rule 1
    if (self.matchExact(cp, mods)) return true;

    // rule 2
    if (self.matchText(cp, mods)) return true;

    // rule 3
    if (self.matchShiftedCodepoint(cp, mods)) return true;

    return false;
}

/// matches against any of the provided codepoints.
pub fn matchesAny(self: Key, cps: []const u21, mods: Modifiers) bool {
    for (cps) |cp| {
        if (self.matches(cp, mods)) return true;
    }
    return false;
}

/// matches base layout codes, useful for shortcut matching when an alternate key
/// layout is used
pub fn matchShortcut(self: Key, cp: u21, mods: Modifiers) bool {
    if (self.base_layout_codepoint == null) return false;
    return cp == self.base_layout_codepoint.? and std.meta.eql(self.mods, mods);
}

/// matches keys that aren't upper case versions when shifted. For example, shift
/// + semicolon produces a colon. The key can be matched against shift +
/// semicolon or just colon...or shift + ctrl + ; or just ctrl + :
pub fn matchShiftedCodepoint(self: Key, cp: u21, mods: Modifiers) bool {
    if (self.shifted_codepoint == null) return false;
    if (!self.mods.shift) return false;
    var self_mods = self.mods;
    self_mods.shift = false;
    self_mods.caps_lock = false;
    self_mods.num_lock = false;
    var tgt_mods = mods;
    tgt_mods.caps_lock = false;
    tgt_mods.num_lock = false;
    return cp == self.shifted_codepoint.? and std.meta.eql(self_mods, mods);
}

/// matches when the utf8 encoding of the codepoint and relevant mods matches the
/// text of the key. This function will consume Shift and Caps Lock when matching
pub fn matchText(self: Key, cp: u21, mods: Modifiers) bool {
    // return early if we have no text
    if (self.text == null) return false;

    var self_mods = self.mods;
    self_mods.num_lock = false;
    self_mods.shift = false;
    self_mods.caps_lock = false;
    var arg_mods = mods;

    // TODO: Use zg case_data for full unicode support. We'll need to allocate the case data
    // somewhere
    const _cp: u21 = if (cp < 128 and (mods.shift or mods.caps_lock))
        // Uppercase our codepoint
        std.ascii.toUpper(@intCast(cp))
    else
        cp;

    arg_mods.num_lock = false;
    arg_mods.shift = false;
    arg_mods.caps_lock = false;

    var buf: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(_cp, &buf) catch return false;
    return std.mem.eql(u8, self.text.?, buf[0..n]) and std.meta.eql(self_mods, arg_mods);
}

// The key must exactly match the codepoint and modifiers. caps_lock and
// num_lock are removed before matching
pub fn matchExact(self: Key, cp: u21, mods: Modifiers) bool {
    var self_mods = self.mods;
    self_mods.caps_lock = false;
    self_mods.num_lock = false;
    var tgt_mods = mods;
    tgt_mods.caps_lock = false;
    tgt_mods.num_lock = false;
    return self.codepoint == cp and std.meta.eql(self_mods, tgt_mods);
}

/// True if the key is a single modifier (ie: left_shift)
pub fn isModifier(self: Key) bool {
    return self.codepoint == left_shift or
        self.codepoint == left_alt or
        self.codepoint == left_super or
        self.codepoint == left_hyper or
        self.codepoint == left_control or
        self.codepoint == left_meta or
        self.codepoint == right_shift or
        self.codepoint == right_alt or
        self.codepoint == right_super or
        self.codepoint == right_hyper or
        self.codepoint == right_control or
        self.codepoint == right_meta;
}

// a few special keys that we encode as their actual ascii value
pub const tab: u21 = 0x09;
pub const enter: u21 = 0x0D;
pub const escape: u21 = 0x1B;
pub const space: u21 = 0x20;
pub const backspace: u21 = 0x7F;

/// multicodepoint is a key which generated text but cannot be expressed as a
/// single codepoint. The value is the maximum unicode codepoint + 1
pub const multicodepoint: u21 = 1_114_112 + 1;

// kitty encodes these keys directly in the private use area. We reuse those
// mappings
pub const insert: u21 = 57348;
pub const delete: u21 = 57349;
pub const left: u21 = 57350;
pub const right: u21 = 57351;
pub const up: u21 = 57352;
pub const down: u21 = 57353;
pub const page_up: u21 = 57354;
pub const page_down: u21 = 57355;
pub const home: u21 = 57356;
pub const end: u21 = 57357;
pub const caps_lock: u21 = 57358;
pub const scroll_lock: u21 = 57359;
pub const num_lock: u21 = 57360;
pub const print_screen: u21 = 57361;
pub const pause: u21 = 57362;
pub const menu: u21 = 57363;
pub const f1: u21 = 57364;
pub const f2: u21 = 57365;
pub const f3: u21 = 57366;
pub const f4: u21 = 57367;
pub const f5: u21 = 57368;
pub const f6: u21 = 57369;
pub const f7: u21 = 57370;
pub const f8: u21 = 57371;
pub const f9: u21 = 57372;
pub const f10: u21 = 57373;
pub const f11: u21 = 57374;
pub const f12: u21 = 57375;
pub const f13: u21 = 57376;
pub const f14: u21 = 57377;
pub const f15: u21 = 57378;
pub const @"f16": u21 = 57379;
pub const f17: u21 = 57380;
pub const f18: u21 = 57381;
pub const f19: u21 = 57382;
pub const f20: u21 = 57383;
pub const f21: u21 = 57384;
pub const f22: u21 = 57385;
pub const f23: u21 = 57386;
pub const f24: u21 = 57387;
pub const f25: u21 = 57388;
pub const f26: u21 = 57389;
pub const f27: u21 = 57390;
pub const f28: u21 = 57391;
pub const f29: u21 = 57392;
pub const f30: u21 = 57393;
pub const f31: u21 = 57394;
pub const @"f32": u21 = 57395;
pub const f33: u21 = 57396;
pub const f34: u21 = 57397;
pub const f35: u21 = 57398;
pub const kp_0: u21 = 57399;
pub const kp_1: u21 = 57400;
pub const kp_2: u21 = 57401;
pub const kp_3: u21 = 57402;
pub const kp_4: u21 = 57403;
pub const kp_5: u21 = 57404;
pub const kp_6: u21 = 57405;
pub const kp_7: u21 = 57406;
pub const kp_8: u21 = 57407;
pub const kp_9: u21 = 57408;
pub const kp_decimal: u21 = 57409;
pub const kp_divide: u21 = 57410;
pub const kp_multiply: u21 = 57411;
pub const kp_subtract: u21 = 57412;
pub const kp_add: u21 = 57413;
pub const kp_enter: u21 = 57414;
pub const kp_equal: u21 = 57415;
pub const kp_separator: u21 = 57416;
pub const kp_left: u21 = 57417;
pub const kp_right: u21 = 57418;
pub const kp_up: u21 = 57419;
pub const kp_down: u21 = 57420;
pub const kp_page_up: u21 = 57421;
pub const kp_page_down: u21 = 57422;
pub const kp_home: u21 = 57423;
pub const kp_end: u21 = 57424;
pub const kp_insert: u21 = 57425;
pub const kp_delete: u21 = 57426;
pub const kp_begin: u21 = 57427;
pub const media_play: u21 = 57428;
pub const media_pause: u21 = 57429;
pub const media_play_pause: u21 = 57430;
pub const media_reverse: u21 = 57431;
pub const media_stop: u21 = 57432;
pub const media_fast_forward: u21 = 57433;
pub const media_rewind: u21 = 57434;
pub const media_track_next: u21 = 57435;
pub const media_track_previous: u21 = 57436;
pub const media_record: u21 = 57437;
pub const lower_volume: u21 = 57438;
pub const raise_volume: u21 = 57439;
pub const mute_volume: u21 = 57440;
pub const left_shift: u21 = 57441;
pub const left_control: u21 = 57442;
pub const left_alt: u21 = 57443;
pub const left_super: u21 = 57444;
pub const left_hyper: u21 = 57445;
pub const left_meta: u21 = 57446;
pub const right_shift: u21 = 57447;
pub const right_control: u21 = 57448;
pub const right_alt: u21 = 57449;
pub const right_super: u21 = 57450;
pub const right_hyper: u21 = 57451;
pub const right_meta: u21 = 57452;
pub const iso_level_3_shift: u21 = 57453;
pub const iso_level_5_shift: u21 = 57454;

pub const name_map = blk: {
    @setEvalBranchQuota(2000);
    break :blk std.StaticStringMap(u21).initComptime(.{
        // common names
        .{ "plus", '+' },
        .{ "minus", '-' },
        .{ "colon", ':' },
        .{ "semicolon", ';' },
        .{ "comma", ',' },

        // special keys
        .{ "tab", tab },
        .{ "enter", enter },
        .{ "escape", escape },
        .{ "space", space },
        .{ "backspace", backspace },
        .{ "insert", insert },
        .{ "delete", delete },
        .{ "left", left },
        .{ "right", right },
        .{ "up", up },
        .{ "down", down },
        .{ "page_up", page_up },
        .{ "page_down", page_down },
        .{ "home", home },
        .{ "end", end },
        .{ "caps_lock", caps_lock },
        .{ "scroll_lock", scroll_lock },
        .{ "num_lock", num_lock },
        .{ "print_screen", print_screen },
        .{ "pause", pause },
        .{ "menu", menu },
        .{ "f1", f1 },
        .{ "f2", f2 },
        .{ "f3", f3 },
        .{ "f4", f4 },
        .{ "f5", f5 },
        .{ "f6", f6 },
        .{ "f7", f7 },
        .{ "f8", f8 },
        .{ "f9", f9 },
        .{ "f10", f10 },
        .{ "f11", f11 },
        .{ "f12", f12 },
        .{ "f13", f13 },
        .{ "f14", f14 },
        .{ "f15", f15 },
        .{ "f16", @"f16" },
        .{ "f17", f17 },
        .{ "f18", f18 },
        .{ "f19", f19 },
        .{ "f20", f20 },
        .{ "f21", f21 },
        .{ "f22", f22 },
        .{ "f23", f23 },
        .{ "f24", f24 },
        .{ "f25", f25 },
        .{ "f26", f26 },
        .{ "f27", f27 },
        .{ "f28", f28 },
        .{ "f29", f29 },
        .{ "f30", f30 },
        .{ "f31", f31 },
        .{ "f32", @"f32" },
        .{ "f33", f33 },
        .{ "f34", f34 },
        .{ "f35", f35 },
        .{ "kp_0", kp_0 },
        .{ "kp_1", kp_1 },
        .{ "kp_2", kp_2 },
        .{ "kp_3", kp_3 },
        .{ "kp_4", kp_4 },
        .{ "kp_5", kp_5 },
        .{ "kp_6", kp_6 },
        .{ "kp_7", kp_7 },
        .{ "kp_8", kp_8 },
        .{ "kp_9", kp_9 },
        .{ "kp_decimal", kp_decimal },
        .{ "kp_divide", kp_divide },
        .{ "kp_multiply", kp_multiply },
        .{ "kp_subtract", kp_subtract },
        .{ "kp_add", kp_add },
        .{ "kp_enter", kp_enter },
        .{ "kp_equal", kp_equal },
        .{ "kp_separator", kp_separator },
        .{ "kp_left", kp_left },
        .{ "kp_right", kp_right },
        .{ "kp_up", kp_up },
        .{ "kp_down", kp_down },
        .{ "kp_page_up", kp_page_up },
        .{ "kp_page_down", kp_page_down },
        .{ "kp_home", kp_home },
        .{ "kp_end", kp_end },
        .{ "kp_insert", kp_insert },
        .{ "kp_delete", kp_delete },
        .{ "kp_begin", kp_begin },
        .{ "media_play", media_play },
        .{ "media_pause", media_pause },
        .{ "media_play_pause", media_play_pause },
        .{ "media_reverse", media_reverse },
        .{ "media_stop", media_stop },
        .{ "media_fast_forward", media_fast_forward },
        .{ "media_rewind", media_rewind },
        .{ "media_track_next", media_track_next },
        .{ "media_track_previous", media_track_previous },
        .{ "media_record", media_record },
        .{ "lower_volume", lower_volume },
        .{ "raise_volume", raise_volume },
        .{ "mute_volume", mute_volume },
        .{ "left_shift", left_shift },
        .{ "left_control", left_control },
        .{ "left_alt", left_alt },
        .{ "left_super", left_super },
        .{ "left_hyper", left_hyper },
        .{ "left_meta", left_meta },
        .{ "right_shift", right_shift },
        .{ "right_control", right_control },
        .{ "right_alt", right_alt },
        .{ "right_super", right_super },
        .{ "right_hyper", right_hyper },
        .{ "right_meta", right_meta },
        .{ "iso_level_3_shift", iso_level_3_shift },
        .{ "iso_level_5_shift", iso_level_5_shift },
    });
};

test "matches 'a'" {
    const key: Key = .{
        .codepoint = 'a',
        .mods = .{ .num_lock = true },
        .text = "a",
    };
    try testing.expect(key.matches('a', .{}));
    try testing.expect(!key.matches('a', .{ .shift = true }));
}

test "matches 'shift+a'" {
    const key: Key = .{
        .codepoint = 'a',
        .shifted_codepoint = 'A',
        .mods = .{ .shift = true },
        .text = "A",
    };
    try testing.expect(key.matches('a', .{ .shift = true }));
    try testing.expect(!key.matches('a', .{}));
    try testing.expect(key.matches('A', .{}));
    try testing.expect(!key.matches('A', .{ .ctrl = true }));
}

test "matches 'shift+tab'" {
    const key: Key = .{
        .codepoint = Key.tab,
        .mods = .{ .shift = true, .num_lock = true },
    };
    try testing.expect(key.matches(Key.tab, .{ .shift = true }));
    try testing.expect(!key.matches(Key.tab, .{}));
}

test "matches 'shift+;'" {
    const key: Key = .{
        .codepoint = ';',
        .shifted_codepoint = ':',
        .mods = .{ .shift = true },
        .text = ":",
    };
    try testing.expect(key.matches(';', .{ .shift = true }));
    try testing.expect(key.matches(':', .{}));

    const colon: Key = .{
        .codepoint = ':',
        .mods = .{},
    };
    try testing.expect(colon.matches(':', .{}));
}

test "name_map" {
    try testing.expectEqual(insert, name_map.get("insert"));
}
