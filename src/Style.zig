const std = @import("std");

const Style = @This();

/// Standard ANSI foreground/background colors.
pub const Color = enum(u8) {
    black = 0,
    red = 1,
    green = 2,
    yellow = 3,
    blue = 4,
    magenta = 5,
    cyan = 6,
    white = 7,
    default = 9,
    bright_black = 60,
    bright_red = 61,
    bright_green = 62,
    bright_yellow = 63,
    bright_blue = 64,
    bright_magenta = 65,
    bright_cyan = 66,
    bright_white = 67,
};

/// 256-color or RGB color specification.
pub const ColorSpec = union(enum) {
    ansi: Color,
    @"256": u8,
    rgb: struct { r: u8, g: u8, b: u8 },
};

pub const FontStyle = packed struct {
    bold: bool = false,
    dim: bool = false,
    italic: bool = false,
    underline: bool = false,
    blink: bool = false,
    inverse: bool = false,
    strikethrough: bool = false,
    _pad: u1 = 0,
};

fg_color: ?ColorSpec = null,
bg_color: ?ColorSpec = null,
font: FontStyle = .{},

/// Create a style with a foreground ANSI color.
pub fn fg(color: Color) Style {
    return .{ .fg_color = .{ .ansi = color } };
}

/// Create a style with a background ANSI color.
pub fn bg(color: Color) Style {
    return .{ .bg_color = .{ .ansi = color } };
}

/// Create a style with a 256-color foreground.
pub fn fg256(code: u8) Style {
    return .{ .fg_color = .{ .@"256" = code } };
}

/// Create a style with an RGB foreground.
pub fn fgRgb(r: u8, g: u8, b: u8) Style {
    return .{ .fg_color = .{ .rgb = .{ .r = r, .g = g, .b = b } } };
}

/// Create a style with an RGB background.
pub fn bgRgb(r: u8, g: u8, b: u8) Style {
    return .{ .bg_color = .{ .rgb = .{ .r = r, .g = g, .b = b } } };
}

pub fn bold() Style {
    return .{ .font = .{ .bold = true } };
}

pub fn dim() Style {
    return .{ .font = .{ .dim = true } };
}

pub fn italic() Style {
    return .{ .font = .{ .italic = true } };
}

pub fn underline() Style {
    return .{ .font = .{ .underline = true } };
}

pub fn strikethrough() Style {
    return .{ .font = .{ .strikethrough = true } };
}

// -- Builder methods for chaining --

pub fn setFg(self: Style, color: Color) Style {
    var s = self;
    s.fg_color = .{ .ansi = color };
    return s;
}

pub fn setFg256(self: Style, code: u8) Style {
    var s = self;
    s.fg_color = .{ .@"256" = code };
    return s;
}

pub fn setFgRgb(self: Style, r: u8, g: u8, b: u8) Style {
    var s = self;
    s.fg_color = .{ .rgb = .{ .r = r, .g = g, .b = b } };
    return s;
}

pub fn setBg(self: Style, color: Color) Style {
    var s = self;
    s.bg_color = .{ .ansi = color };
    return s;
}

pub fn setBg256(self: Style, code: u8) Style {
    var s = self;
    s.bg_color = .{ .@"256" = code };
    return s;
}

pub fn setBgRgb(self: Style, r: u8, g: u8, b: u8) Style {
    var s = self;
    s.bg_color = .{ .rgb = .{ .r = r, .g = g, .b = b } };
    return s;
}

pub fn setBold(self: Style) Style {
    var s = self;
    s.font.bold = true;
    return s;
}

pub fn setDim(self: Style) Style {
    var s = self;
    s.font.dim = true;
    return s;
}

pub fn setItalic(self: Style) Style {
    var s = self;
    s.font.italic = true;
    return s;
}

pub fn setUnderline(self: Style) Style {
    var s = self;
    s.font.underline = true;
    return s;
}

pub fn setStrikethrough(self: Style) Style {
    var s = self;
    s.font.strikethrough = true;
    return s;
}

pub fn setInverse(self: Style) Style {
    var s = self;
    s.font.inverse = true;
    return s;
}

// -- Output --

