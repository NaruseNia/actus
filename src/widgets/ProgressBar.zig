const std = @import("std");
const Event = @import("../event.zig").Event;
const Widget = @import("../Widget.zig");
const Terminal = @import("../Terminal.zig");
const Style = @import("../Style.zig");
const Theme = @import("../Theme.zig");

const ProgressBar = @This();

comptime {
    Widget.assertIsWidget(ProgressBar);
}

// -- Configuration --

pub const Config = struct {
    /// Total value for completion (100%).
    total: u64 = 100,
    /// Current progress (0..total).
    current: u64 = 0,
    /// Width of the bar in characters (0 = auto-fit to terminal).
    width: usize = 40,
    /// Bar character style (plain, blocks, heavy, double, ascii).
    bar_style: BarStyle = .blocks,
    /// Custom bar characters (overrides bar_style).
    custom_chars: ?BarChars = null,
    /// Format string for value display.
    /// "{p}" = percentage, "{c}" = current, "{t}" = total
    format: []const u8 = "{p}%",
    /// Show elapsed time.
    show_elapsed: bool = false,
    /// Show estimated time remaining.
    show_eta: bool = false,
    /// Style for the bar. Overrides theme.primary when set.
    bar_style_override: ?Style = null,
    /// Style for the background. Overrides theme.muted when set.
    bg_style: ?Style = null,
    /// Theme providing default styles.
    theme: Theme = Theme.default,
};

pub const BarStyle = enum {
    plain,       // "===>"
    blocks,      // "████▒▒▒"
    heavy,       // "█████▒▒"
    double,      // "║║║║░░"
    ascii,       // ">>>>..."
};

pub const BarChars = struct {
    filled: []const u8 = "█",
    empty: []const u8 = "░",
    tip: ?[]const u8 = null, // Optional tip character (e.g., ">")
};

// -- State --

/// Start timestamp for ETA calculation.
start_time: i64 = 0,
/// Last update timestamp.
last_update: i64 = 0,
/// Always needs re-render (progress changes).
dirty: bool = true,
/// Temporary buffer for formatted output
fmt_buf: std.ArrayListUnmanaged(u8) = .empty,

config: Config,
allocator: std.mem.Allocator,

pub fn init(allocator: std.mem.Allocator, config: Config) ProgressBar {
    return .{
        .config = config,
        .allocator = allocator,
        .start_time = std.time.milliTimestamp(),
    };
}

pub fn deinit(self: *ProgressBar) void {
    self.fmt_buf.deinit(self.allocator);
}

/// Update progress value.
pub fn update(self: *ProgressBar, current: u64) void {
    self.config.current = current;
    self.last_update = std.time.milliTimestamp();
    self.dirty = true;
}

/// Increment progress by delta.
pub fn increment(self: *ProgressBar, delta: u64) void {
    self.update(self.config.current + delta);
}

/// Whether this is a single-line widget.
pub fn isSingleLine() bool {
    return true;
}

/// Get current completion as percentage (0.0-1.0).
pub fn fraction(self: *const ProgressBar) f64 {
    if (self.config.total == 0) return 0;
    return @as(f64, @floatFromInt(self.config.current)) /
           @as(f64, @floatFromInt(self.config.total));
}

// -- Widget interface --

pub fn handleEvent(_: *ProgressBar, ev: Event) Widget.HandleResult {
    // Progress widgets typically ignore events except Ctrl-C
    // handled by App.runProgress
    _ = ev;
    return .ignored;
}

pub fn render(self: *ProgressBar, writer: anytype) !void {
    try Terminal.clearLine(writer);

    const frac = self.fraction();
    const bar_width = self.config.width;
    const filled_len = @as(usize, @intFromFloat(frac * @as(f64, @floatFromInt(bar_width))));
    const empty_len = bar_width - filled_len;

    // Render bar
    const chars = self.getBarChars();
    const bar_style = self.config.bar_style_override orelse self.config.theme.primary;
    const bg_style = self.config.bg_style orelse self.config.theme.muted;

    try bar_style.writeStart(writer);
    for (0..filled_len) |_| {
        try writer.writeAll(chars.filled);
    }
    try bar_style.writeEnd(writer);

    try bg_style.writeStart(writer);
    for (0..empty_len) |_| {
        try writer.writeAll(chars.empty);
    }
    try bg_style.writeEnd(writer);

    if (chars.tip) |tip| {
        try writer.writeAll(tip);
    }

    // Render format string
    try writer.writeAll(" ");
    const text_style = self.config.theme.text;
    self.fmt_buf.clearRetainingCapacity();
    const formatted = try self.formatProgress(frac);
    try text_style.write(writer, formatted);

    // Render time info
    if (self.config.show_elapsed or self.config.show_eta) {
        try writer.writeAll(" (");
        if (self.config.show_elapsed) {
            try self.renderElapsed(writer);
        }
        if (self.config.show_elapsed and self.config.show_eta) {
            try writer.writeAll(", ");
        }
        if (self.config.show_eta) {
            try self.renderETA(writer, frac);
        }
        try writer.writeAll(")");
    }

    self.dirty = false;
}

