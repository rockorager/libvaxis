//! A Windows TTY implementation, using virtual terminal process output and
//! native windows input
const Tty = @This();

const std = @import("std");
const Event = @import("../event.zig").Event;
const Key = @import("../Key.zig");
const Mouse = @import("../Mouse.zig");
const Parser = @import("../Parser.zig");
const windows = std.os.windows;

stdin: windows.HANDLE,
stdout: windows.HANDLE,

initial_codepage: c_uint,
initial_input_mode: u32,
initial_output_mode: u32,

// a buffer to write key text into
buf: [4]u8 = undefined,

/// The last mouse button that was pressed. We store the previous state of button presses on each
/// mouse event so we can detect which button was released
last_mouse_button_press: u16 = 0,

pub var global_tty: ?Tty = null;

const utf8_codepage: c_uint = 65001;

const InputMode = struct {
    const enable_window_input: u32 = 0x0008; // resize events
    const enable_mouse_input: u32 = 0x0010;
    const enable_extended_flags: u32 = 0x0080; // allows mouse events

    pub fn rawMode() u32 {
        return enable_window_input | enable_mouse_input | enable_extended_flags;
    }
};

const OutputMode = struct {
    const enable_processed_output: u32 = 0x0001; // handle control sequences
    const enable_virtual_terminal_processing: u32 = 0x0004; // handle ANSI sequences
    const disable_newline_auto_return: u32 = 0x0008; // disable inserting a new line when we write at the last column
    const enable_lvb_grid_worldwide: u32 = 0x0010; // enables reverse video and underline

    fn rawMode() u32 {
        return enable_processed_output |
            enable_virtual_terminal_processing |
            disable_newline_auto_return |
            enable_lvb_grid_worldwide;
    }
};

pub fn init() !Tty {
    const stdin = try windows.GetStdHandle(windows.STD_INPUT_HANDLE);
    const stdout = try windows.GetStdHandle(windows.STD_OUTPUT_HANDLE);

    // get initial modes
    var initial_input_mode: windows.DWORD = undefined;
    var initial_output_mode: windows.DWORD = undefined;
    const initial_output_codepage = windows.kernel32.GetConsoleOutputCP();
    {
        if (windows.kernel32.GetConsoleMode(stdin, &initial_input_mode) == 0) {
            return windows.unexpectedError(windows.kernel32.GetLastError());
        }
        if (windows.kernel32.GetConsoleMode(stdout, &initial_output_mode) == 0) {
            return windows.unexpectedError(windows.kernel32.GetLastError());
        }
    }

    // set new modes
    {
        if (SetConsoleMode(stdin, InputMode.rawMode()) == 0)
            return windows.unexpectedError(windows.kernel32.GetLastError());

        if (SetConsoleMode(stdout, OutputMode.rawMode()) == 0)
            return windows.unexpectedError(windows.kernel32.GetLastError());

        if (windows.kernel32.SetConsoleOutputCP(utf8_codepage) == 0)
            return windows.unexpectedError(windows.kernel32.GetLastError());
    }

    const self: Tty = .{
        .stdin = stdin,
        .stdout = stdout,
        .initial_codepage = initial_output_codepage,
        .initial_input_mode = initial_input_mode,
        .initial_output_mode = initial_output_mode,
    };

    // save a copy of this tty as the global_tty for panic handling
    global_tty = self;

    return self;
}

pub fn deinit(self: Tty) void {
    _ = windows.kernel32.SetConsoleOutputCP(self.initial_codepage);
    _ = SetConsoleMode(self.stdin, self.initial_input_mode);
    _ = SetConsoleMode(self.stdout, self.initial_output_mode);
    windows.CloseHandle(self.stdin);
    windows.CloseHandle(self.stdout);
}

pub fn opaqueWrite(ptr: *const anyopaque, bytes: []const u8) !usize {
    const self: *const Tty = @ptrCast(@alignCast(ptr));
    return windows.WriteFile(self.stdout, bytes, null);
}

pub fn anyWriter(self: *const Tty) std.io.AnyWriter {
    return .{
        .context = self,
        .writeFn = Tty.opaqueWrite,
    };
}

pub fn bufferedWriter(self: *const Tty) std.io.BufferedWriter(4096, std.io.AnyWriter) {
    return std.io.bufferedWriter(self.anyWriter());
}

pub fn nextEvent(self: *Tty, parser: *Parser, paste_allocator: ?std.mem.Allocator) !Event {
    // We use a loop so we can ignore certain events
    var state: EventState = .{};
    while (true) {
        var event_count: u32 = 0;
        var input_record: INPUT_RECORD = undefined;
        if (ReadConsoleInputW(self.stdin, &input_record, 1, &event_count) == 0)
            return windows.unexpectedError(windows.kernel32.GetLastError());

        if (try self.eventFromRecord(&input_record, &state, parser, paste_allocator)) |ev| {
            return ev;
        }
    }
}

