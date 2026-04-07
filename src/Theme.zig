const Style = @import("Style.zig");

const Theme = @This();

/// Main emphasis — selected items, active elements.
primary: Style = Style.fg(.cyan).setBold(),
/// Secondary emphasis — key labels, highlights.
accent: Style = Style.fg(.cyan),
/// Dim/supporting text — placeholders, counts, descriptions.
muted: Style = Style.fg(.bright_black),
/// Normal body text.
text: Style = .{},

/// Built-in default theme.
pub const default: Theme = .{};

// -- Tests --

const std = @import("std");

test "default theme has expected styles" {
    const t = Theme.default;

    // primary: cyan + bold
    try std.testing.expectEqual(
        Style.ColorSpec{ .ansi = .cyan },
        t.primary.fg_color.?,
    );
    try std.testing.expect(t.primary.font.bold);

    // accent: cyan (no bold)
    try std.testing.expectEqual(
        Style.ColorSpec{ .ansi = .cyan },
        t.accent.fg_color.?,
    );
    try std.testing.expect(!t.accent.font.bold);

    // muted: bright_black
    try std.testing.expectEqual(
        Style.ColorSpec{ .ansi = .bright_black },
        t.muted.fg_color.?,
    );

    // text: no color
    try std.testing.expect(t.text.fg_color == null);
}

test "custom theme overrides" {
    const custom = Theme{
        .primary = Style.fg(.green).setBold(),
        .accent = Style.fg(.yellow),
        .muted = Style.fg(.white).setDim(),
    };

    try std.testing.expectEqual(
        Style.ColorSpec{ .ansi = .green },
        custom.primary.fg_color.?,
    );
    try std.testing.expectEqual(
        Style.ColorSpec{ .ansi = .yellow },
        custom.accent.fg_color.?,
    );
    try std.testing.expectEqual(
        Style.ColorSpec{ .ansi = .white },
        custom.muted.fg_color.?,
    );
    try std.testing.expect(custom.muted.font.dim);
    // text unchanged (default)
    try std.testing.expect(custom.text.fg_color == null);
}
