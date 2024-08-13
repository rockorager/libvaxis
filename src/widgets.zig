//! Specialized TUI Widgets

const opts = @import("build_options");

pub const border = @import("widgets/border.zig");
pub const alignment = @import("widgets/alignment.zig");
pub const Scrollbar = @import("widgets/Scrollbar.zig");
pub const Table = @import("widgets/Table.zig");
pub const ScrollView = @import("widgets/ScrollView.zig");
pub const LineNumbers = @import("widgets/LineNumbers.zig");
pub const TextView = @import("widgets/TextView.zig");
pub const CodeView = @import("widgets/CodeView.zig");
pub const Terminal = @import("widgets/terminal/Terminal.zig");
pub const TextInput = @import("widgets/TextInput.zig");
