const std = @import("std");
const builtin = @import("builtin");
const Terminal = @import("Terminal.zig");
const input = @import("input.zig");
const Event = @import("event.zig").Event;
const Widget = @import("Widget.zig");
const layout = @import("layout.zig");

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
    const initial = layout.getWidgetLayout(widget, fbs.getWritten());
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
            const wl = layout.getWidgetLayout(widget, fbs.getWritten());
            // Re-render: lines already exist, use cursor movement instead of \n.
            try Terminal.moveCursorDown(&writer, wl.lines_below + 1);
            try writer.writeAll("\r");
            try help_line.render(&writer);
            try Terminal.clearFromCursor(&writer);
            try Terminal.moveCursorUp(&writer, wl.lines_below + 1);
            if (wl.cursor_col) |col| try Terminal.moveCursorTo(&writer, col);
            try Terminal.showCursor(&writer);
            try self.writeToStdout(fbs.getWritten());
            fbs.reset();
        }
    }

    // Final newline so the shell prompt doesn't overlap
    try self.writeToStdout("\r\n");
}

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
