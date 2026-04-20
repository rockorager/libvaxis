const std = @import("std");
const uucode = @import("uucode");
const vaxis = @import("../main.zig");

const vxfw = @import("vxfw.zig");

const assert = std.debug.assert;

const Allocator = std.mem.Allocator;
const Key = vaxis.Key;
const Cell = vaxis.Cell;
const Window = vaxis.Window;
const unicode = vaxis.unicode;

const TextField = @This();

const ellipsis: Cell.Character = .{ .grapheme = "…", .width = 1 };

// Index of our cursor
buf: Buffer,

/// Style to draw the TextField with
style: vaxis.Style = .{},

/// the number of graphemes to skip when drawing. Used for horizontal scrolling
draw_offset: u16 = 0,
/// the column we placed the cursor the last time we drew
prev_cursor_col: u16 = 0,
/// the grapheme index of the cursor the last time we drew
prev_cursor_idx: u16 = 0,
/// approximate distance from an edge before we scroll
scroll_offset: u4 = 4,
/// Previous width we drew at
prev_width: u16 = 0,

previous_val: []const u8 = "",

userdata: ?*anyopaque = null,
onChange: ?*const fn (?*anyopaque, *vxfw.EventContext, []const u8) anyerror!void = null,
onSubmit: ?*const fn (?*anyopaque, *vxfw.EventContext, []const u8) anyerror!void = null,

pub fn init(alloc: std.mem.Allocator) TextField {
    return TextField{
        .buf = Buffer.init(alloc),
    };
}

pub fn deinit(self: *TextField) void {
    self.buf.allocator.free(self.previous_val);
    self.buf.deinit();
}

pub fn widget(self: *TextField) vxfw.Widget {
    return .{
        .userdata = self,
        .eventHandler = typeErasedEventHandler,
        .drawFn = typeErasedDrawFn,
    };
}

fn typeErasedEventHandler(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
    const self: *TextField = @ptrCast(@alignCast(ptr));
    return self.handleEvent(ctx, event);
}

pub fn handleEvent(self: *TextField, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
    switch (event) {
        .focus_out, .focus_in => ctx.redraw = true,
        .key_press => |key| {
            if (key.matches(Key.backspace, .{})) {
                self.deleteBeforeCursor();
                return self.checkChanged(ctx);
            } else if (key.matches(Key.delete, .{}) or key.matches('d', .{ .ctrl = true })) {
                self.deleteAfterCursor();
                return self.checkChanged(ctx);
            } else if (key.matches(Key.left, .{}) or key.matches('b', .{ .ctrl = true })) {
                self.cursorLeft();
                return ctx.consumeAndRedraw();
            } else if (key.matches(Key.right, .{}) or key.matches('f', .{ .ctrl = true })) {
                self.cursorRight();
                return ctx.consumeAndRedraw();
            } else if (key.matches('a', .{ .ctrl = true }) or key.matches(Key.home, .{})) {
                self.buf.moveGapLeft(self.buf.firstHalf().len);
                return ctx.consumeAndRedraw();
            } else if (key.matches('e', .{ .ctrl = true }) or key.matches(Key.end, .{})) {
                self.buf.moveGapRight(self.buf.secondHalf().len);
                return ctx.consumeAndRedraw();
            } else if (key.matches('k', .{ .ctrl = true })) {
                self.deleteToEnd();
                return self.checkChanged(ctx);
            } else if (key.matches('u', .{ .ctrl = true })) {
                self.deleteToStart();
                return self.checkChanged(ctx);
            } else if (key.matches('b', .{ .alt = true }) or key.matches(Key.left, .{ .alt = true })) {
                self.moveBackwardWordwise();
                return ctx.consumeAndRedraw();
            } else if (key.matches('f', .{ .alt = true }) or key.matches(Key.right, .{ .alt = true })) {
                self.moveForwardWordwise();
                return ctx.consumeAndRedraw();
            } else if (key.matches(Key.backspace, .{ .alt = true })) {
                self.deleteWordBefore();
                return self.checkChanged(ctx);
            } else if (key.matches('w', .{ .ctrl = true })) {
                self.deleteWordBeforeWhitespace();
                return self.checkChanged(ctx);
            } else if (key.matches('d', .{ .alt = true })) {
                self.deleteWordAfter();
                return self.checkChanged(ctx);
            } else if (key.matches(vaxis.Key.enter, .{}) or key.matches('j', .{ .ctrl = true })) {
                if (self.onSubmit) |onSubmit| {
                    const value = try self.toOwnedSlice();
                    // Get a ref to the allocator in case onSubmit deinits the TextField
                    const allocator = self.buf.allocator;
                    defer allocator.free(value);
                    try onSubmit(self.userdata, ctx, value);
                    return ctx.consumeAndRedraw();
                }
            } else if (key.text) |text| {
                try self.insertSliceAtCursor(text);
                return self.checkChanged(ctx);
            }
        },
        else => {},
    }
}

