const std = @import("std");

/// Keyboard key representation.
pub const Key = union(enum) {
    /// Printable Unicode character.
    char: u21,
    enter,
    backspace,
    delete,
    left,
    right,
    up,
    down,
    home,
    end,
    tab,
    escape,
    /// Ctrl + a-z (stores the letter, e.g. 'c' for Ctrl-C).
    ctrl: u8,
};

/// Event dispatched to widgets.
pub const Event = union(enum) {
    key: Key,
    // Future extensions:
    // resize: struct { width: u16, height: u16 },
    // mouse: MouseEvent,
    // tick,
};

// -- Tests --

test "Key.char stores codepoint" {
    const k: Key = .{ .char = 'A' };
    try std.testing.expectEqual(@as(u21, 'A'), k.char);
}

test "Key.ctrl stores letter" {
    const k: Key = .{ .ctrl = 'c' };
    try std.testing.expectEqual(@as(u8, 'c'), k.ctrl);
}

test "Event wraps Key" {
    const ev: Event = .{ .key = .enter };
    switch (ev) {
        .key => |key| switch (key) {
            .enter => {},
            else => return error.UnexpectedKey,
        },
    }
}
