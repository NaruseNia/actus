const std = @import("std");
const Event = @import("../event.zig").Event;
const Key = @import("../event.zig").Key;
const Widget = @import("../Widget.zig");
const Terminal = @import("../Terminal.zig");
const Style = @import("../Style.zig");
const Theme = @import("../Theme.zig");
const HelpLine = @import("HelpLine.zig");

const ListView = @This();

comptime {
    Widget.assertIsWidget(ListView);
}

// -- Configuration --

pub const Config = struct {
    /// Maximum number of visible rows. null = show all items.
    max_visible: ?usize = null,
    /// Style applied to the selected item. Overrides theme.primary when set.
    selected_style: ?Style = null,
    /// Style applied to non-selected items. Overrides theme.text when set.
    normal_style: ?Style = null,
    /// Prefix shown before the selected item.
    cursor: []const u8 = "> ",
    /// Prefix shown before non-selected items (should match cursor width).
    indent: []const u8 = "  ",
    /// Show item count at the bottom of the list.
    show_count: bool = false,
    /// Style for the count line. Overrides theme.muted when set.
    count_style: ?Style = null,
    /// Enable incremental filter/search mode.
    filterable: bool = false,
    /// Prefix shown before the filter input line.
    filter_prefix: []const u8 = "/ ",
    /// Placeholder shown when the filter is empty.
    filter_placeholder: []const u8 = "",
    /// Style for the filter placeholder. Overrides theme.muted when set.
    filter_placeholder_style: ?Style = null,
    /// Theme providing default styles.
    theme: Theme = Theme.default,
};

// -- State --

items: []const []const u8,
selected: usize = 0,
scroll_offset: usize = 0,
dirty: bool = true,
confirmed: bool = false,
cancelled: bool = false,
/// Number of lines rendered in the last render call.
last_rendered_lines: usize = 0,
/// Cursor line position after last render (0-indexed from top of block).
cursor_line: usize = 0,

/// Filter input buffer (used when filterable is true).
filter_buffer: std.ArrayListUnmanaged(u8) = .empty,
/// Indices into `items` that match the current filter.
filtered_indices: std.ArrayListUnmanaged(usize) = .empty,

config: Config,
allocator: std.mem.Allocator,

pub fn init(allocator: std.mem.Allocator, items: []const []const u8, config: Config) ListView {
    var lv = ListView{
        .items = items,
        .config = config,
        .allocator = allocator,
    };
    // Initialize filtered_indices with all items
    lv.rebuildFilter();
    return lv;
}

pub fn deinit(self: *ListView) void {
    self.filter_buffer.deinit(self.allocator);
    self.filtered_indices.deinit(self.allocator);
}

/// Returns the currently selected item string.
pub fn selectedItem(self: *const ListView) ?[]const u8 {
    if (self.filteredCount() == 0) return null;
    return self.items[self.filtered_indices.items[self.selected]];
}

/// Returns the index into the original items slice for the current selection.
pub fn selectedIndex(self: *const ListView) ?usize {
    if (self.filteredCount() == 0) return null;
    return self.filtered_indices.items[self.selected];
}

/// Whether the user confirmed the selection with Enter.
pub fn isConfirmed(self: *const ListView) bool {
    return self.confirmed;
}

/// Whether the user cancelled with Escape.
pub fn isCancelled(self: *const ListView) bool {
    return self.cancelled;
}

/// Returns the current filter text.
pub fn filterValue(self: *const ListView) []const u8 {
    return self.filter_buffer.items;
}

/// Returns the default help-line bindings for the current state.
/// Used by `WithHelpLine` to auto-populate the help line.
pub fn helpBindings(_: *const ListView) []const HelpLine.Binding {
    return &.{
        .{ .key = "\xe2\x86\x91\xe2\x86\x93", .action = "Navigate" },
        .{ .key = "Esc", .action = "Clear" },
        .{ .key = "Enter", .action = "Select" },
    };
}

// -- Widget interface --

pub fn handleEvent(self: *ListView, ev: Event) Widget.HandleResult {
    return switch (ev) {
        .key => |key| self.handleKey(key),
    };
}

