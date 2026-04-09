const std = @import("std");
const Event = @import("../event.zig").Event;
const Widget = @import("../Widget.zig");
const Terminal = @import("../Terminal.zig");
const Style = @import("../Style.zig");
const Theme = @import("../Theme.zig");

const Spinner = @This();

comptime {
    Widget.assertIsWidget(Spinner);
}

// -- Configuration --

pub const Config = struct {
    /// Text displayed next to the spinner (e.g., "Loading...")
    text: []const u8 = "",
    /// Style for the text. Overrides theme.text when set.
    text_style: ?Style = null,
    /// Style for the spinner frames. Overrides theme.primary when set.
    spinner_style: ?Style = null,
    /// Animation frames (sequence of characters).
    /// Use presetFrames() for common patterns.
    frames: []const []const u8 = &.{ "|", "/", "-", "\\" },
    /// Text animation pattern (optional).
    /// Use presetTextAnimation() for common effects.
    text_animation: ?TextAnimation = null,
    /// Theme providing default styles.
    theme: Theme = Theme.default,
};

pub const TextAnimation = union(enum) {
    /// Dots flow: "Loading..." → "Loading.." → "Loading."
    dots: struct { base: []const u8, max_dots: usize = 3 },
    /// Bounce: "Loading===" → "Loading  =="
    bounce: struct { base: []const u8, char: u8 = '=', width: usize = 3 },
    /// Pulse: "===" → "====" → "=====" → back to "==="
    pulse: struct { char: u8 = '=', min: usize = 3, max: usize = 5 },
};

// -- State --

/// Current frame index (cycles through 0..frames.len-1)
current_frame: usize = 0,
/// Current text animation step
anim_step: usize = 0,
/// Animation direction (1 or -1) for bounce/pulse
anim_direction: i8 = 1,
/// Always needs re-render (animates continuously)
dirty: bool = true,
/// Temporary buffer for animated text
anim_buf: std.ArrayListUnmanaged(u8) = .empty,

config: Config,
allocator: std.mem.Allocator,

pub fn init(allocator: std.mem.Allocator, config: Config) Spinner {
    return .{
        .config = config,
        .allocator = allocator,
    };
}

pub fn deinit(self: *Spinner) void {
    self.anim_buf.deinit(self.allocator);
}

/// Manually advance to next frame (for testing or manual control).
pub fn tick(self: *Spinner) void {
    self.current_frame = (self.current_frame + 1) % self.config.frames.len;
    self.anim_step +%= 1; // Wrapping add
    self.dirty = true;
}

/// Whether this is a single-line widget (for cursor control).
pub fn isSingleLine() bool {
    return true;
}

/// Get preset frame patterns by name.
pub fn presetFrames(comptime name: []const u8) []const []const u8 {
    if (std.mem.eql(u8, name, "dots")) {
        return &.{ "...", "..", "." };
    } else if (std.mem.eql(u8, name, "pipes")) {
        return &.{ "|", "/", "-", "\\" };
    } else if (std.mem.eql(u8, name, "arrows")) {
        return &.{ "→", "↘", "↓", "↙", "←", "↖", "↑", "↗" };
    } else if (std.mem.eql(u8, name, "blocks")) {
        return &.{ "█", "▓", "▒", "░" };
    } else if (std.mem.eql(u8, name, "heavy_blocks")) {
        return &.{ "█", "▉", "▊", "▋", "▌", "▍", "▎", "▏" };
    } else {
        return &.{ "|", "/", "-", "\\" }; // Default
    }
}

/// Get preset text animation by name.
pub fn presetTextAnimation(comptime name: []const u8, text: []const u8) ?TextAnimation {
    if (std.mem.eql(u8, name, "dots")) {
        return .{ .dots = .{ .base = text, .max_dots = 3 } };
    } else if (std.mem.eql(u8, name, "bounce")) {
        return .{ .bounce = .{ .base = text, .char = '=', .width = 3 } };
    } else if (std.mem.eql(u8, name, "pulse")) {
        return .{ .pulse = .{ .char = '=', .min = 3, .max = 5 } };
    } else {
        return null;
    }
}

// -- Widget interface --

pub fn handleEvent(_: *Spinner, ev: Event) Widget.HandleResult {
    // Progress widgets typically ignore events except Ctrl-C
    // handled by App.runProgress
    _ = ev;
    return .ignored;
}

