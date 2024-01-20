const Key = @This();

pub const Modifiers = packed struct(u8) {
    shift: bool = false,
    alt: bool = false,
    ctrl: bool = false,
    super: bool = false,
    hyper: bool = false,
    meta: bool = false,
    caps_lock: bool = false,
    num_lock: bool = false,
};

/// the unicode codepoint of the key event. This can be greater than the maximum
/// allowable unicode codepoint for special keys
codepoint: u21,

/// the text generated from the key event, if any
text: ?[]const u8 = null,

/// the shifted codepoint of this key event. This will only be present if the
/// Shift modifier was used to generate the event
shifted_codepoint: ?u21 = null,

/// the key that would have been pressed on a standard keyboard layout. This is
/// useful for shortcut matching
base_layout_codepoint: ?u21 = null,

mods: Modifiers = .{},

// a few special keys that we encode as their actual ascii value
pub const enter: u21 = 0x0D;
pub const tab: u21 = 0x09;
pub const escape: u21 = 0x1B;
pub const space: u21 = 0x20;
pub const backspace: u21 = 0x7F;

// kitty encodes these keys directly in the private use area. We reuse those
// mappings
pub const caps_lock: u21 = 57358;
pub const scroll_lock: u21 = 57359;
pub const num_lock: u21 = 57360;
pub const print_screen: u21 = 57361;
pub const pause: u21 = 57362;
pub const menu: u21 = 57363;
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
pub const kp_begin: u21 = 57427;
// TODO: Finish the kitty keys

const MAX_UNICODE: u21 = 1_114_112;
pub const f1: u21 = MAX_UNICODE + 1;
pub const f2: u21 = MAX_UNICODE + 2;
pub const f3: u21 = MAX_UNICODE + 3;
pub const f4: u21 = MAX_UNICODE + 4;
pub const f5: u21 = MAX_UNICODE + 5;
pub const f6: u21 = MAX_UNICODE + 6;
pub const f7: u21 = MAX_UNICODE + 7;
pub const f8: u21 = MAX_UNICODE + 8;
pub const f9: u21 = MAX_UNICODE + 9;
pub const f10: u21 = MAX_UNICODE + 10;
pub const f11: u21 = MAX_UNICODE + 11;
pub const f12: u21 = MAX_UNICODE + 12;
pub const up: u21 = MAX_UNICODE + 13;
pub const down: u21 = MAX_UNICODE + 14;
pub const right: u21 = MAX_UNICODE + 15;
pub const left: u21 = MAX_UNICODE + 16;
pub const page_up: u21 = MAX_UNICODE + 17;
pub const page_down: u21 = MAX_UNICODE + 18;
pub const home: u21 = MAX_UNICODE + 19;
pub const end: u21 = MAX_UNICODE + 20;
pub const insert: u21 = MAX_UNICODE + 21;
pub const delete: u21 = MAX_UNICODE + 22;