/// Write the ANSI escape sequence to enable this style.
pub fn writeStart(self: Style, writer: anytype) !void {
    // Collect SGR parameters
    var params: [16]u32 = undefined;
    var len: usize = 0;

    // Font styles
    if (self.font.bold) {
        params[len] = 1;
        len += 1;
    }
    if (self.font.dim) {
        params[len] = 2;
        len += 1;
    }
    if (self.font.italic) {
        params[len] = 3;
        len += 1;
    }
    if (self.font.underline) {
        params[len] = 4;
        len += 1;
    }
    if (self.font.blink) {
        params[len] = 5;
        len += 1;
    }
    if (self.font.inverse) {
        params[len] = 7;
        len += 1;
    }
    if (self.font.strikethrough) {
        params[len] = 9;
        len += 1;
    }

    if (len == 0 and self.fg_color == null and self.bg_color == null) return;

    try writer.writeAll("\x1b[");

    for (0..len) |i| {
        if (i > 0) try writer.writeAll(";");
        try writer.print("{d}", .{params[i]});
    }

    // Foreground
    if (self.fg_color) |fgc| {
        if (len > 0) try writer.writeAll(";");
        try writeColorParam(writer, fgc, 30);
        len += 1;
    }

    // Background
    if (self.bg_color) |bgc| {
        if (len > 0 or self.fg_color != null) try writer.writeAll(";");
        try writeColorParam(writer, bgc, 40);
    }

    try writer.writeAll("m");
}

/// Write the reset escape sequence.
pub fn writeEnd(_: Style, writer: anytype) !void {
    try writer.writeAll("\x1b[0m");
}

/// Write styled text: start + content + reset.
pub fn write(self: Style, writer: anytype, text: []const u8) !void {
    try self.writeStart(writer);
    try writer.writeAll(text);
    try self.writeEnd(writer);
}

/// Print formatted styled text.
pub fn print(self: Style, writer: anytype, comptime fmt: []const u8, args: anytype) !void {
    try self.writeStart(writer);
    try writer.print(fmt, args);
    try self.writeEnd(writer);
}

fn writeColorParam(writer: anytype, color: ColorSpec, base: u8) !void {
    switch (color) {
        .ansi => |c| {
            const code = @intFromEnum(c);
            if (code >= 60) {
                // bright colors: 90-97 fg, 100-107 bg
                try writer.print("{d}", .{base + 60 + (code - 60)});
            } else {
                try writer.print("{d}", .{@as(u16, base) + code});
            }
        },
        .@"256" => |c| {
            // 38;5;N (fg) or 48;5;N (bg)
            try writer.print("{d};5;{d}", .{ base + 8, c });
        },
        .rgb => |c| {
            // 38;2;R;G;B (fg) or 48;2;R;G;B (bg)
            try writer.print("{d};2;{d};{d};{d}", .{ base + 8, c.r, c.g, c.b });
        },
    }
}

// -- Tests --

test "fg red produces correct escape" {
    var buf: [64]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const writer = fbs.writer();
    const style = Style.fg(.red);
    try style.write(&writer, "hello");
    try std.testing.expectEqualStrings("\x1b[31mhello\x1b[0m", fbs.getWritten());
}

test "bold + green fg" {
    var buf: [64]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const writer = fbs.writer();
    const style = Style.bold().setFg(.green);
    try style.write(&writer, "ok");
    try std.testing.expectEqualStrings("\x1b[1;32mok\x1b[0m", fbs.getWritten());
}

test "bright color" {
    var buf: [64]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const writer = fbs.writer();
    const style = Style.fg(.bright_cyan);
    try style.write(&writer, "hi");
    try std.testing.expectEqualStrings("\x1b[96mhi\x1b[0m", fbs.getWritten());
}

test "256 color fg" {
    var buf: [64]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const writer = fbs.writer();
    const style = Style.fg256(208);
    try style.write(&writer, "x");
    try std.testing.expectEqualStrings("\x1b[38;5;208mx\x1b[0m", fbs.getWritten());
}

test "rgb fg" {
    var buf: [64]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const writer = fbs.writer();
    const style = Style.fgRgb(255, 128, 0);
    try style.write(&writer, "y");
    try std.testing.expectEqualStrings("\x1b[38;2;255;128;0my\x1b[0m", fbs.getWritten());
}

test "fg + bg combination" {
    var buf: [64]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const writer = fbs.writer();
    const style = Style.fg(.white).setBg(.blue);
    try style.write(&writer, "ab");
    try std.testing.expectEqualStrings("\x1b[37;44mab\x1b[0m", fbs.getWritten());
}

test "empty style writes nothing extra" {
    var buf: [64]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const writer = fbs.writer();
    const style = Style{};
    try style.write(&writer, "plain");
    try std.testing.expectEqualStrings("plain\x1b[0m", fbs.getWritten());
}

test "print formatted" {
    var buf: [64]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const writer = fbs.writer();
    const style = Style.fg(.red);
    try style.print(&writer, "n={d}", .{42});
    try std.testing.expectEqualStrings("\x1b[31mn=42\x1b[0m", fbs.getWritten());
}
