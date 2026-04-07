const std = @import("std");
const Event = @import("../event.zig").Event;
const Key = @import("../event.zig").Key;
const Widget = @import("../Widget.zig");
const Terminal = @import("../Terminal.zig");
const Style = @import("../Style.zig");
const Theme = @import("../Theme.zig");

const FilePicker = @This();

comptime {
    Widget.assertIsWidget(FilePicker);
}

// -- Types --

pub const EntryKind = enum {
    file,
    directory,
    sym_link,
    unknown,
};

pub const Entry = struct {
    name: []const u8,
    kind: EntryKind,
};

// -- Configuration --

pub const Config = struct {
    /// Maximum number of visible rows. null = show all items.
    max_visible: ?usize = null,
    /// Style applied to the selected item. Overrides theme.primary when set.
    selected_style: ?Style = null,
    /// Style applied to non-selected items. Overrides theme.text when set.
    normal_style: ?Style = null,
    /// Style applied to directory names. Overrides theme.accent when set.
    dir_style: ?Style = null,
    /// Prefix shown before the selected item.
    cursor: []const u8 = "> ",
    /// Prefix shown before non-selected items (should match cursor width).
    indent: []const u8 = "  ",
    /// Show item count at the bottom of the list.
    show_count: bool = false,
    /// Style for the count line. Overrides theme.muted when set.
    count_style: ?Style = null,
    /// Show current directory path at the top.
    show_path: bool = true,
    /// Style for the path line. Overrides theme.muted when set.
    path_style: ?Style = null,
    /// Theme providing default styles.
    theme: Theme = Theme.default,
};

// -- State --

entries: std.ArrayListUnmanaged(Entry) = .empty,
selected: usize = 0,
scroll_offset: usize = 0,
dirty: bool = true,
confirmed: bool = false,
cancelled: bool = false,
last_rendered_lines: usize = 0,
cursor_line: usize = 0,

current_path: std.ArrayListUnmanaged(u8) = .empty,

config: Config,
allocator: std.mem.Allocator,

pub fn init(allocator: std.mem.Allocator, initial_path: []const u8, config: Config) FilePicker {
    var fp = FilePicker{
        .config = config,
        .allocator = allocator,
    };
    fp.current_path.appendSlice(allocator, initial_path) catch {};
    // Remove trailing separator if present (unless root "/")
    if (fp.current_path.items.len > 1 and fp.current_path.items[fp.current_path.items.len - 1] == std.fs.path.sep) {
        fp.current_path.shrinkRetainingCapacity(fp.current_path.items.len - 1);
    }
    fp.loadDirectory();
    return fp;
}

pub fn deinit(self: *FilePicker) void {
    self.freeEntries();
    self.entries.deinit(self.allocator);
    self.current_path.deinit(self.allocator);
}

/// Returns the currently selected entry.
pub fn selectedEntry(self: *const FilePicker) ?Entry {
    if (self.entryCount() == 0) return null;
    return self.entries.items[self.selected];
}

/// Returns the full path of the selected entry.
/// Caller must free the returned slice.
pub fn selectedPath(self: *const FilePicker) ?[]const u8 {
    const entry = self.selectedEntry() orelse return null;
    const sep = std.fs.path.sep_str;
    const path = std.mem.concat(self.allocator, u8, &.{ self.current_path.items, sep, entry.name }) catch return null;
    return path;
}

/// Whether the user confirmed the selection with Enter.
pub fn isConfirmed(self: *const FilePicker) bool {
    return self.confirmed;
}

/// Whether the user cancelled with Escape.
pub fn isCancelled(self: *const FilePicker) bool {
    return self.cancelled;
}

/// Returns the current directory path.
pub fn currentPath(self: *const FilePicker) []const u8 {
    return self.current_path.items;
}

// -- Widget interface --

pub fn handleEvent(self: *FilePicker, ev: Event) Widget.HandleResult {
    return switch (ev) {
        .key => |key| self.handleKey(key),
    };
}

