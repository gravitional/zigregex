const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Consumers: b.dependency("zigregex", .{}).module("regex").
    const regex = b.addModule("regex", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Driver for the differential tests against Python (tools/regex_diff.py).
    const probe = b.addExecutable(.{
        .name = "regex-probe",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/regex_probe.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "regex", .module = regex }},
        }),
    });
    const probe_step = b.step("probe", "Build tools/regex_probe.zig");
    probe_step.dependOn(&b.addInstallArtifact(probe, .{}).step);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = regex })).step);
}
