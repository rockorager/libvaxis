pub const App = @import("app.zig").App;
pub const Key = @import("Key.zig");
pub const Winsize = @import("Tty.zig").Winsize;

test {
    _ = @import("Key.zig");
    _ = @import("Screen.zig");
    _ = @import("Tty.zig");
    _ = @import("Window.zig");
    _ = @import("app.zig");
    _ = @import("cell.zig");
    _ = @import("queue.zig");
}
