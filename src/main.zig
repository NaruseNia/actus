const std = @import("std");
const actus = @import("actus");

pub fn main() !void {
    var gpa_state: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const allocator = gpa_state.allocator();

    const items = [_][]const u8{
        "Apple",
        "Banana",
        "Cherry",
        "Durian",
        "Elderberry",
        "Fig",
        "Grape",
    };

    var list_view = actus.ListView.init(allocator, &items, .{
        .max_visible = 5,
        .filterable = true,
        .show_count = true,
        .filter_placeholder = "Type to filter...",
    });
    defer list_view.deinit();

    var help_line = actus.HelpLine.init(.{
        .bindings = &.{
            .{ .key = "↑↓", .action = "Navigate" },
            .{ .key = "/", .action = "Filter" },
            .{ .key = "Enter", .action = "Select" },
            .{ .key = "Esc", .action = "Quit" },
        },
    });

    var app = try actus.App.init();
    errdefer app.deinit();

    try app.runWithHelpLine(&list_view, &help_line);

    // Disable raw mode before printing so \n is interpreted normally by the terminal.
    app.deinit();

    const stdout = std.fs.File.stdout();

    // Clean up the list UI before printing results.
    // extra_lines=2 accounts for the "\r\n" from App.run() + the help line.
    var cleanup_buf: [4096]u8 = undefined;
    var cleanup_fbs = std.io.fixedBufferStream(&cleanup_buf);
    try list_view.cleanup(cleanup_fbs.writer(), 2);
    try stdout.writeAll(cleanup_fbs.getWritten());
    if (list_view.isCancelled()) {
        try stdout.writeAll("Cancelled.\n");
    } else if (list_view.selectedItem()) |item| {
        try stdout.writeAll("You selected: ");
        try stdout.writeAll(item);
        try stdout.writeAll("\n");
    }
}
