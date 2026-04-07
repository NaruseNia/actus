const std = @import("std");
const Event = @import("../event.zig").Event;
const Widget = @import("../Widget.zig");
const Terminal = @import("../Terminal.zig");
const Style = @import("../Style.zig");
const Theme = @import("../Theme.zig");
const HelpLine = @import("HelpLine.zig");
const widget_layout = @import("../layout.zig");

/// Wraps any widget with an optional title above and an optional help line below.
/// Combines the functionality of `WithTitle` and `WithHelpLine` in a single wrapper,
/// avoiding the need to chain two separate generic types.
///
/// ```zig
/// var d = actus.Decorated(actus.ListView).init(&lv, .{
///     .title = "Pick one fruit:",
/// });
/// try app.run(&d);
/// ```
pub fn Decorated(comptime ChildWidget: type) type {
    return struct {
        const Self = @This();

        comptime {
            Widget.assertIsWidget(ChildWidget);
            Widget.assertIsWidget(Self);
        }

        child: *ChildWidget,

        // Title state
        title: []const u8,
        title_style: Style,
        has_title: bool,

        // Help line state
        help_line: HelpLine,
        override_bindings: ?[]const HelpLine.Binding,
        has_help: bool,

        // Render state
        first_render: bool = true,
        last_rendered_lines: usize = 0,
        cursor_line: usize = 0,

        pub const Config = struct {
            // Title options
            title: ?[]const u8 = null,
            title_style: ?Style = null,

            // Help line options
            /// Explicit bindings. When null, uses the child's `helpBindings()` if available.
            help_bindings: ?[]const HelpLine.Binding = null,
            /// Set to false to hide the help line entirely.
            show_help: bool = true,
            help_separator: []const u8 = "   ",
            help_key_style: ?Style = null,
            help_action_style: ?Style = null,
            help_separator_style: ?Style = null,

            // Shared
            theme: Theme = Theme.default,
        };

        pub fn init(child: *ChildWidget, config: Config) Self {
            const has_title = config.title != null;
            const has_help = config.show_help;
            return .{
                .child = child,
                .title = config.title orelse "",
                .title_style = config.title_style orelse config.theme.primary,
                .has_title = has_title,
                .help_line = HelpLine.init(.{
                    .bindings = config.help_bindings orelse &.{},
                    .separator = config.help_separator,
                    .key_style = config.help_key_style,
                    .action_style = config.help_action_style,
                    .separator_style = config.help_separator_style,
                    .theme = config.theme,
                }),
                .override_bindings = config.help_bindings,
                .has_help = has_help,
            };
        }

        // -- Widget interface --

        pub fn handleEvent(self: *Self, ev: Event) Widget.HandleResult {
            return self.child.handleEvent(ev);
        }

        pub fn needsRender(self: *const Self) bool {
            if (self.has_help and self.help_line.needsRender()) return true;
            return self.child.needsRender();
        }

        pub fn layoutInfo(self: *const Self) ?Widget.LayoutInfo {
            if (self.last_rendered_lines == 0) return null;
            return .{
                .total_lines = self.last_rendered_lines,
                .cursor_line = self.cursor_line,
            };
        }

        pub fn render(self: *Self, writer: anytype) !void {
            // Sync help bindings from child
            if (self.has_help) self.syncBindings();

            // Title: render only on first frame (static content)
            if (self.first_render and self.has_title) {
                try Terminal.clearLine(writer);
                try self.title_style.write(writer, self.title);
                try writer.writeAll("\n");
            }

            // Render child to buffer for layout analysis
            var child_buf: [Terminal.render_buf_size]u8 = undefined;
            var child_fbs = std.io.fixedBufferStream(&child_buf);
            try self.child.render(&child_fbs.writer());
            const wl = widget_layout.getWidgetLayout(self.child, child_fbs.getWritten());

            // Forward child output
            try writer.writeAll(child_fbs.getWritten());

            // Help line
            if (self.has_help) {
                if (self.first_render) {
                    for (0..wl.lines_below + 1) |_| {
                        try writer.writeAll("\n");
                    }
                    try self.help_line.render(writer);
                    try Terminal.clearFromCursor(writer);
                    try Terminal.moveCursorUp(writer, @intCast(wl.lines_below + 1));
                } else {
                    try Terminal.moveCursorDown(writer, @intCast(wl.lines_below + 1));
                    try writer.writeAll("\r");
                    try self.help_line.render(writer);
                    try Terminal.clearFromCursor(writer);
                    try Terminal.moveCursorUp(writer, @intCast(wl.lines_below + 1));
                }
                if (wl.cursor_col) |col| try Terminal.moveCursorTo(writer, col);
            }

            self.first_render = false;

            // Update layout tracking
            var total = wl.total_lines;
            if (self.has_title) total += 1;
            if (self.has_help) total += 1;
            self.last_rendered_lines = total;
            self.cursor_line = wl.cursor_row + if (self.has_title) @as(usize, 1) else 0;
        }

        pub fn cleanup(self: *Self, writer: anytype, extra_lines: u16) !void {
            var extra = extra_lines;
            if (self.has_help) extra += 1;

            if (comptime @hasDecl(ChildWidget, "cleanup")) {
                try self.child.cleanup(writer, extra);
            } else {
                if (self.last_rendered_lines == 0) return;
                const up = self.cursor_line + extra;
                if (up > 0) {
                    try Terminal.moveCursorUp(writer, @intCast(up));
                }
            }

            if (self.has_title) {
                try Terminal.moveCursorUp(writer, 1);
            }

            try Terminal.clearLine(writer);
            try Terminal.clearFromCursor(writer);
        }

        // -- Internal --

        fn syncBindings(self: *Self) void {
            if (self.override_bindings != null) return;
            if (comptime @hasDecl(ChildWidget, "helpBindings")) {
                self.help_line.setBindings(self.child.helpBindings());
            }
        }
    };
}

