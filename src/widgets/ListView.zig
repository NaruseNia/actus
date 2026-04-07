const std = @import("std");
const Event = @import("../event.zig").Event;
const Key = @import("../event.zig").Key;
const Widget = @import("../Widget.zig");
const Terminal = @import("../Terminal.zig");
const Style = @import("../Style.zig");

const ListView = @This();

comptime {
    Widget.assertIsWidget(ListView);
}

// -- Configuration --

pub const Config = struct {
    /// Maximum number of visible rows. null = show all items.
    max_visible: ?usize = null,
    /// Style applied to the selected item.
    selected_style: Style = Style.fg(.cyan).setBold(),
    /// Style applied to non-selected items.
    normal_style: Style = .{},
    /// Prefix shown before the selected item.
    cursor: []const u8 = "> ",
    /// Prefix shown before non-selected items (should match cursor width).
    indent: []const u8 = "  ",
};

// -- State --

items: []const []const u8,
selected: usize = 0,
scroll_offset: usize = 0,
dirty: bool = true,
confirmed: bool = false,
cancelled: bool = false,
/// Number of lines rendered in the last render call (for cursor repositioning).
last_rendered_lines: usize = 0,

config: Config,

pub fn init(items: []const []const u8, config: Config) ListView {
    return .{
        .items = items,
        .config = config,
    };
}

/// Returns the currently selected item string.
pub fn selectedItem(self: *const ListView) ?[]const u8 {
    if (self.items.len == 0) return null;
    return self.items[self.selected];
}

/// Returns the currently selected index.
pub fn selectedIndex(self: *const ListView) usize {
    return self.selected;
}

/// Whether the user confirmed the selection with Enter.
pub fn isConfirmed(self: *const ListView) bool {
    return self.confirmed;
}

/// Whether the user cancelled with Escape.
pub fn isCancelled(self: *const ListView) bool {
    return self.cancelled;
}

// -- Widget interface --

pub fn handleEvent(self: *ListView, ev: Event) Widget.HandleResult {
    return switch (ev) {
        .key => |key| self.handleKey(key),
    };
}

pub fn render(self: *ListView, writer: anytype) !void {
    // Move cursor back to the start of the previously rendered block
    if (self.last_rendered_lines > 1) {
        try Terminal.moveCursorUp(writer, @intCast(self.last_rendered_lines - 1));
    }

    if (self.items.len == 0) {
        try Terminal.clearLine(writer);
        self.last_rendered_lines = 1;
        self.dirty = false;
        return;
    }

    const visible = self.visibleCount();
    const start = self.scroll_offset;
    const end = start + visible;

    for (start..end) |i| {
        try Terminal.clearLine(writer);
        if (i == self.selected) {
            try self.config.selected_style.writeStart(writer);
            try writer.writeAll(self.config.cursor);
            try writer.writeAll(self.items[i]);
            try self.config.selected_style.writeEnd(writer);
        } else {
            try self.config.normal_style.writeStart(writer);
            try writer.writeAll(self.config.indent);
            try writer.writeAll(self.items[i]);
            try self.config.normal_style.writeEnd(writer);
        }
        if (i < end - 1) {
            try writer.writeAll("\n");
        }
    }

    // Clear any leftover lines from a previous longer render
    if (self.last_rendered_lines > visible) {
        const extra = self.last_rendered_lines - visible;
        for (0..extra) |_| {
            try writer.writeAll("\n");
            try Terminal.clearLine(writer);
        }
        // Move back up to the last visible line
        try Terminal.moveCursorUp(writer, @intCast(extra));
    }

    self.last_rendered_lines = visible;
    self.dirty = false;
}

pub fn needsRender(self: *const ListView) bool {
    return self.dirty;
}

// -- Key handling --

