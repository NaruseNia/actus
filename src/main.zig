const std = @import("std");
const actus = @import("actus");

const demos = [_][]const u8{
    "TextInput",
    "TextInput (password)",
    "ListView",
    "ListView (filterable)",
    "FilePicker",
    "Spinner (basic)",
    "Spinner (animated)",
    "ProgressBar (basic)",
    "ProgressBar (with ETA)",
};

pub fn main() !void {
    var gpa_state: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const allocator = gpa_state.allocator();

    const stdout = std.fs.File.stdout();

    // -- Demo selector --
    var selector = actus.ListView.init(allocator, &demos, .{
        .max_visible = 10,
        .show_count = true,
    });
    defer selector.deinit();

    var d = actus.Decorated(actus.ListView).init(&selector, .{
        .title = "Select a demo:",
    });

    {
        var app = try actus.App.init();
        errdefer app.deinit();
        try app.run(&d);
        app.deinit();
    }

    // Clean up selector UI
    var cleanup_buf: [actus.Terminal.render_buf_size]u8 = undefined;
    var cleanup_fbs = std.io.fixedBufferStream(&cleanup_buf);
    try d.cleanup(cleanup_fbs.writer(), 1);
    try stdout.writeAll(cleanup_fbs.getWritten());

    if (selector.isCancelled()) {
        try stdout.writeAll("Cancelled.\n");
        return;
    }

    const selected = selector.selectedIndex() orelse return;

    // -- Run selected demo --
    switch (selected) {
        0 => try runTextInputDemo(allocator, stdout, .{}),
        1 => try runTextInputDemo(allocator, stdout, .{
            .placeholder = "Enter password...",
            .mask_char = '*',
        }),
        2 => try runListViewDemo(allocator, stdout, .{}),
        3 => try runListViewDemo(allocator, stdout, .{
            .filterable = true,
            .filter_placeholder = "Type to filter...",
        }),
        4 => try runFilePickerDemo(allocator, stdout),
        5 => try runSpinnerDemo(allocator, stdout),
        6 => try runSpinnerAnimatedDemo(allocator, stdout),
        7 => try runProgressBarDemo(allocator, stdout),
        8 => try runProgressBarETADemo(allocator, stdout),
        else => {},
    }
}

fn runTextInputDemo(allocator: std.mem.Allocator, stdout: std.fs.File, config: actus.TextInput.Config) !void {
    var ti = actus.TextInput.init(allocator, config);
    defer ti.deinit();

    var app = try actus.App.init();
    errdefer app.deinit();
    try app.run(&ti);
    app.deinit();

    try stdout.writeAll("\r\n");
    if (ti.isConfirmed()) {
        try stdout.writeAll("Input: ");
        try stdout.writeAll(ti.value());
        try stdout.writeAll("\n");
    } else {
        try stdout.writeAll("Cancelled.\n");
    }
}

fn runListViewDemo(allocator: std.mem.Allocator, stdout: std.fs.File, config: actus.ListView.Config) !void {
    const items = [_][]const u8{
        "Apple",
        "Banana",
        "Cherry",
        "Durian",
        "Elderberry",
        "Fig",
        "Grape",
    };

    var lv = actus.ListView.init(allocator, &items, config);
    defer lv.deinit();

    var d = actus.Decorated(actus.ListView).init(&lv, .{
        .title = "Pick one fruit:",
    });

    var app = try actus.App.init();
    errdefer app.deinit();
    try app.run(&d);
    app.deinit();

    var cleanup_buf: [actus.Terminal.render_buf_size]u8 = undefined;
    var cleanup_fbs = std.io.fixedBufferStream(&cleanup_buf);
    try d.cleanup(cleanup_fbs.writer(), 1);
    try stdout.writeAll(cleanup_fbs.getWritten());

    if (lv.isCancelled()) {
        try stdout.writeAll("Cancelled.\n");
    } else if (lv.selectedItem()) |item| {
        try stdout.writeAll("You selected: ");
        try stdout.writeAll(item);
        try stdout.writeAll("\n");
    }
}

fn runFilePickerDemo(allocator: std.mem.Allocator, stdout: std.fs.File) !void {
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

    var d = actus.Decorated(actus.FilePicker).init(&file_picker, .{
        .title = "Select a file:",
    });

    var app = try actus.App.init();
    errdefer app.deinit();
    try app.run(&d);
    app.deinit();

    var cleanup_buf: [actus.Terminal.render_buf_size]u8 = undefined;
    var cleanup_fbs = std.io.fixedBufferStream(&cleanup_buf);
    try d.cleanup(cleanup_fbs.writer(), 1);
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

fn runSpinnerDemo(allocator: std.mem.Allocator, stdout: std.fs.File) !void {
    var spinner = actus.Spinner.init(allocator, .{
        .text = "Loading...",
        .frames = actus.Spinner.presetFrames("pipes"),
    });
    defer spinner.deinit();

    var app = try actus.App.init();
    errdefer app.deinit();
    // Run for ~2 seconds (20 iterations * 100ms)
    try app.runProgress(&spinner, 100, 20);
    app.deinit();

    try stdout.writeAll("Done!\n");
}

fn runSpinnerAnimatedDemo(allocator: std.mem.Allocator, stdout: std.fs.File) !void {
    var spinner = actus.Spinner.init(allocator, .{
        .text = "Processing",
        .frames = actus.Spinner.presetFrames("dots"),
        .text_animation = actus.Spinner.presetTextAnimation("dots", "Processing"),
        .spinner_style = actus.Style.fg(.green),
    });
    defer spinner.deinit();

    var app = try actus.App.init();
    errdefer app.deinit();
    // Run for ~3 seconds (30 iterations * 100ms)
    try app.runProgress(&spinner, 100, 30);
    app.deinit();

    try stdout.writeAll("Complete!\n");
}

fn runProgressBarDemo(allocator: std.mem.Allocator, stdout: std.fs.File) !void {
    var progress = actus.ProgressBar.init(allocator, .{
        .total = 100,
        .width = 40,
        .bar_style = .blocks,
        .format = "{p}%",
    });
    defer progress.deinit();

    var app = try actus.App.init();
    errdefer app.deinit();

    // Simulate progress: 1 iteration per update
    for (0..101) |i| {
        progress.update(i);
        try app.runProgress(&progress, 50, 1); // 50ms per frame, 1 iteration
    }
    app.deinit();

    try stdout.writeAll("\n");
}

fn runProgressBarETADemo(allocator: std.mem.Allocator, stdout: std.fs.File) !void {
    var progress = actus.ProgressBar.init(allocator, .{
        .total = 100,
        .width = 40,
        .bar_style = .heavy,
        .format = "{p}% ({c}/{t})",
        .show_elapsed = true,
        .show_eta = true,
    });
    defer progress.deinit();

    var app = try actus.App.init();
    errdefer app.deinit();

    // Simulate progress with delay to show ETA
    for (0..101) |i| {
        progress.update(i);
        try app.runProgress(&progress, 100, 1); // 100ms per frame, 1 iteration
    }
    app.deinit();

    try stdout.writeAll("\n");
}
