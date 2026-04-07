const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

const Terminal = @This();

const is_windows = builtin.os.tag == .windows;

/// Platform-specific original terminal state.
const OriginalState = if (is_windows) WindowsState else posix.termios;

const WindowsState = struct {
    stdin_mode: u32,
    stdout_mode: u32,
};

/// Windows console mode constants (not fully defined in std).
const win32 = if (is_windows) struct {
    const ENABLE_ECHO_INPUT: u32 = 0x0004;
    const ENABLE_LINE_INPUT: u32 = 0x0002;
    const ENABLE_PROCESSED_INPUT: u32 = 0x0001;
    const ENABLE_VIRTUAL_TERMINAL_INPUT: u32 = 0x0200;
    const ENABLE_VIRTUAL_TERMINAL_PROCESSING: u32 = 0x0004;
    const ENABLE_PROCESSED_OUTPUT: u32 = 0x0001;
} else struct {};

original: OriginalState,
stdin_handle: if (is_windows) std.os.windows.HANDLE else posix.fd_t,
stdout_handle: if (is_windows) std.os.windows.HANDLE else posix.fd_t,

pub const InitError = if (is_windows)
    error{Unexpected}
else
    posix.TermiosGetError;

pub fn init() InitError!Terminal {
    if (is_windows) {
        return initWindows();
    } else {
        return initPosix();
    }
}

pub fn enableRawMode(self: *Terminal) !void {
    if (is_windows) {
        return self.enableRawModeWindows();
    } else {
        return self.enableRawModePosix();
    }
}

pub fn disableRawMode(self: *Terminal) void {
    if (is_windows) {
        self.disableRawModeWindows();
    } else {
        self.disableRawModePosix();
    }
}

// -- POSIX implementation (macOS, Linux) --

fn initPosix() posix.TermiosGetError!Terminal {
    const stdin_fd = posix.STDIN_FILENO;
    const stdout_fd = posix.STDOUT_FILENO;
    const original = try posix.tcgetattr(stdin_fd);
    return .{
        .original = original,
        .stdin_handle = stdin_fd,
        .stdout_handle = stdout_fd,
    };
}

fn enableRawModePosix(self: *Terminal) posix.TermiosSetError!void {
    var raw = self.original;
    // Disable canonical mode, echo, signals, and extended input processing
    raw.lflag.ECHO = false;
    raw.lflag.ICANON = false;
    raw.lflag.ISIG = false;
    raw.lflag.IEXTEN = false;
    // Disable CR→NL translation and software flow control (Ctrl-S/Q)
    raw.iflag.ICRNL = false;
    raw.iflag.IXON = false;
    // Disable output processing
    raw.oflag.OPOST = false;
    // Read returns after at least 1 byte, no timeout
    raw.cc[@intFromEnum(std.c.V.MIN)] = 1;
    raw.cc[@intFromEnum(std.c.V.TIME)] = 0;
    try posix.tcsetattr(self.stdin_handle, .FLUSH, raw);
}

fn disableRawModePosix(self: *Terminal) void {
    posix.tcsetattr(self.stdin_handle, .FLUSH, self.original) catch {};
}

// -- Windows implementation --

fn initWindows() error{Unexpected}!Terminal {
    const kernel32 = std.os.windows.kernel32;
    const stdin_h = kernel32.GetStdHandle(std.os.windows.STD_INPUT_HANDLE) orelse return error.Unexpected;
    const stdout_h = kernel32.GetStdHandle(std.os.windows.STD_OUTPUT_HANDLE) orelse return error.Unexpected;
    var stdin_mode: u32 = 0;
    var stdout_mode: u32 = 0;
    if (kernel32.GetConsoleMode(stdin_h, &stdin_mode) == 0) return error.Unexpected;
    if (kernel32.GetConsoleMode(stdout_h, &stdout_mode) == 0) return error.Unexpected;
    return .{
        .original = .{ .stdin_mode = stdin_mode, .stdout_mode = stdout_mode },
        .stdin_handle = stdin_h,
        .stdout_handle = stdout_h,
    };
}

