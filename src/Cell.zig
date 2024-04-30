const std = @import("std");
const Image = @import("Image.zig");

char: Character = .{},
style: Style = .{},
link: Hyperlink = .{},
image: ?Image.Placement = null,
default: bool = false,

/// Segment is a contiguous run of text that has a constant style
pub const Segment = struct {
    text: []const u8,
    style: Style = .{},
    link: Hyperlink = .{},
};

pub const Character = struct {
    grapheme: []const u8 = " ",
    /// width should only be provided when the application is sure the terminal
    /// will measure the same width. This can be ensure by using the gwidth method
    /// included in libvaxis. If width is 0, libvaxis will measure the glyph at
    /// render time
    width: usize = 1,
};

pub const CursorShape = enum {
    default,
    block_blink,
    block,
    underline_blink,
    underline,
    beam_blink,
    beam,
};

pub const Hyperlink = struct {
    uri: []const u8 = "",
    /// ie "id=app-1234"
    params: []const u8 = "",
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

    bold: bool = false,
    dim: bool = false,
    italic: bool = false,
    blink: bool = false,
    reverse: bool = false,
    invisible: bool = false,
    strikethrough: bool = false,

    pub fn eql(a: Style, b: Style) bool {
        const SGRBits = packed struct {
            bold: bool,
            dim: bool,
            italic: bool,
            blink: bool,
            reverse: bool,
            invisible: bool,
            strikethrough: bool,
        };
        const a_sgr: SGRBits = .{
            .bold = a.bold,
            .dim = a.dim,
            .italic = a.italic,
            .blink = a.blink,
            .reverse = a.reverse,
            .invisible = a.invisible,
            .strikethrough = a.strikethrough,
        };
        const b_sgr: SGRBits = .{
            .bold = b.bold,
            .dim = b.dim,
            .italic = b.italic,
            .blink = b.blink,
            .reverse = b.reverse,
            .invisible = b.invisible,
            .strikethrough = b.strikethrough,
        };
        const a_cast: u7 = @bitCast(a_sgr);
        const b_cast: u7 = @bitCast(b_sgr);
        return a_cast == b_cast and
            Color.eql(a.fg, b.fg) and
            Color.eql(a.bg, b.bg) and
            Color.eql(a.ul, b.ul) and
            a.ul_style == b.ul_style;
    }
};

pub const Color = union(enum) {
    default,
    index: u8,
    rgb: [3]u8,

    pub fn eql(a: Color, b: Color) bool {
        switch (a) {
            .default => return b == .default,
            .index => |a_idx| {
                switch (b) {
                    .index => |b_idx| return a_idx == b_idx,
                    else => return false,
                }
            },
            .rgb => |a_rgb| {
                switch (b) {
                    .rgb => |b_rgb| return a_rgb[0] == b_rgb[0] and
                        a_rgb[1] == b_rgb[1] and
                        a_rgb[2] == b_rgb[2],
                    else => return false,
                }
            },
        }
    }

    pub fn rgbFromUint(val: u24) Color {
        const r_bits = val & 0b11111111_00000000_00000000;
        const g_bits = val & 0b00000000_11111111_00000000;
        const b_bits = val & 0b00000000_00000000_11111111;
        const rgb = [_]u8{
            @truncate(r_bits >> 16),
            @truncate(g_bits >> 8),
            @truncate(b_bits),
        };
        return .{ .rgb = rgb };
    }
};
