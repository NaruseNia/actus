//! Demonstrates the new text animation effects for Spinner widgets.
//! Run this program to see flow and pulse animations in action.
//!
//! Usage: zig run examples/text_animations.zig

const std = @import("std");
const actus = @import("../src/root.zig");
const Spinner = actus.Spinner;
const App = actus.App;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var app = try App.init();
    defer app.deinit();

    // Demo 1: Flow animation (Claude Code-style "pondering...")
    std.debug.print("\n=== Flow Animation (Claude Code-style) ===\n", .{});
    std.debug.print("Press Ctrl+C to continue to next demo\n", .{});
    {
        var spinner = Spinner.init(allocator, .{
            .text = "Pondering",
            .text_animation = .{ .flow = .{
                .base = "Pondering",
                .width = 3,
                .highlight_style = actus.Style.fg(.yellow),
            }},
            .frames = Spinner.presetFrames(.dot_cycle),
            .spinner_style = actus.Style.fg(.blue),
            .text_style = actus.Style.fg(.white),
        });
        defer spinner.deinit();

        try app.runProgress(&spinner, 50, null);
    }

    // Demo 2: Pulse animation (slow fade in/out)
    std.debug.print("\n=== Pulse Animation (Fade In/Out) ===\n", .{});
    std.debug.print("Press Ctrl+C to continue to next demo\n", .{});
    {
        var spinner = Spinner.init(allocator, .{
            .text = "Processing",
            .text_animation = .{ .pulse = .{
                .base = "Processing",
                .highlight_style = actus.Style.fg(.green).setBold(),
            }},
            .frames = Spinner.presetFrames(.dot_cycle),
            .spinner_style = actus.Style.fg(.cyan),
            .text_style = actus.Style.fg(.white).dim(),
        });
        defer spinner.deinit();

        try app.runProgress(&spinner, 50, null);
    }

    // Demo 3: Flow with custom width and style
    std.debug.print("\n=== Flow Animation (Wide Highlight) ===\n", .{});
    std.debug.print("Press Ctrl+C to exit\n", .{});
    {
        var spinner = Spinner.init(allocator, .{
            .text = "Analyzing data",
            .text_animation = .{ .flow = .{
                .base = "Analyzing data",
                .width = 8,
                .highlight_style = actus.Style.fg(.magenta).setBold(),
            }},
            .frames = Spinner.presetFrames(.dot_cycle),
            .spinner_style = actus.Style.fg(.green),
            .text_style = actus.Style.fg(.cyan),
        });
        defer spinner.deinit();

        try app.runProgress(&spinner, 50, null);
    }

    std.debug.print("\n", .{});
}