pub fn render(self: *ListView, writer: anytype) !void {
    // Move cursor back to the top of the previously rendered block
    if (self.cursor_line > 0) {
        try Terminal.moveCursorUp(writer, @intCast(self.cursor_line));
    }

    // Convention: \n is written BEFORE each new line (except the first).
    // The cursor always ends on the last rendered line (no trailing \n).
    var total_lines: usize = 0;

    // Filter input line
    if (self.config.filterable) {
        try Terminal.clearLine(writer);
        try writer.writeAll(self.config.filter_prefix);
        if (self.filter_buffer.items.len == 0 and self.config.filter_placeholder.len > 0) {
            const fp_style = self.config.filter_placeholder_style orelse self.config.theme.muted;
            try fp_style.write(writer, self.config.filter_placeholder);
        } else {
            try writer.writeAll(self.filter_buffer.items);
        }
        total_lines += 1;
    }

    const count = self.filteredCount();

    if (count == 0) {
        // Empty placeholder line
        if (total_lines > 0) try writer.writeAll("\n");
        try Terminal.clearLine(writer);
        total_lines += 1;
    } else {
        const visible = self.visibleCount();
        const start = self.scroll_offset;
        const end = start + visible;

        for (start..end) |fi| {
            const item_idx = self.filtered_indices.items[fi];
            if (total_lines > 0) try writer.writeAll("\n");
            try Terminal.clearLine(writer);
            if (fi == self.selected) {
                const sel_style = self.config.selected_style orelse self.config.theme.primary;
                try sel_style.writeStart(writer);
                try writer.writeAll(self.config.cursor);
                try writer.writeAll(self.items[item_idx]);
                try sel_style.writeEnd(writer);
            } else {
                const norm_style = self.config.normal_style orelse self.config.theme.text;
                try norm_style.writeStart(writer);
                try writer.writeAll(self.config.indent);
                try writer.writeAll(self.items[item_idx]);
                try norm_style.writeEnd(writer);
            }
            total_lines += 1;
        }
    }

    // Count line
    if (self.config.show_count) {
        if (total_lines > 0) try writer.writeAll("\n");
        try Terminal.clearLine(writer);
        const cnt_style = self.config.count_style orelse self.config.theme.muted;
        if (self.filter_buffer.items.len > 0) {
            try cnt_style.print(writer, "{d}/{d} ({d} total)", .{
                if (count > 0) self.selected + 1 else @as(usize, 0),
                count,
                self.items.len,
            });
        } else {
            try cnt_style.print(writer, "{d}/{d}", .{
                if (count > 0) self.selected + 1 else @as(usize, 0),
                count,
            });
        }
        total_lines += 1;
    }

    // Clear any leftover lines from a previous longer render
    if (self.last_rendered_lines > total_lines) {
        const extra = self.last_rendered_lines - total_lines;
        for (0..extra) |_| {
            try writer.writeAll("\n");
            try Terminal.clearLine(writer);
        }
        try Terminal.moveCursorUp(writer, @intCast(extra));
    }

    self.last_rendered_lines = total_lines;
    self.cursor_line = if (total_lines > 0) total_lines - 1 else 0;

    // Position cursor on the filter input line for text entry
    if (self.config.filterable and total_lines > 1) {
        try Terminal.moveCursorUp(writer, @intCast(total_lines - 1));
        const col = self.config.filter_prefix.len + self.filter_buffer.items.len;
        try Terminal.moveCursorTo(writer, @intCast(col));
        self.cursor_line = 0;
    }

    self.dirty = false;
}

/// Clear all rendered lines from the terminal. Call after the event loop
/// ends to remove the list UI before printing results.
/// `extra_lines`: number of extra lines the cursor moved down since
/// the last render (e.g. 1 if App.run wrote a final "\r\n").
pub fn cleanup(self: *ListView, writer: anytype, extra_lines: u16) !void {
    if (self.last_rendered_lines == 0) return;
    // Move cursor to the top of the rendered block
    const up = self.cursor_line + extra_lines;
    if (up > 0) {
        try Terminal.moveCursorUp(writer, @intCast(up));
    }
    // Clear current line and everything below it
    try Terminal.clearLine(writer);
    try Terminal.clearFromCursor(writer);
    self.last_rendered_lines = 0;
    self.cursor_line = 0;
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
            if (self.config.filterable) {
                self.insertFilterChar(cp);
                return .consumed;
            }
            // Vim keys only when not filterable
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
        .backspace => {
            if (self.config.filterable) {
                self.deleteFilterChar();
                return .consumed;
            }
            return .ignored;
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
            if (self.filteredCount() > 0) {
                self.confirmed = true;
            }
            return .done;
        },
        .escape => {
            if (self.config.filterable and self.filter_buffer.items.len > 0) {
                // Clear filter first
                self.filter_buffer.clearRetainingCapacity();
                self.rebuildFilter();
                self.selected = 0;
                self.scroll_offset = 0;
                self.dirty = true;
                return .consumed;
            }
            self.cancelled = true;
            return .done;
        },
        else => return .ignored,
    }
}

