pub const App = @import("app.zig").App;
pub const Key = @import("Key.zig");

test {
    _ = @import("Key.zig");
    _ = @import("Tty.zig");
    _ = @import("app.zig");
    _ = @import("queue.zig");
}
