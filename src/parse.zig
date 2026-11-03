//! Pattern syntax → AST. The accepted syntax and the error conditions follow
//! Python's `re` (sre_parse), with a few PCRE spellings added (`(?<name>…)`,
//! `\z`). Error messages use Python's wording where there is one.

const std = @import("std");
const Allocator = std.mem.Allocator;
const CharClass = @import("CharClass.zig");

pub const Flags = struct {
    /// `i`: case-insensitive.
    ignore_case: bool = false,
    /// `m`: `^` and `$` also match at line boundaries.
    multiline: bool = false,
    /// `s`: `.` also matches `\n`.
    dot_all: bool = false,
};

pub const Assert = enum {
    /// `\A`, or `^` without multiline.
    text_start,
    /// `^` with multiline.
    line_start,
    /// `$` without multiline: end of text, or before a final `\n`.
    text_end_newline,
    /// `$` with multiline.
    line_end,
    /// `\Z`, `\z`.
    text_end,
    word_boundary,
    not_word_boundary,
};

pub const NodeIndex = u32;

pub const Node = union(enum) {
    empty,
    literal: struct { cp: u21, fold: bool },
    any: struct { dot_all: bool },
    class: u32,
    assert: Assert,
    group: struct { child: NodeIndex, capture: ?u32 },
    concat: []const NodeIndex,
    alt: []const NodeIndex,
    repeat: struct { child: NodeIndex, min: u32, max: ?u32, greedy: bool },
    look: struct { child: NodeIndex, behind: bool, negate: bool, width: u32 },
    backref: struct { group: u32, fold: bool },
};

pub const Name = struct { name: []const u8, group: u32 };

pub const Diagnostics = struct {
    /// Byte offset in the pattern.
    offset: usize = 0,
    message: []const u8 = "",
};

pub const Error = error{ InvalidPattern, OutOfMemory };

pub const Ast = struct {
    nodes: []const Node,
    root: NodeIndex,
    classes: []const CharClass,
    /// Number of groups, including group 0 (the whole match).
    groups: u32,
    names: []const Name,
};

/// Repetition counts above this are rejected (Python's MAXREPEAT - 1).
pub const max_repeat: u32 = std.math.maxInt(u32) - 1;

/// Parse `pattern`. Everything is allocated with `arena`, and `classes` and
/// `names` are meant to outlive the AST, so use an arena that lives as long
/// as the compiled regex.
pub fn parse(arena: Allocator, pattern: []const u8, flags: Flags, diag: ?*Diagnostics) Error!Ast {
    var p: Parser = .{ .arena = arena, .src = pattern, .diag = diag };
    try p.closed.append(arena, true); // group 0
    var f = flags;
    try p.globalFlags(&f);
    const root = try p.parseAlt(f, 0);
    if (p.pos < p.src.len) return p.fail(p.pos, "unbalanced parenthesis");
    return .{
        .nodes = p.nodes.items,
        .root = root,
        .classes = p.classes.items,
        .groups = @intCast(p.closed.items.len),
        .names = p.names.items,
    };
}

