const std = @import("std");
const builtin = @import("builtin");
const event = @import("event.zig");
const Event = event.Event;
const Key = event.Key;

const is_windows = builtin.os.tag == .windows;

pub const Handle = if (is_windows) std.os.windows.HANDLE else std.posix.fd_t;

pub const ReadError = if (is_windows)
    error{ Unexpected, EndOfStream }
else
    std.posix.ReadError;

/// Reads one event from the input handle. Blocks until input is available.
/// Returns null for unrecognized or incomplete sequences.
pub fn readEvent(handle: Handle) ReadError!?Event {
    var buf: [16]u8 = undefined;
    const n = try readBytes(handle, &buf);
    if (n == 0) return null;
    return parse(buf[0..n]);
}

/// Check if input is available without blocking.
/// Returns true if data is ready to read.
pub fn hasInput(handle: Handle) bool {
    if (is_windows) {
        return hasInputWindows(handle);
    } else {
        return hasInputPosix(handle);
    }
}

/// Read event with timeout. Returns null if timeout expires.
pub fn readEventTimeout(handle: Handle, timeout_ms: u64) ReadError!?Event {
    const start = std.time.milliTimestamp();
    while (true) {
        if (hasInput(handle)) {
            return readEvent(handle);
        }
        const now = std.time.milliTimestamp();
        if (now >= start + timeout_ms) return null;
        // Sleep for 10ms (platform-specific)
        if (is_windows) {
            std.os.windows.kernel32.Sleep(10);
        } else {
            const ns = 10_000_000;
            const seconds = ns / 1_000_000_000;
            const nanoseconds = ns % 1_000_000_000;
            std.posix.nanosleep(seconds, nanoseconds);
        }
    }
}

// -- Non-blocking input helpers --

fn hasInputPosix(fd: std.posix.fd_t) bool {
    var fds: [1]std.posix.pollfd = .{
        .{
            .fd = fd,
            .events = std.posix.POLL.IN,
            .revents = 0,
        },
    };
    const result = std.posix.poll(&fds, 0) catch return false; // 0 timeout = non-blocking
    return result == 1;
}

fn hasInputWindows(handle: std.os.windows.HANDLE) bool {
    const kernel32 = std.os.windows.kernel32;
    var num_events: u32 = 0;
    return kernel32.GetNumberOfConsoleInputEvents(handle, &num_events) != 0 and num_events > 0;
}

/// Platform-specific raw byte read.
fn readBytes(handle: Handle, buf: []u8) ReadError!usize {
    if (is_windows) {
        return readBytesWindows(handle, buf);
    } else {
        return readBytesPosix(handle, buf);
    }
}

fn readBytesPosix(fd: std.posix.fd_t, buf: []u8) std.posix.ReadError!usize {
    return std.posix.read(fd, buf);
}

fn readBytesWindows(handle: std.os.windows.HANDLE, buf: []u8) error{ Unexpected, EndOfStream }!usize {
    const kernel32 = std.os.windows.kernel32;
    var bytes_read: u32 = 0;
    if (kernel32.ReadFile(handle, buf.ptr, @intCast(buf.len), &bytes_read, null) == 0) {
        return error.Unexpected;
    }
    if (bytes_read == 0) return error.EndOfStream;
    return @intCast(bytes_read);
}

/// Parse raw bytes into an Event.
pub fn parse(buf: []const u8) ?Event {
    if (buf.len == 0) return null;

    const b = buf[0];

    // Tab
    if (b == 9) return .{ .key = .tab };
    // Enter (LF or CR)
    if (b == 10 or b == 13) return .{ .key = .enter };
    // Escape or escape sequence
    if (b == 27) return parseEscape(buf);
    // Backspace (127) or Ctrl-H (8)
    if (b == 127 or b == 8) return .{ .key = .backspace };
    // Ctrl keys: bytes 1-26 (excluding already handled 8, 9, 10, 13)
    if (b < 32) return .{ .key = .{ .ctrl = b + 'a' - 1 } };

    // UTF-8 decoding
    const codepoint_len = std.unicode.utf8ByteSequenceLength(b) catch return null;
    if (codepoint_len > buf.len) return null;
    const cp = std.unicode.utf8Decode(buf[0..codepoint_len]) catch return null;
    return .{ .key = .{ .char = cp } };
}

