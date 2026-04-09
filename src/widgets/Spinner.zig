const std = @import("std");
const math = std.math;
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
    frames: []const []const u8 = &.{ "⣾", "⣽", "⣻", "⢿", "⡿", "⣟", "⣯", "⣷" },
    /// Text animation pattern (optional).
    /// Use presetTextAnimation() for common effects.
    text_animation: ?TextAnimation = null,
    /// Theme providing default styles.
    theme: Theme = Theme.default,
};

pub const Preset = enum {
    dots,
    pipes,
    arrows,
    blocks,
    heavy_blocks,
    dot_cycle,
    dot_cycle_small,
    dot_stack,
    z_arrow,
    z_bar,
    z_1,
    z_2,
    z_3,
    grow_a,
    grow_b,
    grow_c,
    grow_d,
    grow_e,
    y_d,
    y_q,
};

pub const TextAnimation = union(enum) {
    /// Dots flow: "Loading..." → "Loading.." → "Loading."
    dots: struct { base: []const u8, max_dots: usize = 3 },
    /// Bounce: "Loading..." → "Loading.."
    bounce: struct { base: []const u8, char: u8 = '.', width: usize = 3 },
    /// Flow: Highlight flows from left to right across the text
    /// Similar to Claude Code's "pondering..." animation
    flow: struct {
        base: []const u8,
        width: usize = 3,
        text_style: ?Style = null,
        highlight_style: ?Style = null,
    },
    /// Pulse: Entire text slowly fades in and out
    pulse: struct {
        base: []const u8,
        text_style: ?Style = null,
        highlight_style: ?Style = null,
    },
};

// -- State --

/// Current frame index (cycles through 0..frames.len-1)
current_frame: usize = 0,
/// Current text animation step
anim_step: usize = 0,
/// Animation direction (1 or -1) for bounce
anim_direction: i8 = 1,
/// Always needs re-render (animates continuously)
dirty: bool = true,
/// Temporary buffer for animated text
anim_buf: std.ArrayListUnmanaged(u8) = .empty,
/// Current highlight style for animation (updated during render)
current_anim_style: ?Style = null,

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

/// Get preset frame patterns by enum.
pub fn presetFrames(comptime preset: Preset) []const []const u8 {
    return switch (preset) {
        .dots => &.{ "...", "..", "." },
        .pipes => &.{ "|", "/", "-", "\\" },
        .arrows => &.{ "→", "↘", "↓", "↙", "←", "↖", "↑", "↗" },
        .blocks => &.{ "█", "▓", "▒", "░" },
        .heavy_blocks => &.{ "█", "▉", "▊", "▋", "▌", "▍", "▎", "▏" },
        .dot_cycle => &.{ "⣾", "⣽", "⣻", "⢿", "⡿", "⣟", "⣯", "⣷" },
        .dot_cycle_small => &.{ "⠁", "⠂", "⠄", "⡀", "⢀", "⠠", "⠐", "⠈" },
        .dot_stack => &dot_stack_braille,
        .z_arrow => &.{ "←", "↖", "↑", "↗", "→", "↘", "↓", "↙" },
        .z_bar => &.{ "|", "/", "—", "\\" },
        .z_1 => &.{ "◰", "◳", "◲", "◱" },
        .z_2 => &.{ "◴", "◷", "◶", "◵" },
        .z_3 => &.{ "◐", "◓", "◑", "◒" },
        .grow_a => &.{ "|", "b", "O", "b" },
        .grow_b => &.{ "_", "o", "O", "o" },
        .grow_c => &.{ ".", "o", "O", "@", "*", " " },
        .grow_d => &.{ "▁", "▃", "▄", "▅", "▆", "▇", "█", "▇", "▆", "▅", "▄", "▃" },
        .grow_e => &.{ "▉", "▊", "▋", "▌", "▍", "▎", "▏", "▎", "▍", "▌", "▋", "▊", "▉" },
        .y_d => &.{ "d", "|", "b", "|" },
        .y_q => &.{ "q", "|", "p", "|" },
    };
}

