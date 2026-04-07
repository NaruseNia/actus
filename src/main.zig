const std = @import("std");
const actus = @import("actus");

pub fn main() !void {
    const items = [_][]const u8{
        "Apple",
        "Banana",
        "Cherry",
        "Durian",
        "Elderberry",
        "Fig",
        "Grape",
    };

    var list_view = actus.ListView.init(&items, .{
        .max_visible = 5,
    });

    var app = try actus.App.init();
    defer app.deinit();

    try app.run(&list_view);

    const stdout = std.fs.File.stdout();
    if (list_view.isCancelled()) {
        try stdout.writeAll("Cancelled.\n");
    } else if (list_view.selectedItem()) |item| {
        try stdout.writeAll("You selected: ");
        try stdout.writeAll(item);
        try stdout.writeAll("\n");
    }
}
