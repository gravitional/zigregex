//! Backtracking VM.
//!
//! Choice points and undo records share one explicit stack, so matching does
//! not recurse except into lookarounds (bounded by the pattern's nesting).
//! Failing pops the stack: undo records restore capture slots and loop
//! registers, and the first choice point found is resumed.

const std = @import("std");
const Allocator = std.mem.Allocator;
const compile = @import("compile.zig");
const unicode = @import("unicode.zig");
const CharClass = @import("CharClass.zig");
const Inst = compile.Inst;
const Pc = compile.Pc;

pub const unset = std.math.maxInt(usize);

pub const Error = error{ MatchLimitExceeded, OutOfMemory };

const Entry = union(enum) {
    branch: struct { pc: Pc, pos: usize },
    restore_slot: struct { slot: u32, old: usize },
    restore_reg: struct { reg: u32, old: usize },
};

pub const Vm = struct {
    insts: []const Inst,
    classes: []const CharClass,
    input: []const u8 = "",
    stack: std.ArrayList(Entry) = .empty,
    slots: []usize,
    regs: []usize,
    steps: u64 = 0,
    step_limit: u64,
    /// Reject an empty match at this position (see `Regex.search`).
    forbid_empty_at: ?usize = null,

    /// Run from `pc` at `pos`. Returns the end position, or null. On
    /// success the stack keeps the undo records of this run.
    pub fn run(vm: *Vm, gpa: Allocator, pc0: Pc, pos0: usize, origin: ?usize) Error!?usize {
        const base = vm.stack.items.len;
        const s = vm.input;
        var pc = pc0;
        var pos = pos0;
        while (true) {
            vm.steps += 1;
            if (vm.steps > vm.step_limit) return error.MatchLimitExceeded;
            const ok: bool = switch (vm.insts[pc]) {
                .char => |want| blk: {
                    if (pos >= s.len) break :blk false;
                    const d = decode(s, pos);
                    if (d.cp != want) break :blk false;
                    pos += d.len;
                    break :blk true;
                },
                .char_fold => |want| blk: {
                    if (pos >= s.len) break :blk false;
                    const d = decode(s, pos);
                    if (d.cp != want and unicode.canon(d.cp) != want) break :blk false;
                    pos += d.len;
                    break :blk true;
                },
                .any => blk: {
                    if (pos >= s.len or s[pos] == '\n') break :blk false;
                    pos += decode(s, pos).len;
                    break :blk true;
                },
                .any_all => blk: {
                    if (pos >= s.len) break :blk false;
                    pos += decode(s, pos).len;
                    break :blk true;
                },
                .class => |k| blk: {
                    if (pos >= s.len) break :blk false;
                    const d = decode(s, pos);
                    if (!vm.classes[k].matches(d.cp)) break :blk false;
                    pos += d.len;
                    break :blk true;
                },
                .split => |targets| {
                    try vm.stack.append(gpa, .{ .branch = .{ .pc = targets[1], .pos = pos } });
                    pc = targets[0];
                    continue;
                },
                .jmp => |target| {
                    pc = target;
                    continue;
                },
                .save => |slot| blk: {
                    try vm.stack.append(gpa, .{ .restore_slot = .{ .slot = slot, .old = vm.slots[slot] } });
                    vm.slots[slot] = pos;
                    break :blk true;
                },
                .mark => |reg| blk: {
                    try vm.stack.append(gpa, .{ .restore_reg = .{ .reg = reg, .old = vm.regs[reg] } });
                    vm.regs[reg] = pos;
                    break :blk true;
                },
                .progress => |p| {
                    pc = if (vm.regs[p.reg] == pos) p.exit else pc + 1;
                    continue;
                },
                .assert => |a| assert(s, pos, a),
                .back => |n| blk: {
                    var k: u32 = 0;
                    while (k < n) : (k += 1) {
                        if (pos == 0) break :blk false;
                        pos = prevStart(s, pos);
                    }
                    break :blk true;
                },
                .backref => |b| blk: {
                    const start = vm.slots[2 * b.group];
                    const end = vm.slots[2 * b.group + 1];
                    if (start == unset or end == unset) break :blk false;
                    const e = matchBackref(s, pos, s[start..end], b.fold) orelse break :blk false;
                    pos = e;
                    break :blk true;
                },
                .look => |l| blk: {
                    const mark = vm.stack.items.len;
                    const matched = try vm.run(gpa, pc + 1, pos, if (l.behind) pos else null) != null;
                    if (matched and !l.negate) {
                        // Keep the captures set inside, and their undo records,
                        // but drop the lookaround's choice points: it is atomic.
                        var n = mark;
                        for (vm.stack.items[mark..]) |e| switch (e) {
                            .branch => {},
                            else => {
                                vm.stack.items[n] = e;
                                n += 1;
                            },
                        };
                        vm.stack.shrinkRetainingCapacity(n);
                    } else if (matched) {
                        vm.unwind(mark);
                    }
                    if (matched == l.negate) break :blk false;
                    pc = l.next;
                    continue;
                },
                .look_end => {
                    // A look-behind body must end where the assertion started.
                    if (origin == null or pos == origin.?) return pos;
                    if (vm.backtrack(base, &pc, &pos)) continue;
                    return null;
                },
                .match => {
                    if (vm.forbid_empty_at == null or pos != vm.forbid_empty_at.? or pos != pos0) return pos;
                    if (vm.backtrack(base, &pc, &pos)) continue;
                    return null;
                },
            };
            if (ok) {
                pc += 1;
            } else if (!vm.backtrack(base, &pc, &pos)) {
                return null;
            }
        }
    }

    /// Pop to the most recent choice point above `base`, undoing as we go.
    fn backtrack(vm: *Vm, base: usize, pc: *Pc, pos: *usize) bool {
        while (vm.stack.items.len > base) {
            switch (vm.stack.pop().?) {
                .branch => |b| {
                    pc.* = b.pc;
                    pos.* = b.pos;
                    return true;
                },
                .restore_slot => |r| vm.slots[r.slot] = r.old,
                .restore_reg => |r| vm.regs[r.reg] = r.old,
            }
        }
        return false;
    }

    /// Undo everything above `base`.
    fn unwind(vm: *Vm, base: usize) void {
        while (vm.stack.items.len > base) {
            switch (vm.stack.pop().?) {
                .branch => {},
                .restore_slot => |r| vm.slots[r.slot] = r.old,
                .restore_reg => |r| vm.regs[r.reg] = r.old,
            }
        }
    }
};