fn handleKey(self: *ListView, key: Key) Widget.HandleResult {
    switch (key) {
        .up => {
            self.moveUp();
            return .consumed;
        },
        .down => {
            self.moveDown();
            return .consumed;
        },
        .char => |cp| {
            switch (cp) {
                'k' => {
                    self.moveUp();
                    return .consumed;
                },
                'j' => {
                    self.moveDown();
                    return .consumed;
                },
                'g' => {
                    self.moveToTop();
                    return .consumed;
                },
                'G' => {
                    self.moveToBottom();
                    return .consumed;
                },
                else => return .ignored,
            }
        },
        .home => {
            self.moveToTop();
            return .consumed;
        },
        .end => {
            self.moveToBottom();
            return .consumed;
        },
        .enter => {
            self.confirmed = true;
            return .done;
        },
        .escape => {
            self.cancelled = true;
            return .done;
        },
        else => return .ignored,
    }
}

// -- Navigation --

fn moveUp(self: *ListView) void {
    if (self.items.len == 0) return;
    if (self.selected > 0) {
        self.selected -= 1;
        self.adjustScroll();
        self.dirty = true;
    }
}

fn moveDown(self: *ListView) void {
    if (self.items.len == 0) return;
    if (self.selected < self.items.len - 1) {
        self.selected += 1;
        self.adjustScroll();
        self.dirty = true;
    }
}

fn moveToTop(self: *ListView) void {
    if (self.items.len == 0) return;
    self.selected = 0;
    self.scroll_offset = 0;
    self.dirty = true;
}

fn moveToBottom(self: *ListView) void {
    if (self.items.len == 0) return;
    self.selected = self.items.len - 1;
    self.adjustScroll();
    self.dirty = true;
}

fn adjustScroll(self: *ListView) void {
    const visible = self.visibleCount();
    if (self.selected < self.scroll_offset) {
        self.scroll_offset = self.selected;
    } else if (self.selected >= self.scroll_offset + visible) {
        self.scroll_offset = self.selected - visible + 1;
    }
}

fn visibleCount(self: *const ListView) usize {
    if (self.config.max_visible) |max| {
        return @min(max, self.items.len);
    }
    return self.items.len;
}

// -- Tests --

test "init and defaults" {
    const items = [_][]const u8{ "apple", "banana", "cherry" };
    const lv = ListView.init(&items, .{});
    try std.testing.expectEqual(@as(usize, 0), lv.selectedIndex());
    try std.testing.expectEqualStrings("apple", lv.selectedItem().?);
    try std.testing.expect(!lv.isConfirmed());
    try std.testing.expect(!lv.isCancelled());
}

test "empty items" {
    const items = [_][]const u8{};
    const lv = ListView.init(&items, .{});
    try std.testing.expect(lv.selectedItem() == null);
}

test "move down and up" {
    const items = [_][]const u8{ "a", "b", "c" };
    var lv = ListView.init(&items, .{});

    _ = lv.handleEvent(.{ .key = .down });
    try std.testing.expectEqual(@as(usize, 1), lv.selectedIndex());
    try std.testing.expectEqualStrings("b", lv.selectedItem().?);

    _ = lv.handleEvent(.{ .key = .up });
    try std.testing.expectEqual(@as(usize, 0), lv.selectedIndex());
}

test "move down at bottom stays" {
    const items = [_][]const u8{ "a", "b" };
    var lv = ListView.init(&items, .{});
    _ = lv.handleEvent(.{ .key = .down });
    _ = lv.handleEvent(.{ .key = .down }); // already at bottom
    try std.testing.expectEqual(@as(usize, 1), lv.selectedIndex());
}

test "move up at top stays" {
    const items = [_][]const u8{ "a", "b" };
    var lv = ListView.init(&items, .{});
    _ = lv.handleEvent(.{ .key = .up }); // already at top
    try std.testing.expectEqual(@as(usize, 0), lv.selectedIndex());
}

test "j and k vim keys" {
    const items = [_][]const u8{ "a", "b", "c" };
    var lv = ListView.init(&items, .{});

    _ = lv.handleEvent(.{ .key = .{ .char = 'j' } });
    try std.testing.expectEqual(@as(usize, 1), lv.selectedIndex());

    _ = lv.handleEvent(.{ .key = .{ .char = 'k' } });
    try std.testing.expectEqual(@as(usize, 0), lv.selectedIndex());
}

