# actus

A cross-platform terminal UI widget library for Zig.

Build interactive CLI applications with composable, reusable widgets. Supports macOS, Linux, and Windows.

## Features

- **Cross-platform** -- Raw terminal control via termios (macOS/Linux) and Console API (Windows), with ANSI escape sequences for rendering
- **Composable widgets** -- Each widget implements a common interface (`handleEvent` / `render` / `needsRender`) driven by an external event loop
- **UTF-8 native** -- Full multibyte Unicode support for international text input

### Widgets

| Widget | Status | Description |
|---|---|---|
| **TextInput** | Available | Single-line text input with placeholder, password masking, max length, and character filtering |
| **ListView** | Planned | Scrollable list with selectable items |
| **Progress** | Planned | Progress bar / spinner |

## Requirements

- Zig >= 0.15.2

## Installation

Add `actus` as a dependency in your `build.zig.zon`:

```zig
.dependencies = .{
    .actus = .{
        .url = "https://github.com/NaruseNia/actus/archive/<commit-hash>.tar.gz",
        .hash = "...",
    },
},
```

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

    const stdout = std.fs.File.stdout();
    try stdout.writeAll("You entered: ");
    try stdout.writeAll(text_input.value());
    try stdout.writeAll("\n");
}
```

### TextInput Options

```zig
actus.TextInput.init(allocator, .{
    .placeholder = "Enter password...",  // shown when empty
    .mask_char = '*',                    // password masking
    .max_length = 128,                   // codepoint limit
    .allowed_chars = "0123456789",       // ASCII character filter
});
```

### Keybindings

| Key | Action |
|---|---|
| Printable characters | Insert at cursor |
| Left / Right | Move cursor |
| Home / Ctrl-A | Move to start |
| End / Ctrl-E | Move to end |
| Backspace | Delete before cursor |
| Delete | Delete after cursor |
| Enter | Confirm input |
| Ctrl-C | Exit |

## Development

```sh
zig build          # Build the library and example executable
zig build run      # Run the TextInput demo
zig build test     # Run all unit tests
```

## Architecture

```
src/
  root.zig                -- Library entry point (barrel re-exports)
  event.zig               -- Event / Key type definitions
  Terminal.zig             -- Cross-platform raw mode + ANSI helpers
  input.zig               -- stdin -> Event parser (UTF-8, escape sequences)
  Widget.zig              -- Comptime widget interface + HandleResult
  App.zig                 -- Reusable event loop
  widgets/
    TextInput.zig          -- TextInput widget
  main.zig                -- Example app
```

## Platform Support

| Platform | Terminal Backend | Status |
|---|---|---|
| macOS | termios + ANSI | Supported |
| Linux | termios + ANSI | Supported |
| Windows | Console API + VT | Supported (ANSI via `ENABLE_VIRTUAL_TERMINAL_PROCESSING`) |

## License

MIT
