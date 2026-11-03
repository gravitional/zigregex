//! Driver for tools/regex_diff.py: reads cases from stdin, one per line,
//!
//!     <flags>\t<pattern as hex>\t<subject as hex>
//!
//! where <flags> is a subset of "ims" or "-", and prints one line per case:
//! `E` (invalid pattern), `L` (pattern too large), `X` (match limit), or the
//! matches of a findall-style scan as `start,end[,gstart,gend...];...` in
//! byte offsets, with -1 for groups that did not participate.

const std = @import("std");
const Io = std.Io;
const regex = @import("regex");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    var in_buf: [1 << 16]u8 = undefined;
    var in_file: Io.File.Reader = .init(.stdin(), io, &in_buf);
    const in = &in_file.interface;
    var out_buf: [1 << 16]u8 = undefined;
    var out_file: Io.File.Writer = .init(.stdout(), io, &out_buf);
    const out = &out_file.interface;

    while (try in.takeDelimiter('\n')) |line| {
        var fields = std.mem.splitScalar(u8, line, '\t');
        const flag_text = fields.next() orelse return error.BadInput;
        const pattern = try unhex(gpa, fields.next() orelse return error.BadInput);
        defer gpa.free(pattern);
        const subject = try unhex(gpa, fields.next() orelse return error.BadInput);
        defer gpa.free(subject);

        var flags: regex.Flags = .{};
        for (flag_text) |c| switch (c) {
            'i' => flags.ignore_case = true,
            'm' => flags.multiline = true,
            's' => flags.dot_all = true,
            else => {},
        };
        try probe(gpa, out, pattern, subject, flags);
        try out.writeByte('\n');
    }
    try out.flush();
}

fn probe(gpa: std.mem.Allocator, out: *Io.Writer, pattern: []const u8, subject: []const u8, flags: regex.Flags) !void {
    var re = regex.Regex.compile(gpa, pattern, .{ .flags = flags }) catch |e| switch (e) {
        error.InvalidPattern => return out.writeByte('E'),
        error.PatternTooLarge => return out.writeByte('L'),
        else => return e,
    };
    defer re.deinit();
    var m = try regex.Matcher.init(gpa, &re, .{ .step_limit = 2_000_000 });
    defer m.deinit();
    var it = m.iterator(subject);
    var first = true;
    while (it.next() catch return out.writeByte('X')) |hit| {
        if (!first) try out.writeByte(';');
        first = false;
        for (0..hit.groupCount()) |g| {
            if (g > 0) try out.writeByte(',');
            if (hit.span(g)) |sp| {
                try out.print("{d},{d}", .{ sp.start, sp.end });
            } else {
                try out.writeAll("-1,-1");
            }
        }
    }
}

fn unhex(gpa: std.mem.Allocator, s: []const u8) ![]u8 {
    const out = try gpa.alloc(u8, s.len / 2);
    errdefer gpa.free(out);
    _ = try std.fmt.hexToBytes(out, s);
    return out;
}