test "g and G jump to top/bottom" {
    const items = [_][]const u8{ "a", "b", "c", "d" };
    var lv = ListView.init(&items, .{});

    _ = lv.handleEvent(.{ .key = .{ .char = 'G' } });
    try std.testing.expectEqual(@as(usize, 3), lv.selectedIndex());

    _ = lv.handleEvent(.{ .key = .{ .char = 'g' } });
    try std.testing.expectEqual(@as(usize, 0), lv.selectedIndex());
}

test "home and end keys" {
    const items = [_][]const u8{ "a", "b", "c" };
    var lv = ListView.init(&items, .{});

    _ = lv.handleEvent(.{ .key = .end });
    try std.testing.expectEqual(@as(usize, 2), lv.selectedIndex());

    _ = lv.handleEvent(.{ .key = .home });
    try std.testing.expectEqual(@as(usize, 0), lv.selectedIndex());
}

test "enter confirms" {
    const items = [_][]const u8{ "a", "b" };
    var lv = ListView.init(&items, .{});

    _ = lv.handleEvent(.{ .key = .down });
    const result = lv.handleEvent(.{ .key = .enter });
    try std.testing.expectEqual(Widget.HandleResult.done, result);
    try std.testing.expect(lv.isConfirmed());
    try std.testing.expectEqualStrings("b", lv.selectedItem().?);
}

test "escape cancels" {
    const items = [_][]const u8{ "a", "b" };
    var lv = ListView.init(&items, .{});

    const result = lv.handleEvent(.{ .key = .escape });
    try std.testing.expectEqual(Widget.HandleResult.done, result);
    try std.testing.expect(lv.isCancelled());
}

test "scroll offset with max_visible" {
    const items = [_][]const u8{ "a", "b", "c", "d", "e" };
    var lv = ListView.init(&items, .{ .max_visible = 3 });

    // Initially scroll_offset=0, visible=[a,b,c]
    try std.testing.expectEqual(@as(usize, 0), lv.scroll_offset);

    // Move to d (index 3) -> scroll_offset should be 1
    _ = lv.handleEvent(.{ .key = .down }); // 1
    _ = lv.handleEvent(.{ .key = .down }); // 2
    _ = lv.handleEvent(.{ .key = .down }); // 3
    try std.testing.expectEqual(@as(usize, 3), lv.selectedIndex());
    try std.testing.expectEqual(@as(usize, 1), lv.scroll_offset);

    // Move to e (index 4) -> scroll_offset should be 2
    _ = lv.handleEvent(.{ .key = .down });
    try std.testing.expectEqual(@as(usize, 4), lv.selectedIndex());
    try std.testing.expectEqual(@as(usize, 2), lv.scroll_offset);

    // Move back up to a (index 0)
    _ = lv.handleEvent(.{ .key = .{ .char = 'g' } });
    try std.testing.expectEqual(@as(usize, 0), lv.selectedIndex());
    try std.testing.expectEqual(@as(usize, 0), lv.scroll_offset);
}

test "render contains cursor and selected text" {
    const items = [_][]const u8{ "alpha", "beta" };
    var lv = ListView.init(&items, .{ .cursor = "> ", .indent = "  " });

    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try lv.render(fbs.writer());

    const output = fbs.getWritten();
    // Selected item (alpha) should have cursor prefix
    try std.testing.expect(std.mem.indexOf(u8, output, "> alpha") != null);
    // Non-selected item (beta) should have indent prefix
    try std.testing.expect(std.mem.indexOf(u8, output, "  beta") != null);
}

test "render empty list" {
    const items = [_][]const u8{};
    var lv = ListView.init(&items, .{});

    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try lv.render(fbs.writer());
    // Should not crash, and should produce at least a clearLine
    try std.testing.expect(fbs.getWritten().len > 0);
}

test "unhandled key returns ignored" {
    const items = [_][]const u8{ "a", "b" };
    var lv = ListView.init(&items, .{});

    const result = lv.handleEvent(.{ .key = .tab });
    try std.testing.expectEqual(Widget.HandleResult.ignored, result);
}
