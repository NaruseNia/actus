const std = @import("std");
const actus = @import("actus");

pub fn main() !void {
    runFilePickerDemo() catch |err| {
        std.debug.print("Error: {}\n", .{err});
        return err;
    };
}

fn runListViewDemo() !void {
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

    var wrapped = actus.WithHelpLine(actus.ListView).init(&list_view, .{});

    var app = try actus.App.init();
    errdefer app.deinit();

    try app.run(&wrapped);
    app.deinit();

    const stdout = std.fs.File.stdout();

    var cleanup_buf: [4096]u8 = undefined;
    var cleanup_fbs = std.io.fixedBufferStream(&cleanup_buf);
    try wrapped.cleanup(cleanup_fbs.writer(), 1);
    try stdout.writeAll(cleanup_fbs.getWritten());
    if (list_view.isCancelled()) {
        try stdout.writeAll("Cancelled.\n");
    } else if (list_view.selectedItem()) |item| {
        try stdout.writeAll("You selected: ");
        try stdout.writeAll(item);
        try stdout.writeAll("\n");
    }
}

fn runFilePickerDemo() !void {
    var gpa_state: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const allocator = gpa_state.allocator();

    var file_picker = actus.FilePicker.init(allocator, ".", .{
        .max_visible = 15,
        .filterable = true,
        .show_count = true,
        .show_path = true,
        .show_size = true,
        .show_permissions = true,
        .absolute_path = true,
        .filter_placeholder = "Type to filter...",
    });
    defer file_picker.deinit();

    var wrapped = actus.WithHelpLine(actus.FilePicker).init(&file_picker, .{});

    var app = try actus.App.init();
    errdefer app.deinit();

    try app.run(&wrapped);
    app.deinit();

    const stdout = std.fs.File.stdout();

    var cleanup_buf: [4096]u8 = undefined;
    var cleanup_fbs = std.io.fixedBufferStream(&cleanup_buf);
    try wrapped.cleanup(cleanup_fbs.writer(), 1);
    try stdout.writeAll(cleanup_fbs.getWritten());

    if (file_picker.isCancelled()) {
        try stdout.writeAll("Cancelled.\n");
    } else if (file_picker.selectedPath()) |path| {
        defer allocator.free(path);
        try stdout.writeAll("Selected: ");
        try stdout.writeAll(path);
        try stdout.writeAll("\n");
    }
}