fn checkChanged(self: *TextField, ctx: *vxfw.EventContext) anyerror!void {
    ctx.consumeAndRedraw();
    const onChange = self.onChange orelse return;
    const new = try self.buf.dupe();
    defer {
        self.buf.allocator.free(self.previous_val);
        self.previous_val = new;
    }
    if (std.mem.eql(u8, new, self.previous_val)) return;
    try onChange(self.userdata, ctx, new);
}

/// insert text at the cursor position
pub fn insertSliceAtCursor(self: *TextField, data: []const u8) std.mem.Allocator.Error!void {
    var iter = unicode.graphemeIterator(data);
    while (iter.next()) |text| {
        try self.buf.insertSliceAtCursor(text.bytes(data));
    }
}

pub fn sliceToCursor(self: *TextField, buf: []u8) []const u8 {
    assert(buf.len >= self.buf.cursor);
    @memcpy(buf[0..self.buf.cursor], self.buf.firstHalf());
    return buf[0..self.buf.cursor];
}

/// calculates the display width from the draw_offset to the cursor
pub fn widthToCursor(self: *TextField, ctx: vxfw.DrawContext) u16 {
    var width: u16 = 0;
    const first_half = self.buf.firstHalf();
    var first_iter = unicode.graphemeIterator(first_half);
    var i: usize = 0;
    while (first_iter.next()) |grapheme| {
        defer i += 1;
        if (i < self.draw_offset) {
            continue;
        }
        const g = grapheme.bytes(first_half);
        width += @intCast(ctx.stringWidth(g));
    }
    return width;
}

pub fn cursorLeft(self: *TextField) void {
    // We need to find the size of the last grapheme in the first half
    var iter = unicode.graphemeIterator(self.buf.firstHalf());
    var len: usize = 0;
    while (iter.next()) |grapheme| {
        len = grapheme.len;
    }
    self.buf.moveGapLeft(len);
}

pub fn cursorRight(self: *TextField) void {
    var iter = unicode.graphemeIterator(self.buf.secondHalf());
    const grapheme = iter.next() orelse return;
    self.buf.moveGapRight(grapheme.len);
}

pub fn graphemesBeforeCursor(self: *const TextField) u16 {
    const first_half = self.buf.firstHalf();
    var first_iter = unicode.graphemeIterator(first_half);
    var i: u16 = 0;
    while (first_iter.next()) |_| {
        i += 1;
    }
    return i;
}

fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
    const self: *TextField = @ptrCast(@alignCast(ptr));
    return self.draw(ctx);
}

