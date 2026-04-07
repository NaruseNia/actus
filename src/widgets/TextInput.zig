const std = @import("std");
const Event = @import("../event.zig").Event;
const Key = @import("../event.zig").Key;
const Widget = @import("../Widget.zig");
const Terminal = @import("../Terminal.zig");
const Style = @import("../Style.zig");

const TextInput = @This();

comptime {
    Widget.assertIsWidget(TextInput);
}

// -- Configuration --

pub const Config = struct {
    /// Text displayed when the buffer is empty.
    placeholder: []const u8 = "",
    /// If set, display this character instead of actual input (for passwords).
    mask_char: ?u8 = null,
    /// Maximum number of codepoints allowed. null = unlimited.
    max_length: ?usize = null,
    /// If set, only these ASCII bytes are accepted as input.
    allowed_chars: ?[]const u8 = null,
    /// Style applied to the placeholder text.
    placeholder_style: Style = Style.fg(.bright_black),
};

// -- State --

/// UTF-8 encoded content buffer.
buffer: std.ArrayListUnmanaged(u8) = .empty,
/// Byte offset of cursor into buffer (always at a codepoint boundary).
cursor_byte: usize = 0,
/// Column position of cursor (codepoint count from start).
cursor_col: usize = 0,
/// Whether the widget needs to be re-rendered.
dirty: bool = true,
/// Whether the user has pressed Enter to confirm.
confirmed: bool = false,

config: Config,
allocator: std.mem.Allocator,

pub fn init(allocator: std.mem.Allocator, config: Config) TextInput {
    return .{
        .config = config,
        .allocator = allocator,
    };
}

pub fn deinit(self: *TextInput) void {
    self.buffer.deinit(self.allocator);
}

/// Returns the current input value as a UTF-8 string slice.
pub fn value(self: *const TextInput) []const u8 {
    return self.buffer.items;
}

/// Whether the user has confirmed the input with Enter.
pub fn isConfirmed(self: *const TextInput) bool {
    return self.confirmed;
}

// -- Widget interface --

pub fn handleEvent(self: *TextInput, ev: Event) Widget.HandleResult {
    return switch (ev) {
        .key => |key| self.handleKey(key),
    };
}

pub fn render(self: *TextInput, writer: anytype) !void {
    try Terminal.clearLine(writer);

    const text = self.buffer.items;
    if (text.len == 0) {
        // Show placeholder in configured style
        if (self.config.placeholder.len > 0) {
            try self.config.placeholder_style.write(writer, self.config.placeholder);
        }
        try Terminal.moveCursorTo(writer, 0);
    } else if (self.config.mask_char) |mask| {
        // Password mode
        const n = codepointCount(text);
        for (0..n) |_| {
            try writer.writeByte(mask);
        }
        try Terminal.moveCursorTo(writer, @intCast(self.cursor_col));
    } else {
        try writer.writeAll(text);
        try Terminal.moveCursorTo(writer, @intCast(self.cursor_col));
    }

    self.dirty = false;
}

pub fn needsRender(self: *const TextInput) bool {
    return self.dirty;
}

// -- Key handling --

fn handleKey(self: *TextInput, key: Key) Widget.HandleResult {
    switch (key) {
        .char => |cp| {
            self.insertChar(cp);
            return .consumed;
        },
        .backspace => {
            self.deleteBackward();
            return .consumed;
        },
        .delete => {
            self.deleteForward();
            return .consumed;
        },
        .left => {
            self.moveCursorLeft();
            return .consumed;
        },
        .right => {
            self.moveCursorRight();
            return .consumed;
        },
        .home => {
            self.cursor_byte = 0;
            self.cursor_col = 0;
            self.dirty = true;
            return .consumed;
        },
        .ctrl => |c| {
            if (c == 'a') {
                // Ctrl-A = Home
                self.cursor_byte = 0;
                self.cursor_col = 0;
                self.dirty = true;
                return .consumed;
            }
            if (c == 'e') {
                // Ctrl-E = End
                self.cursor_byte = self.buffer.items.len;
                self.cursor_col = codepointCount(self.buffer.items);
                self.dirty = true;
                return .consumed;
            }
            return .ignored;
        },
        .end => {
            self.cursor_byte = self.buffer.items.len;
            self.cursor_col = codepointCount(self.buffer.items);
            self.dirty = true;
            return .consumed;
        },
        .enter => {
            self.confirmed = true;
            return .consumed;
        },
        else => return .ignored,
    }
}

// -- Buffer operations --