const Parser = struct {
    arena: Allocator,
    src: []const u8,
    pos: usize = 0,
    diag: ?*Diagnostics,
    nodes: std.ArrayList(Node) = .empty,
    classes: std.ArrayList(CharClass) = .empty,
    names: std.ArrayList(Name) = .empty,
    /// closed.items[g]: group g has been closed (index 0 is the whole match).
    closed: std.ArrayList(bool) = .empty,
    /// Nesting depth of look-behind assertions.
    in_lookbehind: u32 = 0,

    fn fail(p: *Parser, offset: usize, msg: []const u8) Error {
        if (p.diag) |d| d.* = .{ .offset = offset, .message = msg };
        return error.InvalidPattern;
    }

    fn add(p: *Parser, n: Node) Allocator.Error!NodeIndex {
        try p.nodes.append(p.arena, n);
        return @intCast(p.nodes.items.len - 1);
    }

    fn peek(p: *Parser) ?u8 {
        return if (p.pos < p.src.len) p.src[p.pos] else null;
    }

    fn eat(p: *Parser, c: u8) bool {
        if (p.peek() == c) {
            p.pos += 1;
            return true;
        }
        return false;
    }

    fn eatStr(p: *Parser, s: []const u8) bool {
        if (std.mem.startsWith(u8, p.src[p.pos..], s)) {
            p.pos += s.len;
            return true;
        }
        return false;
    }

    /// Next code point of the pattern (invalid UTF-8 is taken byte by byte).
    fn nextCodepoint(p: *Parser) u21 {
        const s = p.src;
        const len = std.unicode.utf8ByteSequenceLength(s[p.pos]) catch 1;
        if (len > 1 and p.pos + len <= s.len) {
            if (std.unicode.utf8Decode(s[p.pos .. p.pos + len])) |cp| {
                p.pos += len;
                return cp;
            } else |_| {}
        }
        p.pos += 1;
        return s[p.pos - 1];
    }

    /// `(?ims)` at the start of the pattern.
    fn globalFlags(p: *Parser, f: *Flags) Error!void {
        while (std.mem.startsWith(u8, p.src[p.pos..], "(?")) {
            var j = p.pos + 2;
            var g = f.*;
            while (j < p.src.len and applyFlag(&g, p.src[j], true)) j += 1;
            if (j == p.pos + 2 or j >= p.src.len or p.src[j] != ')') return;
            f.* = g;
            p.pos = j + 1;
        }
    }

    fn parseAlt(p: *Parser, flags: Flags, depth: u32) Error!NodeIndex {
        if (depth > 500) return p.fail(p.pos, "too many nested groups");
        var branches: std.ArrayList(NodeIndex) = .empty;
        try branches.append(p.arena, try p.parseConcat(flags, depth));
        while (p.eat('|')) try branches.append(p.arena, try p.parseConcat(flags, depth));
        if (branches.items.len == 1) return branches.items[0];
        return p.add(.{ .alt = branches.items });
    }

    fn parseConcat(p: *Parser, flags: Flags, depth: u32) Error!NodeIndex {
        var items: std.ArrayList(NodeIndex) = .empty;
        while (p.peek()) |c| {
            if (c == '|' or c == ')') break;
            const atom = try p.parseAtom(flags, depth) orelse continue;
            try items.append(p.arena, try p.parseQuantifiers(atom));
        }
        return switch (items.items.len) {
            0 => p.add(.empty),
            1 => items.items[0],
            else => p.add(.{ .concat = items.items }),
        };
    }

    fn parseQuantifiers(p: *Parser, atom: NodeIndex) Error!NodeIndex {
        const q_start = p.pos;
        const q = try p.quantifier() orelse return atom;
        switch (p.nodes.items[atom]) {
            .assert => return p.fail(q_start, "nothing to repeat"),
            else => {},
        }
        const greedy = !p.eat('?');
        if (p.peek() == '+') return p.fail(p.pos, "possessive quantifiers are not supported");
        const node = try p.add(.{ .repeat = .{ .child = atom, .min = q.min, .max = q.max, .greedy = greedy } });
        const again = p.pos;
        if (try p.quantifier() != null) return p.fail(again, "multiple repeat");
        return node;
    }

    const Quant = struct { min: u32, max: ?u32 };

    /// Parse `*`, `+`, `?` or `{m,n}` at the current position. A `{` that
    /// does not form a valid quantifier is left alone (it is a literal).
    fn quantifier(p: *Parser) Error!?Quant {
        const c = p.peek() orelse return null;
        switch (c) {
            '*' => {
                p.pos += 1;
                return .{ .min = 0, .max = null };
            },
            '+' => {
                p.pos += 1;
                return .{ .min = 1, .max = null };
            },
            '?' => {
                p.pos += 1;
                return .{ .min = 0, .max = 1 };
            },
            '{' => return p.braceQuantifier(),
            else => return null,
        }
    }

    fn braceQuantifier(p: *Parser) Error!?Quant {
        const here = p.pos;
        if (std.mem.startsWith(u8, p.src[here..], "{}")) return null;
        p.pos += 1;
        const lo = p.digits();
        var hi = lo;
        const comma = p.eat(',');
        if (comma) hi = p.digits();
        if (!p.eat('}')) {
            p.pos = here;
            return null;
        }
        const min: u32 = if (lo.len > 0) try p.count(lo, here) else 0;
        const max: ?u32 = if (hi.len > 0) try p.count(hi, here) else if (comma) null else min;
        if (max) |m| if (m < min) return p.fail(here, "min repeat greater than max repeat");
        return .{ .min = min, .max = max };
    }

    fn digits(p: *Parser) []const u8 {
        const s = p.pos;
        while (p.peek()) |c| {
            if (!std.ascii.isDigit(c)) break;
            p.pos += 1;
        }
        return p.src[s..p.pos];
    }

    fn count(p: *Parser, s: []const u8, at: usize) Error!u32 {
        const v = std.fmt.parseInt(u64, s, 10) catch return p.fail(at, "the repetition number is too large");
        if (v > max_repeat) return p.fail(at, "the repetition number is too large");
        return @intCast(v);
    }

    /// One atom; null for constructs that produce nothing (`(?#...)`).
    fn parseAtom(p: *Parser, flags: Flags, depth: u32) Error!?NodeIndex {
        const start = p.pos;
        const c = p.src[p.pos];
        switch (c) {
            '(' => return p.parseGroup(flags, depth),
            '[' => return try p.parseClass(flags),
            '.' => {
                p.pos += 1;
                return try p.add(.{ .any = .{ .dot_all = flags.dot_all } });
            },
            '^' => {
                p.pos += 1;
                return try p.add(.{ .assert = if (flags.multiline) .line_start else .text_start });
            },
            '$' => {
                p.pos += 1;
                return try p.add(.{ .assert = if (flags.multiline) .line_end else .text_end_newline });
            },
            '\\' => return try p.parseEscape(flags),
            '*', '+', '?' => return p.fail(start, "nothing to repeat"),
            '{' => {
                if (try p.braceQuantifier() != null) return p.fail(start, "nothing to repeat");
                p.pos += 1;
                return try p.add(.{ .literal = .{ .cp = '{', .fold = flags.ignore_case } });
            },
            else => {
                const cp = p.nextCodepoint();
                return try p.add(.{ .literal = .{ .cp = cp, .fold = flags.ignore_case } });
            },
        }
    }

    fn parseGroup(p: *Parser, flags: Flags, depth: u32) Error!?NodeIndex {
        const start = p.pos;
        p.pos += 1;
        if (!p.eat('?')) {
            const g: u32 = @intCast(p.closed.items.len);
            try p.closed.append(p.arena, false);
            return try p.finishGroup(flags, depth, start, g);
        }
        if (p.eat(':')) return try p.finishGroup(flags, depth, start, null);
        if (p.eat('#')) {
            const j = std.mem.indexOfScalarPos(u8, p.src, p.pos, ')') orelse
                return p.fail(start, "missing ), unterminated comment");
            p.pos = j + 1;
            return null;
        }
        if (p.eat('=')) return try p.finishLook(flags, depth, start, false, false);
        if (p.eat('!')) return try p.finishLook(flags, depth, start, false, true);
        if (p.eatStr("<=")) return try p.finishLook(flags, depth, start, true, false);
        if (p.eatStr("<!")) return try p.finishLook(flags, depth, start, true, true);
        if (p.eatStr("P=")) {
            const name = try p.groupName(')');
            for (p.names.items) |n| {
                if (std.mem.eql(u8, n.name, name)) {
                    if (!p.closed.items[n.group]) return p.fail(start, "cannot refer to an open group");
                    return try p.backref(n.group, flags, start);
                }
            }
            return p.fail(start + 4, "unknown group name");
        }
        if (p.eatStr("P<") or p.eat('<')) {
            const name = try p.groupName('>');
            for (p.names.items) |n| {
                if (std.mem.eql(u8, n.name, name)) return p.fail(start, "redefinition of group name");
            }
            const g: u32 = @intCast(p.closed.items.len);
            try p.closed.append(p.arena, false);
            try p.names.append(p.arena, .{ .name = name, .group = g });
            return try p.finishGroup(flags, depth, start, g);
        }
        // Inline flags: (?ims-ims:...); (?ims) is only allowed at the start.
        var f = flags;
        const flag_start = p.pos;
        var on: u8 = 0;
        while (p.peek()) |ch| {
            if (!applyFlag(&f, ch, true)) break;
            on |= flagBit(ch);
            p.pos += 1;
        }
        if (p.eat('-')) {
            var off: u8 = 0;
            while (p.peek()) |ch| {
                if (!applyFlag(&f, ch, false)) break;
                off |= flagBit(ch);
                p.pos += 1;
            }
            if (off == 0) return p.fail(p.pos, "missing flag");
            if (on & off != 0) return p.fail(flag_start, "bad inline flags: flag turned on and off");
            if (!p.eat(':')) return p.fail(p.pos, "missing :");
            return try p.finishGroup(f, depth, start, null);
        }
        if (p.pos > flag_start) {
            if (p.eat(':')) return try p.finishGroup(f, depth, start, null);
            if (p.peek() == ')') return p.fail(start, "global flags not at the start of the expression");
            return p.fail(p.pos, "missing -, : or )");
        }
        return p.fail(start + 1, "unknown extension");
    }

    fn finishGroup(p: *Parser, flags: Flags, depth: u32, start: usize, capture: ?u32) Error!NodeIndex {
        const child = try p.parseAlt(flags, depth + 1);
        if (!p.eat(')')) return p.fail(start, "missing ), unterminated subpattern");
        if (capture) |g| p.closed.items[g] = true;
        return p.add(.{ .group = .{ .child = child, .capture = capture } });
    }

    fn finishLook(p: *Parser, flags: Flags, depth: u32, start: usize, behind: bool, negate: bool) Error!NodeIndex {
        if (behind) p.in_lookbehind += 1;
        const child = try p.parseAlt(flags, depth + 1);
        if (behind) p.in_lookbehind -= 1;
        if (!p.eat(')')) return p.fail(start, "missing ), unterminated subpattern");
        var width: u32 = 0;
        if (behind) {
            const w = p.fixedWidth(child) orelse return p.fail(start, "look-behind requires fixed-width pattern");
            width = std.math.cast(u32, w) orelse return p.fail(start, "look-behind requires fixed-width pattern");
        }
        return p.add(.{ .look = .{ .child = child, .behind = behind, .negate = negate, .width = width } });
    }

    fn groupName(p: *Parser, term: u8) Error![]const u8 {
        const s = p.pos;
        const j = std.mem.indexOfScalarPos(u8, p.src, s, term) orelse return p.fail(s, "missing group name terminator");
        const name = p.src[s..j];
        if (name.len == 0) return p.fail(s, "missing group name");
        const ok = (std.ascii.isAlphabetic(name[0]) or name[0] == '_') and for (name) |ch| {
            if (!std.ascii.isAlphanumeric(ch) and ch != '_') break false;
        } else true;
        if (!ok) return p.fail(s, "bad character in group name");
        p.pos = j + 1;
        return name;
    }

    fn backref(p: *Parser, g: u32, flags: Flags, at: usize) Error!NodeIndex {
        if (p.in_lookbehind > 0) return p.fail(at, "cannot refer to a group in a look-behind");
        return p.add(.{ .backref = .{ .group = g, .fold = flags.ignore_case } });
    }

    fn parseEscape(p: *Parser, flags: Flags) Error!NodeIndex {
        const start = p.pos;
        p.pos += 1;
        const c = p.peek() orelse return p.fail(start, "bad escape (end of pattern)");
        switch (c) {
            'A' => return p.assertNode(.text_start),
            'Z', 'z' => return p.assertNode(.text_end),
            'b' => return p.assertNode(.word_boundary),
            'B' => return p.assertNode(.not_word_boundary),
            'd', 'D', 's', 'S', 'w', 'W' => {
                p.pos += 1;
                var b: CharClass.Builder = .{};
                b.builtins.insert(builtinFor(c));
                try p.classes.append(p.arena, try b.finish(p.arena, false, false));
                return p.add(.{ .class = @intCast(p.classes.items.len - 1) });
            },
            '1'...'9' => {
                p.pos += 1;
                var n: u32 = c - '0';
                if (p.peek()) |d1| if (std.ascii.isDigit(d1)) {
                    const d2 = if (p.pos + 1 < p.src.len) p.src[p.pos + 1] else 0;
                    if (isOctal(c) and isOctal(d1) and isOctal(d2)) {
                        p.pos += 2;
                        const v = (@as(u32, c - '0') << 6) | (@as(u32, d1 - '0') << 3) | (d2 - '0');
                        if (v > 0o377) return p.fail(start, "octal escape value outside of range 0-0o377");
                        return p.add(.{ .literal = .{ .cp = @intCast(v), .fold = flags.ignore_case } });
                    }
                    p.pos += 1;
                    n = n * 10 + (d1 - '0');
                };
                if (n >= p.closed.items.len) return p.fail(start, "invalid group reference");
                if (!p.closed.items[n]) return p.fail(start, "cannot refer to an open group");
                return p.backref(n, flags, start);
            },
            else => {
                const cp = try p.escapeValue(start, false);
                return p.add(.{ .literal = .{ .cp = cp, .fold = flags.ignore_case } });
            },
        }
    }

    fn assertNode(p: *Parser, a: Assert) Error!NodeIndex {
        p.pos += 1;
        return p.add(.{ .assert = a });
    }

    /// Value of a character escape; `p.pos` is just after the backslash.
    fn escapeValue(p: *Parser, start: usize, in_class: bool) Error!u21 {
        const c = p.src[p.pos];
        p.pos += 1;
        switch (c) {
            'a' => return 7,
            'b' => if (in_class) return 8,
            'f' => return 12,
            'n' => return '\n',
            'r' => return '\r',
            't' => return '\t',
            'v' => return 11,
            'x' => return p.hexEscape(start, 2),
            'u' => return p.hexEscape(start, 4),
            'U' => return p.hexEscape(start, 8),
            '0'...'7' => if (in_class or c == '0') {
                var v: u32 = c - '0';
                var k: usize = 1;
                while (k < 3) : (k += 1) {
                    const d = p.peek() orelse break;
                    if (!isOctal(d)) break;
                    v = v * 8 + (d - '0');
                    p.pos += 1;
                }
                if (v > 0o377) return p.fail(start, "octal escape value outside of range 0-0o377");
                return @intCast(v);
            },
            else => {},
        }
        if (std.ascii.isAlphanumeric(c)) return p.fail(start, "bad escape");
        p.pos -= 1;
        return p.nextCodepoint();
    }

    fn hexEscape(p: *Parser, start: usize, n: usize) Error!u21 {
        if (p.pos + n > p.src.len) return p.fail(start, "incomplete escape");
        for (p.src[p.pos .. p.pos + n]) |h| if (!std.ascii.isHex(h)) return p.fail(start, "incomplete escape");
        const v = std.fmt.parseInt(u32, p.src[p.pos .. p.pos + n], 16) catch unreachable;
        if (v > 0x10FFFF) return p.fail(start, "bad escape");
        p.pos += n;
        return @intCast(v);
    }

    fn parseClass(p: *Parser, flags: Flags) Error!NodeIndex {
        const start = p.pos;
        p.pos += 1;
        const negated = p.eat('^');
        var b: CharClass.Builder = .{};
        var first = true;
        while (true) {
            const c = p.peek() orelse return p.fail(start, "unterminated character set");
            if (c == ']' and !first) {
                p.pos += 1;
                break;
            }
            first = false;
            const item_start = p.pos;
            const lo = try p.classAtom(&b);
            if (p.peek() == '-' and p.pos + 1 < p.src.len and p.src[p.pos + 1] != ']') {
                p.pos += 1;
                const hi = try p.classAtom(&b);
                const l = lo orelse return p.fail(item_start, "bad character range");
                const h = hi orelse return p.fail(item_start, "bad character range");
                if (l > h) return p.fail(item_start, "bad character range");
                try b.addRange(p.arena, l, h);
            } else if (lo) |l| {
                try b.addRange(p.arena, l, l);
            }
        }
        try p.classes.append(p.arena, try b.finish(p.arena, negated, flags.ignore_case));
        return p.add(.{ .class = @intCast(p.classes.items.len - 1) });
    }

    /// A class member: a code point, or null after adding a class escape.
    fn classAtom(p: *Parser, b: *CharClass.Builder) Error!?u21 {
        if (p.peek() != '\\') return p.nextCodepoint();
        const start = p.pos;
        p.pos += 1;
        const c = p.peek() orelse return p.fail(start, "unterminated character set");
        switch (c) {
            'd', 'D', 's', 'S', 'w', 'W' => {
                p.pos += 1;
                b.builtins.insert(builtinFor(c));
                return null;
            },
            else => return try p.escapeValue(start, true),
        }
    }

    /// Width in code points of every match of `n`, or null if it varies.
    fn fixedWidth(p: *Parser, n: NodeIndex) ?u64 {
        return switch (p.nodes.items[n]) {
            .empty, .assert, .look => 0,
            .literal, .any, .class => 1,
            .group => |g| p.fixedWidth(g.child),
            .concat => |items| blk: {
                var w: u64 = 0;
                for (items) |i| w += p.fixedWidth(i) orelse break :blk null;
                break :blk w;
            },
            .alt => |items| blk: {
                const w = p.fixedWidth(items[0]) orelse break :blk null;
                for (items[1..]) |i| {
                    const wi = p.fixedWidth(i) orelse break :blk null;
                    if (wi != w) break :blk null;
                }
                break :blk w;
            },
            .repeat => |r| if (r.max != null and r.max.? == r.min)
                if (p.fixedWidth(r.child)) |w| std.math.mul(u64, w, r.min) catch null else null
            else
                null,
            .backref => null,
        };
    }
};

