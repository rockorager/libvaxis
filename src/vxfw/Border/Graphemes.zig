//! Contains types and values for graphemes that are used for drawing borders.

const std = @import("std");
const Self = @This();

/// A record containing graphemes that are used for drawing borders.
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

/// Graphemes for bold border.
///
/// ```
/// ┏━━━━━━┓
/// ┃ Bold ┃
/// ┗━━━━━━┛
/// ```
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

/// Graphemes for classic border.
///
/// ```
/// +---------+
/// | Classic |
/// +---------+
/// ```
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

/// Graphemes for double border.
///
/// ```
/// ╔════════╗
/// ║ Double ║
/// ╚════════╝
/// ```
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

/// Graphemes for double-single border.
///
/// ```
/// ╒═══════════════╕
/// │ Double Single │
/// ╘═══════════════╛
/// ```
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

/// Graphemes for round border.
///
/// ```
/// ╭───────╮
/// │ Round │
/// ╰───────╯
/// ```
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

/// Graphemes for single border.
///
/// ```
/// ┌────────┐
/// │ Single │
/// └────────┘
/// ```
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

/// Graphemes for single-double border.
///
/// ```
/// ╓───────────────╖
/// ║ Single Double ║
/// ╙───────────────╜
/// ```
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