pub fn render(self: *Spinner, writer: anytype) !void {
    try Terminal.clearLine(writer);

    // Render spinner frame
    const frame = self.config.frames[self.current_frame];
    const spinner_style = self.config.spinner_style orelse self.config.theme.primary;
    try spinner_style.write(writer, frame);
    try writer.writeAll(" ");

    // Render text with optional animation
    const text_style = self.config.text_style orelse self.config.theme.text;
    if (self.config.text_animation) |anim| {
        self.anim_buf.clearRetainingCapacity();
        const animated_text = try self.applyTextAnimation(anim);
        try text_style.write(writer, animated_text);
    } else {
        try text_style.write(writer, self.config.text);
    }

    // Auto-advance frame for next render
    self.tick();
}

pub fn needsRender(_: *const Spinner) bool {
    return true; // Always animates
}

// -- Text animation helpers --

fn applyTextAnimation(self: *Spinner, anim: TextAnimation) ![]const u8 {
    return switch (anim) {
        .dots => |cfg| {
            const dots = (self.anim_step / 2) % (cfg.max_dots + 1);
            try self.anim_buf.appendSlice(self.allocator, cfg.base);
            for (0..dots) |_| {
                try self.anim_buf.append(self.allocator, '.');
            }
            return self.anim_buf.items;
        },
        .bounce => |cfg| {
            const pos = self.anim_step % (cfg.width * 2);
            const offset = if (pos < cfg.width) pos else (cfg.width * 2 - pos);
            try self.anim_buf.appendSlice(self.allocator, cfg.base);
            try self.anim_buf.appendSlice(self.allocator, " ");
            for (0..(cfg.width - offset)) |_| {
                try self.anim_buf.append(self.allocator, cfg.char);
            }
            return self.anim_buf.items;
        },
        .pulse => |cfg| {
            const range = cfg.max - cfg.min;
            const len = cfg.min + @abs(@mod(self.anim_step, range * 2) - range);
            for (0..len) |_| {
                try self.anim_buf.append(self.allocator, cfg.char);
            }
            return self.anim_buf.items;
        },
    };
}

// -- Tests --

test "init and deinit" {
    const allocator = std.testing.allocator;
    var spinner = Spinner.init(allocator, .{});
    defer spinner.deinit();
    try std.testing.expectEqual(@as(usize, 0), spinner.current_frame);
}

test "tick advances frame" {
    const allocator = std.testing.allocator;
    var spinner = Spinner.init(allocator, .{
        .frames = &.{ "A", "B", "C" },
    });
    defer spinner.deinit();

    try std.testing.expectEqual(@as(usize, 0), spinner.current_frame);
    spinner.tick();
    try std.testing.expectEqual(@as(usize, 1), spinner.current_frame);
    spinner.tick();
    try std.testing.expectEqual(@as(usize, 2), spinner.current_frame);
    spinner.tick();
    try std.testing.expectEqual(@as(usize, 0), spinner.current_frame); // Wrapped
}

test "render contains frame and text" {
    const allocator = std.testing.allocator;
    var spinner = Spinner.init(allocator, .{
        .text = "Loading",
        .frames = &.{ "|", "/" },
    });
    defer spinner.deinit();

    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try spinner.render(fbs.writer());

    const output = fbs.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, output, "|") != null or std.mem.indexOf(u8, output, "/") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Loading") != null);
}

test "presetFrames returns correct patterns" {
    try std.testing.expectEqual(@as(usize, 3), Spinner.presetFrames("dots").len);
    try std.testing.expectEqual(@as(usize, 4), Spinner.presetFrames("pipes").len);
    try std.testing.expectEqual(@as(usize, 4), Spinner.presetFrames("blocks").len);
}

test "presetTextAnimation returns correct types" {
    const anim_dots = Spinner.presetTextAnimation("dots", "Loading");
    try std.testing.expect(anim_dots != null);

    const anim_bounce = Spinner.presetTextAnimation("bounce", "Processing");
    try std.testing.expect(anim_bounce != null);

    const anim_invalid = Spinner.presetTextAnimation("invalid", "Test");
    try std.testing.expect(anim_invalid == null);
}

test "isSingleLine returns true" {
    try std.testing.expect(Spinner.isSingleLine());
}

test "handleEvent returns ignored" {
    const allocator = std.testing.allocator;
    var spinner = Spinner.init(allocator, .{});
    defer spinner.deinit();

    const result = spinner.handleEvent(.{ .key = .enter });
    try std.testing.expectEqual(Widget.HandleResult.ignored, result);
}

test "needsRender always returns true" {
    const allocator = std.testing.allocator;
    var spinner = Spinner.init(allocator, .{});
    defer spinner.deinit();

    try std.testing.expect(spinner.needsRender());
}