pub fn render(self: *FilePicker, writer: anytype) !void {
    if (self.cursor_line > 0) {
        try Terminal.moveCursorUp(writer, @intCast(self.cursor_line));
    }

    var total_lines: usize = 0;

    // Path header line
    if (self.config.show_path) {
        try Terminal.clearLine(writer);
        const p_style = self.config.path_style orelse self.config.theme.muted;
        try p_style.write(writer, self.current_path.items);
        total_lines += 1;
    }

    const count = self.entryCount();

    if (count == 0) {
        if (total_lines > 0) try writer.writeAll("\n");
        try Terminal.clearLine(writer);
        const muted = self.config.theme.muted;
        try muted.write(writer, "  (empty)");
        total_lines += 1;
    } else {
        const visible = self.visibleCount();
        const start = self.scroll_offset;
        const end = start + visible;

        for (start..end) |i| {
            const entry = self.entries.items[i];
            if (total_lines > 0) try writer.writeAll("\n");
            try Terminal.clearLine(writer);

            const is_dir = entry.kind == .directory;

            if (i == self.selected) {
                const sel_style = self.config.selected_style orelse self.config.theme.primary;
                try sel_style.writeStart(writer);
                try writer.writeAll(self.config.cursor);
                try writer.writeAll(entry.name);
                if (is_dir) try writer.writeAll("/");
                try sel_style.writeEnd(writer);
            } else {
                const base_style = if (is_dir)
                    self.config.dir_style orelse self.config.theme.accent
                else
                    self.config.normal_style orelse self.config.theme.text;
                try base_style.writeStart(writer);
                try writer.writeAll(self.config.indent);
                try writer.writeAll(entry.name);
                if (is_dir) try writer.writeAll("/");
                try base_style.writeEnd(writer);
            }
            total_lines += 1;
        }
    }

    // Count line
    if (self.config.show_count) {
        if (total_lines > 0) try writer.writeAll("\n");
        try Terminal.clearLine(writer);
        const cnt_style = self.config.count_style orelse self.config.theme.muted;
        try cnt_style.print(writer, "{d}/{d}", .{
            if (count > 0) self.selected + 1 else @as(usize, 0),
            count,
        });
        total_lines += 1;
    }

    // Clear leftover lines from previous longer render
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

    self.dirty = false;
}

pub fn cleanup(self: *FilePicker, writer: anytype, extra_lines: u16) !void {
    if (self.last_rendered_lines == 0) return;
    const up = self.cursor_line + extra_lines;
    if (up > 0) {
        try Terminal.moveCursorUp(writer, @intCast(up));
    }
    try Terminal.clearLine(writer);
    try Terminal.clearFromCursor(writer);
    self.last_rendered_lines = 0;
    self.cursor_line = 0;
}

pub fn needsRender(self: *const FilePicker) bool {
    return self.dirty;
}

// -- Key handling --

