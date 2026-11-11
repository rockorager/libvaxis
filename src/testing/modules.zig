const std = @import("std");
const vaxis = @import("vaxis");
const unicode = @import("unicode");
const gwidth = @import("gwidth");

test "exported value modules share the renderer's types" {
    try std.testing.expect(unicode.Grapheme == vaxis.unicode.Grapheme);
    try std.testing.expect(unicode.GraphemeIterator == vaxis.unicode.GraphemeIterator);
    try std.testing.expect(gwidth.Method == vaxis.gwidth.Method);
    var screen: vaxis.Screen = .{};
    const method: gwidth.Method = .unicode;
    screen.width_method = method;
    var iter = unicode.graphemeIterator("e\u{0301}界");
    const first: vaxis.unicode.Grapheme = iter.next().?;
    try std.testing.expectEqualStrings("e\u{0301}", first.bytes("e\u{0301}界"));
    try std.testing.expectEqual(@as(u16, 3), gwidth.gwidth("e\u{0301}界", screen.width_method));
}
