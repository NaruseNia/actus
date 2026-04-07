const std = @import("std");
const Event = @import("../event.zig").Event;
const Key = @import("../event.zig").Key;
const Widget = @import("../Widget.zig");
const Terminal = @import("../Terminal.zig");
const Style = @import("../Style.zig");
const Theme = @import("../Theme.zig");
const HelpLine = @import("HelpLine.zig");

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
    size: ?u64 = null,
    mode: ?u32 = null,
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
    /// Show file size next to entries.
    show_size: bool = false,
    /// Show POSIX permission bits next to entries.
    show_permissions: bool = false,
    /// Style for metadata (size, permissions). Overrides theme.muted when set.
    meta_style: ?Style = null,
    /// Show item count at the bottom of the list.
    show_count: bool = false,
    /// Style for the count line. Overrides theme.muted when set.
    count_style: ?Style = null,
    /// Show current directory path at the top.
    show_path: bool = true,
    /// Style for the path line. Overrides theme.muted when set.
    path_style: ?Style = null,
    /// Enable incremental filter/search mode.
    filterable: bool = false,
    /// Prefix shown before the filter input line.
    filter_prefix: []const u8 = "/ ",
    /// Placeholder shown when the filter is empty.
    filter_placeholder: []const u8 = "",
    /// Style for the filter placeholder. Overrides theme.muted when set.
    filter_placeholder_style: ?Style = null,
    /// When set, only files with these extensions are shown. Directories are always shown.
    /// Extensions should include the dot (e.g. &.{ ".zig", ".txt" }).
    allowed_extensions: ?[]const []const u8 = null,
    /// When true, current_path and selectedPath return absolute paths.
    /// When false (default), paths stay relative as given to init.
    absolute_path: bool = false,
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
initial_path: std.ArrayListUnmanaged(u8) = .empty,

/// Filter input buffer (used when filterable is true).
filter_buffer: std.ArrayListUnmanaged(u8) = .empty,
/// Indices into `entries` that match the current filter.
filtered_indices: std.ArrayListUnmanaged(usize) = .empty,

config: Config,
allocator: std.mem.Allocator,

pub fn init(allocator: std.mem.Allocator, initial_path: []const u8, config: Config) FilePicker {
    var fp = FilePicker{
        .config = config,
        .allocator = allocator,
    };
    if (config.absolute_path) {
        // Resolve to absolute path
        if (std.fs.cwd().realpathAlloc(allocator, initial_path)) |abs| {
            fp.current_path.appendSlice(allocator, abs) catch {};
            allocator.free(abs);
        } else |_| {
            fp.current_path.appendSlice(allocator, initial_path) catch {};
        }
    } else {
        fp.current_path.appendSlice(allocator, initial_path) catch {};
    }
    // Remove trailing separator if present (unless root "/")
    if (fp.current_path.items.len > 1 and fp.current_path.items[fp.current_path.items.len - 1] == std.fs.path.sep) {
        fp.current_path.shrinkRetainingCapacity(fp.current_path.items.len - 1);
    }
    // Remember initial path to control ".." visibility
    fp.initial_path.appendSlice(allocator, fp.current_path.items) catch {};
    fp.loadDirectory();
    return fp;
}

pub fn deinit(self: *FilePicker) void {
    self.freeEntries();
    self.entries.deinit(self.allocator);
    self.current_path.deinit(self.allocator);
    self.initial_path.deinit(self.allocator);
    self.filter_buffer.deinit(self.allocator);
    self.filtered_indices.deinit(self.allocator);
}

/// Returns the current filter text.
pub fn filterValue(self: *const FilePicker) []const u8 {
    return self.filter_buffer.items;
}

