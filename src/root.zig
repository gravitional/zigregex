//! A small backtracking regular-expression engine for UTF-8 text.
//!
//! The syntax and matching semantics follow Python's `re` module, which is
//! close to PCRE: literals and escapes, `.`, bracket classes, `\w \d \s` and
//! their negations, `^ $ \A \Z \z \b \B`, capturing / non-capturing / named
//! groups, alternation, greedy and lazy `* + ? {m,n}`, lookahead, fixed-width
//! lookbehind, back-references, and the flags `i m s` (globally `(?i)` or
//! scoped `(?i:...)`). Character properties and case folding come from
//! Python's Unicode database (see tools/gen_unicode_tables.py).
//!
//! Not supported: atomic groups, possessive quantifiers, recursion,
//! conditionals, `\p{...}`, and the `x` / `a` / `L` flags.
//!
//! Positions are byte offsets into the input; matching steps over code
//! points. Invalid UTF-8 is matched byte by byte.
//!
//!     var re = try Regex.compile(gpa, "(\\w+)@(\\w+)", .{});
//!     defer re.deinit();
//!     var m = try Matcher.init(gpa, &re, .{});
//!     defer m.deinit();
//!     var it = m.iterator("a@b, c@d");
//!     while (try it.next()) |hit| std.debug.print("{s}\n", .{hit.group(1).?});

const std = @import("std");
const Allocator = std.mem.Allocator;
const parse = @import("parse.zig");
const compile_ = @import("compile.zig");
const vm_ = @import("vm.zig");
const CharClass = @import("CharClass.zig");

pub const unicode = @import("unicode.zig");
pub const Flags = parse.Flags;
pub const Diagnostics = parse.Diagnostics;

pub const CompileError = error{ InvalidPattern, PatternTooLarge, OutOfMemory };
pub const MatchError = vm_.Error;

pub const Regex = struct {
    arena: std.heap.ArenaAllocator,
    insts: []const compile_.Inst,
    classes: []const CharClass,
    /// Number of groups, including group 0 (the whole match).
    groups: u32,
    names: []const parse.Name,
    regs: u32,
    /// The match must start with this ASCII byte (used to skip ahead).
    first_byte: ?u8,
    /// The match can only start at offset 0.
    anchored: bool,

    pub const Options = struct {
        flags: Flags = .{},
        /// Filled with the offset and reason when compilation fails.
        diagnostics: ?*Diagnostics = null,
    };

    pub fn compile(gpa: Allocator, pattern: []const u8, opts: Options) CompileError!Regex {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        errdefer arena.deinit();
        const a = arena.allocator();
        const ast = try parse.parse(a, pattern, opts.flags, opts.diagnostics);
        const prog = compile_.compile(a, ast) catch |e| {
            if (e == error.PatternTooLarge) if (opts.diagnostics) |d| {
                d.* = .{ .offset = 0, .message = "pattern too large (counted repetitions are expanded)" };
            };
            return e;
        };
        // insts[0] is `save 0`.
        const head = prog.insts[1];
        return .{
            .arena = arena,
            .insts = prog.insts,
            .classes = ast.classes,
            .groups = ast.groups,
            .names = ast.names,
            .regs = prog.regs,
            .first_byte = switch (head) {
                .char => |c| if (c < 0x80) @intCast(c) else null,
                else => null,
            },
            .anchored = switch (head) {
                .assert => |k| k == .text_start,
                else => false,
            },
        };
    }

    pub fn deinit(re: *Regex) void {
        re.arena.deinit();
        re.* = undefined;
    }

    /// Group number of a named group.
    pub fn groupIndex(re: *const Regex, name: []const u8) ?usize {
        for (re.names) |n| if (std.mem.eql(u8, n.name, name)) return n.group;
        return null;
    }
};

pub const Span = struct { start: usize, end: usize };