// -- Filter --

fn insertFilterChar(self: *ListView, cp: u21) void {
    var encoded: [4]u8 = undefined;
    const len = std.unicode.utf8Encode(cp, &encoded) catch return;
    self.filter_buffer.insertSlice(self.allocator, self.filter_buffer.items.len, encoded[0..len]) catch return;
    self.rebuildFilter();
    self.selected = 0;
    self.scroll_offset = 0;
    self.dirty = true;
}

fn deleteFilterChar(self: *ListView) void {
    if (self.filter_buffer.items.len == 0) return;
    // Remove last UTF-8 codepoint
    const prev_len = prevCodepointLen(self.filter_buffer.items, self.filter_buffer.items.len);
    self.filter_buffer.shrinkRetainingCapacity(self.filter_buffer.items.len - prev_len);
    self.rebuildFilter();
    // Keep selected in bounds
    if (self.filteredCount() > 0 and self.selected >= self.filteredCount()) {
        self.selected = self.filteredCount() - 1;
    }
    self.adjustScroll();
    self.dirty = true;
}

fn rebuildFilter(self: *ListView) void {
    self.filtered_indices.clearRetainingCapacity();
    const filter = self.filter_buffer.items;
    for (self.items, 0..) |item, i| {
        if (filter.len == 0 or containsCaseInsensitive(item, filter)) {
            self.filtered_indices.append(self.allocator, i) catch return;
        }
    }
}

fn containsCaseInsensitive(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    const end = haystack.len - needle.len + 1;
    for (0..end) |i| {
        var match = true;
        for (0..needle.len) |j| {
            if (toLowerAscii(haystack[i + j]) != toLowerAscii(needle[j])) {
                match = false;
                break;
            }
        }
        if (match) return true;
    }
    return false;
}

fn toLowerAscii(c: u8) u8 {
    return if (c >= 'A' and c <= 'Z') c + 32 else c;
}

fn filteredCount(self: *const ListView) usize {
    return self.filtered_indices.items.len;
}

// -- Navigation --

fn moveUp(self: *ListView) void {
    if (self.filteredCount() == 0) return;
    if (self.selected > 0) {
        self.selected -= 1;
        self.adjustScroll();
        self.dirty = true;
    }
}

fn moveDown(self: *ListView) void {
    if (self.filteredCount() == 0) return;
    if (self.selected < self.filteredCount() - 1) {
        self.selected += 1;
        self.adjustScroll();
        self.dirty = true;
    }
}

fn moveToTop(self: *ListView) void {
    if (self.filteredCount() == 0) return;
    self.selected = 0;
    self.scroll_offset = 0;
    self.dirty = true;
}

fn moveToBottom(self: *ListView) void {
    if (self.filteredCount() == 0) return;
    self.selected = self.filteredCount() - 1;
    self.adjustScroll();
    self.dirty = true;
}

fn adjustScroll(self: *ListView) void {
    const visible = self.visibleCount();
    if (visible == 0) return;
    if (self.selected < self.scroll_offset) {
        self.scroll_offset = self.selected;
    } else if (self.selected >= self.scroll_offset + visible) {
        self.scroll_offset = self.selected - visible + 1;
    }
}

fn visibleCount(self: *const ListView) usize {
    if (self.config.max_visible) |max| {
        return @min(max, self.filteredCount());
    }
    return self.filteredCount();
}

// -- Helpers --

fn prevCodepointLen(bytes: []const u8, pos: usize) usize {
    if (pos == 0) return 0;
    var i = pos - 1;
    while (i > 0 and (bytes[i] & 0xC0) == 0x80) {
        i -= 1;
    }
    return pos - i;
}

// -- Tests --

test "init and defaults" {
    const allocator = std.testing.allocator;
    const items = [_][]const u8{ "apple", "banana", "cherry" };
    var lv = ListView.init(allocator, &items, .{});
    defer lv.deinit();
    try std.testing.expectEqual(@as(usize, 0), lv.selectedIndex().?);
    try std.testing.expectEqualStrings("apple", lv.selectedItem().?);
    try std.testing.expect(!lv.isConfirmed());
    try std.testing.expect(!lv.isCancelled());
}

