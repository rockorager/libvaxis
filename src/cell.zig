pub const Cell = struct {
    char: Character,
    style: Style = .{},
};

pub const Character = struct {
    grapheme: []const u8,
    width: usize,
};

pub const Style = struct {
    fg: Color = .default,
    bg: Color = .default,
    ul: Color = .default,
    ul_style: UnderlineStyle = .off,
    url: ?[]const u8 = null,
    url_params: ?[]const u8 = null,
};

pub const Color = union(enum) {
    default,
    index: u8,
    rgb: [3]u8,
};

pub const UnderlineStyle = enum {
    off,
    single,
    double,
    curly,
    dotted,
    dashed,
};
