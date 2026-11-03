//! AST → byte code for the backtracking VM (vm.zig).

const std = @import("std");
const Allocator = std.mem.Allocator;
const parse = @import("parse.zig");
const unicode = @import("unicode.zig");
const Node = parse.Node;
const NodeIndex = parse.NodeIndex;

pub const Pc = u32;

pub const Inst = union(enum) {
    /// Match one code point.
    char: u21,
    /// Match one code point whose case-fold canonical member is this one.
    char_fold: u21,
    /// Any code point except `\n`.
    any,
    /// Any code point.
    any_all,
    class: u32,
    /// Continue at `[0]`; on failure, resume at `[1]`.
    split: [2]Pc,
    jmp: Pc,
    /// Record the position in capture slot n (group n/2, start or end).
    save: u32,
    assert: parse.Assert,
    /// Lookaround with body at pc+1 ending in `look_end`; continue at `next`.
    look: struct { next: Pc, behind: bool, negate: bool },
    /// Move back n code points (start of a look-behind body).
    back: u32,
    look_end,
    backref: struct { group: u32, fold: bool },
    /// Record the position in loop register n.
    mark: u32,
    /// Leave a loop whose body matched the empty string: if the position
    /// equals loop register `reg`, jump to `exit`.
    progress: struct { reg: u32, exit: Pc },
    match,
};

pub const Program = struct {
    insts: []const Inst,
    /// Number of loop registers used by `mark` / `progress`.
    regs: u32,
};

pub const Error = error{ PatternTooLarge, OutOfMemory };

/// Upper bound on program size; counted repetitions are expanded, so
/// `(a{1000}){1000}` would otherwise produce a million instructions.
pub const max_insts = 1 << 20;

pub fn compile(gpa: Allocator, ast: parse.Ast) Error!Program {
    var c: Compiler = .{ .gpa = gpa, .ast = ast };
    errdefer c.insts.deinit(gpa);
    _ = try c.emit(.{ .save = 0 });
    try c.node(ast.root);
    _ = try c.emit(.{ .save = 1 });
    _ = try c.emit(.match);
    return .{ .insts = try c.insts.toOwnedSlice(gpa), .regs = c.regs };
}

const Compiler = struct {
    gpa: Allocator,
    ast: parse.Ast,
    insts: std.ArrayList(Inst) = .empty,
    regs: u32 = 0,

    fn pc(c: *Compiler) Pc {
        return @intCast(c.insts.items.len);
    }

    fn emit(c: *Compiler, inst: Inst) Error!Pc {
        if (c.insts.items.len >= max_insts) return error.PatternTooLarge;
        try c.insts.append(c.gpa, inst);
        return c.pc() - 1;
    }

    fn node(c: *Compiler, n: NodeIndex) Error!void {
        switch (c.ast.nodes[n]) {
            .empty => {},
            .literal => |l| _ = try c.emit(if (l.fold) .{ .char_fold = unicode.canon(l.cp) } else .{ .char = l.cp }),
            .any => |a| _ = try c.emit(if (a.dot_all) .any_all else .any),
            .class => |k| _ = try c.emit(.{ .class = k }),
            .assert => |a| _ = try c.emit(.{ .assert = a }),
            .backref => |b| _ = try c.emit(.{ .backref = .{ .group = b.group, .fold = b.fold } }),
            .group => |g| {
                if (g.capture) |k| _ = try c.emit(.{ .save = 2 * k });
                try c.node(g.child);
                if (g.capture) |k| _ = try c.emit(.{ .save = 2 * k + 1 });
            },
            .concat => |items| for (items) |i| try c.node(i),
            .alt => |items| {
                var jumps: std.ArrayList(Pc) = .empty;
                defer jumps.deinit(c.gpa);
                for (items, 0..) |item, k| {
                    if (k + 1 == items.len) {
                        try c.node(item);
                        break;
                    }
                    const s = try c.emit(.{ .split = .{ 0, 0 } });
                    try c.node(item);
                    try jumps.append(c.gpa, try c.emit(.{ .jmp = 0 }));
                    c.insts.items[s] = .{ .split = .{ s + 1, c.pc() } };
                }
                for (jumps.items) |j| c.insts.items[j] = .{ .jmp = c.pc() };
            },
            .repeat => |r| try c.repeat(r.child, r.min, r.max, r.greedy),
            .look => |l| {
                const at = try c.emit(.{ .look = .{ .next = 0, .behind = l.behind, .negate = l.negate } });
                if (l.behind) _ = try c.emit(.{ .back = l.width });
                try c.node(l.child);
                _ = try c.emit(.look_end);
                c.insts.items[at].look.next = c.pc();
            },
        }
    }

    fn repeat(c: *Compiler, child: NodeIndex, min: u32, max: ?u32, greedy: bool) Error!void {
        for (0..min) |_| try c.node(child);
        const m = max orelse {
            // L0: split L1, END   (lazy: END, L1)
            // L1: [mark r] child [progress r -> END] jmp L0
            const nullable = c.canBeEmpty(child);
            const l0 = try c.emit(.{ .split = .{ 0, 0 } });
            const r = c.regs;
            if (nullable) {
                c.regs += 1;
                _ = try c.emit(.{ .mark = r });
            }
            try c.node(child);
            const prog = if (nullable) try c.emit(.{ .progress = .{ .reg = r, .exit = 0 } }) else 0;
            _ = try c.emit(.{ .jmp = l0 });
            const end = c.pc();
            c.insts.items[l0] = .{ .split = if (greedy) .{ l0 + 1, end } else .{ end, l0 + 1 } };
            if (nullable) c.insts.items[prog].progress.exit = end;
            return;
        };
        // Optional copies, all exiting to the same END:
        //   split s+1, END; child; split ..., END; child; ... END:
        // A copy that matches the empty string ends the repetition (via
        // `progress`), as in the unbounded case; without this, failing after
        // `(a?){0,30}` would try every subset of empty copies.
        var splits: std.ArrayList(Pc) = .empty;
        defer splits.deinit(c.gpa);
        var exits: std.ArrayList(Pc) = .empty;
        defer exits.deinit(c.gpa);
        const nullable = m > min and c.canBeEmpty(child);
        const r = c.regs;
        if (nullable) c.regs += 1;
        for (min..m) |_| {
            try splits.append(c.gpa, try c.emit(.{ .split = .{ 0, 0 } }));
            if (nullable) _ = try c.emit(.{ .mark = r });
            try c.node(child);
            if (nullable) try exits.append(c.gpa, try c.emit(.{ .progress = .{ .reg = r, .exit = 0 } }));
        }
        const end = c.pc();
        for (splits.items) |s| c.insts.items[s] = .{ .split = if (greedy) .{ s + 1, end } else .{ end, s + 1 } };
        for (exits.items) |e| c.insts.items[e].progress.exit = end;
    }

    fn canBeEmpty(c: *Compiler, n: NodeIndex) bool {
        return switch (c.ast.nodes[n]) {
            .empty, .assert, .look, .backref => true,
            .literal, .any, .class => false,
            .group => |g| c.canBeEmpty(g.child),
            .concat => |items| for (items) |i| {
                if (!c.canBeEmpty(i)) break false;
            } else true,
            .alt => |items| for (items) |i| {
                if (c.canBeEmpty(i)) break true;
            } else false,
            .repeat => |r| r.min == 0 or c.canBeEmpty(r.child),
        };
    }
};
