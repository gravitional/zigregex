//! A bracket expression such as `[^a-z\d]`, or a class escape (`\w`) used on
//! its own.

const std = @import("std");
const Allocator = std.mem.Allocator;
const unicode = @import("unicode.zig");

const CharClass = @This();

pub const Builtin = enum(u3) { word, not_word, digit, not_digit, space, not_space };

/// Sorted, non-overlapping, non-adjacent inclusive ranges.
ranges: []const [2]u21,
builtins: std.EnumSet(Builtin) = .empty,
negated: bool = false,
/// Case-insensitive: matches when any case variant of the input is a member.
fold: bool = false,

pub fn matches(self: *const CharClass, c: u21) bool {
    var in = self.contains(c);
    if (!in and self.fold) {
        for (unicode.orbit(c)) |v| {
            if (v != c and self.contains(v)) {
                in = true;
                break;
            }
        }
    }
    return in != self.negated;
}

fn contains(self: *const CharClass, c: u21) bool {
    if (unicode.inRanges(self.ranges, c)) return true;
    var it = self.builtins.iterator();
    while (it.next()) |b| {
        const hit = switch (b) {
            .word => unicode.isWord(c),
            .not_word => !unicode.isWord(c),
            .digit => unicode.isDigit(c),
            .not_digit => !unicode.isDigit(c),
            .space => unicode.isSpace(c),
            .not_space => !unicode.isSpace(c),
        };
        if (hit) return true;
    }
    return false;
}

/// Collects ranges while a class is parsed.
pub const Builder = struct {
    ranges: std.ArrayList([2]u21) = .empty,
    builtins: std.EnumSet(Builtin) = .empty,

    pub fn addRange(b: *Builder, gpa: Allocator, lo: u21, hi: u21) Allocator.Error!void {
        try b.ranges.append(gpa, .{ lo, hi });
    }

    /// Sort and merge the ranges; the result is allocated with `gpa`.
    pub fn finish(b: *Builder, gpa: Allocator, negated: bool, fold: bool) Allocator.Error!CharClass {
        const rs = b.ranges.items;
        std.mem.sort([2]u21, rs, {}, struct {
            fn lt(_: void, x: [2]u21, y: [2]u21) bool {
                return x[0] < y[0];
            }
        }.lt);
        var n: usize = 0;
        for (rs) |r| {
            if (n > 0 and @as(u32, r[0]) <= @as(u32, rs[n - 1][1]) + 1) {
                rs[n - 1][1] = @max(rs[n - 1][1], r[1]);
            } else {
                rs[n] = r;
                n += 1;
            }
        }
        const owned = try gpa.dupe([2]u21, rs[0..n]);
        b.ranges.deinit(gpa);
        return .{ .ranges = owned, .builtins = b.builtins, .negated = negated, .fold = fold };
    }
};

test "class membership" {
    const gpa = std.testing.allocator;
    var b: Builder = .{};
    try b.addRange(gpa, 'x', 'z');
    try b.addRange(gpa, 'a', 'c');
    try b.addRange(gpa, 'd', 'd');
    b.builtins.insert(.digit);
    const cls = try b.finish(gpa, false, true);
    defer gpa.free(cls.ranges);
    try std.testing.expectEqual(@as(usize, 2), cls.ranges.len);
    try std.testing.expect(cls.matches('D') and cls.matches('7') and !cls.matches('e'));
}