/// A successful match. It refers to the matcher's buffers and stays valid
/// until the next call on the same `Matcher`.
pub const Match = struct {
    input: []const u8,
    slots: []const usize,

    pub fn start(m: Match) usize {
        return m.slots[0];
    }

    pub fn end(m: Match) usize {
        return m.slots[1];
    }

    pub fn text(m: Match) []const u8 {
        return m.input[m.slots[0]..m.slots[1]];
    }

    /// Span of group `i`, or null if it did not participate.
    pub fn span(m: Match, i: usize) ?Span {
        const s = m.slots[2 * i];
        const e = m.slots[2 * i + 1];
        if (s == vm_.unset or e == vm_.unset) return null;
        return .{ .start = s, .end = e };
    }

    pub fn group(m: Match, i: usize) ?[]const u8 {
        const sp = m.span(i) orelse return null;
        return m.input[sp.start..sp.end];
    }

    pub fn groupCount(m: Match) usize {
        return m.slots.len / 2;
    }
};

/// Matching state for one regex; reuse it across calls to avoid allocation.
pub const Matcher = struct {
    gpa: Allocator,
    re: *const Regex,
    vm: vm_.Vm,

    pub const Options = struct {
        /// Bound on VM steps per search, against catastrophic backtracking.
        step_limit: u64 = 10_000_000,
    };

    pub fn init(gpa: Allocator, re: *const Regex, opts: Options) Allocator.Error!Matcher {
        const slots = try gpa.alloc(usize, 2 * re.groups);
        errdefer gpa.free(slots);
        const regs = try gpa.alloc(usize, re.regs);
        return .{
            .gpa = gpa,
            .re = re,
            .vm = .{ .insts = re.insts, .classes = re.classes, .slots = slots, .regs = regs, .step_limit = opts.step_limit },
        };
    }

    pub fn deinit(m: *Matcher) void {
        m.vm.stack.deinit(m.gpa);
        m.gpa.free(m.vm.slots);
        m.gpa.free(m.vm.regs);
    }

    /// Match starting exactly at `pos` (like Python's `pattern.match(s, pos)`).
    /// Text before `pos` is still visible to `\b` and lookbehind.
    pub fn matchAt(m: *Matcher, input: []const u8, pos: usize) MatchError!?Match {
        m.vm.steps = 0;
        return m.attempt(input, pos, false);
    }

    /// First match starting at or after `start`.
    pub fn search(m: *Matcher, input: []const u8, start: usize) MatchError!?Match {
        return m.searchFrom(input, start, false);
    }

    /// With `must_advance`, an empty match at `start` is rejected (used by
    /// the iterator after an empty match, as in Python 3.7+).
    fn searchFrom(m: *Matcher, input: []const u8, start: usize, must_advance: bool) MatchError!?Match {
        m.vm.steps = 0;
        const re = m.re;
        if (re.anchored) {
            if (start != 0) return null;
            return m.attempt(input, 0, must_advance);
        }
        var pos = start;
        while (pos <= input.len) {
            if (re.first_byte) |b| {
                pos = std.mem.indexOfScalarPos(u8, input, pos, b) orelse return null;
            }
            if (try m.attempt(input, pos, must_advance and pos == start)) |hit| return hit;
            if (pos == input.len) break;
            pos += vm_.decode(input, pos).len;
        }
        return null;
    }

    fn attempt(m: *Matcher, input: []const u8, pos: usize, forbid_empty: bool) MatchError!?Match {
        const v = &m.vm;
        v.input = input;
        v.stack.clearRetainingCapacity();
        @memset(v.slots, vm_.unset);
        @memset(v.regs, vm_.unset);
        v.forbid_empty_at = if (forbid_empty) pos else null;
        _ = try v.run(m.gpa, 0, pos, null) orelse return null;
        return .{ .input = input, .slots = v.slots };
    }

    /// All non-overlapping matches, left to right (Python's `finditer`).
    pub fn iterator(m: *Matcher, input: []const u8) Iterator {
        return .{ .matcher = m, .input = input };
    }
};

pub const Iterator = struct {
    matcher: *Matcher,
    input: []const u8,
    pos: usize = 0,
    must_advance: bool = false,
    done: bool = false,

    pub fn next(it: *Iterator) MatchError!?Match {
        if (it.done or it.pos > it.input.len) return null;
        const hit = try it.matcher.searchFrom(it.input, it.pos, it.must_advance) orelse {
            it.done = true;
            return null;
        };
        it.must_advance = hit.end() == hit.start();
        it.pos = hit.end();
        return hit;
    }
};

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

