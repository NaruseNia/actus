const std = @import("std");
const builtin = @import("builtin");
const Terminal = @import("Terminal.zig");
const input = @import("input.zig");
const Event = @import("event.zig").Event;
const Widget = @import("Widget.zig");

const App = @This();

terminal: Terminal,
running: bool = true,

pub fn init() !App {
    var terminal = try Terminal.init();
    try terminal.enableRawMode();
    return .{ .terminal = terminal };
}

pub fn deinit(self: *App) void {
    self.terminal.disableRawMode();
}

/// Run the event loop with a single widget.
/// The widget must implement handleEvent, render, and needsRender (see Widget.zig).
pub fn run(self: *App, widget: anytype) !void {
    comptime Widget.assertIsWidget(@TypeOf(widget.*));

    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const writer = fbs.writer();

    // Initial render
    try Terminal.hideCursor(&writer);
    try widget.render(&writer);
    try Terminal.showCursor(&writer);
    try self.writeToStdout(fbs.getWritten());
    fbs.reset();

    while (self.running) {
        const maybe_event = try input.readEvent(self.terminal.stdin_handle);
        const ev = maybe_event orelse continue;

        // Ctrl-C exits the loop
        switch (ev) {
            .key => |key| switch (key) {
                .ctrl => |c| if (c == 'c') {
                    self.running = false;
                    continue;
                },
                else => {},
            },
        }

        const result = widget.handleEvent(ev);
        if (result == .done) {
            self.running = false;
            continue;
        }

        if (widget.needsRender()) {
            try Terminal.hideCursor(&writer);
            try widget.render(&writer);
            try Terminal.showCursor(&writer);
            try self.writeToStdout(fbs.getWritten());
            fbs.reset();
        }
    }

    // Final newline so the shell prompt doesn't overlap
    try self.writeToStdout("\r\n");
}

/// Run the event loop with a widget and a help line displayed below it.
/// The help line is rendered after the last line of the widget, regardless
/// of how many lines the widget occupies or where it leaves the cursor.
pub fn runWithHelpLine(self: *App, widget: anytype, help_line: anytype) !void {
    comptime Widget.assertIsWidget(@TypeOf(widget.*));
    comptime Widget.assertIsWidget(@TypeOf(help_line.*));

    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const writer = fbs.writer();

    // Initial render
    try Terminal.hideCursor(&writer);
    try renderWithHelpLine(widget, help_line, &writer, &fbs);
    try Terminal.showCursor(&writer);
    try self.writeToStdout(fbs.getWritten());
    fbs.reset();

    while (self.running) {
        const maybe_event = try input.readEvent(self.terminal.stdin_handle);
        const ev = maybe_event orelse continue;

        // Ctrl-C exits the loop
        switch (ev) {
            .key => |key| switch (key) {
                .ctrl => |c| if (c == 'c') {
                    self.running = false;
                    continue;
                },
                else => {},
            },
        }

        const result = widget.handleEvent(ev);
        if (result == .done) {
            self.running = false;
            continue;
        }

        if (widget.needsRender() or help_line.needsRender()) {
            try Terminal.hideCursor(&writer);
            try renderWithHelpLine(widget, help_line, &writer, &fbs);
            try Terminal.showCursor(&writer);
            try self.writeToStdout(fbs.getWritten());
            fbs.reset();
        }
    }

    // Final newline so the shell prompt doesn't overlap
    try self.writeToStdout("\r\n");
}

/// Render the widget, then the help line below it, then restore cursor.
fn renderWithHelpLine(
    widget: anytype,
    help_line: anytype,
    writer: anytype,
    fbs: anytype,
) !void {
    // Record buffer position before widget render to measure output.
    const before = fbs.pos;
    try widget.render(writer);
    const after = fbs.pos;

    // Analyze the widget's output to find total lines and cursor row.
    const widget_output = fbs.buffer[before..after];
    const info = CursorTracker.analyze(widget_output);

    // Move cursor from where the widget left it to one line past the
    // bottom of the widget's rendered area, then draw the help line.
    const lines_below_cursor = info.max_row - info.cursor_row;
    for (0..lines_below_cursor) |_| {
        try writer.writeAll("\n");
    }
    try writer.writeAll("\r\n");
    try help_line.render(writer);

    // Move cursor back to where the widget expects it.
    const help_lines_below: u16 = @intCast(lines_below_cursor + 1);
    try Terminal.moveCursorUp(writer, help_lines_below);

    // Restore horizontal cursor position if the widget set one.
    if (info.cursor_col) |col| {
        try Terminal.moveCursorTo(writer, col);
    }
}

