const std = @import("std");
const actus = @import("actus");

pub fn main() !void {
    var gpa_state: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const allocator = gpa_state.allocator();

    var text_input = actus.TextInput.init(allocator, .{
        .placeholder = "Type your name...",
        .max_length = 50,
    });
    defer text_input.deinit();

    var app = try actus.App.init();
    defer app.deinit();

    try app.run(&text_input);

    // Print the result after the loop ends
    const stdout = std.fs.File.stdout();
    try stdout.writeAll("You entered: ");
    try stdout.writeAll(text_input.value());
    try stdout.writeAll("\n");
}