pub fn draw(self: *TextField, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
    std.debug.assert(ctx.max.width != null);
    const max_width = ctx.max.width.?;
    if (max_width != self.prev_width) {
        self.prev_width = max_width;
        self.draw_offset = 0;
        self.prev_cursor_col = 0;
    }
    // Create a surface with max width and a minimum height of 1.
    var surface = try vxfw.Surface.init(
        ctx.arena,
        self.widget(),
        .{ .width = max_width, .height = @max(ctx.min.height, 1) },
    );

    const base: vaxis.Cell = .{ .style = self.style };
    @memset(surface.buffer, base);
    const style = self.style;
    const cursor_idx = self.graphemesBeforeCursor();
    if (cursor_idx < self.draw_offset) self.draw_offset = cursor_idx;
    if (max_width == 0) return surface;
    while (true) {
        const width = self.widthToCursor(ctx);
        if (width >= max_width) {
            self.draw_offset +|= width - max_width + 1;
            continue;
        } else break;
    }

    self.prev_cursor_idx = cursor_idx;
    self.prev_cursor_col = 0;

    const first_half = self.buf.firstHalf();
    var first_iter = unicode.graphemeIterator(first_half);
    var col: u16 = 0;
    var i: u16 = 0;
    while (first_iter.next()) |grapheme| {
        if (i < self.draw_offset) {
            i += 1;
            continue;
        }
        const g = grapheme.bytes(first_half);
        const w: u8 = @intCast(ctx.stringWidth(g));
        if (col + w >= max_width) {
            surface.writeCell(max_width - 1, 0, .{
                .char = ellipsis,
                .style = style,
            });
            break;
        }
        surface.writeCell(@intCast(col), 0, .{
            .char = .{
                .grapheme = g,
                .width = w,
            },
            .style = style,
        });
        col += w;
        i += 1;
        if (i == cursor_idx) self.prev_cursor_col = col;
    }
    const second_half = self.buf.secondHalf();
    var second_iter = unicode.graphemeIterator(second_half);
    while (second_iter.next()) |grapheme| {
        if (i < self.draw_offset) {
            i += 1;
            continue;
        }
        const g = grapheme.bytes(second_half);
        const w: u8 = @intCast(ctx.stringWidth(g));
        if (col + w > max_width) {
            surface.writeCell(max_width - 1, 0, .{
                .char = ellipsis,
                .style = style,
            });
            break;
        }
        surface.writeCell(@intCast(col), 0, .{
            .char = .{
                .grapheme = g,
                .width = w,
            },
            .style = style,
        });
        col += w;
        i += 1;
        if (i == cursor_idx) self.prev_cursor_col = col;
    }
    if (self.draw_offset > 0) {
        surface.writeCell(0, 0, .{
            .char = ellipsis,
            .style = style,
        });
    }
    surface.cursor = .{ .col = @intCast(self.prev_cursor_col), .row = 0 };
    return surface;
    // win.showCursor(self.prev_cursor_col, 0);
}

pub fn clearAndFree(self: *TextField) void {
    self.buf.clearAndFree();
    self.reset();
}

pub fn clearRetainingCapacity(self: *TextField) void {
    self.buf.clearRetainingCapacity();
    self.reset();
}

pub fn toOwnedSlice(self: *TextField) ![]const u8 {
    defer self.reset();
    return self.buf.toOwnedSlice();
}

pub fn reset(self: *TextField) void {
    self.draw_offset = 0;
    self.prev_cursor_col = 0;
    self.prev_cursor_idx = 0;
}

// returns the number of bytes before the cursor
pub fn byteOffsetToCursor(self: TextField) usize {
    return self.buf.cursor;
}

pub fn deleteToEnd(self: *TextField) void {
    self.buf.growGapRight(self.buf.secondHalf().len);
}

pub fn deleteToStart(self: *TextField) void {
    self.buf.growGapLeft(self.buf.cursor);
}

pub fn deleteBeforeCursor(self: *TextField) void {
    // We need to find the size of the last grapheme in the first half
    var iter = unicode.graphemeIterator(self.buf.firstHalf());
    var len: usize = 0;
    while (iter.next()) |grapheme| {
        len = grapheme.len;
    }
    self.buf.growGapLeft(len);
}

pub fn deleteAfterCursor(self: *TextField) void {
    var iter = unicode.graphemeIterator(self.buf.secondHalf());
    const grapheme = iter.next() orelse return;
    self.buf.growGapRight(grapheme.len);
}

const DecodedCodepoint = struct {
    cp: u21,
    start: usize,
    len: usize,
};

fn decodeCodepointAt(bytes: []const u8, start: usize) DecodedCodepoint {
    const first = bytes[start];
    const len = std.unicode.utf8ByteSequenceLength(first) catch 1;
    const capped_len = @min(len, bytes.len - start);
    const slice = bytes[start .. start + capped_len];
    const cp = std.unicode.utf8Decode(slice) catch {
        return .{ .cp = first, .start = start, .len = 1 };
    };
    return .{ .cp = cp, .start = start, .len = capped_len };
}

