# CLAUDE.md

## Project Overview

actus is a cross-platform terminal UI widget library for Zig. It provides reusable CLI widgets (TextInput, ListView, Progress, etc.) that can be composed to build interactive terminal applications. Targets macOS, Linux, and Windows.

## Build & Test

```sh
zig build          # Build the library and example executable
zig build run      # Run the TextInput demo
zig build test     # Run all unit tests
```

## Project Structure

```
src/
  root.zig              -- Library entry point; barrel re-exports all public API
  event.zig             -- Event / Key union types shared by all widgets
  Terminal.zig          -- Cross-platform raw mode (termios / Win Console API) + ANSI helpers
  input.zig             -- Stdin byte reader + escape sequence parser -> Event
  Widget.zig            -- Comptime widget interface (assertIsWidget) + HandleResult enum
  App.zig               -- Reusable event loop (read -> dispatch -> render)
  widgets/
    TextInput.zig       -- TextInput widget (placeholder, mask, validation)
  main.zig              -- Example executable
```

## Architecture & Conventions

- **Widget interface**: Widgets implement `handleEvent(Event) HandleResult`, `render(writer) !void`, `needsRender() bool`. Checked at comptime via `Widget.assertIsWidget(T)`.
- **No vtable**: Uses comptime duck typing (`anytype`) instead of runtime vtable. Simpler and zero-cost. Vtable can be added later if heterogeneous widget collections are needed.
- **Terminal abstraction**: `Terminal.zig` handles platform differences (POSIX termios vs Windows Console API). ANSI helpers use `anytype` writer so they work with any writer type.
- **Input parsing**: `input.zig` parses raw bytes into `Event` values. On Windows with VT input enabled, escape sequences match POSIX format.
- **Cross-platform goal**: macOS, Linux, Windows. Platform-specific code is isolated in `Terminal.zig` (raw mode) and `input.zig` (byte reading). Widgets and App are platform-agnostic.
- **UTF-8 native**: TextInput stores UTF-8 bytes in `ArrayListUnmanaged(u8)`, tracks both byte offset and codepoint column for cursor.

## Zig 0.15 Specifics

- `std.fs.File.stdout()` instead of deprecated `std.io.getStdOut()`
- `ArrayListUnmanaged` uses `.empty` init, allocator passed to each mutating call
- `std.unicode.utf8Encode(codepoint, &buf)` argument order (codepoint first)
- termios flags are packed structs with named bool fields (e.g., `raw.lflag.ECHO = false`)
- `cc` array indexed via `@intFromEnum(std.c.V.MIN)`
- `std.io.fixedBufferStream` for testing writers

## Workflow Rules

- **Commit per task**: Commit after each logical unit of work (feature, bug fix, etc.). Do not bundle multiple tasks into a single commit.
- **Write tests**: Every new feature or bug fix must include tests. Run `zig build test` and confirm all tests pass before committing.
- **Ask when uncertain**: If the spec or intent is unclear, do not guess. Use `AskUserQuestion` to ask the user for clarification.

## Adding New Widgets

1. Create `src/widgets/YourWidget.zig`
2. Implement `handleEvent`, `render`, `needsRender`
3. Add `comptime { Widget.assertIsWidget(@This()); }` at top
4. Re-export from `src/root.zig`
5. Add tests in the same file
