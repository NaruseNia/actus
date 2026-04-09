# actus User Guide

## Table of Contents

- [Getting Started](#getting-started)
- [Core Concepts](#core-concepts)
- [Widgets](#widgets)
  - [TextInput](#textinput)
  - [ListView](#listview)
  - [FilePicker](#filepicker)
  - [ProgressBar](#progressbar)
  - [HelpLine](#helpline)
  - [WithHelpLine](#withhelpline)
  - [WithTitle](#withtitle)
  - [Decorated](#decorated)
- [Composing Widgets](#composing-widgets)
- [Styling and Themes](#styling-and-themes)
- [Creating Custom Widgets](#creating-custom-widgets)
- [API Reference](#api-reference)

---

## Getting Started

### Installation

Add `actus` to your `build.zig.zon`:

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
const actus_dep = b.dependency("actus", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("actus", actus_dep.module("actus"));
```

### Minimal Example

```zig
const std = @import("std");
const actus = @import("actus");

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var ti = actus.TextInput.init(allocator, .{
        .placeholder = "Type something...",
    });
    defer ti.deinit();

    var app = try actus.App.init();
    defer app.deinit();
    try app.run(&ti);

    const stdout = std.fs.File.stdout();
    if (ti.isConfirmed()) {
        try stdout.writeAll(ti.value());
        try stdout.writeAll("\n");
    }
}
```

---

## Core Concepts

### Widget Interface

Every widget implements three methods:

```zig
fn handleEvent(self: *Self, ev: Event) Widget.HandleResult
fn render(self: *Self, writer: anytype) !void
fn needsRender(self: *const Self) bool
```

`HandleResult` controls event flow:

| Value | Meaning |
|---|---|
| `.consumed` | Widget handled the event |
| `.ignored` | Widget did not handle the event |
| `.done` | Event loop should exit |

### Event Loop

`App` provides the event loop. Call `App.init()` to enter raw mode, `App.run(&widget)` to start, and `App.deinit()` to restore the terminal.

```zig
var app = try actus.App.init();
defer app.deinit();
try app.run(&my_widget);
```

### Optional Widget Methods

Widgets may also implement:

| Method | Purpose |
|---|---|
| `layoutInfo() ?Widget.LayoutInfo` | Reports total lines and cursor position for layout-aware wrappers |
| `cleanup(writer, extra_lines) !void` | Clears rendered lines from the terminal after the event loop |
| `helpBindings() []const HelpLine.Binding` | Provides key-action pairs for auto-populating `WithHelpLine` |

---

## Widgets

### TextInput

Single-line text input with UTF-8 support.

```zig
var ti = actus.TextInput.init(allocator, .{
    .placeholder = "Enter your name...",
    .mask_char = '*',           // password mode
    .max_length = 100,          // codepoint limit
    .allowed_chars = "0-9",     // ASCII character filter
    .placeholder_style = actus.Style.fg(.yellow),
    .theme = actus.Theme.default,
});
defer ti.deinit();
```

**Keybindings:**

| Key | Action |
|---|---|
| Printable characters | Insert at cursor |
| Left / Right | Move cursor |
| Home / Ctrl-A | Move to start |
| End / Ctrl-E | Move to end |
| Backspace | Delete before cursor |
| Delete | Delete after cursor |
| Enter | Confirm input (`.done`) |
| Ctrl-C | Exit |

**Reading results:**

```zig
if (ti.isConfirmed()) {
    const text = ti.value(); // []const u8
}
```

---

### ListView

Scrollable list with selectable items.

```zig
const items = [_][]const u8{ "Apple", "Banana", "Cherry" };

var lv = actus.ListView.init(allocator, &items, .{
    .max_visible = 5,          // scrollable window size
    .filterable = true,        // enable incremental search
    .show_count = true,        // show "1/3" at the bottom
    .filter_placeholder = "Type to filter...",
    .cursor = "> ",            // selected item prefix
    .indent = "  ",            // non-selected item prefix
});
defer lv.deinit();
```

**Keybindings:**

| Key | Action |
|---|---|
| Up / k | Move up |
| Down / j | Move down |
| Home / g | Jump to top |
| End / G | Jump to bottom |
| Enter | Confirm selection (`.done`) |
| Escape | Cancel (`.done`) |
| Printable (filterable) | Filter items |
| Backspace (filterable) | Delete filter character |
| Ctrl-C | Exit |

**Reading results:**

```zig
if (lv.isCancelled()) {
    // user pressed Escape
} else if (lv.selectedItem()) |item| {
    // item: []const u8
}
// Also available:
// lv.selectedIndex() -> ?usize (index into original items)
// lv.filterValue() -> []const u8
```

**Cleanup** (removes rendered lines from terminal):

```zig
var buf: [actus.Terminal.render_buf_size]u8 = undefined;
var fbs = std.io.fixedBufferStream(&buf);
try lv.cleanup(fbs.writer(), 1); // 1 = extra lines from App.run's final "\r\n"
try stdout.writeAll(fbs.getWritten());
```

---

### FilePicker

File and directory browser with navigation.

```zig
var fp = actus.FilePicker.init(allocator, ".", .{
    .max_visible = 15,
    .filterable = true,
    .show_count = true,
    .show_path = true,          // show current directory path
    .show_size = true,          // show file sizes
    .show_permissions = true,   // show rwx permissions
    .absolute_path = true,      // selectedPath returns absolute path
    .allowed_extensions = &.{ ".zig", ".md" }, // filter by extension
    .filter_placeholder = "Type to filter...",
});
defer fp.deinit();
```

**Keybindings:**

| Key | Action |
|---|---|
| Up / k | Move up |
| Down / j | Move down |
| Home / g | Jump to top |
| End / G | Jump to bottom |
| Enter (on directory) | Navigate into directory |
| Enter (on file) | Select file (`.done`) |
| Enter (on `..`) | Navigate to parent |
| Escape | Cancel (`.done`) |
| Ctrl-C | Exit |

**Reading results:**

```zig
if (fp.isCancelled()) {
    // user cancelled
} else if (fp.selectedPath()) |path| {
    defer allocator.free(path); // caller owns the memory
    // use path
}
// Also available:
// fp.selectedEntry() -> ?FilePicker.Entry
// fp.currentPath() -> []const u8
```

---

### ProgressBar

Animated progress bar with customizable visual styles and time estimation.

```zig
var pb = actus.ProgressBar.init(allocator, .{
    .total = 100,              // total value for 100% completion
    .current = 0,              // initial progress
    .width = 40,               // bar width in characters
    .bar_style = .blocks,      // visual style
    .format = "{p}%",          // display format
    .show_elapsed = true,      // show elapsed time
    .show_eta = true,          // show estimated time remaining
    .theme = actus.Theme.default,
});
defer pb.deinit();

// Update progress during a loop
for (0..100) |i| {
    pb.update(i);

    const stdout = std.fs.File.stdout();
    var buf: [actus.Terminal.render_buf_size]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try pb.render(fbs.writer());
    try stdout.writeAll(fbs.getWritten());

    std.time.sleep(10_000_000); // 0.01 seconds
}
```

**Config options:**

| Field | Type | Default | Description |
|---|---|---|---|
| `total` | `u64` | `100` | Total value for completion (100%) |
| `current` | `u64` | `0` | Initial progress value (0..total) |
| `width` | `usize` | `40` | Width of the bar in characters |
| `bar_style` | `BarStyle` | `.blocks` | Visual style (see below) |
| `custom_chars` | `?BarChars` | `null` | Custom bar characters |
| `format` | `[]const u8` | `"{p}%"` | Format string for value display |
| `show_elapsed` | `bool` | `false` | Show elapsed time |
| `show_eta` | `bool` | `false` | Show estimated time remaining |
| `bar_style_override` | `?Style` | `null` | Override bar style (overrides `theme.primary`) |
| `bg_style` | `?Style` | `null` | Override background style (overrides `theme.muted`) |
| `theme` | `Theme` | `Theme.default` | Fallback theme |

**BarStyle options:**

| Style | Appearance | Description |
|---|---|---|
| `.plain` | `===>----` | Simple ASCII arrow style |
| `.blocks` | `████▒▒▒` | Unicode block characters (default) |
| `.heavy` | `█████▒▒` | Dark shading blocks |
| `.double` | `║║║║░░` | Double vertical bars |
| `.ascii` | `>>>>....` | Plain ASCII characters |

**Format placeholders:**

| Placeholder | Meaning | Example |
|---|---|---|
| `{p}` | Percentage (0.0-100.0) | `50.0%` |
| `{c}` | Current value | `50` |
| `{t}` | Total value | `100` |

Example: `"{p}% ({c}/{t})"` renders as `"50.0% (50/100)"`

**Methods:**

```zig
// Update progress to a specific value
pb.update(42);

// Increment progress by a delta
pb.increment(5);

// Get completion as fraction (0.0-1.0)
const frac = pb.fraction(); // e.g., 0.42 for 42%
```

**Keybindings:**

`ProgressBar` ignores all keyboard events (returns `.ignored` from `handleEvent`). It is designed for use in manual event loops or with `App.runProgress()` if available.

**Example output:**

```
████████████████████▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒ 50.0% (0:25, 0:25)
```

---

### HelpLine

Read-only widget that displays key-action bindings. Usually used indirectly via `WithHelpLine`.

```zig
var hl = actus.HelpLine.init(.{
    .bindings = &.{
        .{ .key = "Enter", .action = "Select" },
        .{ .key = "Esc", .action = "Cancel" },
    },
    .separator = "   ",
});
```

`HelpLine` always returns `.ignored` from `handleEvent` -- it is purely a display widget.

---

### WithHelpLine

Generic wrapper that adds a help line **below** any widget.

```zig
var lv = actus.ListView.init(allocator, &items, .{});
defer lv.deinit();

// Auto-populates from lv.helpBindings() if available
var wrapped = actus.WithHelpLine(actus.ListView).init(&lv, .{});
```

If the child widget implements `helpBindings()`, bindings are synced automatically on every render. You can also provide explicit bindings:

```zig
var wrapped = actus.WithHelpLine(actus.ListView).init(&lv, .{
    .bindings = &.{
        .{ .key = "q", .action = "Quit" },
    },
});
```

**Config options:**

| Field | Type | Default | Description |
|---|---|---|---|
| `bindings` | `?[]const Binding` | `null` | Explicit bindings (overrides child's) |
| `separator` | `[]const u8` | `"   "` | Separator between bindings |
| `key_style` | `?Style` | `null` | Style for key labels |
| `action_style` | `?Style` | `null` | Style for action labels |
| `separator_style` | `?Style` | `null` | Style for separators |
| `theme` | `Theme` | `Theme.default` | Fallback theme |

---

### WithTitle

Generic wrapper that adds a styled title line **above** any widget.

```zig
var lv = actus.ListView.init(allocator, &items, .{});
defer lv.deinit();

var titled = actus.WithTitle(actus.ListView).init(&lv, .{
    .title = "Pick one fruit:",
});
```

**Config options:**

| Field | Type | Default | Description |
|---|---|---|---|
| `title` | `[]const u8` | `""` | Title text |
| `title_style` | `?Style` | `null` | Style for title (defaults to `theme.primary`) |
| `theme` | `Theme` | `Theme.default` | Fallback theme |

The title is rendered once and stays fixed. Child widget output is forwarded via an internal buffer (same pattern as `WithHelpLine`).

---

### Decorated

Convenience wrapper that combines a title above and a help line below in a single type. This is the recommended way to add title and help line to a widget.

```zig
var lv = actus.ListView.init(allocator, &items, .{});
defer lv.deinit();

var d = actus.Decorated(actus.ListView).init(&lv, .{
    .title = "Pick one fruit:",
});
```

This is equivalent to manually chaining `WithHelpLine` and `WithTitle`, but without intermediate variables.

**Config options:**

| Field | Type | Default | Description |
|---|---|---|---|
| `title` | `?[]const u8` | `null` | Title text (`null` = no title) |
| `title_style` | `?Style` | `null` | Style for title (defaults to `theme.primary`) |
| `show_help` | `bool` | `true` | Show/hide the help line |
| `help_bindings` | `?[]const Binding` | `null` | Explicit bindings (overrides child's) |
| `help_separator` | `[]const u8` | `"   "` | Separator between bindings |
| `help_key_style` | `?Style` | `null` | Style for key labels |
| `help_action_style` | `?Style` | `null` | Style for action labels |
| `help_separator_style` | `?Style` | `null` | Style for separators |
| `theme` | `Theme` | `Theme.default` | Fallback theme |

---

## Composing Widgets

### Using Decorated (recommended)

`Decorated` is the simplest way to add a title and help line:

```zig
var lv = actus.ListView.init(allocator, &items, .{ .filterable = true });
defer lv.deinit();

var d = actus.Decorated(actus.ListView).init(&lv, .{
    .title = "Pick one fruit:",
});

var app = try actus.App.init();
defer app.deinit();
try app.run(&d);

// Cleanup
var buf: [actus.Terminal.render_buf_size]u8 = undefined;
var fbs = std.io.fixedBufferStream(&buf);
try d.cleanup(fbs.writer(), 1);
try stdout.writeAll(fbs.getWritten());

// Read result
if (lv.selectedItem()) |item| {
    // ...
}
```

The result looks like:

```
Pick one fruit:
/ Type to filter...
> Apple
  Banana
  Cherry
  1/3
↑↓ Navigate   Esc Clear   Enter Select
```

### Using WithTitle + WithHelpLine separately

For more control, you can chain `WithHelpLine` and `WithTitle` individually:

```zig
const WithHL = actus.WithHelpLine(actus.ListView);
var with_help = WithHL.init(&lv, .{});
var titled = actus.WithTitle(WithHL).init(&with_help, .{
    .title = "Pick one fruit:",
});
try app.run(&titled);
```

---

## Styling and Themes

### Style

`Style` provides a builder pattern for ANSI colors and font attributes.

```zig
const actus = @import("actus");
const Style = actus.Style;

// Constructors
const s1 = Style.fg(.red);                        // foreground color
const s2 = Style.bg(.blue);                        // background color
const s3 = Style.bold();                           // bold text
const s4 = Style.fg(.cyan).setBold().setItalic();  // chained

// 256-color and RGB
const s5 = Style.fg256(208);                       // 256-color orange
const s6 = Style.fgRgb(255, 128, 0);              // RGB orange

// Writing styled text
try style.write(writer, "hello");
try style.print(writer, "count: {d}", .{42});

// Manual control
try style.writeStart(writer);   // emit opening escape
try writer.writeAll("text");
try style.writeEnd(writer);     // emit reset
```

### Theme

`Theme` defines four semantic style slots used by all widgets:

```zig
const Theme = actus.Theme;

// Default theme
const t = Theme.default;
// t.primary = cyan + bold (selected items, active elements)
// t.accent  = cyan        (key labels, highlights)
// t.muted   = bright_black (placeholders, counts)
// t.text    = unstyled     (normal body text)

// Custom theme
const custom = Theme{
    .primary = Style.fg(.green).setBold(),
    .accent = Style.fg(.yellow),
    .muted = Style.fg(.white).setDim(),
    .text = Style.fg(.white),
};

// Pass to any widget
var ti = actus.TextInput.init(allocator, .{
    .theme = custom,
});
```

Widgets accept optional style overrides for specific elements (e.g., `selected_style`, `count_style`). When `null`, the corresponding theme slot is used.

---

## Creating Custom Widgets

### Basic Structure

```zig
const std = @import("std");
const Event = @import("actus").Event;
const Widget = @import("actus").Widget;

const MyWidget = @This();

comptime {
    Widget.assertIsWidget(MyWidget); // compile-time validation
}

// State
dirty: bool = true,

pub fn handleEvent(self: *MyWidget, ev: Event) Widget.HandleResult {
    switch (ev) {
        .key => |key| switch (key) {
            .enter => return .done,
            else => {},
        },
    }
    return .ignored;
}

pub fn render(self: *MyWidget, writer: anytype) !void {
    try writer.writeAll("Hello from MyWidget!");
    self.dirty = false;
}

pub fn needsRender(self: *const MyWidget) bool {
    return self.dirty;
}
```

### Optional Methods

Add these for richer integration:

```zig
// For WithHelpLine auto-population
pub fn helpBindings(_: *const MyWidget) []const HelpLine.Binding {
    return &.{
        .{ .key = "Enter", .action = "Confirm" },
        .{ .key = "Esc", .action = "Cancel" },
    };
}

// For multi-line widgets (enables correct WithHelpLine/WithTitle positioning)
pub fn layoutInfo(self: *const MyWidget) ?Widget.LayoutInfo {
    return .{
        .total_lines = self.line_count,
        .cursor_line = self.cursor_pos,
    };
}

// For cleaning up after App.run
pub fn cleanup(self: *MyWidget, writer: anytype, extra_lines: u16) !void {
    const up = self.cursor_pos + extra_lines;
    if (up > 0) try Terminal.moveCursorUp(writer, @intCast(up));
    try Terminal.clearLine(writer);
    try Terminal.clearFromCursor(writer);
}
```

---

## API Reference

### Event Types

```zig
const Key = union(enum) {
    char: u21,          // Unicode codepoint
    ctrl: u8,           // Ctrl+letter (e.g., 'c' for Ctrl-C)
    enter,
    backspace,
    delete,
    left, right, up, down,
    home, end,
    tab,
    escape,
};

const Event = union(enum) {
    key: Key,
};
```

### Widget.HandleResult

```zig
const HandleResult = enum { consumed, ignored, done };
```

### Widget.LayoutInfo

```zig
const LayoutInfo = struct {
    total_lines: usize,  // total lines the widget occupies
    cursor_line: usize,  // row the cursor is on (0-indexed)
};
```

### App

```zig
fn init() !App                     // enter raw mode
fn deinit(self: *App) void         // restore terminal
fn run(self: *App, widget: anytype) !void  // single-widget event loop
fn runWithHelpLine(self: *App, widget: anytype, help_line: anytype) !void
```

### Terminal

```zig
const render_buf_size: usize = 4096;  // shared buffer size constant

fn hideCursor(writer: anytype) !void
fn showCursor(writer: anytype) !void
fn clearLine(writer: anytype) !void
fn clearFromCursor(writer: anytype) !void
fn moveCursorUp(writer: anytype, n: u16) !void
fn moveCursorDown(writer: anytype, n: u16) !void
fn moveCursorTo(writer: anytype, col: u16) !void
```