fn insertChar(self: *TextInput, cp: u21) void {
    // Validate max length (in codepoints)
    if (self.config.max_length) |max| {
        if (codepointCount(self.buffer.items) >= max) return;
    }
    // Validate allowed characters (ASCII subset only)
    if (self.config.allowed_chars) |allowed| {
        if (cp < 128) {
            const byte: u8 = @intCast(cp);
            if (std.mem.indexOfScalar(u8, allowed, byte) == null) return;
        }
    }

    var encoded: [4]u8 = undefined;
    const len = std.unicode.utf8Encode(cp, &encoded) catch return;
    self.buffer.insertSlice(self.allocator, self.cursor_byte, encoded[0..len]) catch return;
    self.cursor_byte += len;
    self.cursor_col += 1;
    self.dirty = true;
}

fn deleteBackward(self: *TextInput) void {
    if (self.cursor_byte == 0) return;
    const prev_len = prevCodepointLen(self.buffer.items, self.cursor_byte);
    const start = self.cursor_byte - prev_len;
    self.buffer.replaceRange(self.allocator, start, prev_len, &.{}) catch return;
    self.cursor_byte = start;
    self.cursor_col -= 1;
    self.dirty = true;
}

fn deleteForward(self: *TextInput) void {
    if (self.cursor_byte >= self.buffer.items.len) return;
    const cp_len = std.unicode.utf8ByteSequenceLength(self.buffer.items[self.cursor_byte]) catch return;
    self.buffer.replaceRange(self.allocator, self.cursor_byte, cp_len, &.{}) catch return;
    self.dirty = true;
}

fn moveCursorLeft(self: *TextInput) void {
    if (self.cursor_byte == 0) return;
    const prev_len = prevCodepointLen(self.buffer.items, self.cursor_byte);
    self.cursor_byte -= prev_len;
    self.cursor_col -= 1;
    self.dirty = true;
}

fn moveCursorRight(self: *TextInput) void {
    if (self.cursor_byte >= self.buffer.items.len) return;
    const cp_len = std.unicode.utf8ByteSequenceLength(self.buffer.items[self.cursor_byte]) catch return;
    self.cursor_byte += cp_len;
    self.cursor_col += 1;
    self.dirty = true;
}

// -- Helpers --

/// Count the number of UTF-8 codepoints in a byte slice.
fn codepointCount(bytes: []const u8) usize {
    var count: usize = 0;
    var i: usize = 0;
    while (i < bytes.len) {
        const len = std.unicode.utf8ByteSequenceLength(bytes[i]) catch break;
        i += len;
        count += 1;
    }
    return count;
}

/// Get the byte length of the codepoint immediately before `pos`.
fn prevCodepointLen(bytes: []const u8, pos: usize) usize {
    if (pos == 0) return 0;
    // Walk backward over continuation bytes (10xxxxxx)
    var i = pos - 1;
    while (i > 0 and (bytes[i] & 0xC0) == 0x80) {
        i -= 1;
    }
    return pos - i;
}

// -- Tests --

test "init and deinit" {
    const allocator = std.testing.allocator;
    var ti = TextInput.init(allocator, .{});
    defer ti.deinit();
    try std.testing.expectEqualStrings("", ti.value());
    try std.testing.expect(!ti.isConfirmed());
}

test "insert characters" {
    const allocator = std.testing.allocator;
    var ti = TextInput.init(allocator, .{});
    defer ti.deinit();

    ti.insertChar('h');
    ti.insertChar('i');
    try std.testing.expectEqualStrings("hi", ti.value());
    try std.testing.expectEqual(@as(usize, 2), ti.cursor_col);
}

test "insert UTF-8 multibyte" {
    const allocator = std.testing.allocator;
    var ti = TextInput.init(allocator, .{});
    defer ti.deinit();

    ti.insertChar(0x3042); // あ
    try std.testing.expectEqualStrings("\xe3\x81\x82", ti.value());
    try std.testing.expectEqual(@as(usize, 1), ti.cursor_col);
    try std.testing.expectEqual(@as(usize, 3), ti.cursor_byte);
}

test "delete backward" {
    const allocator = std.testing.allocator;
    var ti = TextInput.init(allocator, .{});
    defer ti.deinit();

    ti.insertChar('a');
    ti.insertChar('b');
    ti.deleteBackward();
    try std.testing.expectEqualStrings("a", ti.value());
    try std.testing.expectEqual(@as(usize, 1), ti.cursor_col);
}

test "delete backward at start does nothing" {
    const allocator = std.testing.allocator;
    var ti = TextInput.init(allocator, .{});
    defer ti.deinit();

    ti.deleteBackward();
    try std.testing.expectEqualStrings("", ti.value());
}

test "delete forward" {
    const allocator = std.testing.allocator;
    var ti = TextInput.init(allocator, .{});
    defer ti.deinit();

    ti.insertChar('a');
    ti.insertChar('b');
    ti.cursor_byte = 0;
    ti.cursor_col = 0;
    ti.deleteForward();
    try std.testing.expectEqualStrings("b", ti.value());
}

