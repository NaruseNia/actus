const std = @import("std");

/// Count the number of UTF-8 codepoints in a byte slice.
pub fn codepointCount(bytes: []const u8) usize {
    var count: usize = 0;
    var i: usize = 0;
    while (i < bytes.len) {
        const len = std.unicode.utf8ByteSequenceLength(bytes[i]) catch break;
        i += len;
        count += 1;
    }
    return count;
}

/// Get the byte length of the codepoint immediately before `pos`.
pub fn prevCodepointLen(bytes: []const u8, pos: usize) usize {
    if (pos == 0) return 0;
    // Walk backward over continuation bytes (10xxxxxx)
    var i = pos - 1;
    while (i > 0 and (bytes[i] & 0xC0) == 0x80) {
        i -= 1;
    }
    return pos - i;
}

test "codepointCount" {
    try std.testing.expectEqual(@as(usize, 5), codepointCount("hello"));
    try std.testing.expectEqual(@as(usize, 2), codepointCount("\xe3\x81\x82\xe3\x81\x84")); // あい
    try std.testing.expectEqual(@as(usize, 0), codepointCount(""));
}

test "prevCodepointLen" {
    // ASCII
    try std.testing.expectEqual(@as(usize, 1), prevCodepointLen("abc", 3));
    // 3-byte UTF-8 (あ = 0xE3 0x81 0x82)
    try std.testing.expectEqual(@as(usize, 3), prevCodepointLen("\xe3\x81\x82", 3));
    // At start
    try std.testing.expectEqual(@as(usize, 0), prevCodepointLen("abc", 0));
}
