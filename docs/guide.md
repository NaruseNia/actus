# actus User Guide

## Table of Contents

- [Getting Started](#getting-started)
- [Core Concepts](#core-concepts)
- [Widgets](#widgets)
  - [TextInput](#textinput)
  - [ListView](#listview)
  - [FilePicker](#filepicker)
  - [HelpLine](#helpline)
  - [WithHelpLine](#withhelpline)
  - [WithTitle](#withtitle)
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

## Composing Widgets

Wrappers are composable. You can stack `WithTitle` and `WithHelpLine` around any widget:

```zig
const actus = @import("actus");

var lv = actus.ListView.init(allocator, &items, .{ .filterable = true });
defer lv.deinit();

// Step 1: Wrap with help line (auto-populated from ListView.helpBindings)
const WithHL = actus.WithHelpLine(actus.ListView);
var with_help = WithHL.init(&lv, .{});

// Step 2: Wrap with title
var titled = actus.WithTitle(WithHL).init(&with_help, .{
    .title = "Pick one fruit:",
});

// Step 3: Run
var app = try actus.App.init();
defer app.deinit();
try app.run(&titled);

// Step 4: Cleanup (removes all rendered lines)
var buf: [actus.Terminal.render_buf_size]u8 = undefined;
var fbs = std.io.fixedBufferStream(&buf);
try titled.cleanup(fbs.writer(), 1);
try stdout.writeAll(fbs.getWritten());

// Step 5: Read result
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