pub fn needsRender(_: *const ProgressBar) bool {
    return true; // Always animates
}

// -- Helpers --

fn getBarChars(self: *const ProgressBar) BarChars {
    if (self.config.custom_chars) |chars| return chars;

    return switch (self.config.bar_style) {
        .plain => .{ .filled = "=", .empty = "-", .tip = ">" },
        .blocks => .{ .filled = "█", .empty = "░" },
        .heavy => .{ .filled = "█", .empty = "▒" },
        .double => .{ .filled = "║", .empty = "░" },
        .ascii => .{ .filled = ">", .empty = "." },
    };
}

fn formatProgress(self: *ProgressBar, frac: f64) ![]const u8 {
    const percentage = frac * 100;
    const current = self.config.current;
    const total = self.config.total;

    // Parse format string and replace placeholders
    const fmt = self.config.format;
    try self.fmt_buf.ensureTotalCapacity(self.allocator, fmt.len + 32);

    var i: usize = 0;
    while (i < fmt.len) {
        if (i + 2 < fmt.len and fmt[i] == '{' and fmt[i + 2] == '}') {
            const placeholder = fmt[i + 1];
            switch (placeholder) {
                'p' => {
                    const p_str = try std.fmt.allocPrint(
                        self.allocator,
                        "{d:.1}",
                        .{percentage}
                    );
                    defer self.allocator.free(p_str);
                    try self.fmt_buf.appendSlice(self.allocator, p_str);
                },
                'c' => {
                    const c_str = try std.fmt.allocPrint(
                        self.allocator,
                        "{d}",
                        .{current}
                    );
                    defer self.allocator.free(c_str);
                    try self.fmt_buf.appendSlice(self.allocator, c_str);
                },
                't' => {
                    const t_str = try std.fmt.allocPrint(
                        self.allocator,
                        "{d}",
                        .{total}
                    );
                    defer self.allocator.free(t_str);
                    try self.fmt_buf.appendSlice(self.allocator, t_str);
                },
                else => {
                    try self.fmt_buf.append(self.allocator, '{');
                    try self.fmt_buf.append(self.allocator, placeholder);
                    try self.fmt_buf.append(self.allocator, '}');
                },
            }
            i += 3;
        } else {
            try self.fmt_buf.append(self.allocator, fmt[i]);
            i += 1;
        }
    }

    return self.fmt_buf.items;
}

fn renderElapsed(self: *const ProgressBar, writer: anytype) !void {
    const elapsed_ms = std.time.milliTimestamp() - self.start_time;
    try writer.writeAll(self.formatDuration(elapsed_ms));
}

fn renderETA(self: *const ProgressBar, writer: anytype, frac: f64) !void {
    if (frac <= 0) {
        try writer.writeAll("--:--");
        return;
    }
    const elapsed_ms = std.time.milliTimestamp() - self.start_time;
    if (elapsed_ms <= 0) {
        try writer.writeAll("--:--");
        return;
    }
    const total_ms = @as(i64, @intFromFloat(@divTrunc(
        @as(f128, @floatFromInt(elapsed_ms)),
        frac
    )));
    const eta_ms = total_ms - elapsed_ms;
    try writer.writeAll(self.formatDuration(eta_ms));
}

fn formatDuration(self: *const ProgressBar, ms: i64) []const u8 {
    const seconds = @max(0, ms / 1000);
    const mins = @min(99, seconds / 60);
    const secs = seconds % 60;

    // Reuse fmt_buf for duration formatting
    self.fmt_buf.clearRetainingCapacity();
    self.fmt_buf.appendSlice(self.allocator,
        std.fmt.allocPrint(self.allocator, "{d}:{d:0>2}", .{ mins, secs }) catch "--:--"
    ) catch {};

    return self.fmt_buf.items;
}

