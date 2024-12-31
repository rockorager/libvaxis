const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const Model = struct {
    scroll_view: vxfw.ScrollView,
    text: std.ArrayList(vxfw.RichText),

    arena: std.heap.ArenaAllocator,

    pub fn widget(self: *Model) vxfw.Widget {
        return .{
            .userdata = self,
            .eventHandler = Model.typeErasedEventHandler,
            .drawFn = Model.typeErasedDrawFn,
        };
    }

    fn typeErasedEventHandler(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        const self: *Model = @ptrCast(@alignCast(ptr));
        switch (event) {
            .key_press => |key| {
                if (key.matches('c', .{ .ctrl = true })) {
                    ctx.quit = true;
                    return;
                }
                return self.scroll_view.handleEvent(ctx, event);
            },
            else => {},
        }
    }

    fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *Model = @ptrCast(@alignCast(ptr));
        const max = ctx.max.size();

        const scroll_view: vxfw.SubSurface = .{
            .origin = .{ .row = 0, .col = 0 },
            .surface = try self.scroll_view.draw(ctx),
        };

        const children = try ctx.arena.alloc(vxfw.SubSurface, 1);
        children[0] = scroll_view;

        return .{
            .size = max,
            .widget = self.widget(),
            .focusable = true,
            .buffer = &.{},
            .children = children,
        };
    }

    fn widgetBuilder(ptr: *const anyopaque, idx: usize, _: usize) ?vxfw.Widget {
        const self: *const Model = @ptrCast(@alignCast(ptr));
        if (idx >= self.text.items.len) return null;

        return self.text.items[idx].widget();
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();

    var app = try vxfw.App.init(allocator);
    errdefer app.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const model = try allocator.create(Model);
    defer allocator.destroy(model);
    model.* = .{
        .scroll_view = .{
            .children = .{
                .builder = .{
                    .userdata = model,
                    .buildFn = Model.widgetBuilder,
                },
            },
        },
        .text = std.ArrayList(vxfw.RichText).init(allocator),
        .arena = arena,
    };
    defer model.text.deinit();

    var lipsum = std.ArrayList([]const u8).init(allocator);
    defer lipsum.deinit();

    try lipsum.append("    Lorem ipsum dolor sit amet, consectetur adipiscing elit. Nunc sit amet nunc porta, commodo tellus eu, blandit lectus. Aliquam dignissim rhoncus mi eu ultrices. Suspendisse lectus massa, bibendum sed lorem sit amet, egestas aliquam ante. Mauris venenatis nibh neque. Nulla a mi eget purus porttitor malesuada. Sed ac porta felis. Morbi ultricies urna nisi, et maximus elit convallis a. Morbi ut felis nec orci euismod congue efficitur egestas ex. Quisque eu feugiat magna. Pellentesque porttitor tortor ut iaculis dictum. Nulla erat neque, sollicitudin vitae enim nec, pharetra blandit tortor. Sed orci ante, condimentum vitae sodales in, sodales ut nulla. Suspendisse quam felis, aliquet ut neque a, lacinia sagittis turpis. Vivamus nec dui purus. Proin tempor nisl et porttitor consequat.");
    try lipsum.append("    Vivamus elit massa, commodo in laoreet nec, scelerisque ac orci. Donec nec ante sit amet nisi ullamcorper dictum quis non enim. Proin ante libero, consequat sit amet semper a, vulputate non odio. Mauris ut suscipit lacus. Mauris nec dolor id ex mollis tempor at quis ligula. Integer varius commodo ipsum id gravida. Sed ut lobortis est, id egestas nunc. In fringilla ullamcorper porttitor. Donec quis dignissim arcu, vitae sagittis tortor. Sed tempor porttitor arcu, sit amet elementum est ornare id. Morbi rhoncus, ipsum eget tincidunt volutpat, mauris enim vestibulum nibh, mollis iaculis ante enim quis enim. Donec pharetra odio vel ex fringilla, ut laoreet ipsum commodo. Praesent tempus, leo a pellentesque sodales, erat ipsum pretium nulla, id faucibus sem turpis at nibh. Aenean ut dui luctus, vehicula felis vel, aliquam nulla.");
    try lipsum.append("    Cras interdum mattis elit non varius. In condimentum velit a tellus sollicitudin interdum. Etiam pulvinar semper ex, eget congue ante tristique ut. Phasellus commodo magna magna, at fermentum tortor porttitor ac. Fusce a efficitur diam, a congue ante. Mauris maximus ultrices leo, non viverra ex hendrerit eu. Donec laoreet turpis nulla, eget imperdiet tortor mollis aliquam. Donec a est eget ante consequat rhoncus.");
    try lipsum.append("    Morbi facilisis libero nec viverra imperdiet. Ut dictum faucibus bibendum. Vestibulum ut nisl eu magna sollicitudin elementum vel eu ante. Phasellus euismod ligula massa, vel rutrum elit hendrerit ut. Vivamus id luctus lectus, at ullamcorper leo. Pellentesque in risus finibus, viverra ligula sed, porta nisl. Aliquam pretium accumsan placerat. Etiam a elit posuere, varius erat sed, aliquet quam. Morbi finibus gravida erat, non imperdiet dolor sollicitudin dictum. Aenean eget ullamcorper lacus, et hendrerit lorem. Quisque sed varius mauris.");
    try lipsum.append("    Nullam vitae euismod mauris, eu gravida dolor. Nunc vel urna laoreet justo faucibus tempus. Vestibulum tincidunt sagittis metus ac dignissim. Curabitur eleifend dolor consequat malesuada posuere. In hac habitasse platea dictumst. Fusce eget ipsum tincidunt, placerat orci ut, malesuada ante. Vivamus ultrices purus vel orci posuere, sed posuere eros porta. Vestibulum a tellus et tortor scelerisque varius. Pellentesque vel leo sed est semper bibendum. Mauris tellus ante, cursus et nunc vitae, dictum pellentesque ex. In tristique purus felis, non efficitur ante mollis id. Nulla quam nisi, suscipit sit amet mattis vel, placerat sit amet lectus. Vestibulum cursus auctor quam, at convallis felis euismod non. Sed nec magna nisi. Morbi scelerisque accumsan nunc, sed sagittis sem varius sit amet. Maecenas arcu dui, euismod et sem quis, condimentum blandit tellus.");
    try lipsum.append("    Nullam auctor lobortis libero non viverra. Mauris a imperdiet eros, a luctus est. Integer pellentesque eros et metus rhoncus egestas. Suspendisse eu risus mauris. Mauris posuere nulla in justo pharetra molestie. Maecenas sagittis at nunc et finibus. Vestibulum quis leo ac mauris malesuada vestibulum vitae eu enim. Ut et maximus elit. Pellentesque lorem felis, tristique vitae posuere vitae, auctor tempus magna. Fusce cursus purus sit amet risus pulvinar, non egestas ligula imperdiet.");
    try lipsum.append("    Proin rhoncus tincidunt congue. Curabitur pretium mauris eu erat iaculis semper. Vestibulum augue tortor, vehicula id maximus at, semper eu leo. Vivamus feugiat at purus eu dapibus. Mauris luctus sollicitudin nibh, in placerat est mattis vitae. Morbi ut risus felis. Etiam lobortis mollis diam, id tempor odio sollicitudin a. Morbi congue, lacus ac accumsan consequat, ipsum eros facilisis est, in congue metus ex nec ligula. Vestibulum dolor ligula, interdum nec iaculis vel, interdum a diam. Curabitur mattis, risus at rhoncus gravida, diam est viverra diam, ut mattis augue nulla sed lacus.");
    try lipsum.append("    Duis rutrum orci sit amet dui imperdiet porta. In pulvinar imperdiet enim nec tristique. Etiam egestas pulvinar arcu, viverra mollis ipsum. Ut sit amet sapien nibh. Maecenas ut velit egestas, suscipit dolor vel, interdum tellus. Pellentesque faucibus euismod risus, ac vehicula erat sodales a. Aliquam egestas sit amet enim ac posuere. In id venenatis eros, et pharetra neque. Proin facilisis, odio id vehicula elementum, sapien ligula interdum dui, quis vestibulum est quam sit amet nisl. Aliquam in orci et felis aliquet tempus quis id magna. Sed interdum malesuada sem. Proin sagittis est metus, eu vestibulum nunc lacinia in. Vestibulum enim erat, cursus at justo at, porta feugiat quam. Phasellus vestibulum finibus nulla, at egestas augue imperdiet dapibus. Nunc in felis at ante congue interdum ut nec sapien.");
    try lipsum.append("    Etiam lacinia ornare mauris, ut lacinia elit sollicitudin non. Morbi cursus dictum enim, et vulputate mi sollicitudin vel. Fusce rutrum augue justo. Phasellus et mauris tincidunt erat lacinia bibendum sed eu orci. Sed nunc lectus, dignissim sit amet ultricies sit amet, efficitur eu urna. Fusce feugiat malesuada ipsum nec congue. Praesent ultrices metus eu pulvinar laoreet. Maecenas pellentesque, metus ac lobortis rhoncus, ligula eros consequat urna, eget dictum lectus sem ut orci. Donec lobortis, lacus sed bibendum auctor, odio turpis suscipit odio, vitae feugiat leo metus ac lectus. Curabitur sed sem arcu.");
    try lipsum.append("    Mauris nisi tortor, auctor venenatis turpis a, finibus condimentum lectus. Donec id velit odio. Curabitur ac varius lorem. Nam cursus quam in velit gravida, in bibendum purus fermentum. Sed non rutrum dui, nec ultrices ligula. Integer lacinia blandit nisl non sollicitudin. Praesent nec malesuada eros, sit amet tincidunt nunc.");

    for (0..10) |_| {
        for (lipsum.items) |paragraph| {
            var spans = std.ArrayList(vxfw.RichText.TextSpan).init(arena.allocator());
            try spans.append(.{ .text = paragraph });

            try model.text.append(.{ .text = spans.items, .softwrap = true });
        }
    }

    try app.run(model.widget(), .{});
    app.deinit();
}
