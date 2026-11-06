const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const ref_mod = b.addModule("ref", .{
        .root_source_file = b.path("ref/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const test_step = b.step("test", "Run the reference model tests");
    const ref_t = b.addTest(.{ .root_module = ref_mod });
    test_step.dependOn(&b.addRunArtifact(ref_t).step);

    const compare = b.addExecutable(.{
        .name = "compare",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/compare/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "ref", .module = ref_mod }},
        }),
    });
    b.installArtifact(compare);

    const alacdec = b.addExecutable(.{
        .name = "alacdec",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/alacdec/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "ref", .module = ref_mod }},
        }),
    });
    b.installArtifact(alacdec);
}
