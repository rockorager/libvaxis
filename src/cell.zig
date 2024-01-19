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
    url: ?[]const u8 = null,
    url_params: ?[]const u8 = null,
};

pub const Color = union(enum) {
    default,
    index: u8,
    rgb: [3]u8,
};