fn isUtf8ContinuationByte(c: u8) bool {
    return (c & 0b1100_0000) == 0b1000_0000;
}

fn decodeCodepointBefore(bytes: []const u8, end: usize) DecodedCodepoint {
    var start = end - 1;
    while (start > 0 and isUtf8ContinuationByte(bytes[start])) : (start -= 1) {}
    const slice = bytes[start..end];
    const cp = std.unicode.utf8Decode(slice) catch {
        return .{ .cp = bytes[end - 1], .start = end - 1, .len = 1 };
    };
    return .{ .cp = cp, .start = start, .len = end - start };
}

/// Returns true if the codepoint is a readline-style word constituent.
fn isWordCodepoint(cp: u21) bool {
    if (cp == '_') return true;
    return switch (uucode.get(.general_category, cp)) {
        .letter_uppercase,
        .letter_lowercase,
        .letter_titlecase,
        .letter_modifier,
        .letter_other,
        .number_decimal_digit,
        .number_letter,
        .number_other,
        .mark_nonspacing,
        .mark_spacing_combining,
        .mark_enclosing,
        .punctuation_connector,
        => true,
        else => false,
    };
}

fn isWhitespaceCodepoint(cp: u21) bool {
    return switch (cp) {
        ' ', '\t', '\n', '\r', 0x0b, 0x0c, 0x85 => true,
        else => switch (uucode.get(.general_category, cp)) {
            .separator_space,
            .separator_line,
            .separator_paragraph,
            => true,
            else => false,
        },
    };
}

/// Moves the cursor backward by one word using character-class boundaries.
/// Skips non-word characters, then skips word characters (matching readline backward-word).
pub fn moveBackwardWordwise(self: *TextField) void {
    const first_half = self.buf.firstHalf();
    var i: usize = first_half.len;
    // Skip non-word characters
    while (i > 0) {
        const decoded = decodeCodepointBefore(first_half, i);
        if (isWordCodepoint(decoded.cp)) break;
        i = decoded.start;
    }
    // Skip word characters
    while (i > 0) {
        const decoded = decodeCodepointBefore(first_half, i);
        if (!isWordCodepoint(decoded.cp)) break;
        i = decoded.start;
    }
    self.buf.moveGapLeft(self.buf.cursor - i);
}

/// Moves the cursor forward by one word using character-class boundaries.
/// Skips non-word characters, then skips word characters — landing at the end of the next word
/// (matching readline forward-word).
pub fn moveForwardWordwise(self: *TextField) void {
    const second_half = self.buf.secondHalf();
    var i: usize = 0;
    // Skip non-word characters
    while (i < second_half.len) {
        const decoded = decodeCodepointAt(second_half, i);
        if (isWordCodepoint(decoded.cp)) break;
        i += decoded.len;
    }
    // Skip word characters
    while (i < second_half.len) {
        const decoded = decodeCodepointAt(second_half, i);
        if (!isWordCodepoint(decoded.cp)) break;
        i += decoded.len;
    }
    self.buf.moveGapRight(i);
}

/// Deletes the word before the cursor using character-class boundaries
/// (matching readline backward-kill-word / Alt+Backspace).
pub fn deleteWordBefore(self: *TextField) void {
    const pre = self.buf.cursor;
    self.moveBackwardWordwise();
    self.buf.growGapRight(pre - self.buf.cursor);
}

/// Deletes the word before the cursor using whitespace boundaries
/// (matching readline unix-word-rubout / Ctrl+W).
pub fn deleteWordBeforeWhitespace(self: *TextField) void {
    const first_half = self.buf.firstHalf();
    var i: usize = first_half.len;
    // Skip trailing whitespace
    while (i > 0) {
        const decoded = decodeCodepointBefore(first_half, i);
        if (!isWhitespaceCodepoint(decoded.cp)) break;
        i = decoded.start;
    }
    // Skip non-whitespace
    while (i > 0) {
        const decoded = decodeCodepointBefore(first_half, i);
        if (isWhitespaceCodepoint(decoded.cp)) break;
        i = decoded.start;
    }
    const to_delete = self.buf.cursor - i;
    self.buf.moveGapLeft(to_delete);
    self.buf.growGapRight(to_delete);
}