/// Returns the currently selected entry.
pub fn selectedEntry(self: *const FilePicker) ?Entry {
    if (self.filteredCount() == 0) return null;
    return self.entries.items[self.filtered_indices.items[self.selected]];
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

/// Returns the default help-line bindings for the current state.
/// Used by `WithHelpLine` to auto-populate the help line.
pub fn helpBindings(self: *const FilePicker) []const HelpLine.Binding {
    if (self.config.filterable and self.filter_buffer.items.len > 0) {
        return &.{
            .{ .key = "\xe2\x86\x91\xe2\x86\x93", .action = "Navigate" },
            .{ .key = "\xe2\x86\x90", .action = "Parent" },
            .{ .key = "Esc", .action = "Clear" },
            .{ .key = "Enter", .action = "Open/Select" },
        };
    }
    return &.{
        .{ .key = "\xe2\x86\x91\xe2\x86\x93", .action = "Navigate" },
        .{ .key = "\xe2\x86\x90", .action = "Parent" },
        .{ .key = "Esc", .action = "Cancel" },
        .{ .key = "Enter", .action = "Open/Select" },
    };
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

    // Filter input line
    if (self.config.filterable) {
        if (total_lines > 0) try writer.writeAll("\n");
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
        if (total_lines > 0) try writer.writeAll("\n");
        try Terminal.clearLine(writer);
        const muted = self.config.theme.muted;
        try muted.write(writer, "  (empty)");
        total_lines += 1;
    } else {
        const visible = self.visibleCount();
        const start = self.scroll_offset;
        const end = start + visible;

        for (start..end) |fi| {
            const entry_idx = self.filtered_indices.items[fi];
            const entry = self.entries.items[entry_idx];
            if (total_lines > 0) try writer.writeAll("\n");
            try Terminal.clearLine(writer);

            const is_dir = entry.kind == .directory;

            // Cursor prefix (not styled with meta)
            if (fi == self.selected) {
                const sel_style = self.config.selected_style orelse self.config.theme.primary;
                try sel_style.writeStart(writer);
                try writer.writeAll(self.config.cursor);
                try sel_style.writeEnd(writer);
            } else {
                try writer.writeAll(self.config.indent);
            }

            // Metadata columns (permissions, size) before filename
            try self.renderEntryMeta(writer, entry);

            // Filename
            if (fi == self.selected) {
                const sel_style = self.config.selected_style orelse self.config.theme.primary;
                try sel_style.writeStart(writer);
                try writer.writeAll(entry.name);
                if (is_dir) try writer.writeAll("/");
                try sel_style.writeEnd(writer);
            } else {
                const base_style = if (is_dir)
                    self.config.dir_style orelse self.config.theme.accent
                else
                    self.config.normal_style orelse self.config.theme.text;
                try base_style.writeStart(writer);
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
        if (self.filter_buffer.items.len > 0) {
            try cnt_style.print(writer, "{d}/{d} ({d} total)", .{
                if (count > 0) self.selected + 1 else @as(usize, 0),
                count,
                self.entries.items.len,
            });
        } else {
            try cnt_style.print(writer, "{d}/{d}", .{
                if (count > 0) self.selected + 1 else @as(usize, 0),
                count,
            });
        }
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

    // Position cursor on the filter input line for text entry
    if (self.config.filterable and total_lines > 1) {
        const filter_line: usize = if (self.config.show_path) 1 else 0;
        const lines_to_go_up = self.cursor_line -| filter_line;
        if (lines_to_go_up > 0) {
            try Terminal.moveCursorUp(writer, @intCast(lines_to_go_up));
        }
        const col = self.config.filter_prefix.len + self.filter_buffer.items.len;
        try Terminal.moveCursorTo(writer, @intCast(col));
        self.cursor_line = filter_line;
    }

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

pub fn layoutInfo(self: *const FilePicker) ?Widget.LayoutInfo {
    if (self.last_rendered_lines == 0) return null;
    return .{
        .total_lines = self.last_rendered_lines,
        .cursor_line = self.cursor_line,
    };
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
        .left => {
            self.goToParent();
            return .consumed;
        },
        .backspace => {
            if (self.config.filterable) {
                self.deleteFilterChar();
                return .consumed;
            }
            self.goToParent();
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
        .home => {
            self.moveToTop();
            return .consumed;
        },
        .end => {
            self.moveToBottom();
            return .consumed;
        },
        .enter => {
            if (self.filteredCount() == 0) return .done;
            const entry_idx = self.filtered_indices.items[self.selected];
            const entry = self.entries.items[entry_idx];
            if (entry.kind == .directory) {
                self.enterDirectory(entry.name);
                return .consumed;
            }
            self.confirmed = true;
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

// -- Directory operations --

fn loadDirectory(self: *FilePicker) void {
    self.freeEntries();

    const path = if (self.current_path.items.len == 0) "." else self.current_path.items;
    var dir = std.fs.cwd().openDir(path, .{ .iterate = true }) catch return;
    defer dir.close();

    var iter = dir.iterate();
    const need_stat = self.config.show_size or self.config.show_permissions;

    while (iter.next() catch null) |fs_entry| {
        const kind: EntryKind = switch (fs_entry.kind) {
            .directory => .directory,
            .sym_link => .sym_link,
            .file => .file,
            else => .unknown,
        };

        // Extension filter: directories always pass, files must match
        if (kind != .directory) {
            if (self.config.allowed_extensions) |exts| {
                if (!matchesExtension(fs_entry.name, exts)) continue;
            }
        }

        var entry = Entry{
            .name = undefined,
            .kind = kind,
        };
        if (need_stat) {
            if (dir.statFile(fs_entry.name)) |stat| {
                entry.size = stat.size;
                entry.mode = @as(u32, @intCast(@as(u16, @bitCast(stat.mode))));
            } else |_| {}
        }
        const name = self.allocator.dupe(u8, fs_entry.name) catch continue;
        entry.name = name;
        self.entries.append(self.allocator, entry) catch {
            self.allocator.free(name);
            continue;
        };
    }

    self.sortEntries();

    // Insert ".." at the top when not at the initial directory
    if (!std.mem.eql(u8, self.current_path.items, self.initial_path.items)) {
        const dotdot = self.allocator.dupe(u8, "..") catch ".."[0..0];
        if (dotdot.len > 0) {
            self.entries.insert(self.allocator, 0, .{
                .name = dotdot,
                .kind = .directory,
            }) catch {
                self.allocator.free(dotdot);
            };
        }
    }

    // Reset filter on directory change
    self.filter_buffer.clearRetainingCapacity();
    self.rebuildFilter();
    self.selected = 0;
    self.scroll_offset = 0;
    self.dirty = true;
}

fn enterDirectory(self: *FilePicker, name: []const u8) void {
    if (std.mem.eql(u8, name, "..")) {
        self.goToParent();
        return;
    }
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

fn filteredCount(self: *const FilePicker) usize {
    return self.filtered_indices.items.len;
}

fn moveUp(self: *FilePicker) void {
    if (self.filteredCount() == 0) return;
    if (self.selected > 0) {
        self.selected -= 1;
        self.adjustScroll();
        self.dirty = true;
    }
}

fn moveDown(self: *FilePicker) void {
    if (self.filteredCount() == 0) return;
    if (self.selected < self.filteredCount() - 1) {
        self.selected += 1;
        self.adjustScroll();
        self.dirty = true;
    }
}

fn moveToTop(self: *FilePicker) void {
    if (self.filteredCount() == 0) return;
    self.selected = 0;
    self.scroll_offset = 0;
    self.dirty = true;
}

fn moveToBottom(self: *FilePicker) void {
    if (self.filteredCount() == 0) return;
    self.selected = self.filteredCount() - 1;
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
        return @min(max, self.filteredCount());
    }
    return self.filteredCount();
}

// -- Filter --

fn insertFilterChar(self: *FilePicker, cp: u21) void {
    var encoded: [4]u8 = undefined;
    const len = std.unicode.utf8Encode(cp, &encoded) catch return;
    self.filter_buffer.insertSlice(self.allocator, self.filter_buffer.items.len, encoded[0..len]) catch return;
    self.rebuildFilter();
    self.selected = 0;
    self.scroll_offset = 0;
    self.dirty = true;
}

fn deleteFilterChar(self: *FilePicker) void {
    if (self.filter_buffer.items.len == 0) return;
    const prev_len = prevCodepointLen(self.filter_buffer.items, self.filter_buffer.items.len);
    self.filter_buffer.shrinkRetainingCapacity(self.filter_buffer.items.len - prev_len);
    self.rebuildFilter();
    if (self.filteredCount() > 0 and self.selected >= self.filteredCount()) {
        self.selected = self.filteredCount() - 1;
    }
    self.adjustScroll();
    self.dirty = true;
}

fn rebuildFilter(self: *FilePicker) void {
    self.filtered_indices.clearRetainingCapacity();
    const filter = self.filter_buffer.items;
    for (self.entries.items, 0..) |entry, i| {
        if (filter.len == 0 or containsCaseInsensitive(entry.name, filter)) {
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

fn prevCodepointLen(bytes: []const u8, pos: usize) usize {
    if (pos == 0) return 0;
    var i = pos - 1;
    while (i > 0 and (bytes[i] & 0xC0) == 0x80) {
        i -= 1;
    }
    return pos - i;
}

// -- Extension filter --

fn matchesExtension(name: []const u8, exts: []const []const u8) bool {
    for (exts) |ext| {
        if (std.mem.endsWith(u8, name, ext)) return true;
    }
    return false;
}

// -- Metadata rendering --

fn renderEntryMeta(self: *const FilePicker, writer: anytype, entry: Entry) !void {
    const has_meta = self.config.show_permissions or self.config.show_size;
    if (!has_meta) return;

    const m_style = self.config.meta_style orelse self.config.theme.muted;

    // Fixed-width columns: "rwxr-xr-x " (10) + "  1.2K " (7)
    // Each column ends with a space so the next column (or filename) aligns.
    if (self.config.show_permissions) {
        if (entry.mode) |mode| {
            var perm_buf: [9]u8 = undefined;
            const perm = formatPermissions(mode, &perm_buf);
            try m_style.write(writer, perm);
        } else {
            try m_style.write(writer, "---------");
        }
        try writer.writeAll(" ");
    }

    if (self.config.show_size) {
        // Fixed 6-char wide size column, right-aligned
        const size_width: usize = 6;
        if (entry.kind == .directory) {
            try m_style.write(writer, "     -");
        } else if (entry.size) |size| {
            var size_buf: [8]u8 = undefined;
            const size_str = formatSize(size, &size_buf);
            const padding = if (size_str.len < size_width) size_width - size_str.len else 0;
            for (0..padding) |_| try writer.writeAll(" ");
            try m_style.write(writer, size_str);
        } else {
            try m_style.write(writer, "     ?");
        }
        try writer.writeAll(" ");
    }
}

pub fn formatSize(size: u64, buf: *[8]u8) []const u8 {
    if (size < 1024) {
        return std.fmt.bufPrint(buf, "{d}B", .{size}) catch "?";
    } else if (size < 1024 * 1024) {
        const kb = @as(f64, @floatFromInt(size)) / 1024.0;
        return formatFloat(buf, kb, "K");
    } else if (size < 1024 * 1024 * 1024) {
        const mb = @as(f64, @floatFromInt(size)) / (1024.0 * 1024.0);
        return formatFloat(buf, mb, "M");
    } else {
        const gb = @as(f64, @floatFromInt(size)) / (1024.0 * 1024.0 * 1024.0);
        return formatFloat(buf, gb, "G");
    }
}

fn formatFloat(buf: *[8]u8, val: f64, suffix: []const u8) []const u8 {
    if (val < 10.0) {
        return std.fmt.bufPrint(buf, "{d:.1}{s}", .{ val, suffix }) catch "?";
    } else {
        const int_val: u64 = @intFromFloat(val);
        return std.fmt.bufPrint(buf, "{d}{s}", .{ int_val, suffix }) catch "?";
    }
}

pub fn formatPermissions(mode: u32, buf: *[9]u8) []const u8 {
    const chars = "rwx";
    inline for (0..3) |group| {
        const shift: u5 = @intCast((2 - group) * 3);
        const bits: u3 = @truncate(mode >> shift);
        inline for (0..3) |bit| {
            const idx = group * 3 + bit;
            const flag: u3 = @as(u3, 1) << @intCast(2 - bit);
            buf[idx] = if (bits & flag != 0) chars[bit] else '-';
        }
    }
    return buf[0..9];
}

// -- Tests --

test "init loads directory entries" {
    const allocator = std.testing.allocator;
    var fp = FilePicker.init(allocator, ".", .{});
    defer fp.deinit();
    // Current directory should have at least some entries (src, build.zig, etc.)
    try std.testing.expect(fp.filteredCount() > 0);
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
    if (fp.filteredCount() < 2) return;

    _ = fp.handleEvent(.{ .key = .down });
    try std.testing.expectEqual(@as(usize, 1), fp.selected);

    _ = fp.handleEvent(.{ .key = .up });
    try std.testing.expectEqual(@as(usize, 0), fp.selected);
}

test "move down at bottom stays" {
    const allocator = std.testing.allocator;
    var fp = FilePicker.init(allocator, ".", .{});
    defer fp.deinit();
    if (fp.filteredCount() == 0) return;

    // Move to bottom
    for (0..fp.filteredCount()) |_| {
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
    if (fp.filteredCount() < 2) return;

    _ = fp.handleEvent(.{ .key = .{ .char = 'j' } });
    try std.testing.expectEqual(@as(usize, 1), fp.selected);

    _ = fp.handleEvent(.{ .key = .{ .char = 'k' } });
    try std.testing.expectEqual(@as(usize, 0), fp.selected);
}

test "g and G jump to top/bottom" {
    const allocator = std.testing.allocator;
    var fp = FilePicker.init(allocator, ".", .{});
    defer fp.deinit();
    if (fp.filteredCount() < 2) return;

    _ = fp.handleEvent(.{ .key = .{ .char = 'G' } });
    try std.testing.expectEqual(fp.filteredCount() - 1, fp.selected);

    _ = fp.handleEvent(.{ .key = .{ .char = 'g' } });
    try std.testing.expectEqual(@as(usize, 0), fp.selected);
}

test "home and end keys" {
    const allocator = std.testing.allocator;
    var fp = FilePicker.init(allocator, ".", .{});
    defer fp.deinit();
    if (fp.filteredCount() < 2) return;

    _ = fp.handleEvent(.{ .key = .end });
    try std.testing.expectEqual(fp.filteredCount() - 1, fp.selected);

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
    if (fp.filteredCount() < 5) return;

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
    if (fp.filteredCount() == 0) return;

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
    if (fp.filteredCount() == 0) return;

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
    if (fp.filteredCount() == 0) return;

    const entry = fp.selectedEntry().?;
    try std.testing.expect(entry.name.len > 0);
}

test "selectedPath returns full path" {
    const allocator = std.testing.allocator;
    var fp = FilePicker.init(allocator, "src", .{});
    defer fp.deinit();
    if (fp.filteredCount() == 0) return;

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

test "formatSize bytes" {
    var buf: [8]u8 = undefined;
    try std.testing.expectEqualStrings("0B", formatSize(0, &buf));
    try std.testing.expectEqualStrings("512B", formatSize(512, &buf));
    try std.testing.expectEqualStrings("1023B", formatSize(1023, &buf));
}

test "formatSize kilobytes" {
    var buf: [8]u8 = undefined;
    try std.testing.expectEqualStrings("1.0K", formatSize(1024, &buf));
    try std.testing.expectEqualStrings("1.5K", formatSize(1536, &buf));
    try std.testing.expectEqualStrings("10K", formatSize(10240, &buf));
}

test "formatSize megabytes" {
    var buf: [8]u8 = undefined;
    try std.testing.expectEqualStrings("1.0M", formatSize(1048576, &buf));
    try std.testing.expectEqualStrings("5.5M", formatSize(5767168, &buf));
}

test "formatSize gigabytes" {
    var buf: [8]u8 = undefined;
    try std.testing.expectEqualStrings("1.0G", formatSize(1073741824, &buf));
}

test "formatPermissions 0o755" {
    var buf: [9]u8 = undefined;
    try std.testing.expectEqualStrings("rwxr-xr-x", formatPermissions(0o755, &buf));
}

test "formatPermissions 0o644" {
    var buf: [9]u8 = undefined;
    try std.testing.expectEqualStrings("rw-r--r--", formatPermissions(0o644, &buf));
}

test "formatPermissions 0o000" {
    var buf: [9]u8 = undefined;
    try std.testing.expectEqualStrings("---------", formatPermissions(0o000, &buf));
}

test "formatPermissions 0o777" {
    var buf: [9]u8 = undefined;
    try std.testing.expectEqualStrings("rwxrwxrwx", formatPermissions(0o777, &buf));
}

test "render with show_size" {
    const allocator = std.testing.allocator;
    var fp = FilePicker.init(allocator, ".", .{ .show_size = true });
    defer fp.deinit();
    if (fp.filteredCount() == 0) return;

    var buf: [8192]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try fp.render(fbs.writer());

    // Should render without errors (basic smoke test)
    try std.testing.expect(fbs.getWritten().len > 0);
}

test "render with show_permissions" {
    const allocator = std.testing.allocator;
    var fp = FilePicker.init(allocator, ".", .{ .show_permissions = true });
    defer fp.deinit();
    if (fp.filteredCount() == 0) return;

    var buf: [8192]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try fp.render(fbs.writer());

    const output = fbs.getWritten();
    // Should contain permission-like patterns (r/w/x or -)
    try std.testing.expect(std.mem.indexOf(u8, output, "rw") != null or
        std.mem.indexOf(u8, output, "---") != null);
}

test "render with show_size and show_permissions" {
    const allocator = std.testing.allocator;
    var fp = FilePicker.init(allocator, ".", .{ .show_size = true, .show_permissions = true });
    defer fp.deinit();
    if (fp.filteredCount() == 0) return;

    var buf: [8192]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try fp.render(fbs.writer());

    try std.testing.expect(fbs.getWritten().len > 0);
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

test "filter narrows results" {
    const allocator = std.testing.allocator;
    // src/ directory should have .zig files
    var fp = FilePicker.init(allocator, "src", .{ .filterable = true });
    defer fp.deinit();

    const total_before = fp.filteredCount();
    if (total_before < 2) return;

    // Type a filter that should narrow results
    _ = fp.handleEvent(.{ .key = .{ .char = 'r' } });
    _ = fp.handleEvent(.{ .key = .{ .char = 'o' } });
    _ = fp.handleEvent(.{ .key = .{ .char = 'o' } });
    _ = fp.handleEvent(.{ .key = .{ .char = 't' } });

    try std.testing.expectEqualStrings("root", fp.filterValue());
    try std.testing.expect(fp.filteredCount() <= total_before);
}

test "filter backspace widens results" {
    const allocator = std.testing.allocator;
    var fp = FilePicker.init(allocator, "src", .{ .filterable = true });
    defer fp.deinit();

    _ = fp.handleEvent(.{ .key = .{ .char = 'r' } });
    _ = fp.handleEvent(.{ .key = .{ .char = 'o' } });
    _ = fp.handleEvent(.{ .key = .{ .char = 'o' } });
    const count_after_roo = fp.filteredCount();

    _ = fp.handleEvent(.{ .key = .backspace });
    try std.testing.expect(fp.filteredCount() >= count_after_roo);
    try std.testing.expectEqualStrings("ro", fp.filterValue());
}

test "escape clears filter before cancelling" {
    const allocator = std.testing.allocator;
    var fp = FilePicker.init(allocator, "src", .{ .filterable = true });
    defer fp.deinit();

    _ = fp.handleEvent(.{ .key = .{ .char = 'a' } });
    try std.testing.expectEqualStrings("a", fp.filterValue());

    // First escape clears filter
    const result1 = fp.handleEvent(.{ .key = .escape });
    try std.testing.expectEqual(Widget.HandleResult.consumed, result1);
    try std.testing.expectEqualStrings("", fp.filterValue());
    try std.testing.expect(!fp.isCancelled());

    // Second escape cancels
    const result2 = fp.handleEvent(.{ .key = .escape });
    try std.testing.expectEqual(Widget.HandleResult.done, result2);
    try std.testing.expect(fp.isCancelled());
}

test "vim keys disabled when filterable" {
    const allocator = std.testing.allocator;
    var fp = FilePicker.init(allocator, ".", .{ .filterable = true });
    defer fp.deinit();

    // 'j' should go to filter, not move down
    _ = fp.handleEvent(.{ .key = .{ .char = 'j' } });
    try std.testing.expectEqual(@as(usize, 0), fp.selected);
    try std.testing.expectEqualStrings("j", fp.filterValue());
}

test "filter reset on directory change" {
    const allocator = std.testing.allocator;
    var fp = FilePicker.init(allocator, ".", .{ .filterable = true });
    defer fp.deinit();

    // First, find a directory in the unfiltered list
    var dir_fi: ?usize = null;
    for (fp.filtered_indices.items, 0..) |entry_idx, fi| {
        if (fp.entries.items[entry_idx].kind == .directory) {
            dir_fi = fi;
            break;
        }
    }
    if (dir_fi == null) return;

    // Type a filter, then clear it so we can select the directory
    _ = fp.handleEvent(.{ .key = .{ .char = 'x' } });
    try std.testing.expectEqualStrings("x", fp.filterValue());
    // Clear filter to restore all entries
    _ = fp.handleEvent(.{ .key = .escape });

    // Select a directory and enter it
    fp.selected = dir_fi.?;
    _ = fp.handleEvent(.{ .key = .enter });
    // Filter should be cleared after directory change
    try std.testing.expectEqualStrings("", fp.filterValue());
}

test "left arrow goes to parent when filterable" {
    const allocator = std.testing.allocator;
    var fp = FilePicker.init(allocator, "src", .{ .filterable = true });
    defer fp.deinit();

    const original_path_len = fp.current_path.items.len;
    _ = fp.handleEvent(.{ .key = .left });
    try std.testing.expect(fp.current_path.items.len < original_path_len);
}

test "containsCaseInsensitive" {
    try std.testing.expect(containsCaseInsensitive("Apple", "app"));
    try std.testing.expect(containsCaseInsensitive("Apple", "PLE"));
    try std.testing.expect(containsCaseInsensitive("Apple", "apple"));
    try std.testing.expect(!containsCaseInsensitive("Apple", "xyz"));
    try std.testing.expect(containsCaseInsensitive("Apple", ""));
    try std.testing.expect(!containsCaseInsensitive("", "a"));
}

test "render with filterable" {
    const allocator = std.testing.allocator;
    var fp = FilePicker.init(allocator, ".", .{ .filterable = true, .filter_prefix = "/ " });
    defer fp.deinit();

    var buf: [8192]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try fp.render(fbs.writer());

    const output = fbs.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, output, "/ ") != null);
}

test "helpBindings default state" {
    const allocator = std.testing.allocator;
    var fp = FilePicker.init(allocator, ".", .{});
    defer fp.deinit();

    const bindings = fp.helpBindings();
    try std.testing.expectEqual(@as(usize, 4), bindings.len);
    try std.testing.expectEqualStrings("Cancel", bindings[2].action);
}

test "helpBindings with active filter shows Clear" {
    const allocator = std.testing.allocator;
    var fp = FilePicker.init(allocator, ".", .{ .filterable = true });
    defer fp.deinit();

    _ = fp.handleEvent(.{ .key = .{ .char = 'a' } });
    const bindings = fp.helpBindings();
    try std.testing.expectEqualStrings("Clear", bindings[2].action);
}

test "helpBindings after filter cleared shows Cancel" {
    const allocator = std.testing.allocator;
    var fp = FilePicker.init(allocator, ".", .{ .filterable = true });
    defer fp.deinit();

    _ = fp.handleEvent(.{ .key = .{ .char = 'a' } });
    _ = fp.handleEvent(.{ .key = .escape }); // Clear filter
    const bindings = fp.helpBindings();
    try std.testing.expectEqualStrings("Cancel", bindings[2].action);
}

test "absolute_path resolves to absolute" {
    const allocator = std.testing.allocator;
    var fp = FilePicker.init(allocator, ".", .{ .absolute_path = true });
    defer fp.deinit();

    // Should start with "/" on POSIX
    try std.testing.expect(fp.currentPath().len > 1);
    try std.testing.expect(fp.currentPath()[0] == '/');
}

test "relative path stays relative" {
    const allocator = std.testing.allocator;
    var fp = FilePicker.init(allocator, "src", .{ .absolute_path = false });
    defer fp.deinit();

    try std.testing.expectEqualStrings("src", fp.currentPath());
}

test "absolute_path selectedPath returns absolute" {
    const allocator = std.testing.allocator;
    var fp = FilePicker.init(allocator, ".", .{ .absolute_path = true });
    defer fp.deinit();
    if (fp.filteredCount() == 0) return;

    const path = fp.selectedPath().?;
    defer allocator.free(path);
    try std.testing.expect(path[0] == '/');
}

test "allowed_extensions filters files" {
    const allocator = std.testing.allocator;
    const exts = [_][]const u8{".zig"};
    var fp = FilePicker.init(allocator, "src", .{ .allowed_extensions = &exts });
    defer fp.deinit();

    // All non-directory entries should end with .zig
    for (fp.entries.items) |entry| {
        if (entry.kind != .directory) {
            try std.testing.expect(std.mem.endsWith(u8, entry.name, ".zig"));
        }
    }
}

test "allowed_extensions still shows directories" {
    const allocator = std.testing.allocator;
    const exts = [_][]const u8{".nonexistent"};
    var fp = FilePicker.init(allocator, ".", .{ .allowed_extensions = &exts });
    defer fp.deinit();

    // Should have at least directories (src/, .zig-cache/, etc.)
    var has_dir = false;
    for (fp.entries.items) |entry| {
        if (entry.kind == .directory) {
            has_dir = true;
            break;
        }
    }
    try std.testing.expect(has_dir);
}

test "allowed_extensions null shows all files" {
    const allocator = std.testing.allocator;
    var fp_all = FilePicker.init(allocator, "src", .{ .allowed_extensions = null });
    defer fp_all.deinit();

    const exts = [_][]const u8{".zig"};
    var fp_zig = FilePicker.init(allocator, "src", .{ .allowed_extensions = &exts });
    defer fp_zig.deinit();

    // Without filter should have >= entries than with filter
    try std.testing.expect(fp_all.entries.items.len >= fp_zig.entries.items.len);
}

test "matchesExtension" {
    const exts = [_][]const u8{ ".zig", ".txt" };
    try std.testing.expect(matchesExtension("main.zig", &exts));
    try std.testing.expect(matchesExtension("readme.txt", &exts));
    try std.testing.expect(!matchesExtension("image.png", &exts));
    try std.testing.expect(!matchesExtension("noext", &exts));
}

test "WithHelpLine(FilePicker) satisfies Widget interface" {
    const WithHelpLine = @import("WithHelpLine.zig").WithHelpLine;
    comptime Widget.assertIsWidget(WithHelpLine(FilePicker));
}

test "WithHelpLine(FilePicker) renders with help bindings" {
    const WithHelpLine = @import("WithHelpLine.zig").WithHelpLine;
    const allocator = std.testing.allocator;
    var fp = FilePicker.init(allocator, ".", .{});
    defer fp.deinit();

    var w = WithHelpLine(FilePicker).init(&fp, .{});

    var buf: [8192]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try w.render(&fbs.writer());

    const output = fbs.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, output, "Navigate") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Parent") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Cancel") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Open/Select") != null);
}
