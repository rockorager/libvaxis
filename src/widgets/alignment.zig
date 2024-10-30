const Window = @import("../Window.zig");

pub fn center(parent: Window, cols: u16, rows: u16) Window {
    const y_off = (parent.height / 2) -| (rows / 2);
    const x_off = (parent.width / 2) -| (cols / 2);
    return parent.child(.{
        .x_off = x_off,
        .y_off = y_off,
        .width = cols,
        .height = rows,
    });
}

pub fn topLeft(parent: Window, cols: u16, rows: u16) Window {
    const y_off: u16 = 0;
    const x_off: u16 = 0;
    return parent.child(.{ .x_off = x_off, .y_off = y_off, .width = cols, .height = rows });
}

pub fn topRight(parent: Window, cols: u16, rows: u16) Window {
    const y_off: u16 = 0;
    const x_off = parent.width -| cols;
    return parent.child(.{ .x_off = x_off, .y_off = y_off, .width = cols, .height = rows });
}

pub fn bottomLeft(parent: Window, cols: u16, rows: u16) Window {
    const y_off = parent.height -| rows;
    const x_off: u16 = 0;
    return parent.child(.{ .x_off = x_off, .y_off = y_off, .width = cols, .height = rows });
}

pub fn bottomRight(parent: Window, cols: u16, rows: u16) Window {
    const y_off = parent.height -| rows;
    const x_off = parent.width -| cols;
    return parent.child(.{ .x_off = x_off, .y_off = y_off, .width = cols, .height = rows });
}
