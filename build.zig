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
            .{ .name = "image", .module = x17.module("image") },
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
    // whole MP3 files, cut into frames by the test, for the MP3 program's tests
    for ([_][]const u8{ "clicks.vbr.mp3", "mono.cbr.mp3", "clicks.m2.mp3", "clicks.m25_8k.mp3", "heavy.cbr.mp3" }) |file| {
        dsp_t.root_module.addAnonymousImport(file, .{ .root_source_file = b.path(b.fmt("testdata/{s}", .{file})) });
    }
    test_step.dependOn(&b.addRunArtifact(dsp_t).step);

    // ALAC on sm1, played through x17's host model
    const dspplay = b.addExecutable(.{
        .name = "dspplay",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/dspplay/main.zig"),
            .target = target,
            // the emulator is the hot path: Debug is far below real time
            .optimize = .ReleaseFast,
            .imports = &.{
                .{ .name = "ref", .module = ref_mod },
                .{ .name = "dsp", .module = b.createModule(.{
                    .root_source_file = b.path("dsp/player.zig"),
                    .target = target,
                    .optimize = .ReleaseFast,
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

    // aac_packet as an x17 image: tools/aacimage writes the source, x17 image assembles it
    const aacimage = b.addExecutable(.{
        .name = "aacimage",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/aacimage/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "dsp", .module = dspplay.root_module.import_table.get("dsp").? }},
        }),
    });
    const gen = b.addRunArtifact(aacimage);
    gen.addDirectoryArg(b.path("dsp/lib"));
    const img = b.addRunArtifact(x17.artifact("x17"));
    img.addArgs(&.{ "image", "-o" });
    const x17i = img.addOutputFileArg("aac.x17i");
    img.addArg("-g");
    const dbg = img.addOutputFileArg("aac.json");
    img.addFileArg(gen.captureStdOut(.{ .basename = "aac.sm" }));
    const sm1 = b.step("sm1", "Build zig-out/sm1/aac.x17i and mp3.x17i, the decoders' x17 images");
    sm1.dependOn(&b.addInstallFileWithDir(x17i, .{ .custom = "sm1" }, "aac.x17i").step);
    sm1.dependOn(&b.addInstallFileWithDir(dbg, .{ .custom = "sm1" }, "aac.json").step);

    // mp3_packet's image, the same way: tools/mp3image writes the source
    const mp3image = b.addExecutable(.{
        .name = "mp3image",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/mp3image/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "dsp", .module = dspplay.root_module.import_table.get("dsp").? }},
        }),
    });
    const mgen = b.addRunArtifact(mp3image);
    mgen.addDirectoryArg(b.path("dsp/lib"));
    const mimg = b.addRunArtifact(x17.artifact("x17"));
    mimg.addArgs(&.{ "image", "-o" });
    const mx17i = mimg.addOutputFileArg("mp3.x17i");
    mimg.addArg("-g");
    const mdbg = mimg.addOutputFileArg("mp3.json");
    mimg.addFileArg(mgen.captureStdOut(.{ .basename = "mp3.sm" }));
    sm1.dependOn(&b.addInstallFileWithDir(mx17i, .{ .custom = "sm1" }, "mp3.x17i").step);
    sm1.dependOn(&b.addInstallFileWithDir(mdbg, .{ .custom = "sm1" }, "mp3.json").step);

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
