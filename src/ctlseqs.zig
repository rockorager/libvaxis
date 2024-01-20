// Queries
pub const primary_device_attrs = "\x1b[c";
pub const tertiary_device_attrs = "\x1b[=c";
pub const xtversion = "\x1b[>0q";

// Key encoding
pub const csi_u = "\x1b[?u";
pub const csi_u_push = "\x1b[>{d}u";
pub const csi_u_pop = "\x1b[<u";

// Cursor
pub const home = "\x1b[H";
pub const cup = "\x1b[{d};{d}H";
pub const hide_cursor = "\x1b[?25l";
pub const show_cursor = "\x1b[?25h";

// alt screen
pub const smcup = "\x1b[?1049h";
pub const rmcup = "\x1b[?1049l";

// colors
pub const fg_base = "\x1b[3{d}m";
pub const fg_bright = "\x1b[9{d}m";
pub const bg_base = "\x1b[4{d}m";
pub const bg_bright = "\x1b[10{d}m";

pub const fg_reset = "\x1b[39m";
pub const bg_reset = "\x1b[49m";
pub const ul_reset = "\x1b[59m";
pub const fg_indexed = "\x1b[38;5;{d}m";
pub const bg_indexed = "\x1b[48:5:{d}m";
pub const ul_indexed = "\x1b[58:5:{d}m";
pub const fg_rgb = "\x1b[38:2:{d}:{d}:{d}m";
pub const bg_rgb = "\x1b[48:2:{d}:{d}:{d}m";
pub const ul_rgb = "\x1b[58:2:{d}:{d}:{d}m";

// Underlines
pub const ul_off = "\x1b[24m"; // NOTE: this could be \x1b[4:0m but is not as widely supported
pub const ul_single = "\x1b[4m";
pub const ul_double = "\x1b[4:2m";
pub const ul_curly = "\x1b[4:3m";
pub const ul_dotted = "\x1b[4:4m";
pub const ul_dashed = "\x1b[4:5m";

// Attributes
pub const bold_set = "\x1b[1m";
pub const dim_set = "\x1b[2m";
pub const italic_set = "\x1b[3m";
pub const blink_set = "\x1b[5m";
pub const reverse_set = "\x1b[7m";
pub const invisible_set = "\x1b[8m";
pub const strikethrough_set = "\x1b[9m";
pub const bold_dim_reset = "\x1b[22m";
pub const italic_reset = "\x1b[23m";
pub const blink_reset = "\x1b[25m";
pub const reverse_reset = "\x1b[27m";
pub const invisible_reset = "\x1b[28m";
pub const strikethrough_reset = "\x1b[29m";

// OSC sequences
pub const osc8 = "\x1b]8;{s};{s}\x1b\\";
pub const osc8_clear = "\x1b]8;;\x1b\\";
