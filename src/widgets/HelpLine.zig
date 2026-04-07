const std = @import("std");
const Event = @import("../event.zig").Event;
const Widget = @import("../Widget.zig");
const Terminal = @import("../Terminal.zig");
const Style = @import("../Style.zig");

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
    separator: []const u8 = " | ",
    /// Style applied to the key portion.
    key_style: Style = Style.fg(.cyan),
    /// Style applied to the action description.
    action_style: Style = Style.fg(.bright_black),
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

    for (self.config.bindings, 0..) |binding, i| {
        if (i > 0) {
            try writer.writeAll(self.config.separator);
        }
        try self.config.key_style.write(writer, binding.key);
        try writer.writeAll(" ");
        try self.config.action_style.write(writer, binding.action);
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
    // Should contain the separator
    try std.testing.expect(std.mem.indexOf(u8, output, " │ ") != null);
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

test "render with custom separator" {
    var buf: [512]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const writer = fbs.writer();

    var hl = HelpLine.init(.{
        .bindings = &.{
            .{ .key = "a", .action = "A" },
            .{ .key = "b", .action = "B" },
        },
        .separator = " | ",
    });

    try hl.render(&writer);

    const output = fbs.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, output, " | ") != null);
    // Default separator should NOT appear
    try std.testing.expect(std.mem.indexOf(u8, output, "│") == null);
}