// -- Tests --

test "init and deinit" {
    const allocator = std.testing.allocator;
    var pb = ProgressBar.init(allocator, .{});
    defer pb.deinit();
    try std.testing.expectEqual(@as(u64, 0), pb.config.current);
}

test "fraction calculates correctly" {
    const allocator = std.testing.allocator;
    var pb = ProgressBar.init(allocator, .{
        .total = 100,
        .current = 50,
    });
    defer pb.deinit();

    try std.testing.expectApproxEqAbs(@as(f64, 0.5), pb.fraction(), 0.001);
    pb.update(75);
    try std.testing.expectApproxEqAbs(@as(f64, 0.75), pb.fraction(), 0.001);
}

test "update changes current value" {
    const allocator = std.testing.allocator;
    var pb = ProgressBar.init(allocator, .{
        .total = 100,
        .current = 0,
    });
    defer pb.deinit();

    try std.testing.expectEqual(@as(u64, 0), pb.config.current);
    pb.update(42);
    try std.testing.expectEqual(@as(u64, 42), pb.config.current);
}

test "increment updates value" {
    const allocator = std.testing.allocator;
    var pb = ProgressBar.init(allocator, .{
        .total = 100,
        .current = 0,
    });
    defer pb.deinit();

    try std.testing.expectEqual(@as(u64, 0), pb.config.current);
    pb.increment(25);
    try std.testing.expectEqual(@as(u64, 25), pb.config.current);
    pb.increment(25);
    try std.testing.expectEqual(@as(u64, 50), pb.config.current);
}

test "fraction handles zero total" {
    const allocator = std.testing.allocator;
    var pb = ProgressBar.init(allocator, .{
        .total = 0,
        .current = 0,
    });
    defer pb.deinit();

    try std.testing.expectEqual(@as(f64, 0), pb.fraction());
}

test "isSingleLine returns true" {
    try std.testing.expect(ProgressBar.isSingleLine());
}

test "handleEvent returns ignored" {
    const allocator = std.testing.allocator;
    var pb = ProgressBar.init(allocator, .{});
    defer pb.deinit();

    const result = pb.handleEvent(.{ .key = .enter });
    try std.testing.expectEqual(Widget.HandleResult.ignored, result);
}

test "needsRender always returns true" {
    const allocator = std.testing.allocator;
    var pb = ProgressBar.init(allocator, .{});
    defer pb.deinit();

    try std.testing.expect(pb.needsRender());
}

test "getBarChars returns correct chars for styles" {
    const allocator = std.testing.allocator;

    var pb_plain = ProgressBar.init(allocator, .{ .bar_style = .plain });
    defer pb_plain.deinit();
    const chars_plain = pb_plain.getBarChars();
    try std.testing.expectEqualStrings("=", chars_plain.filled);
    try std.testing.expectEqualStrings("-", chars_plain.empty);
    try std.testing.expect(chars_plain.tip != null);

    var pb_blocks = ProgressBar.init(allocator, .{ .bar_style = .blocks });
    defer pb_blocks.deinit();
    const chars_blocks = pb_blocks.getBarChars();
    try std.testing.expectEqualStrings("█", chars_blocks.filled);
    try std.testing.expectEqualStrings("░", chars_blocks.empty);
}

test "formatProgress handles placeholders" {
    const allocator = std.testing.allocator;
    var pb = ProgressBar.init(allocator, .{
        .total = 100,
        .current = 50,
        .format = "{p}% ({c}/{t})",
    });
    defer pb.deinit();

    const formatted = try pb.formatProgress(pb.fraction());
    try std.testing.expect(std.mem.indexOf(u8, formatted, "50") != null);
    try std.testing.expect(std.mem.indexOf(u8, formatted, "%") != null);
}

test "fraction handles clamping" {
    const allocator = std.testing.allocator;
    var pb = ProgressBar.init(allocator, .{
        .total = 100,
        .current = 150, // Over 100%
    });
    defer pb.deinit();

    // Should not exceed 1.0
    try std.testing.expect(pb.fraction() >= 1.0);
}