pub const EventState = struct {
    ansi_buf: [128]u8 = undefined,
    ansi_idx: usize = 0,
    utf16_buf: [2]u16 = undefined,
    utf16_half: bool = false,
};

pub fn eventFromRecord(self: *Tty, record: *const INPUT_RECORD, state: *EventState, parser: *Parser, paste_allocator: ?std.mem.Allocator) !?Event {
    switch (record.EventType) {
        0x0001 => { // Key event
            const event = record.Event.KeyEvent;

            if (state.utf16_half) half: {
                state.utf16_half = false;
                state.utf16_buf[1] = event.uChar.UnicodeChar;
                const codepoint: u21 = std.unicode.utf16DecodeSurrogatePair(&state.utf16_buf) catch break :half;
                const n = std.unicode.utf8Encode(codepoint, &self.buf) catch return null;

                const key: Key = .{
                    .codepoint = codepoint,
                    .base_layout_codepoint = codepoint,
                    .mods = translateMods(event.dwControlKeyState),
                    .text = self.buf[0..n],
                };

                switch (event.bKeyDown) {
                    0 => return .{ .key_release = key },
                    else => return .{ .key_press = key },
                }
            }

            const base_layout: u16 = switch (event.wVirtualKeyCode) {
                0x00 => blk: { // delivered when we get an escape sequence or a unicode codepoint
                    if (state.ansi_idx == 0 and event.uChar.AsciiChar != 27)
                        break :blk event.uChar.UnicodeChar;
                    state.ansi_buf[state.ansi_idx] = event.uChar.AsciiChar;
                    state.ansi_idx += 1;
                    if (state.ansi_idx <= 2) return null;
                    const result = try parser.parse(state.ansi_buf[0..state.ansi_idx], paste_allocator);
                    return if (result.n == 0) null else evt: {
                        state.ansi_idx = 0;
                        break :evt result.event;
                    };
                },
                0x08 => Key.backspace,
                0x09 => Key.tab,
                0x0D => Key.enter,
                0x13 => Key.pause,
                0x14 => Key.caps_lock,
                0x1B => Key.escape,
                0x20 => Key.space,
                0x21 => Key.page_up,
                0x22 => Key.page_down,
                0x23 => Key.end,
                0x24 => Key.home,
                0x25 => Key.left,
                0x26 => Key.up,
                0x27 => Key.right,
                0x28 => Key.down,
                0x2c => Key.print_screen,
                0x2d => Key.insert,
                0x2e => Key.delete,
                0x30...0x39 => |k| k,
                0x41...0x5a => |k| k + 0x20, // translate to lowercase
                0x5b => Key.left_meta,
                0x5c => Key.right_meta,
                0x60 => Key.kp_0,
                0x61 => Key.kp_1,
                0x62 => Key.kp_2,
                0x63 => Key.kp_3,
                0x64 => Key.kp_4,
                0x65 => Key.kp_5,
                0x66 => Key.kp_6,
                0x67 => Key.kp_7,
                0x68 => Key.kp_8,
                0x69 => Key.kp_9,
                0x6a => Key.kp_multiply,
                0x6b => Key.kp_add,
                0x6c => Key.kp_separator,
                0x6d => Key.kp_subtract,
                0x6e => Key.kp_decimal,
                0x6f => Key.kp_divide,
                0x70 => Key.f1,
                0x71 => Key.f2,
                0x72 => Key.f3,
                0x73 => Key.f4,
                0x74 => Key.f5,
                0x75 => Key.f6,
                0x76 => Key.f8,
                0x77 => Key.f8,
                0x78 => Key.f9,
                0x79 => Key.f10,
                0x7a => Key.f11,
                0x7b => Key.f12,
                0x7c => Key.f13,
                0x7d => Key.f14,
                0x7e => Key.f15,
                0x7f => Key.f16,
                0x80 => Key.f17,
                0x81 => Key.f18,
                0x82 => Key.f19,
                0x83 => Key.f20,
                0x84 => Key.f21,
                0x85 => Key.f22,
                0x86 => Key.f23,
                0x87 => Key.f24,
                0x90 => Key.num_lock,
                0x91 => Key.scroll_lock,
                0xa0 => Key.left_shift,
                0xa1 => Key.right_shift,
                0xa2 => Key.left_control,
                0xa3 => Key.right_control,
                0xa4 => Key.left_alt,
                0xa5 => Key.right_alt,
                0xad => Key.mute_volume,
                0xae => Key.lower_volume,
                0xaf => Key.raise_volume,
                0xb0 => Key.media_track_next,
                0xb1 => Key.media_track_previous,
                0xb2 => Key.media_stop,
                0xb3 => Key.media_play_pause,
                0xba => ';',
                0xbb => '+',
                0xbc => ',',
                0xbd => '-',
                0xbe => '.',
                0xbf => '/',
                0xc0 => '`',
                0xdb => '[',
                0xdc => '\\',
                0xdd => ']',
                0xde => '\'',
                else => return null,
            };

            if (std.unicode.utf16IsHighSurrogate(base_layout)) {
                state.utf16_buf[0] = base_layout;
                state.utf16_half = true;
                return null;
            }
            if (std.unicode.utf16IsLowSurrogate(base_layout)) {
                return null;
            }

            var codepoint: u21 = base_layout;
            var text: ?[]const u8 = null;
            switch (event.uChar.UnicodeChar) {
                0x00...0x1F => {},
                else => |cp| {
                    codepoint = cp;
                    const n = try std.unicode.utf8Encode(codepoint, &self.buf);
                    text = self.buf[0..n];
                },
            }

            const key: Key = .{
                .codepoint = codepoint,
                .base_layout_codepoint = base_layout,
                .mods = translateMods(event.dwControlKeyState),
                .text = text,
            };

            switch (event.bKeyDown) {
                0 => return .{ .key_release = key },
                else => return .{ .key_press = key },
            }
        },
        0x0002 => { // Mouse event
            // see https://learn.microsoft.com/en-us/windows/console/mouse-event-record-str

            const event = record.Event.MouseEvent;

            // High word of dwButtonState represents mouse wheel. Positive is wheel_up, negative
            // is wheel_down
            // Low word represents button state
            const mouse_wheel_direction: i16 = blk: {
                const wheelu32: u32 = event.dwButtonState >> 16;
                const wheelu16: u16 = @truncate(wheelu32);
                break :blk @bitCast(wheelu16);
            };

            const buttons: u16 = @truncate(event.dwButtonState);
            // save the current state when we are done
            defer self.last_mouse_button_press = buttons;
            const button_xor = self.last_mouse_button_press ^ buttons;

            var event_type: Mouse.Type = .press;
            const btn: Mouse.Button = switch (button_xor) {
                0x0000 => blk: {
                    // Check wheel event
                    if (event.dwEventFlags & 0x0004 > 0) {
                        if (mouse_wheel_direction > 0)
                            break :blk .wheel_up
                        else
                            break :blk .wheel_down;
                    }

                    // If we have no change but one of the buttons is still pressed we have a
                    // drag event. Find out which button is held down
                    if (buttons > 0 and event.dwEventFlags & 0x0001 > 0) {
                        event_type = .drag;
                        if (buttons & 0x0001 > 0) break :blk .left;
                        if (buttons & 0x0002 > 0) break :blk .right;
                        if (buttons & 0x0004 > 0) break :blk .middle;
                        if (buttons & 0x0008 > 0) break :blk .button_8;
                        if (buttons & 0x0010 > 0) break :blk .button_9;
                    }

                    if (event.dwEventFlags & 0x0001 > 0) event_type = .motion;
                    break :blk .none;
                },
                0x0001 => blk: {
                    if (buttons & 0x0001 == 0) event_type = .release;
                    break :blk .left;
                },
                0x0002 => blk: {
                    if (buttons & 0x0002 == 0) event_type = .release;
                    break :blk .right;
                },
                0x0004 => blk: {
                    if (buttons & 0x0004 == 0) event_type = .release;
                    break :blk .middle;
                },
                0x0008 => blk: {
                    if (buttons & 0x0008 == 0) event_type = .release;
                    break :blk .button_8;
                },
                0x0010 => blk: {
                    if (buttons & 0x0010 == 0) event_type = .release;
                    break :blk .button_9;
                },
                else => {
                    std.log.warn("unknown mouse event: {}", .{event});
                    return null;
                },
            };

            const shift: u32 = 0x0010;
            const alt: u32 = 0x0001 | 0x0002;
            const ctrl: u32 = 0x0004 | 0x0008;
            const mods: Mouse.Modifiers = .{
                .shift = event.dwControlKeyState & shift > 0,
                .alt = event.dwControlKeyState & alt > 0,
                .ctrl = event.dwControlKeyState & ctrl > 0,
            };

            const mouse: Mouse = .{
                .col = @as(u16, @bitCast(event.dwMousePosition.X)), // Windows reports with 0 index
                .row = @as(u16, @bitCast(event.dwMousePosition.Y)), // Windows reports with 0 index
                .mods = mods,
                .type = event_type,
                .button = btn,
            };
            return .{ .mouse = mouse };
        },
        0x0004 => { // Screen resize events
            // NOTE: Even though the event comes with a size, it may not be accurate. We ask for
            // the size directly when we get this event
            var console_info: windows.CONSOLE_SCREEN_BUFFER_INFO = undefined;
            if (windows.kernel32.GetConsoleScreenBufferInfo(self.stdout, &console_info) == 0) {
                return windows.unexpectedError(windows.kernel32.GetLastError());
            }
            const window_rect = console_info.srWindow;
            const width = window_rect.Right - window_rect.Left + 1;
            const height = window_rect.Bottom - window_rect.Top + 1;
            return .{
                .winsize = .{
                    .cols = @intCast(width),
                    .rows = @intCast(height),
                    .x_pixel = 0,
                    .y_pixel = 0,
                },
            };
        },
        0x0010 => { // Focus events
            switch (record.Event.FocusEvent.bSetFocus) {
                0 => return .focus_out,
                else => return .focus_in,
            }
        },
        else => {},
    }
    return null;
}