/// Deletes the word after the cursor using character-class boundaries
/// (matching readline kill-word / Alt+D).
pub fn deleteWordAfter(self: *TextField) void {
    const second_half = self.buf.secondHalf();
    var i: usize = 0;
    // Skip non-word characters
    while (i < second_half.len) {
        const decoded = decodeCodepointAt(second_half, i);
        if (isWordCodepoint(decoded.cp)) break;
        i += decoded.len;
    }
    // Skip word characters
    while (i < second_half.len) {
        const decoded = decodeCodepointAt(second_half, i);
        if (!isWordCodepoint(decoded.cp)) break;
        i += decoded.len;
    }
    self.buf.growGapRight(i);
}

test "sliceToCursor" {
    var input = init(std.testing.allocator);
    defer input.deinit();
    try input.insertSliceAtCursor("hello, world");
    input.cursorLeft();
    input.cursorLeft();
    input.cursorLeft();
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("hello, wo", input.sliceToCursor(&buf));
    input.cursorRight();
    try std.testing.expectEqualStrings("hello, wor", input.sliceToCursor(&buf));
}

pub const Buffer = struct {
    allocator: std.mem.Allocator,
    buffer: []u8,
    cursor: usize,
    gap_size: usize,

    pub fn init(allocator: std.mem.Allocator) Buffer {
        return .{
            .allocator = allocator,
            .buffer = &.{},
            .cursor = 0,
            .gap_size = 0,
        };
    }

    pub fn deinit(self: *Buffer) void {
        self.allocator.free(self.buffer);
    }

    pub fn firstHalf(self: Buffer) []const u8 {
        return self.buffer[0..self.cursor];
    }

    pub fn secondHalf(self: Buffer) []const u8 {
        return self.buffer[self.cursor + self.gap_size ..];
    }

    pub fn grow(self: *Buffer, n: usize) std.mem.Allocator.Error!void {
        // Always grow by 512 bytes
        const new_size = self.buffer.len + n + 512;
        // Allocate the new memory
        const new_memory = try self.allocator.alloc(u8, new_size);
        // Copy the first half
        @memcpy(new_memory[0..self.cursor], self.firstHalf());
        // Copy the second half
        const second_half = self.secondHalf();
        @memcpy(new_memory[new_size - second_half.len ..], second_half);
        self.allocator.free(self.buffer);
        self.buffer = new_memory;
        self.gap_size = new_size - second_half.len - self.cursor;
    }

    pub fn insertSliceAtCursor(self: *Buffer, slice: []const u8) std.mem.Allocator.Error!void {
        if (slice.len == 0) return;
        if (self.gap_size <= slice.len) try self.grow(slice.len);
        @memcpy(self.buffer[self.cursor .. self.cursor + slice.len], slice);
        self.cursor += slice.len;
        self.gap_size -= slice.len;
    }

    /// Move the gap n bytes to the left
    pub fn moveGapLeft(self: *Buffer, n: usize) void {
        const new_idx = self.cursor -| n;
        const dst = self.buffer[new_idx + self.gap_size ..];
        const src = self.buffer[new_idx..self.cursor];
        std.mem.copyForwards(u8, dst, src);
        self.cursor = new_idx;
    }

    pub fn moveGapRight(self: *Buffer, n: usize) void {
        const new_idx = self.cursor + n;
        const dst = self.buffer[self.cursor..];
        const src = self.buffer[self.cursor + self.gap_size .. new_idx + self.gap_size];
        std.mem.copyForwards(u8, dst, src);
        self.cursor = new_idx;
    }

    /// grow the gap by moving the cursor n bytes to the left
    pub fn growGapLeft(self: *Buffer, n: usize) void {
        // gap grows by the delta
        self.gap_size += n;
        self.cursor -|= n;
    }

    /// grow the gap by removing n bytes after the cursor
    pub fn growGapRight(self: *Buffer, n: usize) void {
        self.gap_size = @min(self.gap_size + n, self.buffer.len - self.cursor);
    }

    pub fn clearAndFree(self: *Buffer) void {
        self.cursor = 0;
        self.allocator.free(self.buffer);
        self.buffer = &.{};
        self.gap_size = 0;
    }

    pub fn clearRetainingCapacity(self: *Buffer) void {
        self.cursor = 0;
        self.gap_size = self.buffer.len;
    }

    pub fn toOwnedSlice(self: *Buffer) std.mem.Allocator.Error![]const u8 {
        const slice = try self.dupe();
        self.clearAndFree();
        return slice;
    }

    pub fn realLength(self: *const Buffer) usize {
        return self.firstHalf().len + self.secondHalf().len;
    }

    pub fn dupe(self: *const Buffer) std.mem.Allocator.Error![]const u8 {
        const first_half = self.firstHalf();
        const second_half = self.secondHalf();
        const buf = try self.allocator.alloc(u8, first_half.len + second_half.len);
        @memcpy(buf[0..first_half.len], first_half);
        @memcpy(buf[first_half.len..], second_half);
        return buf;
    }
};

