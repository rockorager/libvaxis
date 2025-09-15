const std = @import("std");
const Self = @This();

const BorderStyle = enum {
    arrow,
    bold,
    classic,
    double,
    doubleSingle,
    round,
    single,
    singleDouble,
};

const BorderCharacterPosition = enum {
    topLeft,
    topCenter,
    topRight,
    rightCenter,
    bottomRight,
    bottomCenter,
    bottomLeft,
    leftCenter,
};

pub const BorderCharacters = struct {
    topLeft: []const u8,
    topCenter: []const u8,
    topRight: []const u8,
    rightCenter: []const u8,
    bottomRight: []const u8,
    bottomCenter: []const u8,
    bottomLeft: []const u8,
    leftCenter: []const u8,
};

const BorderPosition = enum { bottom, left, right, top };

// arrow: BorderCharacters = .{
//     .topLeft = "↘",
//     .topCenter = "↓",
//     .topRight = "↙",
//     .rightCenter = "←",
//     .bottomRight = "↖",
//     .bottomCenter = "↑",
//     .bottomLeft = "↗",
//     .leftCenter = "→",
// },

pub const bold: BorderCharacters = .{
    .topLeft = "┏",
    .topCenter = "━",
    .topRight = "┓",
    .rightCenter = "┃",
    .bottomRight = "┛",
    .bottomCenter = "━",
    .bottomLeft = "┗",
    .leftCenter = "┃",
};

pub const classic: BorderCharacters = .{
    .topLeft = "+",
    .topCenter = "-",
    .topRight = "+",
    .rightCenter = "|",
    .bottomRight = "+",
    .bottomCenter = "-",
    .bottomLeft = "+",
    .leftCenter = "|",
};

pub const double: BorderCharacters = .{
    .topLeft = "╔",
    .topCenter = "═",
    .topRight = "╗",
    .rightCenter = "║",
    .bottomRight = "╝",
    .bottomCenter = "═",
    .bottomLeft = "╚",
    .leftCenter = "║",
};

pub const doubleSingle: BorderCharacters = .{
    .topLeft = "╒",
    .topCenter = "═",
    .topRight = "╕",
    .rightCenter = "│",
    .bottomRight = "╛",
    .bottomCenter = "═",
    .bottomLeft = "╘",
    .leftCenter = "│",
};

pub const round: BorderCharacters = .{
    .topLeft = "╭",
    .topCenter = "─",
    .topRight = "╮",
    .rightCenter = "│",
    .bottomRight = "╯",
    .bottomCenter = "─",
    .bottomLeft = "╰",
    .leftCenter = "│",
};

pub const single: BorderCharacters = .{
    .topLeft = "┌",
    .topCenter = "─",
    .topRight = "┐",
    .rightCenter = "│",
    .bottomRight = "┘",
    .bottomCenter = "─",
    .bottomLeft = "└",
    .leftCenter = "│",
};

pub const singleDouble: BorderCharacters = .{
    .topLeft = "╓",
    .topCenter = "─",
    .topRight = "╖",
    .rightCenter = "║",
    .bottomRight = "╜",
    .bottomCenter = "─",
    .bottomLeft = "╙",
    .leftCenter = "║",
};