const Decoded = struct { cp: u21, len: u3 };

/// Decode one code point; invalid UTF-8 is read as single bytes.
pub fn decode(s: []const u8, i: usize) Decoded {
    const c = s[i];
    if (c < 0x80) return .{ .cp = c, .len = 1 };
    const len = std.unicode.utf8ByteSequenceLength(c) catch return .{ .cp = c, .len = 1 };
    if (i + len > s.len) return .{ .cp = c, .len = 1 };
    const cp = std.unicode.utf8Decode(s[i .. i + len]) catch return .{ .cp = c, .len = 1 };
    return .{ .cp = cp, .len = len };
}

/// Start of the code point that ends at `i` (i > 0).
pub fn prevStart(s: []const u8, i: usize) usize {
    var j = i - 1;
    while (j > 0 and i - j < 4 and s[j] & 0xC0 == 0x80) j -= 1;
    if (s[j] & 0xC0 == 0x80) return i - 1;
    const d = decode(s, j);
    return if (j + d.len == i) j else i - 1;
}

fn wordBefore(s: []const u8, pos: usize) bool {
    return pos > 0 and unicode.isWord(decode(s, prevStart(s, pos)).cp);
}

fn wordAt(s: []const u8, pos: usize) bool {
    return pos < s.len and unicode.isWord(decode(s, pos).cp);
}

fn assert(s: []const u8, pos: usize, a: @import("parse.zig").Assert) bool {
    return switch (a) {
        .text_start => pos == 0,
        .line_start => pos == 0 or s[pos - 1] == '\n',
        .text_end => pos == s.len,
        .text_end_newline => pos == s.len or (pos + 1 == s.len and s[pos] == '\n'),
        .line_end => pos == s.len or s[pos] == '\n',
        // Python 3.14: `\B` matches the empty string (it did not before).
        .word_boundary => wordBefore(s, pos) != wordAt(s, pos),
        .not_word_boundary => wordBefore(s, pos) == wordAt(s, pos),
    };
}

fn matchBackref(s: []const u8, pos: usize, text: []const u8, fold: bool) ?usize {
    if (!fold) {
        return if (std.mem.startsWith(u8, s[pos..], text)) pos + text.len else null;
    }
    var i: usize = 0;
    var p = pos;
    while (i < text.len) {
        if (p >= s.len) return null;
        const a = decode(text, i);
        const b = decode(s, p);
        if (a.cp != b.cp and unicode.canon(a.cp) != unicode.canon(b.cp)) return null;
        i += a.len;
        p += b.len;
    }
    return p;
}