test "empty items" {
    const allocator = std.testing.allocator;
    const items = [_][]const u8{};
    var lv = ListView.init(allocator, &items, .{});
    defer lv.deinit();
    try std.testing.expect(lv.selectedItem() == null);
    try std.testing.expect(lv.selectedIndex() == null);
}

test "move down and up" {
    const allocator = std.testing.allocator;
    const items = [_][]const u8{ "a", "b", "c" };
    var lv = ListView.init(allocator, &items, .{});
    defer lv.deinit();

    _ = lv.handleEvent(.{ .key = .down });
    try std.testing.expectEqual(@as(usize, 1), lv.selectedIndex().?);
    try std.testing.expectEqualStrings("b", lv.selectedItem().?);

    _ = lv.handleEvent(.{ .key = .up });
    try std.testing.expectEqual(@as(usize, 0), lv.selectedIndex().?);
}

test "move down at bottom stays" {
    const allocator = std.testing.allocator;
    const items = [_][]const u8{ "a", "b" };
    var lv = ListView.init(allocator, &items, .{});
    defer lv.deinit();
    _ = lv.handleEvent(.{ .key = .down });
    _ = lv.handleEvent(.{ .key = .down }); // already at bottom
    try std.testing.expectEqual(@as(usize, 1), lv.selectedIndex().?);
}

test "move up at top stays" {
    const allocator = std.testing.allocator;
    const items = [_][]const u8{ "a", "b" };
    var lv = ListView.init(allocator, &items, .{});
    defer lv.deinit();
    _ = lv.handleEvent(.{ .key = .up }); // already at top
    try std.testing.expectEqual(@as(usize, 0), lv.selectedIndex().?);
}

test "j and k vim keys" {
    const allocator = std.testing.allocator;
    const items = [_][]const u8{ "a", "b", "c" };
    var lv = ListView.init(allocator, &items, .{});
    defer lv.deinit();

    _ = lv.handleEvent(.{ .key = .{ .char = 'j' } });
    try std.testing.expectEqual(@as(usize, 1), lv.selectedIndex().?);

    _ = lv.handleEvent(.{ .key = .{ .char = 'k' } });
    try std.testing.expectEqual(@as(usize, 0), lv.selectedIndex().?);
}

test "vim keys disabled when filterable" {
    const allocator = std.testing.allocator;
    const items = [_][]const u8{ "a", "b", "c" };
    var lv = ListView.init(allocator, &items, .{ .filterable = true });
    defer lv.deinit();

    // 'j' should go to filter, not move down
    _ = lv.handleEvent(.{ .key = .{ .char = 'j' } });
    try std.testing.expectEqual(@as(usize, 0), lv.selected);
    try std.testing.expectEqualStrings("j", lv.filterValue());
}

test "g and G jump to top/bottom" {
    const allocator = std.testing.allocator;
    const items = [_][]const u8{ "a", "b", "c", "d" };
    var lv = ListView.init(allocator, &items, .{});
    defer lv.deinit();

    _ = lv.handleEvent(.{ .key = .{ .char = 'G' } });
    try std.testing.expectEqual(@as(usize, 3), lv.selectedIndex().?);

    _ = lv.handleEvent(.{ .key = .{ .char = 'g' } });
    try std.testing.expectEqual(@as(usize, 0), lv.selectedIndex().?);
}

test "home and end keys" {
    const allocator = std.testing.allocator;
    const items = [_][]const u8{ "a", "b", "c" };
    var lv = ListView.init(allocator, &items, .{});
    defer lv.deinit();

    _ = lv.handleEvent(.{ .key = .end });
    try std.testing.expectEqual(@as(usize, 2), lv.selectedIndex().?);

    _ = lv.handleEvent(.{ .key = .home });
    try std.testing.expectEqual(@as(usize, 0), lv.selectedIndex().?);
}

test "enter confirms" {
    const allocator = std.testing.allocator;
    const items = [_][]const u8{ "a", "b" };
    var lv = ListView.init(allocator, &items, .{});
    defer lv.deinit();

    _ = lv.handleEvent(.{ .key = .down });
    const result = lv.handleEvent(.{ .key = .enter });
    try std.testing.expectEqual(Widget.HandleResult.done, result);
    try std.testing.expect(lv.isConfirmed());
    try std.testing.expectEqualStrings("b", lv.selectedItem().?);
}