// -- Tests --

const testing = std.testing;

const MockWidget = struct {
    rendered: bool = false,
    event_count: usize = 0,
    last_result: Widget.HandleResult = .consumed,

    pub fn handleEvent(self: *MockWidget, _: Event) Widget.HandleResult {
        self.event_count += 1;
        return self.last_result;
    }

    pub fn render(self: *MockWidget, writer: anytype) !void {
        try writer.writeAll("mock content");
        self.rendered = true;
    }

    pub fn needsRender(_: *const MockWidget) bool {
        return true;
    }
};

const MockWidgetWithBindings = struct {
    rendered: bool = false,

    pub fn handleEvent(_: *MockWidgetWithBindings, _: Event) Widget.HandleResult {
        return .consumed;
    }

    pub fn render(self: *MockWidgetWithBindings, writer: anytype) !void {
        try writer.writeAll("bindable");
        self.rendered = true;
    }

    pub fn needsRender(_: *const MockWidgetWithBindings) bool {
        return true;
    }

    pub fn helpBindings(_: *const MockWidgetWithBindings) []const HelpLine.Binding {
        return &.{
            .{ .key = "Enter", .action = "Select" },
        };
    }
};

test "Decorated satisfies Widget interface" {
    comptime Widget.assertIsWidget(Decorated(MockWidget));
    comptime Widget.assertIsWidget(Decorated(MockWidgetWithBindings));
}

test "handleEvent delegates to child" {
    var mock = MockWidget{};
    var d = Decorated(MockWidget).init(&mock, .{ .title = "T" });
    const result = d.handleEvent(.{ .key = .enter });
    try testing.expectEqual(Widget.HandleResult.consumed, result);
    try testing.expectEqual(@as(usize, 1), mock.event_count);
}

test "render contains title and child content" {
    var mock = MockWidget{};
    var d = Decorated(MockWidget).init(&mock, .{ .title = "My Title" });

    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try d.render(fbs.writer());

    const output = fbs.getWritten();
    try testing.expect(std.mem.indexOf(u8, output, "My Title") != null);
    try testing.expect(std.mem.indexOf(u8, output, "mock content") != null);
}

test "title appears before child" {
    var mock = MockWidget{};
    var d = Decorated(MockWidget).init(&mock, .{ .title = "Title" });

    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try d.render(fbs.writer());

    const output = fbs.getWritten();
    const title_pos = std.mem.indexOf(u8, output, "Title").?;
    const child_pos = std.mem.indexOf(u8, output, "mock content").?;
    try testing.expect(title_pos < child_pos);
}

test "auto-populates help bindings from child" {
    var mock = MockWidgetWithBindings{};
    var d = Decorated(MockWidgetWithBindings).init(&mock, .{ .title = "T" });

    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try d.render(fbs.writer());

    const output = fbs.getWritten();
    try testing.expect(std.mem.indexOf(u8, output, "Enter") != null);
    try testing.expect(std.mem.indexOf(u8, output, "Select") != null);
}

test "explicit help_bindings override child" {
    var mock = MockWidgetWithBindings{};
    var d = Decorated(MockWidgetWithBindings).init(&mock, .{
        .title = "T",
        .help_bindings = &.{.{ .key = "q", .action = "Quit" }},
    });

    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try d.render(fbs.writer());

    const output = fbs.getWritten();
    try testing.expect(std.mem.indexOf(u8, output, "Quit") != null);
    try testing.expect(std.mem.indexOf(u8, output, "Select") == null);
}

test "no title when title is null" {
    var mock = MockWidget{};
    var d = Decorated(MockWidget).init(&mock, .{});

    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try d.render(fbs.writer());

    const output = fbs.getWritten();
    try testing.expect(std.mem.indexOf(u8, output, "mock content") != null);
}

test "no help line when show_help is false" {
    var mock = MockWidgetWithBindings{};
    var d = Decorated(MockWidgetWithBindings).init(&mock, .{
        .show_help = false,
    });

    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try d.render(fbs.writer());

    const output = fbs.getWritten();
    try testing.expect(std.mem.indexOf(u8, output, "bindable") != null);
    try testing.expect(std.mem.indexOf(u8, output, "Select") == null);
}

test "layoutInfo accounts for title and help" {
    var mock = MockWidget{};
    var d = Decorated(MockWidget).init(&mock, .{ .title = "T" });

    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try d.render(fbs.writer());

    const info = d.layoutInfo().?;
    // title(1) + child(1) + help(1) = 3
    try testing.expectEqual(@as(usize, 3), info.total_lines);
    // cursor on line 1 (0-indexed, after title)
    try testing.expectEqual(@as(usize, 1), info.cursor_line);
}

test "second render does not re-render title" {
    var mock = MockWidget{};
    var d = Decorated(MockWidget).init(&mock, .{ .title = "Title" });

    var buf1: [4096]u8 = undefined;
    var fbs1 = std.io.fixedBufferStream(&buf1);
    try d.render(fbs1.writer());
    try testing.expect(std.mem.indexOf(u8, fbs1.getWritten(), "Title") != null);

    var buf2: [4096]u8 = undefined;
    var fbs2 = std.io.fixedBufferStream(&buf2);
    try d.render(fbs2.writer());
    try testing.expect(std.mem.indexOf(u8, fbs2.getWritten(), "Title") == null);
}
