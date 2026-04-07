const std = @import("std");
const Event = @import("event.zig").Event;

/// Result of handling an event.
pub const HandleResult = enum {
    /// Widget consumed the event; do not propagate further.
    consumed,
    /// Widget did not handle the event; pass to the next handler.
    ignored,
    /// Widget is done; the event loop should exit.
    done,
};

/// Layout information for widgets that track their own height and cursor position.
/// Widgets can optionally implement `layoutInfo() ?LayoutInfo` to provide this.
pub const LayoutInfo = struct {
    /// Total number of lines the widget occupies.
    total_lines: usize,
    /// Row the cursor is on (0-indexed from widget start).
    cursor_line: usize,
};

/// Comptime check: asserts that T has the required widget methods.
/// A valid widget must implement:
///   - handleEvent(self: *T, ev: Event) HandleResult
///   - render(self: *T, writer: anytype) !void
///   - needsRender(self: *const T) bool
pub fn assertIsWidget(comptime T: type) void {
    const has_handle_event = @hasDecl(T, "handleEvent");
    const has_render = @hasDecl(T, "render");
    const has_needs_render = @hasDecl(T, "needsRender");

    if (!has_handle_event) {
        @compileError(@typeName(T) ++ " must implement handleEvent(self, Event) HandleResult");
    }
    if (!has_render) {
        @compileError(@typeName(T) ++ " must implement render(self, writer) !void");
    }
    if (!has_needs_render) {
        @compileError(@typeName(T) ++ " must implement needsRender(self) bool");
    }
}

// -- Tests --

const TestWidget = struct {
    dirty: bool = true,

    pub fn handleEvent(self: *TestWidget, ev: Event) HandleResult {
        _ = self;
        _ = ev;
        return .consumed;
    }

    pub fn render(self: *TestWidget, writer: anytype) !void {
        _ = self;
        try writer.writeAll("hello");
    }

    pub fn needsRender(self: *const TestWidget) bool {
        return self.dirty;
    }
};

test "assertIsWidget accepts valid widget" {
    // If this compiles, the assertion passed.
    comptime assertIsWidget(TestWidget);
}

test "TestWidget implements HandleResult correctly" {
    var w = TestWidget{};
    const result = w.handleEvent(.{ .key = .enter });
    try std.testing.expectEqual(HandleResult.consumed, result);
}

test "TestWidget render writes to writer" {
    var w = TestWidget{};
    var buf: [32]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try w.render(fbs.writer());
    try std.testing.expectEqualStrings("hello", fbs.getWritten());
}

test "TestWidget needsRender returns dirty state" {
    const w = TestWidget{ .dirty = true };
    try std.testing.expect(w.needsRender());
    const w2 = TestWidget{ .dirty = false };
    try std.testing.expect(!w2.needsRender());
}