test "escape cancels" {
    const allocator = std.testing.allocator;
    const items = [_][]const u8{ "a", "b" };
    var lv = ListView.init(allocator, &items, .{});
    defer lv.deinit();

    const result = lv.handleEvent(.{ .key = .escape });
    try std.testing.expectEqual(Widget.HandleResult.done, result);
    try std.testing.expect(lv.isCancelled());
}

test "scroll offset with max_visible" {
    const allocator = std.testing.allocator;
    const items = [_][]const u8{ "a", "b", "c", "d", "e" };
    var lv = ListView.init(allocator, &items, .{ .max_visible = 3 });
    defer lv.deinit();

    try std.testing.expectEqual(@as(usize, 0), lv.scroll_offset);

    _ = lv.handleEvent(.{ .key = .down }); // 1
    _ = lv.handleEvent(.{ .key = .down }); // 2
    _ = lv.handleEvent(.{ .key = .down }); // 3
    try std.testing.expectEqual(@as(usize, 3), lv.selectedIndex().?);
    try std.testing.expectEqual(@as(usize, 1), lv.scroll_offset);

    _ = lv.handleEvent(.{ .key = .down });
    try std.testing.expectEqual(@as(usize, 4), lv.selectedIndex().?);
    try std.testing.expectEqual(@as(usize, 2), lv.scroll_offset);

    _ = lv.handleEvent(.{ .key = .{ .char = 'g' } });
    try std.testing.expectEqual(@as(usize, 0), lv.selectedIndex().?);
    try std.testing.expectEqual(@as(usize, 0), lv.scroll_offset);
}

test "filter narrows results" {
    const allocator = std.testing.allocator;
    const items = [_][]const u8{ "Apple", "Banana", "Apricot", "Cherry" };
    var lv = ListView.init(allocator, &items, .{ .filterable = true });
    defer lv.deinit();

    // Type "ap" — should match Apple and Apricot (case-insensitive)
    _ = lv.handleEvent(.{ .key = .{ .char = 'a' } });
    _ = lv.handleEvent(.{ .key = .{ .char = 'p' } });
    try std.testing.expectEqual(@as(usize, 2), lv.filteredCount());
    try std.testing.expectEqualStrings("Apple", lv.selectedItem().?);

    // Move down to Apricot
    _ = lv.handleEvent(.{ .key = .down });
    try std.testing.expectEqualStrings("Apricot", lv.selectedItem().?);
}

test "filter backspace widens results" {
    const allocator = std.testing.allocator;
    const items = [_][]const u8{ "Apple", "Banana", "Apricot" };
    var lv = ListView.init(allocator, &items, .{ .filterable = true });
    defer lv.deinit();

    _ = lv.handleEvent(.{ .key = .{ .char = 'a' } });
    _ = lv.handleEvent(.{ .key = .{ .char = 'p' } });
    _ = lv.handleEvent(.{ .key = .{ .char = 'r' } });
    try std.testing.expectEqual(@as(usize, 1), lv.filteredCount()); // Apricot only

    _ = lv.handleEvent(.{ .key = .backspace });
    try std.testing.expectEqual(@as(usize, 2), lv.filteredCount()); // Apple + Apricot
}

test "escape clears filter before cancelling" {
    const allocator = std.testing.allocator;
    const items = [_][]const u8{ "Apple", "Banana" };
    var lv = ListView.init(allocator, &items, .{ .filterable = true });
    defer lv.deinit();

    _ = lv.handleEvent(.{ .key = .{ .char = 'a' } });
    try std.testing.expectEqualStrings("a", lv.filterValue());

    // First escape clears filter
    const result1 = lv.handleEvent(.{ .key = .escape });
    try std.testing.expectEqual(Widget.HandleResult.consumed, result1);
    try std.testing.expectEqualStrings("", lv.filterValue());
    try std.testing.expect(!lv.isCancelled());

    // Second escape cancels
    const result2 = lv.handleEvent(.{ .key = .escape });
    try std.testing.expectEqual(Widget.HandleResult.done, result2);
    try std.testing.expect(lv.isCancelled());
}

