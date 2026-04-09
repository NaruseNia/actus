# actus

A cross-platform terminal UI widget library for Zig.

Build interactive CLI applications with composable, reusable widgets. Supports macOS, Linux, and Windows.

## Features

- **Cross-platform** -- Raw terminal control via termios (macOS/Linux) and Console API (Windows), with ANSI escape sequences for rendering
- **Composable widgets** -- Each widget implements a common interface (`handleEvent` / `render` / `needsRender`) driven by an external event loop
- **Generic wrappers** -- `WithTitle` and `WithHelpLine` wrap any widget to add a title or key-binding display
- **Theming** -- Centralized `Theme` struct with `Style` builder for colors and font attributes
- **UTF-8 native** -- Full multibyte Unicode support for international text input

### Widgets

| Widget | Description |
|---|---|
| **TextInput** | Single-line text input with placeholder, password masking, max length, and character filtering |
| **ListView** | Scrollable list with selectable items, optional filtering, item count display |
| **FilePicker** | File/directory browser with navigation, metadata display, filtering, and extension filtering |
| **ProgressBar** | Animated progress bar with customizable styles, ETA calculation, and elapsed time display |
| **Spinner** | Animated loading indicator with 20+ preset frame patterns and text animations |
| **HelpLine** | Read-only key-binding display (typically used via `WithHelpLine`) |
| **WithHelpLine** | Generic wrapper that adds a help line below any widget |
| **WithTitle** | Generic wrapper that adds a styled title line above any widget |
| **Decorated** | Convenience wrapper combining title + help line in one type |

## Requirements

- Zig >= 0.15.2

## Installation

Fetch the package using `zig fetch`:

```sh
zig fetch --save git+https://github.com/NaruseNia/actus.git#refs/tags/v0.1.0
```

This adds `actus` to your `build.zig.zon` automatically.

Then in your `build.zig`:

```zig
const actus = b.dependency("actus", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("actus", actus.module("actus"));
```

## Quick Start

```zig
const std = @import("std");
const actus = @import("actus");

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const items = [_][]const u8{ "Apple", "Banana", "Cherry" };
    var lv = actus.ListView.init(allocator, &items, .{ .filterable = true });
    defer lv.deinit();

    // Decorated adds a title above and a help line below in one wrapper
    var d = actus.Decorated(actus.ListView).init(&lv, .{
        .title = "Pick a fruit:",
    });

    var app = try actus.App.init();
    defer app.deinit();
    try app.run(&d);

    const stdout = std.fs.File.stdout();
    if (lv.selectedItem()) |item| {
        try stdout.writeAll(item);
        try stdout.writeAll("\n");
    }
}
```

See [docs/guide.md](docs/guide.md) for full usage guide and API reference.

## Development

```sh
zig build          # Build the library and example executable
zig build run      # Run the interactive demo selector
zig build test     # Run all unit tests
```

## Architecture

```
src/
  root.zig              -- Library entry point (barrel re-exports)
  event.zig             -- Event / Key type definitions
  Terminal.zig           -- Cross-platform raw mode + ANSI helpers
  input.zig             -- stdin -> Event parser (UTF-8, escape sequences)
  Widget.zig            -- Comptime widget interface + HandleResult + LayoutInfo
  App.zig               -- Reusable event loop
  Style.zig             -- ANSI styling (colors, font attributes)
  Theme.zig             -- Theme configuration (primary, accent, muted, text)
  layout.zig            -- Shared widget layout detection
  unicode.zig           -- Shared UTF-8 helpers
  cursor_tracker.zig    -- Cursor position analysis from ANSI output
  widgets/
    TextInput.zig       -- Single-line text input
    ListView.zig        -- Scrollable selectable list
    FilePicker.zig      -- File/directory browser
    ProgressBar.zig     -- Animated progress bar
    Spinner.zig         -- Animated loading indicator
    HelpLine.zig        -- Key-binding display
    WithHelpLine.zig    -- Generic wrapper: help line below widget
    WithTitle.zig       -- Generic wrapper: title above widget
    Decorated.zig       -- Convenience wrapper: title + help line combined
  main.zig              -- Interactive demo app
```

## Platform Support

| Platform | Terminal Backend | Status |
|---|---|---|
| macOS | termios + ANSI | Supported |
| Linux | termios + ANSI | Supported |
| Windows | Console API + VT | Supported (ANSI via `ENABLE_VIRTUAL_TERMINAL_PROCESSING`) |

## License

MIT
