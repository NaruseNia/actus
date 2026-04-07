const std = @import("std");
const Event = @import("../event.zig").Event;
const Widget = @import("../Widget.zig");
const Terminal = @import("../Terminal.zig");
const Style = @import("../Style.zig");
const Theme = @import("../Theme.zig");
const widget_layout = @import("../layout.zig");

/// Wraps any widget with a title line displayed above it.
/// The composite satisfies the Widget interface and can be used with `App.run`.
pub fn WithTitle(comptime ChildWidget: type) type {
    return struct {
        const Self = @This();

        comptime {
            Widget.assertIsWidget(ChildWidget);
            Widget.assertIsWidget(Self);
        }

        child: *ChildWidget,
        title: []const u8,
        style: Style,
        first_render: bool = true,
        last_rendered_lines: usize = 0,
        cursor_line: usize = 0,

        pub const Config = struct {
            title: []const u8 = "",
            /// Style for the title text. Overrides theme.primary when set.
            title_style: ?Style = null,
            theme: Theme = Theme.default,
        };

        pub fn init(child: *ChildWidget, config: Config) Self {
            return .{
                .child = child,
                .title = config.title,
                .style = config.title_style orelse config.theme.primary,
            };
        }

        // -- Widget interface --

        pub fn handleEvent(self: *Self, ev: Event) Widget.HandleResult {
            return self.child.handleEvent(ev);
        }

        pub fn needsRender(self: *const Self) bool {
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
            if (self.first_render) {
                // Title line + newline to push child below on first render only.
                // The title is static, so we never re-render it.
                try self.renderTitle(writer);
                try writer.writeAll("\n");
                self.first_render = false;
            }

            // Render child to buffer to analyze layout, then forward output.
            var child_buf: [Terminal.render_buf_size]u8 = undefined;
            var child_fbs = std.io.fixedBufferStream(&child_buf);
            try self.child.render(&child_fbs.writer());

            const wl = widget_layout.getWidgetLayout(self.child, child_fbs.getWritten());
            try writer.writeAll(child_fbs.getWritten());

            self.last_rendered_lines = wl.total_lines + 1; // +1 for title
            self.cursor_line = wl.cursor_row + 1; // +1 for title
        }

        /// Clear all rendered lines (title + child) from the terminal.
        pub fn cleanup(self: *Self, writer: anytype, extra_lines: u16) !void {
            const total_extra = extra_lines;
            if (comptime @hasDecl(ChildWidget, "cleanup")) {
                // Child cleanup handles its own lines; we add the title line
                try self.child.cleanup(writer, total_extra);
                // Move up one more for the title and clear it
                try Terminal.moveCursorUp(writer, 1);
                try Terminal.clearLine(writer);
                try Terminal.clearFromCursor(writer);
            } else {
                if (self.last_rendered_lines == 0) return;
                const up = self.cursor_line + total_extra;
                if (up > 0) {
                    try Terminal.moveCursorUp(writer, @intCast(up));
                }
                try Terminal.clearLine(writer);
                try Terminal.clearFromCursor(writer);
            }
        }

        // -- Internal --

        fn renderTitle(self: *const Self, writer: anytype) !void {
            try Terminal.clearLine(writer);
            try self.style.write(writer, self.title);
        }

        // Forward helpBindings from child if available
        pub fn helpBindings(self: *const Self) []const @import("HelpLine.zig").Binding {
            if (comptime @hasDecl(ChildWidget, "helpBindings")) {
                return self.child.helpBindings();
            }
            return &.{};
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
        try writer.writeAll("bindable content");
        self.rendered = true;
    }

    pub fn needsRender(_: *const MockWidgetWithBindings) bool {
        return true;
    }

    const HelpLine = @import("HelpLine.zig");

    pub fn helpBindings(_: *const MockWidgetWithBindings) []const HelpLine.Binding {
        return &.{
            .{ .key = "Enter", .action = "Select" },
        };
    }
};

test "WithTitle satisfies Widget interface" {
    comptime Widget.assertIsWidget(WithTitle(MockWidget));
}

test "handleEvent delegates to child" {
    var mock = MockWidget{};
    var w = WithTitle(MockWidget).init(&mock, .{ .title = "Test" });

    const result = w.handleEvent(.{ .key = .enter });
    try testing.expectEqual(Widget.HandleResult.consumed, result);
    try testing.expectEqual(@as(usize, 1), mock.event_count);
}

test "handleEvent returns child's result" {
    var mock = MockWidget{ .last_result = .done };
    var w = WithTitle(MockWidget).init(&mock, .{ .title = "Test" });

    const result = w.handleEvent(.{ .key = .enter });
    try testing.expectEqual(Widget.HandleResult.done, result);
}

test "needsRender reflects child state" {
    var mock = MockWidget{};
    var w = WithTitle(MockWidget).init(&mock, .{ .title = "Test" });
    try testing.expect(w.needsRender());
}

test "render output contains title and child content" {
    var mock = MockWidget{};
    var w = WithTitle(MockWidget).init(&mock, .{ .title = "Pick one" });

    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try w.render(fbs.writer());

    const output = fbs.getWritten();
    try testing.expect(std.mem.indexOf(u8, output, "Pick one") != null);
    try testing.expect(std.mem.indexOf(u8, output, "mock content") != null);
}

test "title appears before child content" {
    var mock = MockWidget{};
    var w = WithTitle(MockWidget).init(&mock, .{ .title = "Title" });

    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try w.render(fbs.writer());

    const output = fbs.getWritten();
    const title_pos = std.mem.indexOf(u8, output, "Title").?;
    const child_pos = std.mem.indexOf(u8, output, "mock content").?;
    try testing.expect(title_pos < child_pos);
}

test "title and child separated by newline" {
    var mock = MockWidget{};
    var w = WithTitle(MockWidget).init(&mock, .{ .title = "Title" });

    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try w.render(fbs.writer());

    const output = fbs.getWritten();
    const title_end = std.mem.indexOf(u8, output, "Title").? + "Title".len;
    const child_start = std.mem.indexOf(u8, output, "mock content").?;
    const between = output[title_end..child_start];
    try testing.expect(std.mem.indexOf(u8, between, "\n") != null);
}

test "layoutInfo accounts for title line" {
    var mock = MockWidget{};
    var w = WithTitle(MockWidget).init(&mock, .{ .title = "Title" });

    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try w.render(fbs.writer());

    const info = w.layoutInfo().?;
    // title(1) + child(1 line "mock content") = 2 total lines
    try testing.expectEqual(@as(usize, 2), info.total_lines);
    // cursor is on line 1 (0-indexed, after title on line 0)
    try testing.expectEqual(@as(usize, 1), info.cursor_line);
}

test "helpBindings forwarded from child" {
    const HelpLine = @import("HelpLine.zig");
    var mock = MockWidgetWithBindings{};
    const W = WithTitle(MockWidgetWithBindings);
    var w = W.init(&mock, .{ .title = "Test" });

    const bindings: []const HelpLine.Binding = w.helpBindings();
    try testing.expectEqual(@as(usize, 1), bindings.len);
    try testing.expectEqualStrings("Enter", bindings[0].key);
}

test "helpBindings returns empty for widget without them" {
    var mock = MockWidget{};
    var w = WithTitle(MockWidget).init(&mock, .{ .title = "Test" });
    const bindings = w.helpBindings();
    try testing.expectEqual(@as(usize, 0), bindings.len);
}

test "second render does not re-render title" {
    var mock = MockWidget{};
    var w = WithTitle(MockWidget).init(&mock, .{ .title = "Title" });

    // First render
    var buf1: [4096]u8 = undefined;
    var fbs1 = std.io.fixedBufferStream(&buf1);
    try w.render(fbs1.writer());
    const out1 = fbs1.getWritten();
    try testing.expect(std.mem.indexOf(u8, out1, "Title") != null);

    // Second render should NOT contain title (it's static)
    var buf2: [4096]u8 = undefined;
    var fbs2 = std.io.fixedBufferStream(&buf2);
    try w.render(fbs2.writer());

    const out2 = fbs2.getWritten();
    try testing.expect(std.mem.indexOf(u8, out2, "Title") == null);
    // But should still contain child content
    try testing.expect(std.mem.indexOf(u8, out2, "mock content") != null);
}