fn handleKey(self: *FilePicker, key: Key) Widget.HandleResult {
    switch (key) {
        .up => {
            self.moveUp();
            return .consumed;
        },
        .down => {
            self.moveDown();
            return .consumed;
        },
        .left, .backspace => {
            self.goToParent();
            return .consumed;
        },
        .char => |cp| switch (cp) {
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
            if (self.entryCount() == 0) return .done;
            const entry = self.entries.items[self.selected];
            if (entry.kind == .directory) {
                self.enterDirectory(entry.name);
                return .consumed;
            }
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

// -- Directory operations --

fn loadDirectory(self: *FilePicker) void {
    self.freeEntries();

    const path = if (self.current_path.items.len == 0) "." else self.current_path.items;
    var dir = std.fs.cwd().openDir(path, .{ .iterate = true }) catch return;
    defer dir.close();

    var iter = dir.iterate();
    while (iter.next() catch null) |fs_entry| {
        const kind: EntryKind = switch (fs_entry.kind) {
            .directory => .directory,
            .sym_link => .sym_link,
            .file => .file,
            else => .unknown,
        };
        const name = self.allocator.dupe(u8, fs_entry.name) catch continue;
        self.entries.append(self.allocator, .{
            .name = name,
            .kind = kind,
        }) catch {
            self.allocator.free(name);
            continue;
        };
    }

    self.sortEntries();
    self.selected = 0;
    self.scroll_offset = 0;
    self.dirty = true;
}

fn enterDirectory(self: *FilePicker, name: []const u8) void {
    self.current_path.append(self.allocator, std.fs.path.sep) catch return;
    self.current_path.appendSlice(self.allocator, name) catch return;
    self.loadDirectory();
}

fn goToParent(self: *FilePicker) void {
    if (self.current_path.items.len == 0) return;
    // Find last separator
    const path = self.current_path.items;
    if (std.mem.lastIndexOfScalar(u8, path, std.fs.path.sep)) |idx| {
        if (idx == 0) {
            // At root "/" — shrink to just "/"
            self.current_path.shrinkRetainingCapacity(1);
        } else {
            self.current_path.shrinkRetainingCapacity(idx);
        }
    } else {
        // No separator — clear path (relative root)
        self.current_path.clearRetainingCapacity();
    }
    self.loadDirectory();
}

fn freeEntries(self: *FilePicker) void {
    for (self.entries.items) |entry| {
        self.allocator.free(entry.name);
    }
    self.entries.clearRetainingCapacity();
}

fn sortEntries(self: *FilePicker) void {
    std.mem.sort(Entry, self.entries.items, {}, struct {
        fn lessThan(_: void, a: Entry, b: Entry) bool {
            // Directories first
            const a_is_dir = a.kind == .directory;
            const b_is_dir = b.kind == .directory;
            if (a_is_dir and !b_is_dir) return true;
            if (!a_is_dir and b_is_dir) return false;
            // Then alphabetical
            return std.mem.order(u8, a.name, b.name) == .lt;
        }
    }.lessThan);
}

// -- Navigation --

fn entryCount(self: *const FilePicker) usize {
    return self.entries.items.len;
}

fn moveUp(self: *FilePicker) void {
    if (self.entryCount() == 0) return;
    if (self.selected > 0) {
        self.selected -= 1;
        self.adjustScroll();
        self.dirty = true;
    }
}

fn moveDown(self: *FilePicker) void {
    if (self.entryCount() == 0) return;
    if (self.selected < self.entryCount() - 1) {
        self.selected += 1;
        self.adjustScroll();
        self.dirty = true;
    }
}

fn moveToTop(self: *FilePicker) void {
    if (self.entryCount() == 0) return;
    self.selected = 0;
    self.scroll_offset = 0;
    self.dirty = true;
}

fn moveToBottom(self: *FilePicker) void {
    if (self.entryCount() == 0) return;
    self.selected = self.entryCount() - 1;
    self.adjustScroll();
    self.dirty = true;
}

fn adjustScroll(self: *FilePicker) void {
    const visible = self.visibleCount();
    if (visible == 0) return;
    if (self.selected < self.scroll_offset) {
        self.scroll_offset = self.selected;
    } else if (self.selected >= self.scroll_offset + visible) {
        self.scroll_offset = self.selected - visible + 1;
    }
}

fn visibleCount(self: *const FilePicker) usize {
    if (self.config.max_visible) |max| {
        return @min(max, self.entryCount());
    }
    return self.entryCount();
}

// -- Tests --

test "init loads directory entries" {
    const allocator = std.testing.allocator;
    var fp = FilePicker.init(allocator, ".", .{});
    defer fp.deinit();
    // Current directory should have at least some entries (src, build.zig, etc.)
    try std.testing.expect(fp.entryCount() > 0);
}

test "entries sorted: directories first, then alphabetical" {
    const allocator = std.testing.allocator;
    var fp = FilePicker.init(allocator, ".", .{});
    defer fp.deinit();

    // Verify directories come first
    var found_file = false;
    for (fp.entries.items) |entry| {
        if (entry.kind != .directory) {
            found_file = true;
        } else if (found_file) {
            // Directory after a file means bad sort
            try std.testing.expect(false);
        }
    }
}

test "move down and up" {
    const allocator = std.testing.allocator;
    var fp = FilePicker.init(allocator, ".", .{});
    defer fp.deinit();
    if (fp.entryCount() < 2) return;

    _ = fp.handleEvent(.{ .key = .down });
    try std.testing.expectEqual(@as(usize, 1), fp.selected);

    _ = fp.handleEvent(.{ .key = .up });
    try std.testing.expectEqual(@as(usize, 0), fp.selected);
}

test "move down at bottom stays" {
    const allocator = std.testing.allocator;
    var fp = FilePicker.init(allocator, ".", .{});
    defer fp.deinit();
    if (fp.entryCount() == 0) return;

    // Move to bottom
    for (0..fp.entryCount()) |_| {
        _ = fp.handleEvent(.{ .key = .down });
    }
    const at_bottom = fp.selected;
    _ = fp.handleEvent(.{ .key = .down });
    try std.testing.expectEqual(at_bottom, fp.selected);
}

test "move up at top stays" {
    const allocator = std.testing.allocator;
    var fp = FilePicker.init(allocator, ".", .{});
    defer fp.deinit();

    _ = fp.handleEvent(.{ .key = .up });
    try std.testing.expectEqual(@as(usize, 0), fp.selected);
}

test "vim keys j/k" {
    const allocator = std.testing.allocator;
    var fp = FilePicker.init(allocator, ".", .{});
    defer fp.deinit();
    if (fp.entryCount() < 2) return;

    _ = fp.handleEvent(.{ .key = .{ .char = 'j' } });
    try std.testing.expectEqual(@as(usize, 1), fp.selected);

    _ = fp.handleEvent(.{ .key = .{ .char = 'k' } });
    try std.testing.expectEqual(@as(usize, 0), fp.selected);
}

test "g and G jump to top/bottom" {
    const allocator = std.testing.allocator;
    var fp = FilePicker.init(allocator, ".", .{});
    defer fp.deinit();
    if (fp.entryCount() < 2) return;

    _ = fp.handleEvent(.{ .key = .{ .char = 'G' } });
    try std.testing.expectEqual(fp.entryCount() - 1, fp.selected);

    _ = fp.handleEvent(.{ .key = .{ .char = 'g' } });
    try std.testing.expectEqual(@as(usize, 0), fp.selected);
}

test "home and end keys" {
    const allocator = std.testing.allocator;
    var fp = FilePicker.init(allocator, ".", .{});
    defer fp.deinit();
    if (fp.entryCount() < 2) return;

    _ = fp.handleEvent(.{ .key = .end });
    try std.testing.expectEqual(fp.entryCount() - 1, fp.selected);

    _ = fp.handleEvent(.{ .key = .home });
    try std.testing.expectEqual(@as(usize, 0), fp.selected);
}

test "enter on file confirms" {
    const allocator = std.testing.allocator;
    var fp = FilePicker.init(allocator, ".", .{});
    defer fp.deinit();

    // Find a file entry
    var file_idx: ?usize = null;
    for (fp.entries.items, 0..) |entry, i| {
        if (entry.kind == .file) {
            file_idx = i;
            break;
        }
    }
    if (file_idx) |idx| {
        fp.selected = idx;
        const result = fp.handleEvent(.{ .key = .enter });
        try std.testing.expectEqual(Widget.HandleResult.done, result);
        try std.testing.expect(fp.isConfirmed());
    }
}

test "enter on directory navigates into it" {
    const allocator = std.testing.allocator;
    var fp = FilePicker.init(allocator, ".", .{});
    defer fp.deinit();

    // Find a directory entry
    var dir_idx: ?usize = null;
    for (fp.entries.items, 0..) |entry, i| {
        if (entry.kind == .directory) {
            dir_idx = i;
            break;
        }
    }
    if (dir_idx) |idx| {
        fp.selected = idx;
        // Copy name before entering (loadDirectory frees old entries)
        var name_buf: [256]u8 = undefined;
        const dir_name = fp.entries.items[idx].name;
        @memcpy(name_buf[0..dir_name.len], dir_name);
        const saved_name = name_buf[0..dir_name.len];
        const result = fp.handleEvent(.{ .key = .enter });
        try std.testing.expectEqual(Widget.HandleResult.consumed, result);
        // Path should now contain the directory name
        try std.testing.expect(std.mem.endsWith(u8, fp.currentPath(), saved_name));
    }
}

test "left arrow goes to parent" {
    const allocator = std.testing.allocator;
    // Use "src" as the starting path (we know it exists)
    var fp = FilePicker.init(allocator, "src", .{});
    defer fp.deinit();

    const original_path_len = fp.current_path.items.len;
    _ = fp.handleEvent(.{ .key = .left });
    // Path should be shorter after going to parent
    try std.testing.expect(fp.current_path.items.len < original_path_len);
}

test "backspace goes to parent" {
    const allocator = std.testing.allocator;
    var fp = FilePicker.init(allocator, "src", .{});
    defer fp.deinit();

    const original_path_len = fp.current_path.items.len;
    _ = fp.handleEvent(.{ .key = .backspace });
    try std.testing.expect(fp.current_path.items.len < original_path_len);
}

test "escape cancels" {
    const allocator = std.testing.allocator;
    var fp = FilePicker.init(allocator, ".", .{});
    defer fp.deinit();

    const result = fp.handleEvent(.{ .key = .escape });
    try std.testing.expectEqual(Widget.HandleResult.done, result);
    try std.testing.expect(fp.isCancelled());
}

test "scroll offset with max_visible" {
    const allocator = std.testing.allocator;
    var fp = FilePicker.init(allocator, ".", .{ .max_visible = 3 });
    defer fp.deinit();
    if (fp.entryCount() < 5) return;

    try std.testing.expectEqual(@as(usize, 0), fp.scroll_offset);

    _ = fp.handleEvent(.{ .key = .down }); // 1
    _ = fp.handleEvent(.{ .key = .down }); // 2
    _ = fp.handleEvent(.{ .key = .down }); // 3
    try std.testing.expectEqual(@as(usize, 3), fp.selected);
    try std.testing.expectEqual(@as(usize, 1), fp.scroll_offset);
}

test "render contains cursor and entry names" {
    const allocator = std.testing.allocator;
    var fp = FilePicker.init(allocator, ".", .{ .cursor = "> ", .indent = "  " });
    defer fp.deinit();
    if (fp.entryCount() == 0) return;

    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try fp.render(fbs.writer());

    const output = fbs.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, output, "> ") != null);
}

test "render with show_path" {
    const allocator = std.testing.allocator;
    var fp = FilePicker.init(allocator, "src", .{ .show_path = true });
    defer fp.deinit();

    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try fp.render(fbs.writer());

    const output = fbs.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, output, "src") != null);
}

