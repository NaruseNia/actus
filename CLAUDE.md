# CLAUDE.md

## Project Overview

actus is a cross-platform terminal UI widget library for Zig. It provides reusable CLI widgets (TextInput, ListView, FilePicker, etc.) that can be composed to build interactive terminal applications. Targets macOS, Linux, and Windows.

## Build & Test

```sh
zig build          # Build the library and example executable
zig build run      # Run the interactive demo selector
zig build test     # Run all unit tests
```

## Project Structure

```
src/
  root.zig              -- Library entry point; barrel re-exports all public API
  event.zig             -- Event / Key union types shared by all widgets
  Terminal.zig          -- Cross-platform raw mode (termios / Win Console API) + ANSI helpers
  input.zig             -- Stdin byte reader + escape sequence parser -> Event
  Widget.zig            -- Comptime widget interface (assertIsWidget) + HandleResult + LayoutInfo
  App.zig               -- Reusable event loop (read -> dispatch -> render)
  Style.zig             -- ANSI styling system (colors, font attributes, builder pattern)
  Theme.zig             -- Theme configuration (primary, accent, muted, text)
  layout.zig            -- Shared widget layout detection (getWidgetLayout)
  unicode.zig           -- Shared UTF-8 helpers (codepointCount, prevCodepointLen)
  cursor_tracker.zig    -- Cursor position analysis from rendered ANSI output
  widgets/
    TextInput.zig       -- TextInput widget (placeholder, mask, validation)
    ListView.zig        -- ListView widget (scrollable, filterable, multi-item)
    FilePicker.zig      -- FilePicker widget (directory navigation, metadata, extensions)
    HelpLine.zig        -- HelpLine widget (key-binding display, read-only)
    WithHelpLine.zig    -- Generic wrapper: adds HelpLine below any widget
    WithTitle.zig       -- Generic wrapper: adds styled title above any widget
  main.zig              -- Interactive demo selector
```

## Architecture & Conventions

- **Widget interface**: Widgets implement `handleEvent(Event) HandleResult`, `render(writer) !void`, `needsRender() bool`. Checked at comptime via `Widget.assertIsWidget(T)`.
- **Optional widget methods**: `layoutInfo() ?LayoutInfo` (for multi-line layout tracking), `cleanup(writer, extra_lines) !void` (for clearing rendered lines), `helpBindings() []const HelpLine.Binding` (for auto-populating help lines).
- **No vtable**: Uses comptime duck typing (`anytype`) instead of runtime vtable. Simpler and zero-cost.
- **Generic wrappers**: `WithTitle(ChildWidget)` and `WithHelpLine(ChildWidget)` are comptime-generic types that wrap any widget. They render child to an internal buffer, analyze layout, then forward output. Wrappers are composable: `WithTitle(WithHelpLine(ListView))`.
- **Terminal abstraction**: `Terminal.zig` handles platform differences (POSIX termios vs Windows Console API). ANSI helpers use `anytype` writer. `Terminal.render_buf_size` is the shared buffer size constant (4096).
- **Input parsing**: `input.zig` parses raw bytes into `Event` values. On Windows with VT input enabled, escape sequences match POSIX format.
- **Layout detection**: `layout.zig` provides `getWidgetLayout()` which prefers `widget.layoutInfo()` (via `@hasDecl`) over byte-level `CursorTracker` analysis.
- **Style/Theme**: `Style.zig` provides a builder pattern for ANSI colors and font attributes. `Theme.zig` defines four semantic style slots (primary, accent, muted, text). Widgets accept optional style overrides that fall back to theme defaults.
- **Cross-platform goal**: macOS, Linux, Windows. Platform-specific code is isolated in `Terminal.zig` (raw mode) and `input.zig` (byte reading). Widgets and App are platform-agnostic.
- **UTF-8 native**: Text-editing widgets store UTF-8 bytes in `ArrayListUnmanaged(u8)`, track both byte offset and codepoint column. Shared helpers live in `unicode.zig`.

## Zig 0.15 Specifics

- `std.fs.File.stdout()` instead of deprecated `std.io.getStdOut()`
- `ArrayListUnmanaged` uses `.empty` init, allocator passed to each mutating call
- `std.unicode.utf8Encode(codepoint, &buf)` argument order (codepoint first)
- termios flags are packed structs with named bool fields (e.g., `raw.lflag.ECHO = false`)
- `cc` array indexed via `@intFromEnum(std.c.V.MIN)`
- `std.io.fixedBufferStream` for testing writers
- `usingnamespace` is removed; use comptime `if` with function pointer declarations instead

## Workflow Rules

- **Commit per task**: Commit after each logical unit of work (feature, bug fix, etc.). Do not bundle multiple tasks into a single commit.
- **Write tests**: Every new feature or bug fix must include tests. Run `zig build test` and confirm all tests pass before committing.
- **Ask when uncertain**: If the spec or intent is unclear, do not guess. Use `AskUserQuestion` to ask the user for clarification.

## Adding New Widgets

1. Create `src/widgets/YourWidget.zig`
2. Implement `handleEvent`, `render`, `needsRender`
3. Add `comptime { Widget.assertIsWidget(@This()); }` at top
4. Optionally implement `layoutInfo`, `cleanup`, `helpBindings`
5. Re-export from `src/root.zig`
6. Add tests in the same file