test "TextField.zig: Buffer" {
    var gap_buf = Buffer.init(std.testing.allocator);
    defer gap_buf.deinit();

    try gap_buf.insertSliceAtCursor("abc");
    try std.testing.expectEqualStrings("abc", gap_buf.firstHalf());
    try std.testing.expectEqualStrings("", gap_buf.secondHalf());

    gap_buf.moveGapLeft(1);
    try std.testing.expectEqualStrings("ab", gap_buf.firstHalf());
    try std.testing.expectEqualStrings("c", gap_buf.secondHalf());

    try gap_buf.insertSliceAtCursor(" ");
    try std.testing.expectEqualStrings("ab ", gap_buf.firstHalf());
    try std.testing.expectEqualStrings("c", gap_buf.secondHalf());

    gap_buf.growGapLeft(1);
    try std.testing.expectEqualStrings("ab", gap_buf.firstHalf());
    try std.testing.expectEqualStrings("c", gap_buf.secondHalf());
    try std.testing.expectEqual(2, gap_buf.cursor);

    gap_buf.growGapRight(1);
    try std.testing.expectEqualStrings("ab", gap_buf.firstHalf());
    try std.testing.expectEqualStrings("", gap_buf.secondHalf());
    try std.testing.expectEqual(2, gap_buf.cursor);
}

test TextField {
    // Boiler plate draw context init
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    vxfw.DrawContext.init(.unicode);

    // Create some object which reacts to text field changes
    const Foo = struct {
        allocator: std.mem.Allocator,
        text: []const u8,

        fn onChange(ptr: ?*anyopaque, ctx: *vxfw.EventContext, str: []const u8) anyerror!void {
            const foo: *@This() = @ptrCast(@alignCast(ptr));
            foo.text = try foo.allocator.dupe(u8, str);
            ctx.consumeAndRedraw();
        }
    };
    var foo: Foo = .{ .text = "", .allocator = arena.allocator() };

    // Text field expands to the width, so it can't be null. It is always 1 line tall
    const draw_ctx: vxfw.DrawContext = .{
        .arena = arena.allocator(),
        .min = .{},
        .max = .{ .width = 8, .height = 1 },
        .cell_size = .{ .width = 10, .height = 20 },
    };
    _ = draw_ctx;

    var ctx: vxfw.EventContext = .{
        .alloc = arena.allocator(),
        .cmds = .empty,
    };

    // Enough boiler plate...Create the text field
    var text_field = TextField.init(std.testing.allocator);
    defer text_field.deinit();
    text_field.onChange = Foo.onChange;
    text_field.onSubmit = Foo.onChange;
    text_field.userdata = &foo;

    const tf_widget = text_field.widget();
    // Send some key events to the widget
    try tf_widget.handleEvent(&ctx, .{ .key_press = .{ .codepoint = 'H', .text = "H" } });
    // The foo object stores the last text that we saw from an onChange call
    try std.testing.expectEqualStrings("H", foo.text);
    try tf_widget.handleEvent(&ctx, .{ .key_press = .{ .codepoint = 'e', .text = "e" } });
    try std.testing.expectEqualStrings("He", foo.text);
    try tf_widget.handleEvent(&ctx, .{ .key_press = .{ .codepoint = 'l', .text = "l" } });
    try std.testing.expectEqualStrings("Hel", foo.text);
    try tf_widget.handleEvent(&ctx, .{ .key_press = .{ .codepoint = 'l', .text = "l" } });
    try std.testing.expectEqualStrings("Hell", foo.text);
    try tf_widget.handleEvent(&ctx, .{ .key_press = .{ .codepoint = 'o', .text = "o" } });
    try std.testing.expectEqualStrings("Hello", foo.text);

    // An arrow moves the cursor. The text doesn't change
    try tf_widget.handleEvent(&ctx, .{ .key_press = .{ .codepoint = vaxis.Key.left } });
    try std.testing.expectEqualStrings("Hello", foo.text);

    try tf_widget.handleEvent(&ctx, .{ .key_press = .{ .codepoint = '_', .text = "_" } });
    try std.testing.expectEqualStrings("Hell_o", foo.text);
}

