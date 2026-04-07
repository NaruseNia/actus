const std = @import("std");
const Event = @import("../event.zig").Event;
const Widget = @import("../Widget.zig");
const Terminal = @import("../Terminal.zig");
const HelpLine = @import("HelpLine.zig");
const widget_layout = @import("../layout.zig");

/// Wraps any widget with a HelpLine displayed below it.
/// The composite satisfies the Widget interface and can be used with `App.run`.
///
/// If the child widget implements `helpBindings`, the help line is automatically
/// populated from the child's bindings (which may change dynamically based on state).
/// Explicit `bindings` in Config override the child's defaults.
pub fn WithHelpLine(comptime ChildWidget: type) type {
    return struct {
        const Self = @This();

        comptime {
            Widget.assertIsWidget(ChildWidget);
            Widget.assertIsWidget(Self);
        }

        child: *ChildWidget,
        help_line: HelpLine,
        override_bindings: ?[]const HelpLine.Binding,
        first_render: bool = true,
        last_rendered_lines: usize = 0,
        cursor_line: usize = 0,

        pub const Config = struct {
            /// Explicit bindings. When null, uses the child's `helpBindings()` if available.
            bindings: ?[]const HelpLine.Binding = null,
            /// Separator between bindings.
            separator: []const u8 = "   ",
            /// Style overrides (forwarded to HelpLine).
            key_style: ?@import("../Style.zig") = null,
            action_style: ?@import("../Style.zig") = null,
            separator_style: ?@import("../Style.zig") = null,
            theme: @import("../Theme.zig") = @import("../Theme.zig").default,
        };

        pub fn init(child: *ChildWidget, config: Config) Self {
            return .{
                .child = child,
                .help_line = HelpLine.init(.{
                    .bindings = config.bindings orelse &.{},
                    .separator = config.separator,
                    .key_style = config.key_style,
                    .action_style = config.action_style,
                    .separator_style = config.separator_style,
                    .theme = config.theme,
                }),
                .override_bindings = config.bindings,
            };
        }

        // -- Widget interface --

        pub fn handleEvent(self: *Self, ev: Event) Widget.HandleResult {
            return self.child.handleEvent(ev);
        }

        pub fn needsRender(self: *const Self) bool {
            return self.child.needsRender() or self.help_line.needsRender();
        }

        pub fn render(self: *Self, writer: anytype) !void {
            // Update bindings from child if no override is set
            self.syncBindings();

            // Render child to an internal buffer so we can analyze layout
            var child_buf: [4096]u8 = undefined;
            var child_fbs = std.io.fixedBufferStream(&child_buf);
            const child_writer = child_fbs.writer();

            try self.child.render(&child_writer);

            const wl = widget_layout.getWidgetLayout(self.child, child_fbs.getWritten());

            // Forward child output to the real writer
            try writer.writeAll(child_fbs.getWritten());

            // Position and render help line
            if (self.first_render) {
                // Initial render: use \n to scroll terminal and create lines
                for (0..wl.lines_below + 1) |_| {
                    try writer.writeAll("\n");
                }
                try self.help_line.render(writer);
                try Terminal.clearFromCursor(writer);
                try Terminal.moveCursorUp(writer, @intCast(wl.lines_below + 1));
                self.first_render = false;
            } else {
                // Subsequent renders: lines already exist, use cursor movement
                try Terminal.moveCursorDown(writer, @intCast(wl.lines_below + 1));
                try writer.writeAll("\r");
                try self.help_line.render(writer);
                try Terminal.clearFromCursor(writer);
                try Terminal.moveCursorUp(writer, @intCast(wl.lines_below + 1));
            }

            // Restore cursor column
            if (wl.cursor_col) |col| try Terminal.moveCursorTo(writer, col);

            // Update composite layout fields for potential nesting
            self.last_rendered_lines = wl.total_lines + 1; // +1 for help line
            self.cursor_line = wl.cursor_row;
        }

        /// Clear all rendered lines (child + help line) from the terminal.
        /// `extra_lines`: lines the cursor moved down since last render
        /// (e.g. 1 for App.run's final "\r\n").
        pub fn cleanup(self: *Self, writer: anytype, extra_lines: u16) !void {
            const total_extra = extra_lines + 1; // +1 for the help line
            if (comptime @hasDecl(ChildWidget, "cleanup")) {
                try self.child.cleanup(writer, total_extra);
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

        // -- Internal helpers --

        fn syncBindings(self: *Self) void {
            if (self.override_bindings != null) return;

            if (comptime @hasDecl(ChildWidget, "helpBindings")) {
                const bindings = self.child.helpBindings();
                self.help_line.setBindings(bindings);
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
    mode: enum { normal, special } = .normal,

    pub fn handleEvent(_: *MockWidgetWithBindings, _: Event) Widget.HandleResult {
        return .consumed;
    }

    pub fn render(self: *MockWidgetWithBindings, writer: anytype) !void {
        try writer.writeAll("mock with bindings");
        self.rendered = true;
    }

    pub fn needsRender(_: *const MockWidgetWithBindings) bool {
        return true;
    }

    pub fn helpBindings(self: *const MockWidgetWithBindings) []const HelpLine.Binding {
        return switch (self.mode) {
            .normal => &.{
                .{ .key = "a", .action = "Action A" },
                .{ .key = "b", .action = "Action B" },
            },
            .special => &.{
                .{ .key = "x", .action = "Special" },
            },
        };
    }
};

test "WithHelpLine satisfies Widget interface" {
    comptime Widget.assertIsWidget(WithHelpLine(MockWidget));
    comptime Widget.assertIsWidget(WithHelpLine(MockWidgetWithBindings));
}

test "handleEvent delegates to child" {
    var mock = MockWidget{};
    var w = WithHelpLine(MockWidget).init(&mock, .{});

    const result = w.handleEvent(.{ .key = .enter });
    try testing.expectEqual(Widget.HandleResult.consumed, result);
    try testing.expectEqual(@as(usize, 1), mock.event_count);
}

test "handleEvent returns child's result" {
    var mock = MockWidget{ .last_result = .done };
    var w = WithHelpLine(MockWidget).init(&mock, .{});

    const result = w.handleEvent(.{ .key = .enter });
    try testing.expectEqual(Widget.HandleResult.done, result);
}

test "needsRender reflects child state" {
    var mock = MockWidget{};
    var w = WithHelpLine(MockWidget).init(&mock, .{});

    // MockWidget.needsRender always returns true
    try testing.expect(w.needsRender());
}

test "needsRender reflects help_line state" {
    var mock = MockWidget{};
    var w = WithHelpLine(MockWidget).init(&mock, .{});

    // After render, help_line dirty becomes false
    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try w.render(&fbs.writer());

    // Change bindings to mark help_line dirty
    w.help_line.setBindings(&.{.{ .key = "q", .action = "Quit" }});
    try testing.expect(w.needsRender());
}

test "render output contains child and help line content" {
    var mock = MockWidget{};
    var w = WithHelpLine(MockWidget).init(&mock, .{
        .bindings = &.{
            .{ .key = "Enter", .action = "Select" },
        },
    });

    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try w.render(&fbs.writer());

    const output = fbs.getWritten();
    try testing.expect(std.mem.indexOf(u8, output, "mock content") != null);
    try testing.expect(std.mem.indexOf(u8, output, "Enter") != null);
    try testing.expect(std.mem.indexOf(u8, output, "Select") != null);
}

test "child helpBindings auto-populates help line" {
    var mock = MockWidgetWithBindings{};
    var w = WithHelpLine(MockWidgetWithBindings).init(&mock, .{});

    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try w.render(&fbs.writer());

    const output = fbs.getWritten();
    try testing.expect(std.mem.indexOf(u8, output, "Action A") != null);
    try testing.expect(std.mem.indexOf(u8, output, "Action B") != null);
}

test "child helpBindings responds to state change" {
    var mock = MockWidgetWithBindings{};
    var w = WithHelpLine(MockWidgetWithBindings).init(&mock, .{});

    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try w.render(&fbs.writer());
    fbs.reset();

    // Change child state
    mock.mode = .special;
    try w.render(&fbs.writer());

    const output = fbs.getWritten();
    try testing.expect(std.mem.indexOf(u8, output, "Special") != null);
    // Should NOT contain old bindings
    try testing.expect(std.mem.indexOf(u8, output, "Action A") == null);
}

test "override bindings take priority over child helpBindings" {
    var mock = MockWidgetWithBindings{};
    var w = WithHelpLine(MockWidgetWithBindings).init(&mock, .{
        .bindings = &.{
            .{ .key = "q", .action = "Quit" },
        },
    });

    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try w.render(&fbs.writer());

    const output = fbs.getWritten();
    try testing.expect(std.mem.indexOf(u8, output, "Quit") != null);
    // Child's bindings should NOT appear
    try testing.expect(std.mem.indexOf(u8, output, "Action A") == null);
}

test "widget without helpBindings gets empty help line" {
    var mock = MockWidget{};
    var w = WithHelpLine(MockWidget).init(&mock, .{});

    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try w.render(&fbs.writer());

    const output = fbs.getWritten();
    // Should still contain child content
    try testing.expect(std.mem.indexOf(u8, output, "mock content") != null);
}

test "first render uses newlines, subsequent uses cursor movement" {
    var mock = MockWidget{};
    var w = WithHelpLine(MockWidget).init(&mock, .{
        .bindings = &.{.{ .key = "q", .action = "Quit" }},
    });

    // First render
    var buf1: [4096]u8 = undefined;
    var fbs1 = std.io.fixedBufferStream(&buf1);
    try w.render(&fbs1.writer());
    const out1 = fbs1.getWritten();

    // First render should contain \n after child content
    const child_end = std.mem.indexOf(u8, out1, "mock content").? + "mock content".len;
    try testing.expect(std.mem.indexOf(u8, out1[child_end..], "\n") != null);

    // Second render
    var buf2: [4096]u8 = undefined;
    var fbs2 = std.io.fixedBufferStream(&buf2);
    try w.render(&fbs2.writer());
    const out2 = fbs2.getWritten();

    // Second render should use cursor down (\x1b[<n>B) instead of \n after child
    const child_end2 = std.mem.indexOf(u8, out2, "mock content").? + "mock content".len;
    const after_child = out2[child_end2..];
    // Should have cursor down escape before help line
    try testing.expect(std.mem.indexOf(u8, after_child, "\x1b[") != null);
    // Should NOT have bare \n as first movement
    try testing.expect(after_child[0] != '\n');
}
