pub const Cell = struct {
    char: Character = .{},
    style: Style = .{},
};

pub const Character = struct {
    grapheme: []const u8 = " ",
    width: usize = 1,
};

pub const Style = struct {
    pub const Underline = enum {
        off,
        single,
        double,
        curly,
        dotted,
        dashed,
    };

    fg: Color = .default,
    bg: Color = .default,
    ul: Color = .default,
    ul_style: Underline = .off,
    // TODO: url should maybe go outside of style. We'll need to allocate these
    // in the internal screen
    url: ?[]const u8 = null,
    url_params: ?[]const u8 = null,

    bold: bool = false,
    dim: bool = false,
    italic: bool = false,
    blink: bool = false,
    reverse: bool = false,
    invisible: bool = false,
    strikethrough: bool = false,
};

pub const Color = union(enum) {
    default,
    index: u8,
    rgb: [3]u8,
};