test "moveBackwardWordwise stops at word boundary" {
    var input = TextField.init(std.testing.allocator);
    defer input.deinit();
    try input.insertSliceAtCursor("hello-world");
    input.moveBackwardWordwise();
    try std.testing.expectEqualStrings("hello-", input.buf.firstHalf());
    try std.testing.expectEqualStrings("world", input.buf.secondHalf());
    input.moveBackwardWordwise();
    try std.testing.expectEqualStrings("", input.buf.firstHalf());
    try std.testing.expectEqualStrings("hello-world", input.buf.secondHalf());
}

test "moveForwardWordwise stops at end of word" {
    var input = TextField.init(std.testing.allocator);
    defer input.deinit();
    try input.insertSliceAtCursor("hello-world");
    input.buf.moveGapLeft(input.buf.firstHalf().len);
    input.moveForwardWordwise();
    // Stops at end of "hello": "hello|-world"
    try std.testing.expectEqualStrings("hello", input.buf.firstHalf());
    try std.testing.expectEqualStrings("-world", input.buf.secondHalf());
    input.moveForwardWordwise();
    // Skips "-" then stops at end of "world": "hello-world|"
    try std.testing.expectEqualStrings("hello-world", input.buf.firstHalf());
    try std.testing.expectEqualStrings("", input.buf.secondHalf());
}

test "moveBackwardWordwise with path separators" {
    var input = TextField.init(std.testing.allocator);
    defer input.deinit();
    try input.insertSliceAtCursor("/usr/local/bin");
    input.moveBackwardWordwise();
    try std.testing.expectEqualStrings("/usr/local/", input.buf.firstHalf());
    input.moveBackwardWordwise();
    try std.testing.expectEqualStrings("/usr/", input.buf.firstHalf());
    input.moveBackwardWordwise();
    try std.testing.expectEqualStrings("/", input.buf.firstHalf());
    input.moveBackwardWordwise();
    try std.testing.expectEqualStrings("", input.buf.firstHalf());
}

test "deleteWordBefore with hyphens" {
    var input = TextField.init(std.testing.allocator);
    defer input.deinit();
    try input.insertSliceAtCursor("hello-world");
    input.deleteWordBefore();
    try std.testing.expectEqualStrings("hello-", input.buf.firstHalf());
    try std.testing.expectEqualStrings("", input.buf.secondHalf());
    input.deleteWordBefore();
    try std.testing.expectEqualStrings("", input.buf.firstHalf());
}

test "deleteWordBeforeWhitespace deletes to whitespace" {
    var input = TextField.init(std.testing.allocator);
    defer input.deinit();
    try input.insertSliceAtCursor("hello-world foo.bar");
    input.deleteWordBeforeWhitespace();
    try std.testing.expectEqualStrings("hello-world ", input.buf.firstHalf());
    input.deleteWordBeforeWhitespace();
    try std.testing.expectEqualStrings("", input.buf.firstHalf());
}

