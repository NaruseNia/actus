# CLAUDE.md

## Project Overview

actus is a terminal UI widget library for Zig. It provides reusable CLI widgets (ListView, TextInput, Progress, etc.) that can be composed to build interactive terminal applications.

## Build & Test

```sh
zig build          # Build the library and example executable
zig build run      # Run the example app
zig build test     # Run all tests (module + executable tests)
```

## Project Structure

- `src/root.zig` - Library entry point (public API exposed to consumers)
- `src/main.zig` - Example executable / development playground
- `build.zig` - Build configuration; exposes `actus` module for consumers
- `build.zig.zon` - Package metadata (minimum Zig version: 0.15.2)

## Conventions

- Library code goes in `src/root.zig` (or files re-exported from it)
- The `actus` module name is used for both the package export and internal import
- Tests are colocated with source code using Zig's `test` blocks
- Target Zig version: 0.15.2+
