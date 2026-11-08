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
    test_step.dependOn(&b.addSystemCommand(&.{ "sh", "tools/provenance/check.sh" }).step);

    // the stage libraries in dsp/lib, run in x17's emulator against ref/dsp
    const x17 = b.dependency("x17", .{ .target = target, .optimize = optimize });
    const dsp_t = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("dsp/tests.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "ref", .module = ref_mod },
            .{ .name = "asm", .module = x17.module("asm") },
            .{ .name = "emu", .module = x17.module("emu") },
            .{ .name = "host", .module = x17.module("host") },
        },
    }) });
    // the access units aacdec dumped, for aac_packet's test
    for ([_][]const u8{ "tone.aac_at", "sweep.ff_tns", "pink.ff_pns", "pink.ff_is", "clicks.aac_at" }) |name| {
        const file = b.fmt("{s}.pkts", .{name});
        dsp_t.root_module.addAnonymousImport(file, .{ .root_source_file = b.path(b.fmt("testdata/aac/{s}", .{file})) });
    }
    // the packets alacdec dumped, for alac_packet's test
    for ([_][]const u8{ "mono.at", "tone.at", "white24.at", "clicks.c0.ff", "clicks.o30.ff", "mono.at.int", "tone.at.int" }) |name| {
        const file = b.fmt("{s}.pkts", .{name});
        dsp_t.root_module.addAnonymousImport(file, .{ .root_source_file = b.path(b.fmt("testdata/alac/{s}", .{file})) });
    }
    test_step.dependOn(&b.addRunArtifact(dsp_t).step);

    // ALAC on sm1, played through x17's host model
    const dspplay = b.addExecutable(.{
        .name = "dspplay",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/dspplay/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "ref", .module = ref_mod },
                .{ .name = "dsp", .module = b.createModule(.{
                    .root_source_file = b.path("dsp/player.zig"),
                    .target = target,
                    .optimize = optimize,
                    .imports = &.{
                        .{ .name = "ref", .module = ref_mod },
                        .{ .name = "asm", .module = x17.module("asm") },
                        .{ .name = "emu", .module = x17.module("emu") },
                        .{ .name = "host", .module = x17.module("host") },
                    },
                }) },
            },
        }),
    });
    b.installArtifact(dspplay);

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

    const aacdec = b.addExecutable(.{
        .name = "aacdec",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/aacdec/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "ref", .module = ref_mod }},
        }),
    });
    b.installArtifact(aacdec);
}
