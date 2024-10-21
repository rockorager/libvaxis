/// A mouse event
pub const Mouse = @This();

pub const Shape = enum {
    default,
    text,
    pointer,
    help,
    progress,
    wait,
    @"ew-resize",
    @"ns-resize",
    cell,
};

pub const Button = enum(u8) {
    left,
    middle,
    right,
    none,
    wheel_up = 64,
    wheel_down = 65,
    wheel_right = 66,
    wheel_left = 67,
    button_8 = 128,
    button_9 = 129,
    button_10 = 130,
    button_11 = 131,
};

pub const Modifiers = packed struct(u3) {
    shift: bool = false,
    alt: bool = false,
    ctrl: bool = false,
};

pub const Type = enum {
    press,
    release,
    motion,
    drag,
};

col: u16,
row: u16,
xoffset: u16 = 0,
yoffset: u16 = 0,
button: Button,
mods: Modifiers,
type: Type,
