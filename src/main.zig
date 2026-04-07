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

    var app = try actus.App.init();
    defer app.deinit();

    try app.run(&list_view);

    const stdout = std.fs.File.stdout();

    // Clean up the list UI before printing results
    var cleanup_buf: [4096]u8 = undefined;
    var cleanup_fbs = std.io.fixedBufferStream(&cleanup_buf);
    try list_view.cleanup(cleanup_fbs.writer());
    try stdout.writeAll(cleanup_fbs.getWritten());
    if (list_view.isCancelled()) {
        try stdout.writeAll("Cancelled.\n");
    } else if (list_view.selectedItem()) |item| {
        try stdout.writeAll("You selected: ");
        try stdout.writeAll(item);
        try stdout.writeAll("\n");
    }
}
