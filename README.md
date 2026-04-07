# actus

A terminal UI widget library for Zig.

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

## Usage

```zig
const actus = @import("actus");
```

## Development

```sh
# Build
zig build

# Run example
zig build run

# Test
zig build test
```

## License

MIT