test "cursor movement left and right" {
    const allocator = std.testing.allocator;
    var ti = TextInput.init(allocator, .{});
    defer ti.deinit();

    ti.insertChar('a');
    ti.insertChar('b');
    ti.insertChar('c');
    // cursor at end: col=3, byte=3
    ti.moveCursorLeft();
    try std.testing.expectEqual(@as(usize, 2), ti.cursor_col);
    try std.testing.expectEqual(@as(usize, 2), ti.cursor_byte);
    ti.moveCursorRight();
    try std.testing.expectEqual(@as(usize, 3), ti.cursor_col);
    try std.testing.expectEqual(@as(usize, 3), ti.cursor_byte);
}

test "cursor movement with multibyte UTF-8" {
    const allocator = std.testing.allocator;
    var ti = TextInput.init(allocator, .{});
    defer ti.deinit();

    ti.insertChar(0x3042); // あ (3 bytes)
    ti.insertChar(0x3044); // い (3 bytes)
    try std.testing.expectEqual(@as(usize, 6), ti.cursor_byte);
    try std.testing.expectEqual(@as(usize, 2), ti.cursor_col);

    ti.moveCursorLeft();
    try std.testing.expectEqual(@as(usize, 3), ti.cursor_byte);
    try std.testing.expectEqual(@as(usize, 1), ti.cursor_col);
}

test "max_length enforced" {
    const allocator = std.testing.allocator;
    var ti = TextInput.init(allocator, .{ .max_length = 3 });
    defer ti.deinit();

    ti.insertChar('a');
    ti.insertChar('b');
    ti.insertChar('c');
    ti.insertChar('d'); // should be rejected
    try std.testing.expectEqualStrings("abc", ti.value());
}

test "allowed_chars filter" {
    const allocator = std.testing.allocator;
    var ti = TextInput.init(allocator, .{ .allowed_chars = "0123456789" });
    defer ti.deinit();

    ti.insertChar('a'); // rejected
    ti.insertChar('1'); // accepted
    ti.insertChar('2'); // accepted
    try std.testing.expectEqualStrings("12", ti.value());
}

test "enter confirms" {
    const allocator = std.testing.allocator;
    var ti = TextInput.init(allocator, .{});
    defer ti.deinit();

    try std.testing.expect(!ti.isConfirmed());
    _ = ti.handleEvent(.{ .key = .enter });
    try std.testing.expect(ti.isConfirmed());
}

test "render placeholder when empty" {
    const allocator = std.testing.allocator;
    var ti = TextInput.init(allocator, .{ .placeholder = "type here" });
    defer ti.deinit();

    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try ti.render(fbs.writer());

    const output = fbs.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, output, "type here") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\x1b[90m") != null); // bright_black (gray)
}

test "render with mask char" {
    const allocator = std.testing.allocator;
    var ti = TextInput.init(allocator, .{ .mask_char = '*' });
    defer ti.deinit();

    ti.insertChar('a');
    ti.insertChar('b');
    ti.insertChar('c');

    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try ti.render(fbs.writer());

    const output = fbs.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, output, "***") != null);
    // Actual text should not appear
    try std.testing.expect(std.mem.indexOf(u8, output, "abc") == null);
}

test "render normal text" {
    const allocator = std.testing.allocator;
    var ti = TextInput.init(allocator, .{});
    defer ti.deinit();

    ti.insertChar('h');
    ti.insertChar('i');

    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try ti.render(fbs.writer());

    const output = fbs.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, output, "hi") != null);
}

test "handleEvent returns ignored for unhandled keys" {
    const allocator = std.testing.allocator;
    var ti = TextInput.init(allocator, .{});
    defer ti.deinit();

    const result = ti.handleEvent(.{ .key = .escape });
    try std.testing.expectEqual(Widget.HandleResult.ignored, result);
}

test "codepointCount" {
    try std.testing.expectEqual(@as(usize, 5), codepointCount("hello"));
    try std.testing.expectEqual(@as(usize, 2), codepointCount("\xe3\x81\x82\xe3\x81\x84")); // あい
    try std.testing.expectEqual(@as(usize, 0), codepointCount(""));
}

test "prevCodepointLen" {
    // ASCII
    try std.testing.expectEqual(@as(usize, 1), prevCodepointLen("abc", 3));
    // 3-byte UTF-8 (あ = 0xE3 0x81 0x82)
    try std.testing.expectEqual(@as(usize, 3), prevCodepointLen("\xe3\x81\x82", 3));
    // At start
    try std.testing.expectEqual(@as(usize, 0), prevCodepointLen("abc", 0));
}
