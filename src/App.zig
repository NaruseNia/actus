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

    // Initial render: use \n to establish lines on the terminal.
    try Terminal.hideCursor(&writer);
    try widget.render(&writer);
    const initial = getWidgetLayout(widget, &fbs);
    // Use \n to scroll and create lines for the first time.
    for (0..initial.lines_below + 1) |_| {
        try writer.writeAll("\n");
    }
    try help_line.render(&writer);
    try Terminal.clearFromCursor(&writer);
    try Terminal.moveCursorUp(&writer, initial.lines_below + 1);
    if (initial.cursor_col) |col| try Terminal.moveCursorTo(&writer, col);
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
            try widget.render(&writer);
            const layout = getWidgetLayout(widget, &fbs);
            // Re-render: lines already exist, use cursor movement instead of \n.
            try Terminal.moveCursorDown(&writer, layout.lines_below + 1);
            try writer.writeAll("\r");
            try help_line.render(&writer);
            try Terminal.clearFromCursor(&writer);
            try Terminal.moveCursorUp(&writer, layout.lines_below + 1);
            if (layout.cursor_col) |col| try Terminal.moveCursorTo(&writer, col);
            try Terminal.showCursor(&writer);
            try self.writeToStdout(fbs.getWritten());
            fbs.reset();
        }
    }

    // Final newline so the shell prompt doesn't overlap
    try self.writeToStdout("\r\n");
}

/// Layout info needed to position the help line below a widget.
const WidgetLayout = struct {
    /// Number of lines from the cursor to the bottom of the widget.
    lines_below: u16,
    /// Cursor column to restore, or null if not set.
    cursor_col: ?u16,
};

/// Get widget layout after render. Prefers the widget's own fields
/// (last_rendered_lines, cursor_line) over byte-level analysis, because
/// CursorTracker can be fooled by cursor movements the widget makes
/// to clear leftover lines from a previous taller render.
fn getWidgetLayout(widget: anytype, fbs: anytype) WidgetLayout {
    const WidgetT = @TypeOf(widget.*);
    const has_rendered_lines = @hasField(WidgetT, "last_rendered_lines");
    const has_cursor_line = @hasField(WidgetT, "cursor_line");

    if (has_rendered_lines and has_cursor_line) {
        // Widget reports its own height — use it directly.
        const total = widget.last_rendered_lines;
        const cursor_row = widget.cursor_line;
        const bottom = if (total > 0) total - 1 else 0;
        const lines_below: u16 = @intCast(bottom -| cursor_row);
        // Scan the rendered output for the last \x1b[<N>G to find cursor column.
        const col = CursorTracker.findLastColumn(fbs.getWritten());
        return .{ .lines_below = lines_below, .cursor_col = col };
    } else {
        // Fallback: analyze the raw output bytes.
        const info = CursorTracker.analyze(fbs.getWritten());
        const lines_below: u16 = @intCast(info.max_row -| info.cursor_row);
        return .{ .lines_below = lines_below, .cursor_col = info.cursor_col };
    }
}

const CursorTracker = @import("cursor_tracker.zig");

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