fn enableRawModeWindows(self: *Terminal) error{Unexpected}!void {
    const kernel32 = std.os.windows.kernel32;
    // Disable line input, echo, and processed input; enable VT input
    const new_stdin = (self.original.stdin_mode & ~(win32.ENABLE_ECHO_INPUT | win32.ENABLE_LINE_INPUT | win32.ENABLE_PROCESSED_INPUT)) | win32.ENABLE_VIRTUAL_TERMINAL_INPUT;
    if (kernel32.SetConsoleMode(self.stdin_handle, new_stdin) == 0) return error.Unexpected;
    // Enable VT processing for output
    const new_stdout = self.original.stdout_mode | win32.ENABLE_VIRTUAL_TERMINAL_PROCESSING | win32.ENABLE_PROCESSED_OUTPUT;
    if (kernel32.SetConsoleMode(self.stdout_handle, new_stdout) == 0) return error.Unexpected;
}

fn disableRawModeWindows(self: *Terminal) void {
    const kernel32 = std.os.windows.kernel32;
    _ = kernel32.SetConsoleMode(self.stdin_handle, self.original.stdin_mode);
    _ = kernel32.SetConsoleMode(self.stdout_handle, self.original.stdout_mode);
}

// -- ANSI escape helpers --
// These work on any platform once raw mode / VT processing is enabled.

pub fn hideCursor(writer: anytype) !void {
    try writer.writeAll("\x1b[?25l");
}

pub fn showCursor(writer: anytype) !void {
    try writer.writeAll("\x1b[?25h");
}

pub fn moveCursorTo(writer: anytype, col: u16) !void {
    try writer.print("\x1b[{d}G", .{@as(u32, col) + 1}); // 1-indexed
}

pub fn clearLine(writer: anytype) !void {
    try writer.writeAll("\r\x1b[2K");
}

pub fn moveCursorUp(writer: anytype, n: u16) !void {
    if (n == 0) return;
    try writer.print("\x1b[{d}A", .{n});
}

pub fn moveCursorDown(writer: anytype, n: u16) !void {
    if (n == 0) return;
    try writer.print("\x1b[{d}B", .{n});
}

pub fn clearFromCursor(writer: anytype) !void {
    try writer.writeAll("\x1b[J");
}

// -- Tests --

test "ANSI hideCursor writes correct escape" {
    var buf: [32]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const writer = fbs.writer();
    try hideCursor(&writer);
    try std.testing.expectEqualStrings("\x1b[?25l", fbs.getWritten());
}

test "ANSI showCursor writes correct escape" {
    var buf: [32]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const writer = fbs.writer();
    try showCursor(&writer);
    try std.testing.expectEqualStrings("\x1b[?25h", fbs.getWritten());
}

test "ANSI clearLine writes correct escape" {
    var buf: [32]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const writer = fbs.writer();
    try clearLine(&writer);
    try std.testing.expectEqualStrings("\r\x1b[2K", fbs.getWritten());
}

test "ANSI moveCursorTo column 0 writes col 1" {
    var buf: [32]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const writer = fbs.writer();
    try moveCursorTo(&writer, 0);
    try std.testing.expectEqualStrings("\x1b[1G", fbs.getWritten());
}

test "ANSI moveCursorUp writes correct escape" {
    var buf: [32]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const writer = fbs.writer();
    try moveCursorUp(&writer, 3);
    try std.testing.expectEqualStrings("\x1b[3A", fbs.getWritten());
}

test "ANSI moveCursorUp zero writes nothing" {
    var buf: [32]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const writer = fbs.writer();
    try moveCursorUp(&writer, 0);
    try std.testing.expectEqualStrings("", fbs.getWritten());
}

test "ANSI clearFromCursor writes correct escape" {
    var buf: [32]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const writer = fbs.writer();
    try clearFromCursor(&writer);
    try std.testing.expectEqualStrings("\x1b[J", fbs.getWritten());
}

test "ANSI moveCursorTo column 9 writes col 10" {
    var buf: [32]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const writer = fbs.writer();
    try moveCursorTo(&writer, 9);
    try std.testing.expectEqualStrings("\x1b[10G", fbs.getWritten());
}
