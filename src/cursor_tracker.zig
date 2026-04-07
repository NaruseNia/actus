const std = @import("std");

/// Analyzes rendered bytes to track cursor row position.
/// Counts '\n' (moves cursor down) and '\x1b[<N>A' (moves cursor up).
const CursorTracker = @This();

/// Row the cursor is on after all output (0-indexed from render start).
cursor_row: usize,
/// Maximum row reached during output.
max_row: usize,
/// Last explicit column set via '\x1b[<N>G', or null if none.
cursor_col: ?u16,

pub fn analyze(bytes: []const u8) CursorTracker {
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

/// Scan bytes for the last '\x1b[<N>G' and return the column (0-indexed).
pub fn findLastColumn(bytes: []const u8) ?u16 {
    var col: ?u16 = null;
    var i: usize = 0;
    while (i < bytes.len) {
        if (bytes[i] == '\x1b' and i + 1 < bytes.len and bytes[i + 1] == '[') {
            i += 2;
            var n: usize = 0;
            var has_num = false;
            while (i < bytes.len and bytes[i] >= '0' and bytes[i] <= '9') {
                n = n * 10 + (bytes[i] - '0');
                has_num = true;
                i += 1;
            }
            if (i < bytes.len) {
                if (bytes[i] == 'G') {
                    col = if (has_num and n > 0) @intCast(n - 1) else 0;
                }
                i += 1;
            }
        } else {
            i += 1;
        }
    }
    return col;
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