/// Spans of all matches, formatted as "s-e s-e ...".
fn findAll(pattern: []const u8, input: []const u8) ![]u8 {
    var re = try Regex.compile(testing.allocator, pattern, .{});
    defer re.deinit();
    var m = try Matcher.init(testing.allocator, &re, .{});
    defer m.deinit();
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    errdefer out.deinit();
    var it = m.iterator(input);
    while (try it.next()) |hit| {
        if (out.written().len > 0) try out.writer.writeByte(' ');
        try out.writer.print("{d}-{d}", .{ hit.start(), hit.end() });
    }
    return out.toOwnedSlice();
}

fn expectAll(pattern: []const u8, input: []const u8, expected: []const u8) !void {
    const got = try findAll(pattern, input);
    defer testing.allocator.free(got);
    testing.expectEqualStrings(expected, got) catch |e| {
        std.debug.print("pattern {s} on {s}\n", .{ pattern, input });
        return e;
    };
}

test "basics" {
    try expectAll("a+", "baaab a", "1-4 6-7");
    try expectAll("a|ab", "ab", "0-1");
    try expectAll("(a|ab)(c|bcd)", "abcd", "0-4");
    try expectAll("a*?b", "aaab", "0-4");
    try expectAll("x*", "axx", "0-0 1-3 3-3");
    try expectAll("\\bfoo\\b", "foo food foo", "0-3 9-12");
    try expectAll("(?<!\\\\)\\\\[A-Za-z]{2,}", "\\cdot \\\\cdot \\x", "0-5");
    try expectAll("^a|a$", "aba", "0-1 2-3");
    try expectAll("(?m)^a", "a\na", "0-1 2-3");
    try expectAll("a$", "a\n", "0-1");
    try expectAll("a\\Z", "a\n", "");
    try expectAll("[㐀-鿿]", "a中b文", "1-4 5-8");
    try expectAll("(?i)straße", "STRASSE STRAẞE", "8-16");
    try expectAll("(?i)[a-c]+", "xABCx", "1-4");
    try expectAll("(a)\\1", "aa ab", "0-2");
    try expectAll("(?<=ab)c", "abc ac", "2-3");
    try expectAll("(?=(a+))a*b\\1", "baaabac", "3-6");
    try expectAll("(a?)*", "b", "0-0 1-1");
    try expectAll("(a?){0,30}b", "aab", "0-3");
}

test "groups" {
    var re = try Regex.compile(testing.allocator, "(?P<user>\\w+)@(\\w+)|(x)", .{});
    defer re.deinit();
    var m = try Matcher.init(testing.allocator, &re, .{});
    defer m.deinit();
    const hit = (try m.search("  bob@host", 0)).?;
    try testing.expectEqualStrings("bob", hit.group(re.groupIndex("user").?).?);
    try testing.expectEqualStrings("host", hit.group(2).?);
    try testing.expectEqual(@as(?[]const u8, null), hit.group(3));
}

test "match limit" {
    var re = try Regex.compile(testing.allocator, "(a*)*b", .{});
    defer re.deinit();
    var m = try Matcher.init(testing.allocator, &re, .{ .step_limit = 10_000 });
    defer m.deinit();
    const input: [40]u8 = @splat('a');
    try testing.expectError(error.MatchLimitExceeded, m.search(&input, 0));
}

test "diagnostics" {
    var d: Diagnostics = .{};
    try testing.expectError(error.InvalidPattern, Regex.compile(testing.allocator, "ab(c", .{ .diagnostics = &d }));
    try testing.expectEqual(@as(usize, 2), d.offset);
    try testing.expectError(error.PatternTooLarge, Regex.compile(testing.allocator, "(a{1000}){2000}", .{ .diagnostics = &d }));
}

test {
    _ = parse;
    _ = unicode;
    _ = CharClass;
}