test "deleteWordAfter with mixed punctuation" {
    var input = TextField.init(std.testing.allocator);
    defer input.deinit();
    try input.insertSliceAtCursor("foo.bar baz");
    input.buf.moveGapLeft(input.buf.firstHalf().len);
    input.deleteWordAfter();
    try std.testing.expectEqualStrings("", input.buf.firstHalf());
    try std.testing.expectEqualStrings(".bar baz", input.buf.secondHalf());
    input.deleteWordAfter();
    try std.testing.expectEqualStrings("", input.buf.firstHalf());
    try std.testing.expectEqualStrings(" baz", input.buf.secondHalf());
}

test "moveForwardWordwise with dots" {
    var input = TextField.init(std.testing.allocator);
    defer input.deinit();
    try input.insertSliceAtCursor("foo.bar.baz");
    input.buf.moveGapLeft(input.buf.firstHalf().len);
    input.moveForwardWordwise();
    try std.testing.expectEqualStrings("foo", input.buf.firstHalf());
    input.moveForwardWordwise();
    try std.testing.expectEqualStrings("foo.bar", input.buf.firstHalf());
    input.moveForwardWordwise();
    try std.testing.expectEqualStrings("foo.bar.baz", input.buf.firstHalf());
}

test "word motion with underscores treats them as word chars" {
    var input = TextField.init(std.testing.allocator);
    defer input.deinit();
    try input.insertSliceAtCursor("hello_world-test");
    input.moveBackwardWordwise();
    try std.testing.expectEqualStrings("hello_world-", input.buf.firstHalf());
    input.moveBackwardWordwise();
    try std.testing.expectEqualStrings("", input.buf.firstHalf());
}

test "word motion with non-ASCII text" {
    var input = TextField.init(std.testing.allocator);
    defer input.deinit();
    try input.insertSliceAtCursor("café-latte");
    input.moveBackwardWordwise();
    try std.testing.expectEqualStrings("café-", input.buf.firstHalf());
    try std.testing.expectEqualStrings("latte", input.buf.secondHalf());
    input.moveBackwardWordwise();
    try std.testing.expectEqualStrings("", input.buf.firstHalf());

    input.moveForwardWordwise();
    try std.testing.expectEqualStrings("caf\xc3\xa9", input.buf.firstHalf());
    try std.testing.expectEqualStrings("-latte", input.buf.secondHalf());
}

test "non-ASCII punctuation acts as a separator" {
    var input = TextField.init(std.testing.allocator);
    defer input.deinit();
    try input.insertSliceAtCursor("hello\u{2014}world");
    input.moveBackwardWordwise();
    try std.testing.expectEqualStrings("hello\u{2014}", input.buf.firstHalf());
    try std.testing.expectEqualStrings("world", input.buf.secondHalf());

    input.buf.moveGapLeft(input.buf.firstHalf().len);
    input.moveForwardWordwise();
    try std.testing.expectEqualStrings("hello", input.buf.firstHalf());
    try std.testing.expectEqualStrings("\u{2014}world", input.buf.secondHalf());
}

test "deleteWordBeforeWhitespace handles unicode whitespace" {
    var input = TextField.init(std.testing.allocator);
    defer input.deinit();
    try input.insertSliceAtCursor("hello\u{3000}world");
    input.deleteWordBeforeWhitespace();
    try std.testing.expectEqualStrings("hello\u{3000}", input.buf.firstHalf());
    try std.testing.expectEqualStrings("", input.buf.secondHalf());
}

test "deleteWordBefore with non-ASCII text" {
    var input = TextField.init(std.testing.allocator);
    defer input.deinit();
    try input.insertSliceAtCursor("über-cool");
    input.deleteWordBefore();
    try std.testing.expectEqualStrings("über-", input.buf.firstHalf());
    input.deleteWordBefore();
    try std.testing.expectEqualStrings("", input.buf.firstHalf());
}

test "word motion with spaces" {
    var input = TextField.init(std.testing.allocator);
    defer input.deinit();
    try input.insertSliceAtCursor("hello world");
    input.moveBackwardWordwise();
    try std.testing.expectEqualStrings("hello ", input.buf.firstHalf());
    input.moveBackwardWordwise();
    try std.testing.expectEqualStrings("", input.buf.firstHalf());
}

test "refAllDecls" {
    std.testing.refAllDecls(@This());
}
