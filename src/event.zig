pub const Key = @import("Key.zig");

/// The events that Vaxis emits. This can be used as the generic EventType if
/// there are no internal events
pub const Event = union(enum) {
    key_press: Key,
    focus_in,
    focus_out,
};