fn translateMods(mods: u32) Key.Modifiers {
    const left_alt: u32 = 0x0002;
    const right_alt: u32 = 0x0001;
    const left_ctrl: u32 = 0x0008;
    const right_ctrl: u32 = 0x0004;

    const caps: u32 = 0x0080;
    const num_lock: u32 = 0x0020;
    const shift: u32 = 0x0010;
    const alt: u32 = left_alt | right_alt;
    const ctrl: u32 = left_ctrl | right_ctrl;

    return .{
        .shift = mods & shift > 0,
        .alt = mods & alt > 0,
        .ctrl = mods & ctrl > 0,
        .caps_lock = mods & caps > 0,
        .num_lock = mods & num_lock > 0,
    };
}

// From gitub.com/ziglibs/zig-windows-console. Thanks :)
//
// Events
const union_unnamed_248 = extern union {
    UnicodeChar: windows.WCHAR,
    AsciiChar: windows.CHAR,
};
pub const KEY_EVENT_RECORD = extern struct {
    bKeyDown: windows.BOOL,
    wRepeatCount: windows.WORD,
    wVirtualKeyCode: windows.WORD,
    wVirtualScanCode: windows.WORD,
    uChar: union_unnamed_248,
    dwControlKeyState: windows.DWORD,
};
pub const PKEY_EVENT_RECORD = *KEY_EVENT_RECORD;

