const std = @import("std");
const CursorTracker = @import("cursor_tracker.zig");
const Widget = @import("Widget.zig");

/// Layout information extracted from a widget after rendering.
pub const WidgetLayout = struct {
    /// Number of lines from the cursor to the bottom of the widget.
    lines_below: u16,
    /// Cursor column to restore, or null if not set.
    cursor_col: ?u16,
    /// Total number of lines the widget occupies.
    total_lines: usize,
    /// Row the cursor is on (0-indexed from widget start).
    cursor_row: usize,
};

/// Get widget layout after render. Prefers the widget's `layoutInfo()` method
/// over byte-level analysis, because CursorTracker can be fooled by cursor
/// movements the widget makes to clear leftover lines from a previous taller render.
pub fn getWidgetLayout(widget: anytype, rendered_bytes: []const u8) WidgetLayout {
    const WidgetT = WidgetPtrChild(@TypeOf(widget));

    if (comptime @hasDecl(WidgetT, "layoutInfo")) {
        if (widget.layoutInfo()) |info| {
            const bottom = if (info.total_lines > 0) info.total_lines - 1 else 0;
            const lines_below: u16 = @intCast(bottom -| info.cursor_line);
            const col = CursorTracker.findLastColumn(rendered_bytes);
            return .{
                .lines_below = lines_below,
                .cursor_col = col,
                .total_lines = info.total_lines,
                .cursor_row = info.cursor_line,
            };
        }
    }

    // Fallback: analyze the raw output bytes.
    const info = CursorTracker.analyze(rendered_bytes);
    const lines_below: u16 = @intCast(info.max_row -| info.cursor_row);
    return .{
        .lines_below = lines_below,
        .cursor_col = info.cursor_col,
        .total_lines = info.max_row + 1,
        .cursor_row = info.cursor_row,
    };
}

/// Extract the child type from a single-level pointer type.
fn WidgetPtrChild(comptime T: type) type {
    return @typeInfo(T).pointer.child;
}

// -- Tests --

const MockWidgetWithLayout = struct {
    total: usize = 5,
    cursor: usize = 1,

    pub fn layoutInfo(self: *const MockWidgetWithLayout) ?Widget.LayoutInfo {
        return .{ .total_lines = self.total, .cursor_line = self.cursor };
    }
};

const MockWidgetWithoutLayout = struct {
    value: u8 = 0,
};

test "uses layoutInfo when available" {
    const mock = MockWidgetWithLayout{ .total = 5, .cursor = 1 };
    // Rendered bytes with a column set: \x1b[3G
    const wl = getWidgetLayout(&mock, "\x1b[3G");
    try std.testing.expectEqual(@as(u16, 3), wl.lines_below); // (5-1) - 1
    try std.testing.expectEqual(@as(u16, 2), wl.cursor_col.?); // 3G = col 2 (0-indexed)
    try std.testing.expectEqual(@as(usize, 5), wl.total_lines);
    try std.testing.expectEqual(@as(usize, 1), wl.cursor_row);
}

test "falls back to CursorTracker when layoutInfo missing" {
    const mock = MockWidgetWithoutLayout{};
    // 3 lines: "a\nb\nc" -> max_row=2, cursor_row=2
    const wl = getWidgetLayout(&mock, "a\nb\nc");
    try std.testing.expectEqual(@as(u16, 0), wl.lines_below);
    try std.testing.expect(wl.cursor_col == null);
    try std.testing.expectEqual(@as(usize, 3), wl.total_lines);
    try std.testing.expectEqual(@as(usize, 2), wl.cursor_row);
}

test "single line widget without layoutInfo" {
    const mock = MockWidgetWithoutLayout{};
    const wl = getWidgetLayout(&mock, "hello");
    try std.testing.expectEqual(@as(u16, 0), wl.lines_below);
    try std.testing.expectEqual(@as(usize, 1), wl.total_lines);
    try std.testing.expectEqual(@as(usize, 0), wl.cursor_row);
}
