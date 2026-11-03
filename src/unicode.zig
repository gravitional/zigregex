//! Character properties used by the matcher, with ASCII fast paths.
//! The tables are generated from Python (see tools/gen_unicode_tables.py) so
//! that `\w`, `\d`, `\s` and case folding agree with Python's `re`.

const std = @import("std");
const tables = @import("unicode_tables.zig");

pub const version = tables.unicode_version;

pub fn inRanges(rs: []const [2]u21, c: u21) bool {
    var lo: usize = 0;
    var hi: usize = rs.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (c < rs[mid][0]) {
            hi = mid;
        } else if (c > rs[mid][1]) {
            lo = mid + 1;
        } else return true;
    }
    return false;
}

pub fn isWord(c: u21) bool {
    if (c < 0x80) return std.ascii.isAlphanumeric(@intCast(c)) or c == '_';
    return inRanges(&tables.word, c);
}

pub fn isDigit(c: u21) bool {
    if (c < 0x80) return c >= '0' and c <= '9';
    return inRanges(&tables.digit, c);
}

pub fn isSpace(c: u21) bool {
    if (c < 0x80) return (c >= '\t' and c <= '\r') or (c >= 0x1C and c <= ' ');
    return inRanges(&tables.space, c);
}

/// Canonical member of the case-fold class of `c`: two code points match
/// case-insensitively iff their canonical members are equal.
pub fn canon(c: u21) u21 {
    if (c < 0x80) {
        // `k`, `s` and `i` have non-ASCII partners (K, ſ, ı), whose canonical
        // member is the ASCII upper-case letter, like every other ASCII letter.
        return if (c >= 'a' and c <= 'z') c - 32 else c;
    }
    const t = &tables.fold_canon;
    var lo: usize = 0;
    var hi: usize = t.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (t[mid][0] < c) lo = mid + 1 else hi = mid;
    }
    return if (lo < t.len and t[lo][0] == c) t[lo][1] else c;
}

/// All code points that fold to the same class as `c` (including `c`), or an
/// empty slice when `c` is alone in its class.
pub fn orbit(c: u21) []const u21 {
    const k = canon(c);
    const t = &tables.fold_orbits;
    var lo: usize = 0;
    var hi: usize = t.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (t[mid][0] < k) lo = mid + 1 else hi = mid;
    }
    if (lo < t.len and t[lo][0] == k) return tables.fold_members[t[lo][1]..][0..t[lo][2]];
    return &.{};
}

test "properties" {
    try std.testing.expect(isWord('中') and isWord('é') and isWord('²') and !isWord('，'));
    try std.testing.expect(isDigit('٣') and !isDigit('²'));
    try std.testing.expect(isSpace(0x3000) and isSpace(0x1F) and !isSpace(0x200B));
}

test "case folding" {
    try std.testing.expectEqual(canon('a'), canon('A'));
    try std.testing.expectEqual(canon('s'), canon(0x17F)); // ſ
    try std.testing.expectEqual(canon('k'), canon(0x212A)); // Kelvin sign
    try std.testing.expectEqual(canon('Ω'), canon('ω'));
    try std.testing.expect(canon('中') == '中');
    try std.testing.expect(std.mem.indexOfScalar(u21, orbit('S'), 0x17F) != null);
}
