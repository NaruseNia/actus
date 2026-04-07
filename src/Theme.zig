const Style = @import("Style.zig");

const Theme = @This();

/// Styles for `TextInput`.
pub const TextInput = struct {
    placeholder: Style = Style.fg(.bright_black),
};

/// Styles for `ListView`.
pub const ListView = struct {
    selected: Style = Style.fg(.cyan).setBold(),
    normal: Style = .{},
    count: Style = Style.fg(.bright_black),
    filter_placeholder: Style = Style.fg(.bright_black),
};

/// Styles for `HelpLine`.
pub const HelpLine = struct {
    key: Style = Style.fg(.cyan),
    action: Style = Style.fg(.bright_black),
    separator: Style = Style.fg(.bright_black),
};

text_input: TextInput = .{},
list_view: ListView = .{},
help_line: HelpLine = .{},

/// Built-in default theme.
pub const default: Theme = .{};

// -- Tests --

const std = @import("std");

test "default theme has expected styles" {
    const t = Theme.default;

    // TextInput: placeholder is bright_black
    try std.testing.expectEqual(
        Style.ColorSpec{ .ansi = .bright_black },
        t.text_input.placeholder.fg_color.?,
    );

    // ListView: selected is cyan + bold
    try std.testing.expectEqual(
        Style.ColorSpec{ .ansi = .cyan },
        t.list_view.selected.fg_color.?,
    );
    try std.testing.expect(t.list_view.selected.font.bold);

    // ListView: normal has no color
    try std.testing.expect(t.list_view.normal.fg_color == null);

    // HelpLine: key is cyan
    try std.testing.expectEqual(
        Style.ColorSpec{ .ansi = .cyan },
        t.help_line.key.fg_color.?,
    );
}

test "custom theme overrides" {
    const custom = Theme{
        .text_input = .{
            .placeholder = Style.fg(.red),
        },
        .list_view = .{
            .selected = Style.fg(.green).setBold(),
        },
        .help_line = .{
            .key = Style.fg(.yellow),
        },
    };

    try std.testing.expectEqual(
        Style.ColorSpec{ .ansi = .red },
        custom.text_input.placeholder.fg_color.?,
    );
    try std.testing.expectEqual(
        Style.ColorSpec{ .ansi = .green },
        custom.list_view.selected.fg_color.?,
    );
    try std.testing.expectEqual(
        Style.ColorSpec{ .ansi = .yellow },
        custom.help_line.key.fg_color.?,
    );
}
