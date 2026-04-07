const std = @import("std");
const CursorTracker = @import("cursor_tracker.zig");

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

/// Get widget layout after render. Prefers the widget's own fields
/// (last_rendered_lines, cursor_line) over byte-level analysis, because
/// CursorTracker can be fooled by cursor movements the widget makes
/// to clear leftover lines from a previous taller render.
pub fn getWidgetLayout(widget: anytype, rendered_bytes: []const u8) WidgetLayout {
    const WidgetT = WidgetPtrChild(@TypeOf(widget));
    const has_rendered_lines = @hasField(WidgetT, "last_rendered_lines");
    const has_cursor_line = @hasField(WidgetT, "cursor_line");

    if (has_rendered_lines and has_cursor_line) {
        const total = widget.last_rendered_lines;
        const cursor_row = widget.cursor_line;
        const bottom = if (total > 0) total - 1 else 0;
        const lines_below: u16 = @intCast(bottom -| cursor_row);
        const col = CursorTracker.findLastColumn(rendered_bytes);
        return .{
            .lines_below = lines_below,
            .cursor_col = col,
            .total_lines = total,
            .cursor_row = cursor_row,
        };
    } else {
        const info = CursorTracker.analyze(rendered_bytes);
        const lines_below: u16 = @intCast(info.max_row -| info.cursor_row);
        return .{
            .lines_below = lines_below,
            .cursor_col = info.cursor_col,
            .total_lines = info.max_row + 1,
            .cursor_row = info.cursor_row,
        };
    }
}

/// Extract the child type from a single-level pointer type.
fn WidgetPtrChild(comptime T: type) type {
    return @typeInfo(T).pointer.child;
}

// -- Tests --

const MockWidgetWithLayout = struct {
    last_rendered_lines: usize = 5,
    cursor_line: usize = 1,
};

const MockWidgetWithoutLayout = struct {
    value: u8 = 0,
};

test "uses widget fields when available" {
    const mock = MockWidgetWithLayout{ .last_rendered_lines = 5, .cursor_line = 1 };
    // Rendered bytes with a column set: \x1b[3G
    const layout = getWidgetLayout(&mock, "\x1b[3G");
    try std.testing.expectEqual(@as(u16, 3), layout.lines_below); // (5-1) - 1
    try std.testing.expectEqual(@as(u16, 2), layout.cursor_col.?); // 3G = col 2 (0-indexed)
    try std.testing.expectEqual(@as(usize, 5), layout.total_lines);
    try std.testing.expectEqual(@as(usize, 1), layout.cursor_row);
}

test "falls back to CursorTracker when fields missing" {
    const mock = MockWidgetWithoutLayout{};
    // 3 lines: "a\nb\nc" -> max_row=2, cursor_row=2
    const layout = getWidgetLayout(&mock, "a\nb\nc");
    try std.testing.expectEqual(@as(u16, 0), layout.lines_below); // max_row - cursor_row = 0
    try std.testing.expect(layout.cursor_col == null);
    try std.testing.expectEqual(@as(usize, 3), layout.total_lines);
    try std.testing.expectEqual(@as(usize, 2), layout.cursor_row);
}

test "single line widget without layout fields" {
    const mock = MockWidgetWithoutLayout{};
    const layout = getWidgetLayout(&mock, "hello");
    try std.testing.expectEqual(@as(u16, 0), layout.lines_below);
    try std.testing.expectEqual(@as(usize, 1), layout.total_lines);
    try std.testing.expectEqual(@as(usize, 0), layout.cursor_row);
}
