const std = @import("std");
const Self = @This();

pub const Record = struct {
    top_left: []const u8,
    top_edge: []const u8,
    top_right: []const u8,
    right_edge: []const u8,
    bottom_right: []const u8,
    bottom_edge: []const u8,
    bottom_left: []const u8,
    left_edge: []const u8,
};

pub const bold: Record = .{
    .top_left = "┏",
    .top_edge = "━",
    .top_right = "┓",
    .right_edge = "┃",
    .bottom_right = "┛",
    .bottom_edge = "━",
    .bottom_left = "┗",
    .left_edge = "┃",
};

pub const classic: Record = .{
    .top_left = "+",
    .top_edge = "-",
    .top_right = "+",
    .right_edge = "|",
    .bottom_right = "+",
    .bottom_edge = "-",
    .bottom_left = "+",
    .left_edge = "|",
};

pub const double: Record = .{
    .top_left = "╔",
    .top_edge = "═",
    .top_right = "╗",
    .right_edge = "║",
    .bottom_right = "╝",
    .bottom_edge = "═",
    .bottom_left = "╚",
    .left_edge = "║",
};

pub const double_single: Record = .{
    .top_left = "╒",
    .top_edge = "═",
    .top_right = "╕",
    .right_edge = "│",
    .bottom_right = "╛",
    .bottom_edge = "═",
    .bottom_left = "╘",
    .left_edge = "│",
};

pub const round: Record = .{
    .top_left = "╭",
    .top_edge = "─",
    .top_right = "╮",
    .right_edge = "│",
    .bottom_right = "╯",
    .bottom_edge = "─",
    .bottom_left = "╰",
    .left_edge = "│",
};

pub const single: Record = .{
    .top_left = "┌",
    .top_edge = "─",
    .top_right = "┐",
    .right_edge = "│",
    .bottom_right = "┘",
    .bottom_edge = "─",
    .bottom_left = "└",
    .left_edge = "│",
};

pub const single_double: Record = .{
    .top_left = "╓",
    .top_edge = "─",
    .top_right = "╖",
    .right_edge = "║",
    .bottom_right = "╜",
    .bottom_edge = "─",
    .bottom_left = "╙",
    .left_edge = "║",
};