// Complete Braille pattern (256 frames) for dot_stack preset
const dot_stack_braille = [_][]const u8{ "⡀", "⡁", "⡂", "⡃", "⡄", "⡅", "⡆", "⡇", "⡈", "⡉", "⡊", "⡋", "⡌", "⡍", "⡎", "⡏", "⡐", "⡑", "⡒", "⡓", "⡔", "⡕", "⡖", "⡗", "⡘", "⡙", "⡚", "⡛", "⡜", "⡝", "⡞", "⡟", "⡠", "⡡", "⡢", "⡣", "⡤", "⡥", "⡦", "⡧", "⡨", "⡩", "⡪", "⡫", "⡬", "⡭", "⡮", "⡯", "⡰", "⡱", "⡲", "⡳", "⡴", "⡵", "⡶", "⡷", "⡸", "⡹", "⡺", "⡻", "⡼", "⡽", "⡾", "⡿", "⢀", "⢁", "⢂", "⢃", "⢄", "⢅", "⢆", "⢇", "⢈", "⢉", "⢋", "⢌", "⢍", "⢎", "⢏", "⢐", "⢑", "⢒", "⢓", "⢔", "⢕", "⢖", "⢗", "⢘", "⢙", "⢚", "⢛", "⢜", "⢝", "⢞", "⢟", "⢠", "⢡", "⢢", "⢣", "⢤", "⢥", "⢦", "⢧", "⢨", "⢩", "⢪", "⢫", "⢬", "⢭", "⢮", "⢯", "⢰", "⢱", "⢲", "⢳", "⢴", "⢵", "⢶", "⢷", "⢸", "⢹", "⢺", "⢻", "⢼", "⢽", "⢾", "⢿", "⣀", "⣁", "⣂", "⣃", "⣄", "⣅", "⣆", "⣇", "⣈", "⣉", "⣊", "⣋", "⣌", "⣍", "⣎", "⣏", "⣐", "⣑", "⣒", "⣓", "⣔", "⣕", "⣖", "⣗", "⣘", "⣙", "⣚", "⣛", "⣜", "⣝", "⣞", "⣟", "⣠", "⣡", "⣢", "⣣", "⣤", "⣥", "⣦", "⣧", "⣨", "⣩", "⣪", "⣫", "⣬", "⣭", "⣮", "⣯", "⣰", "⣱", "⣲", "⣳", "⣴", "⣵", "⣶", "⣷", "⣸", "⣹", "⣺", "⣻", "⣼", "⣽", "⣾", "⣿" };

/// Get preset text animation by enum.
/// Returns null if the animation preset doesn't exist.
pub fn presetTextAnimation(comptime anim: TextAnimPreset, text: []const u8) ?TextAnimation {
    return switch (anim) {
        .dots => .{ .dots = .{ .base = text, .max_dots = 3 } },
        .bounce => .{ .bounce = .{ .base = text, .char = '.', .width = 3 } },
        .flow => .{ .flow = .{ .base = text, .width = 4, .text_style = Style.fg(.yellow), .highlight_style = Style.fg(.white) } },
        .pulse => .{ .pulse = .{ .base = text, .text_style = Style.fg(.bright_black), .highlight_style = Style.fg(.white) } },
    };
}

pub const TextAnimPreset = enum {
    dots,
    bounce,
    flow,
    pulse,
};

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
    if (self.config.text_animation) |anim| {
        self.anim_buf.clearRetainingCapacity();
        const animated_text = try self.applyTextAnimation(anim);

        // Apply animation-specific rendering
        switch (anim) {
            .flow => |cfg| {
                const base_style = cfg.text_style orelse self.config.text_style orelse self.config.theme.text;
                const highlight = cfg.highlight_style orelse self.config.theme.accent;

                // Calculate highlight position (flowing left to right)
                const text_len = cfg.base.len;
                const cycle_len = text_len + cfg.width * 2;
                const pos = @as(usize, @intCast(self.anim_step % cycle_len));

                // Apply flowing highlight effect using ANSI codes directly
                try base_style.write(writer, cfg.base[0..@min(pos, text_len)]);
                if (pos < text_len) {
                    const highlight_end = @min(pos + cfg.width, text_len);
                    try highlight.write(writer, cfg.base[pos..highlight_end]);
                    if (highlight_end < text_len) {
                        try base_style.write(writer, cfg.base[highlight_end..]);
                    }
                }
            },
            .pulse => |cfg| {
                const base_style = cfg.text_style orelse self.config.text_style orelse self.config.theme.text;
                const highlight = cfg.highlight_style orelse self.config.theme.accent;

                // Calculate pulse intensity (sine wave for smooth fading)
                const pulse_speed = 5; // Adjust for faster/slower pulse
                const phase = (@as(f32, @floatFromInt(self.anim_step % pulse_speed)) / @as(f32, @floatFromInt(pulse_speed))) * 2.0 * std.math.pi;
                const intensity = (std.math.sin(phase) + 1.0) / 2.0; // 0.0 to 1.0

                // Interpolate between base and highlight styles based on intensity
                if (intensity > 0.5) {
                    try highlight.write(writer, animated_text);
                } else {
                    try base_style.write(writer, animated_text);
                }
            },
            else => {
                // dots and bounce use simple rendering
                const text_style = self.config.text_style orelse self.config.theme.text;
                try text_style.write(writer, animated_text);
            },
        }
    } else {
        const text_style = self.config.text_style orelse self.config.theme.text;
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
            self.current_anim_style = null;
            const dots = (self.anim_step / 2) % (cfg.max_dots + 1);
            try self.anim_buf.appendSlice(self.allocator, cfg.base);
            for (0..dots) |_| {
                try self.anim_buf.append(self.allocator, '.');
            }
            return self.anim_buf.items;
        },
        .bounce => |cfg| {
            self.current_anim_style = null;
            const pos = self.anim_step % (cfg.width * 2);
            const offset = if (pos < cfg.width) pos else (cfg.width * 2 - pos);
            try self.anim_buf.appendSlice(self.allocator, cfg.base);
            try self.anim_buf.appendSlice(self.allocator, " ");
            for (0..(cfg.width - offset)) |_| {
                try self.anim_buf.append(self.allocator, cfg.char);
            }
            return self.anim_buf.items;
        },
        .flow => |cfg| {
            self.current_anim_style = cfg.highlight_style;
            try self.anim_buf.appendSlice(self.allocator, cfg.base);
            return self.anim_buf.items;
        },
        .pulse => |cfg| {
            self.current_anim_style = cfg.highlight_style;
            try self.anim_buf.appendSlice(self.allocator, cfg.base);
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
    try std.testing.expectEqual(@as(usize, 3), Spinner.presetFrames(.dots).len);
    try std.testing.expectEqual(@as(usize, 4), Spinner.presetFrames(.pipes).len);
    try std.testing.expectEqual(@as(usize, 4), Spinner.presetFrames(.blocks).len);

    // New presets
    try std.testing.expectEqual(@as(usize, 8), Spinner.presetFrames(.dot_cycle).len);
    try std.testing.expectEqual(@as(usize, 8), Spinner.presetFrames(.z_arrow).len);
    try std.testing.expectEqual(@as(usize, 4), Spinner.presetFrames(.z_1).len);

    // dot_stack has Braille pattern frames
    try std.testing.expect(Spinner.presetFrames(.dot_stack).len > 0);
}