fn builtinFor(c: u8) CharClass.Builtin {
    return switch (c) {
        'd' => .digit,
        'D' => .not_digit,
        's' => .space,
        'S' => .not_space,
        'w' => .word,
        else => .not_word,
    };
}

fn isOctal(c: u8) bool {
    return c >= '0' and c <= '7';
}

fn flagBit(c: u8) u8 {
    return switch (c) {
        'i' => 1,
        'm' => 2,
        's' => 4,
        else => 0,
    };
}

fn applyFlag(f: *Flags, c: u8, on: bool) bool {
    switch (c) {
        'i' => f.ignore_case = on,
        'm' => f.multiline = on,
        's' => f.dot_all = on,
        else => return false,
    }
    return true;
}

test "parse errors" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const bad = [_][2][]const u8{
        .{ "*a", "nothing to repeat" },
        .{ "a**", "multiple repeat" },
        .{ "(a", "missing ), unterminated subpattern" },
        .{ "a)", "unbalanced parenthesis" },
        .{ "[a", "unterminated character set" },
        .{ "[z-a]", "bad character range" },
        .{ "\\q", "bad escape" },
        .{ "(a)\\2", "invalid group reference" },
        .{ "(a\\1)", "cannot refer to an open group" },
        .{ "(?<=a+)", "look-behind requires fixed-width pattern" },
        .{ "(?<=a|bc)", "look-behind requires fixed-width pattern" },
        .{ "a{3,2}", "min repeat greater than max repeat" },
        .{ "a(?i)", "global flags not at the start of the expression" },
        .{ "\\b*", "nothing to repeat" },
        .{ "a*+", "possessive quantifiers are not supported" },
    };
    for (bad) |case| {
        var d: Diagnostics = .{};
        try std.testing.expectError(error.InvalidPattern, parse(arena, case[0], .{}, &d));
        try std.testing.expectEqualStrings(case[1], d.message);
    }
    const good = [_][]const u8{ "a{", "a{}", "a{,}", "a{x}", "[]a]", "[^]a]", "[a-]", "(?i)a(?-i:b)", "(?P<x>a)(?P=x)", "\\0\\101[\\1]", "(?<=ab|cd)x", "(?#c)a" };
    for (good) |pat| _ = try parse(arena, pat, .{}, null);
}