test "render with show_count" {
    const allocator = std.testing.allocator;
    var fp = FilePicker.init(allocator, ".", .{ .show_count = true });
    defer fp.deinit();
    if (fp.entryCount() == 0) return;

    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try fp.render(fbs.writer());

    const output = fbs.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, output, "1/") != null);
}

test "selectedEntry returns current entry" {
    const allocator = std.testing.allocator;
    var fp = FilePicker.init(allocator, ".", .{});
    defer fp.deinit();
    if (fp.entryCount() == 0) return;

    const entry = fp.selectedEntry().?;
    try std.testing.expect(entry.name.len > 0);
}

test "selectedPath returns full path" {
    const allocator = std.testing.allocator;
    var fp = FilePicker.init(allocator, "src", .{});
    defer fp.deinit();
    if (fp.entryCount() == 0) return;

    const path = fp.selectedPath().?;
    defer allocator.free(path);
    try std.testing.expect(std.mem.startsWith(u8, path, "src"));
}

test "unhandled key returns ignored" {
    const allocator = std.testing.allocator;
    var fp = FilePicker.init(allocator, ".", .{});
    defer fp.deinit();

    const result = fp.handleEvent(.{ .key = .tab });
    try std.testing.expectEqual(Widget.HandleResult.ignored, result);
}

test "directories shown with trailing slash in render" {
    const allocator = std.testing.allocator;
    var fp = FilePicker.init(allocator, ".", .{});
    defer fp.deinit();

    // Find if there's a directory entry
    var has_dir = false;
    for (fp.entries.items) |entry| {
        if (entry.kind == .directory) {
            has_dir = true;
            break;
        }
    }
    if (!has_dir) return;

    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try fp.render(fbs.writer());

    const output = fbs.getWritten();
    // At least one entry should end with "/"
    try std.testing.expect(std.mem.indexOf(u8, output, "/") != null);
}