pub const MOUSE_EVENT_RECORD = extern struct {
    dwMousePosition: windows.COORD,
    dwButtonState: windows.DWORD,
    dwControlKeyState: windows.DWORD,
    dwEventFlags: windows.DWORD,
};
pub const PMOUSE_EVENT_RECORD = *MOUSE_EVENT_RECORD;

pub const WINDOW_BUFFER_SIZE_RECORD = extern struct {
    dwSize: windows.COORD,
};
pub const PWINDOW_BUFFER_SIZE_RECORD = *WINDOW_BUFFER_SIZE_RECORD;

pub const MENU_EVENT_RECORD = extern struct {
    dwCommandId: windows.UINT,
};
pub const PMENU_EVENT_RECORD = *MENU_EVENT_RECORD;

pub const FOCUS_EVENT_RECORD = extern struct {
    bSetFocus: windows.BOOL,
};
pub const PFOCUS_EVENT_RECORD = *FOCUS_EVENT_RECORD;

const union_unnamed_249 = extern union {
    KeyEvent: KEY_EVENT_RECORD,
    MouseEvent: MOUSE_EVENT_RECORD,
    WindowBufferSizeEvent: WINDOW_BUFFER_SIZE_RECORD,
    MenuEvent: MENU_EVENT_RECORD,
    FocusEvent: FOCUS_EVENT_RECORD,
};
pub const INPUT_RECORD = extern struct {
    EventType: windows.WORD,
    Event: union_unnamed_249,
};
pub const PINPUT_RECORD = *INPUT_RECORD;

pub extern "kernel32" fn ReadConsoleInputW(hConsoleInput: windows.HANDLE, lpBuffer: PINPUT_RECORD, nLength: windows.DWORD, lpNumberOfEventsRead: *windows.DWORD) callconv(windows.WINAPI) windows.BOOL;
// TODO: remove this in zig 0.13.0
pub extern "kernel32" fn SetConsoleMode(in_hConsoleHandle: windows.HANDLE, in_dwMode: windows.DWORD) callconv(windows.WINAPI) windows.BOOL;
