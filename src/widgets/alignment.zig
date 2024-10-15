const Window = @import("../Window.zig");

pub fn center(parent: Window, cols: usize, rows: usize) Window {
    const y_off = (parent.height / 2) -| (rows / 2);
    const x_off = (parent.width / 2) -| (cols / 2);
    return parent.child(.{
        .x_off = x_off,
        .y_off = y_off,
        .width = .{ .limit = cols },
        .height = .{ .limit = rows },
    });
}
