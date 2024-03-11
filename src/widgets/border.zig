const Cell = @import("../Cell.zig");
const Window = @import("../Window.zig");

const Style = Cell.Style;
const Character = Cell.Character;

const horizontal = Character{ .grapheme = "─", .width = 1 };
const vertical = Character{ .grapheme = "│", .width = 1 };
const top_left = Character{ .grapheme = "╭", .width = 1 };
const top_right = Character{ .grapheme = "╮", .width = 1 };
const bottom_right = Character{ .grapheme = "╯", .width = 1 };
const bottom_left = Character{ .grapheme = "╰", .width = 1 };

pub fn all(win: Window, style: Style) Window {
    const h = win.height;
    const w = win.width;
    win.writeCell(0, 0, .{ .char = top_left, .style = style });
    win.writeCell(0, h -| 1, .{ .char = bottom_left, .style = style });
    win.writeCell(w -| 1, 0, .{ .char = top_right, .style = style });
    win.writeCell(w -| 1, h -| 1, .{ .char = bottom_right, .style = style });
    var i: usize = 1;
    while (i < (h -| 1)) : (i += 1) {
        win.writeCell(0, i, .{ .char = vertical, .style = style });
        win.writeCell(w -| 1, i, .{ .char = vertical, .style = style });
    }
    i = 1;
    while (i < w -| 1) : (i += 1) {
        win.writeCell(i, 0, .{ .char = horizontal, .style = style });
        win.writeCell(i, h -| 1, .{ .char = horizontal, .style = style });
    }
    return win.initChild(1, 1, .{ .limit = w -| 2 }, .{ .limit = h -| 2 });
}

pub fn right(win: Window, style: Style) Window {
    const h = win.height;
    const w = win.width;
    var i: usize = 0;
    while (i < h) : (i += 1) {
        win.writeCell(w -| 1, i, .{ .char = vertical, .style = style });
    }
    return win.initChild(0, 0, .{ .limit = w -| 1 }, .expand);
}

pub fn bottom(win: Window, style: Style) Window {
    const h = win.height;
    const w = win.width;
    var i: usize = 0;
    while (i < w) : (i += 1) {
        win.writeCell(i, h -| 1, .{ .char = horizontal, .style = style });
    }
    return win.initChild(0, 0, .expand, .{ .limit = h -| 1 });
}
