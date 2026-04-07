const std = @import("std");
const Event = @import("../event.zig").Event;
const Widget = @import("../Widget.zig");
const Terminal = @import("../Terminal.zig");
const Style = @import("../Style.zig");
const Theme = @import("../Theme.zig");

const HelpLine = @This();

comptime {
    Widget.assertIsWidget(HelpLine);
}

// -- Configuration --

pub const Binding = struct {
    key: []const u8,
    action: []const u8,
};

pub const Config = struct {
    /// Key-action pairs to display.
    bindings: []const Binding = &.{},
    /// Separator between bindings.
    separator: []const u8 = "   ",
    /// Style applied to the key portion. Overrides theme.accent when set.
    key_style: ?Style = null,
    /// Style applied to the action description. Overrides theme.muted when set.
    action_style: ?Style = null,
    /// Style applied to the separator. Overrides theme.muted when set.
    separator_style: ?Style = null,
    /// Theme providing default styles.
    theme: Theme = Theme.default,
};

// -- State --

dirty: bool = true,
config: Config,

pub fn init(config: Config) HelpLine {
    return .{ .config = config };
}

/// Replace bindings at runtime.
pub fn setBindings(self: *HelpLine, bindings: []const Binding) void {
    self.config.bindings = bindings;
    self.dirty = true;
}

// -- Widget interface --

pub fn handleEvent(_: *HelpLine, _: Event) Widget.HandleResult {
    return .ignored;
}

pub fn render(self: *HelpLine, writer: anytype) !void {
    try Terminal.clearLine(writer);

    const k_style = self.config.key_style orelse self.config.theme.accent;
    const a_style = self.config.action_style orelse self.config.theme.muted;
    const s_style = self.config.separator_style orelse self.config.theme.muted;

    for (self.config.bindings, 0..) |binding, i| {
        if (i > 0) {
            try s_style.write(writer, self.config.separator);
        }
        try k_style.write(writer, binding.key);
        try writer.writeAll(" ");
        try a_style.write(writer, binding.action);
    }

    self.dirty = false;
}

pub fn needsRender(self: *const HelpLine) bool {
    return self.dirty;
}

// -- Tests --

test "handleEvent always returns ignored" {
    var hl = HelpLine.init(.{});
    try std.testing.expectEqual(Widget.HandleResult.ignored, hl.handleEvent(.{ .key = .enter }));
    try std.testing.expectEqual(Widget.HandleResult.ignored, hl.handleEvent(.{ .key = .escape }));
}

test "render writes bindings with styles and separators" {
    var buf: [512]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const writer = fbs.writer();

    var hl = HelpLine.init(.{
        .bindings = &.{
            .{ .key = "Enter", .action = "Select" },
            .{ .key = "Esc", .action = "Quit" },
        },
    });

    try hl.render(&writer);

    const output = fbs.getWritten();

    // Should contain clear-line escape
    try std.testing.expect(std.mem.indexOf(u8, output, "\r\x1b[2K") != null);
    // Should contain the key and action text
    try std.testing.expect(std.mem.indexOf(u8, output, "Enter") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Select") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Esc") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Quit") != null);
    // Should contain the separator text (wrapped in style escapes)
    try std.testing.expect(std.mem.indexOf(u8, output, "   ") != null);
    // Should not be dirty after render
    try std.testing.expect(!hl.needsRender());
}

test "render with no bindings writes only clear-line" {
    var buf: [64]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const writer = fbs.writer();

    var hl = HelpLine.init(.{});
    try hl.render(&writer);

    try std.testing.expectEqualStrings("\r\x1b[2K", fbs.getWritten());
}

test "needsRender reflects dirty state" {
    var hl = HelpLine.init(.{});
    try std.testing.expect(hl.needsRender());

    var buf: [64]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try hl.render(&fbs.writer());
    try std.testing.expect(!hl.needsRender());
}

test "setBindings marks dirty" {
    var buf: [64]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);

    var hl = HelpLine.init(.{});
    try hl.render(&fbs.writer());
    try std.testing.expect(!hl.needsRender());

    const new_bindings: []const Binding = &.{
        .{ .key = "q", .action = "Quit" },
    };
    hl.setBindings(new_bindings);
    try std.testing.expect(hl.needsRender());
}

test "render uses custom theme styles" {
    var buf: [512]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const writer = fbs.writer();

    const custom_theme = Theme{ .accent = Style.fg(.red), .muted = Style.fg(.green) };
    var hl = HelpLine.init(.{
        .bindings = &.{
            .{ .key = "Enter", .action = "Select" },
        },
        .theme = custom_theme,
    });

    try hl.render(&writer);

    const output = fbs.getWritten();
    // red fg for key = \x1b[31m, green fg for action = \x1b[32m
    try std.testing.expect(std.mem.indexOf(u8, output, "\x1b[31m") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\x1b[32m") != null);
}

test "key_style overrides theme" {
    var buf: [512]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const writer = fbs.writer();

    var hl = HelpLine.init(.{
        .bindings = &.{
            .{ .key = "q", .action = "Quit" },
        },
        .key_style = Style.fg(.yellow),
        .theme = Theme{ .accent = Style.fg(.red) },
    });

    try hl.render(&writer);

    const output = fbs.getWritten();
    // yellow fg = \x1b[33m, not red \x1b[31m
    try std.testing.expect(std.mem.indexOf(u8, output, "\x1b[33m") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\x1b[31m") == null);
}

test "render with custom separator" {
    var buf: [512]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const writer = fbs.writer();

    var hl = HelpLine.init(.{
        .bindings = &.{
            .{ .key = "a", .action = "A" },
            .{ .key = "b", .action = "B" },
        },
        .separator = " ~ ",
    });

    try hl.render(&writer);

    const output = fbs.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, output, " ~ ") != null);
}