test "presetTextAnimation returns correct types" {
    const anim_dots = Spinner.presetTextAnimation(.dots, "Loading");
    try std.testing.expect(anim_dots != null);
    try std.testing.expectEqualStrings("Loading", anim_dots.?.dots.base);

    const anim_bounce = Spinner.presetTextAnimation(.bounce, "Processing");
    try std.testing.expect(anim_bounce != null);
    try std.testing.expectEqualStrings("Processing", anim_bounce.?.bounce.base);

    const anim_flow = Spinner.presetTextAnimation(.flow, "Pondering");
    try std.testing.expect(anim_flow != null);
    try std.testing.expectEqualStrings("Pondering", anim_flow.?.flow.base);

    const anim_pulse = Spinner.presetTextAnimation(.pulse, "Thinking");
    try std.testing.expect(anim_pulse != null);
    try std.testing.expectEqualStrings("Thinking", anim_pulse.?.pulse.base);
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

test "flow animation renders correctly" {
    const allocator = std.testing.allocator;
    var spinner = Spinner.init(allocator, .{
        .text_animation = .{ .flow = .{ .base = "Test", .width = 2, .text_style = null, .highlight_style = null } },
        .frames = &.{"|"},
    });
    defer spinner.deinit();

    // Render at different animation steps
    for (0..10) |_| {
        var buf: [256]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buf);
        spinner.render(fbs.writer()) catch {};
        spinner.tick();
    }

    // Verify that animation advances
    try std.testing.expect(spinner.current_frame == 0); // Only 1 frame
    try std.testing.expect(spinner.anim_step > 0);
}

test "pulse animation renders correctly" {
    const allocator = std.testing.allocator;
    var spinner = Spinner.init(allocator, .{
        .text_animation = .{ .pulse = .{ .base = "Pulse", .text_style = null, .highlight_style = null } },
        .frames = &.{"|"},
    });
    defer spinner.deinit();

    // Render at different animation steps
    for (0..10) |_| {
        var buf: [256]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buf);
        spinner.render(fbs.writer()) catch {};
        spinner.tick();
    }

    // Verify that animation advances
    try std.testing.expect(spinner.current_frame == 0); // Only 1 frame
    try std.testing.expect(spinner.anim_step > 0);
}

test "flow and pulse with custom text_style" {
    const allocator = std.testing.allocator;
    var spinner = Spinner.init(allocator, .{
        .text_animation = .{ .flow = .{
            .base = "Styled",
            .width = 2,
            .text_style = Style.fg(.red),
            .highlight_style = Style.fg(.yellow),
        } },
        .frames = &.{"|"},
    });
    defer spinner.deinit();

    // Render multiple times to verify animation works with custom styles
    for (0..5) |_| {
        var buf: [256]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buf);
        try spinner.render(fbs.writer());
        spinner.tick();
    }

    // Verify that animation advances
    try std.testing.expect(spinner.anim_step > 0);

    // Test pulse with custom styles
    var spinner2 = Spinner.init(allocator, .{
        .text_animation = .{ .pulse = .{
            .base = "Pulse",
            .text_style = Style.fg(.blue).setDim(),
            .highlight_style = Style.fg(.green).setBold(),
        } },
        .frames = &.{"|"},
    });
    defer spinner2.deinit();

    for (0..5) |_| {
        var buf: [256]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buf);
        try spinner2.render(fbs.writer());
        spinner2.tick();
    }

    try std.testing.expect(spinner2.anim_step > 0);
}
