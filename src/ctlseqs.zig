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

// alt screen
pub const smcup = "\x1b[?1049h";
pub const rmcup = "\x1b[?1049l";