test "enter on empty filtered list does not confirm" {
    const allocator = std.testing.allocator;
    const items = [_][]const u8{ "Apple", "Banana" };
    var lv = ListView.init(allocator, &items, .{ .filterable = true });
    defer lv.deinit();

    _ = lv.handleEvent(.{ .key = .{ .char = 'z' } });
    _ = lv.handleEvent(.{ .key = .{ .char = 'z' } });
    _ = lv.handleEvent(.{ .key = .{ .char = 'z' } });
    try std.testing.expectEqual(@as(usize, 0), lv.filteredCount());

    const result = lv.handleEvent(.{ .key = .enter });
    try std.testing.expectEqual(Widget.HandleResult.done, result);
    try std.testing.expect(!lv.isConfirmed());
}

test "render contains cursor and selected text" {
    const allocator = std.testing.allocator;
    const items = [_][]const u8{ "alpha", "beta" };
    var lv = ListView.init(allocator, &items, .{ .cursor = "> ", .indent = "  " });
    defer lv.deinit();

    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try lv.render(fbs.writer());

    const output = fbs.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, output, "> alpha") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "  beta") != null);
}

test "render empty list" {
    const allocator = std.testing.allocator;
    const items = [_][]const u8{};
    var lv = ListView.init(allocator, &items, .{});
    defer lv.deinit();

    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try lv.render(fbs.writer());
    try std.testing.expect(fbs.getWritten().len > 0);
}

test "render with show_count" {
    const allocator = std.testing.allocator;
    const items = [_][]const u8{ "a", "b", "c" };
    var lv = ListView.init(allocator, &items, .{ .show_count = true });
    defer lv.deinit();

    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try lv.render(fbs.writer());

    const output = fbs.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, output, "1/3") != null);
}

test "render with filter and count shows total" {
    const allocator = std.testing.allocator;
    const items = [_][]const u8{ "Apple", "Banana", "Apricot" };
    var lv = ListView.init(allocator, &items, .{ .filterable = true, .show_count = true });
    defer lv.deinit();

    // "ap" matches Apple and Apricot but not Banana
    _ = lv.handleEvent(.{ .key = .{ .char = 'a' } });
    _ = lv.handleEvent(.{ .key = .{ .char = 'p' } });

    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try lv.render(fbs.writer());

    const output = fbs.getWritten();
    // Should show filtered count and total
    try std.testing.expect(std.mem.indexOf(u8, output, "1/2") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "(3 total)") != null);
}

test "render uses custom theme styles" {
    const allocator = std.testing.allocator;
    const items = [_][]const u8{ "alpha", "beta" };
    const custom_theme = Theme{ .primary = Style.fg(.red).setBold() };
    var lv = ListView.init(allocator, &items, .{ .theme = custom_theme });
    defer lv.deinit();

    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try lv.render(fbs.writer());

    const output = fbs.getWritten();
    // red+bold = \x1b[1;31m
    try std.testing.expect(std.mem.indexOf(u8, output, "\x1b[1;31m") != null);
}

test "selected_style overrides theme" {
    const allocator = std.testing.allocator;
    const items = [_][]const u8{ "alpha", "beta" };
    var lv = ListView.init(allocator, &items, .{
        .selected_style = Style.fg(.green),
        .theme = Theme{ .primary = Style.fg(.red) },
    });
    defer lv.deinit();

    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try lv.render(fbs.writer());

    const output = fbs.getWritten();
    // green fg = \x1b[32m, not red \x1b[31m
    try std.testing.expect(std.mem.indexOf(u8, output, "\x1b[32m") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\x1b[31m") == null);
}

test "unhandled key returns ignored" {
    const allocator = std.testing.allocator;
    const items = [_][]const u8{ "a", "b" };
    var lv = ListView.init(allocator, &items, .{});
    defer lv.deinit();

    const result = lv.handleEvent(.{ .key = .tab });
    try std.testing.expectEqual(Widget.HandleResult.ignored, result);
}

test "containsCaseInsensitive" {
    try std.testing.expect(containsCaseInsensitive("Apple", "app"));
    try std.testing.expect(containsCaseInsensitive("Apple", "PLE"));
    try std.testing.expect(containsCaseInsensitive("Apple", "apple"));
    try std.testing.expect(!containsCaseInsensitive("Apple", "xyz"));
    try std.testing.expect(containsCaseInsensitive("Apple", ""));
    try std.testing.expect(!containsCaseInsensitive("", "a"));
}