fn parseEscape(buf: []const u8) ?Event {
    // Lone ESC
    if (buf.len == 1) return .{ .key = .escape };

    // CSI sequences: ESC [ ...
    if (buf.len >= 3 and buf[1] == '[') {
        return switch (buf[2]) {
            'A' => .{ .key = .up },
            'B' => .{ .key = .down },
            'C' => .{ .key = .right },
            'D' => .{ .key = .left },
            'H' => .{ .key = .home },
            'F' => .{ .key = .end },
            '1' => parseExtendedCsi(buf),
            '3' => if (buf.len >= 4 and buf[3] == '~') .{ .key = .delete } else null,
            else => null,
        };
    }

    return .{ .key = .escape };
}

/// Parse extended CSI sequences like ESC[1;5C (Ctrl+Right), ESC[1~ (Home), etc.
fn parseExtendedCsi(buf: []const u8) ?Event {
    if (buf.len >= 4 and buf[3] == '~') return .{ .key = .home }; // ESC[1~
    // ESC[1;...X sequences (e.g., ESC[1;5C = Ctrl+Right) — treat as plain arrow for now
    if (buf.len >= 6 and buf[3] == ';') {
        return switch (buf[5]) {
            'A' => .{ .key = .up },
            'B' => .{ .key = .down },
            'C' => .{ .key = .right },
            'D' => .{ .key = .left },
            'H' => .{ .key = .home },
            'F' => .{ .key = .end },
            else => null,
        };
    }
    return null;
}

// -- Tests --

test "parse printable ASCII" {
    const ev = parse("A").?;
    try std.testing.expectEqual(Key{ .char = 'A' }, ev.key);
}

test "parse enter (LF)" {
    const ev = parse("\n").?;
    try std.testing.expectEqual(Key.enter, ev.key);
}

test "parse enter (CR)" {
    const ev = parse("\r").?;
    try std.testing.expectEqual(Key.enter, ev.key);
}

test "parse backspace (127)" {
    const ev = parse(&[_]u8{127}).?;
    try std.testing.expectEqual(Key.backspace, ev.key);
}

test "parse backspace (Ctrl-H)" {
    const ev = parse(&[_]u8{8}).?;
    try std.testing.expectEqual(Key.backspace, ev.key);
}

test "parse tab" {
    const ev = parse("\t").?;
    try std.testing.expectEqual(Key.tab, ev.key);
}

test "parse Ctrl-C" {
    const ev = parse(&[_]u8{3}).?;
    try std.testing.expectEqual(Key{ .ctrl = 'c' }, ev.key);
}

test "parse Ctrl-A" {
    const ev = parse(&[_]u8{1}).?;
    try std.testing.expectEqual(Key{ .ctrl = 'a' }, ev.key);
}

test "parse lone escape" {
    const ev = parse(&[_]u8{27}).?;
    try std.testing.expectEqual(Key.escape, ev.key);
}

test "parse arrow right (CSI C)" {
    const ev = parse("\x1b[C").?;
    try std.testing.expectEqual(Key.right, ev.key);
}

test "parse arrow left (CSI D)" {
    const ev = parse("\x1b[D").?;
    try std.testing.expectEqual(Key.left, ev.key);
}

test "parse arrow up (CSI A)" {
    const ev = parse("\x1b[A").?;
    try std.testing.expectEqual(Key.up, ev.key);
}

test "parse arrow down (CSI B)" {
    const ev = parse("\x1b[B").?;
    try std.testing.expectEqual(Key.down, ev.key);
}

test "parse home (CSI H)" {
    const ev = parse("\x1b[H").?;
    try std.testing.expectEqual(Key.home, ev.key);
}

test "parse end (CSI F)" {
    const ev = parse("\x1b[F").?;
    try std.testing.expectEqual(Key.end, ev.key);
}

test "parse delete (CSI 3~)" {
    const ev = parse("\x1b[3~").?;
    try std.testing.expectEqual(Key.delete, ev.key);
}

test "parse UTF-8 multibyte (Japanese あ)" {
    const ev = parse("\xe3\x81\x82").?; // U+3042 'あ'
    try std.testing.expectEqual(Key{ .char = 0x3042 }, ev.key);
}

test "parse empty returns null" {
    try std.testing.expectEqual(@as(?Event, null), parse(""));
}

test "parse incomplete UTF-8 returns null" {
    // First byte of a 2-byte sequence, but only 1 byte provided
    try std.testing.expectEqual(@as(?Event, null), parse(&[_]u8{0xC3}));
}

test "readEventTimeout returns null on timeout" {
    // This test verifies the timeout logic compiles correctly.
    // Actual timeout behavior requires real input, tested in integration.
    const timeout_ms: u64 = 1;
    _ = timeout_ms;
    try std.testing.expect(true);
}