/// Analyzes rendered bytes to track cursor row position.
/// Counts '\n' (moves cursor down) and '\x1b[<N>A' (moves cursor up).
const CursorTracker = struct {
    /// Row the cursor is on after all output (0-indexed from render start).
    cursor_row: usize,
    /// Maximum row reached during output.
    max_row: usize,
    /// Last explicit column set via '\x1b[<N>G', or null if none.
    cursor_col: ?u16,

    fn analyze(bytes: []const u8) CursorTracker {
        var row: usize = 0;
        var max_row: usize = 0;
        var col: ?u16 = null;
        var i: usize = 0;

        while (i < bytes.len) {
            if (bytes[i] == '\n') {
                row += 1;
                if (row > max_row) max_row = row;
                i += 1;
            } else if (bytes[i] == '\x1b' and i + 1 < bytes.len and bytes[i + 1] == '[') {
                // Parse CSI sequence: \x1b[ <number> <letter>
                i += 2;
                var n: usize = 0;
                var has_num = false;
                while (i < bytes.len and bytes[i] >= '0' and bytes[i] <= '9') {
                    n = n * 10 + (bytes[i] - '0');
                    has_num = true;
                    i += 1;
                }
                if (i < bytes.len) {
                    const cmd = bytes[i];
                    i += 1;
                    switch (cmd) {
                        'A' => { // Cursor Up
                            const up = if (has_num) n else 1;
                            row -|= up;
                        },
                        'B' => { // Cursor Down
                            const down = if (has_num) n else 1;
                            row += down;
                            if (row > max_row) max_row = row;
                        },
                        'G' => { // Cursor Horizontal Absolute (1-indexed)
                            if (has_num and n > 0) {
                                col = @intCast(n - 1);
                            } else {
                                col = 0;
                            }
                        },
                        else => {},
                    }
                }
            } else {
                i += 1;
            }
        }

        return .{
            .cursor_row = row,
            .max_row = max_row,
            .cursor_col = col,
        };
    }

    // -- Tests --

    test "single line no escapes" {
        const info = analyze("hello");
        try std.testing.expectEqual(@as(usize, 0), info.cursor_row);
        try std.testing.expectEqual(@as(usize, 0), info.max_row);
        try std.testing.expect(info.cursor_col == null);
    }

    test "newlines count rows" {
        const info = analyze("a\nb\nc\nd");
        try std.testing.expectEqual(@as(usize, 3), info.cursor_row);
        try std.testing.expectEqual(@as(usize, 3), info.max_row);
    }

    test "cursor up reduces row" {
        // 3 newlines then move up 2
        const info = analyze("a\nb\nc\x1b[2A");
        try std.testing.expectEqual(@as(usize, 0), info.cursor_row);
        try std.testing.expectEqual(@as(usize, 2), info.max_row);
    }

    test "cursor up saturates at zero" {
        const info = analyze("a\n\x1b[5A");
        try std.testing.expectEqual(@as(usize, 0), info.cursor_row);
    }

    test "cursor horizontal absolute" {
        const info = analyze("\x1b[10G");
        try std.testing.expectEqual(@as(u16, 9), info.cursor_col.?);
    }

    test "complex sequence: newlines + up + column" {
        // 5 lines, cursor up 3, set column to 5
        const info = analyze("a\nb\nc\nd\ne\x1b[3A\x1b[5G");
        try std.testing.expectEqual(@as(usize, 1), info.cursor_row);
        try std.testing.expectEqual(@as(usize, 4), info.max_row);
        try std.testing.expectEqual(@as(u16, 4), info.cursor_col.?);
    }
};

fn writeToStdout(_: *const App, bytes: []const u8) !void {
    const stdout = std.fs.File.stdout();
    try stdout.writeAll(bytes);
}

// -- Tests --

// App.run requires a real terminal, so unit tests are limited.
// We test that init/deinit compile and the widget type check works.

const MockWidget = struct {
    rendered: bool = false,
    event_count: usize = 0,

    pub fn handleEvent(self: *MockWidget, _: Event) Widget.HandleResult {
        self.event_count += 1;
        return .consumed;
    }

    pub fn render(self: *MockWidget, _: anytype) !void {
        self.rendered = true;
    }

    pub fn needsRender(_: *const MockWidget) bool {
        return false;
    }
};

test "MockWidget satisfies widget interface" {
    comptime Widget.assertIsWidget(MockWidget);
}
