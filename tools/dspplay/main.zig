//! Plays the ALAC track of an .m4a through sm1: each packet runs alac_packet (dsp/lib/alac.sm)
//! in x17's emulator under its host model, and the drained PCM goes to stdout as s16le stereo
//! (a mono track on both channels).
//!
//!     dspplay in.m4a | ffplay -f s16le -ar 44100 -ac 2 -
//!     dspplay in.m4a --check
//!
//! --check writes no audio: it decodes every packet with ref/dsp/alac too and reports each
//! frame whose samples differ, then a summary; it exits 1 on any difference.
const std = @import("std");
const ref = @import("ref");
const dsp = @import("dsp");

const mp4 = ref.alac.mp4;

const Diff = struct { at: usize, want: i32, got: i16 };

fn firstDiff(want: []const i32, got: []const i16) ?Diff {
    if (want.len != got.len) return .{ .at = @min(want.len, got.len), .want = 0, .got = 0 };
    for (want, got, 0..) |w, g, i| if (@as(i32, g) != w) return .{ .at = i, .want = w, .got = g };
    return null;
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const check = args.len == 3 and std.mem.eql(u8, args[2], "--check");
    if (args.len < 2 or (args.len == 3 and !check) or args.len > 3) {
        std.debug.print("usage: dspplay in.m4a [--check]\n", .{});
        std.process.exit(2);
    }
    const file = try std.Io.Dir.cwd().readFileAlloc(io, args[1], gpa, .limited(1 << 31));
    defer gpa.free(file);
    var packets = try mp4.Packets.init(file);
    const cfg = try ref.alac.config.parse(packets.t.cookie);
    const nch: usize = cfg.channels;
    std.debug.print("{s}: {d} packets, {d} ch, {d} bit, {d} Hz, frame {d}\n", .{ args[1], packets.t.count, nch, cfg.bit_depth, cfg.sample_rate, cfg.frame_length });
    if (!dsp.supported(cfg)) {
        std.debug.print("alac_packet decodes 16-bit, 1 or 2 channel tracks with frames up to 4096\n", .{});
        std.process.exit(1);
    }
    if (!check) std.debug.print("play: | ffplay -f s16le -ar {d} -ac 2 -\n", .{cfg.sample_rate});

    const prog = try dsp.program(gpa);
    defer gpa.free(prog);
    var player = try dsp.Player.init(gpa, prog, cfg);
    defer player.deinit();
    var twin = try ref.dsp.alac.decoder.Decoder.init(gpa, cfg);
    defer twin.deinit();
    const want = try gpa.alloc(i32, @as(usize, cfg.frame_length) * nch);
    defer gpa.free(want);
    const silence = try gpa.alloc(i16, @as(usize, cfg.frame_length) * nch);
    defer gpa.free(silence);
    @memset(silence, 0);

    var obuf: [1 << 16]u8 = undefined;
    var ow = std.Io.File.stdout().writer(io, &obuf);
    const w = &ow.interface;

    var k: usize = 0;
    var bad: usize = 0;
    var failed: usize = 0;
    var max_bundles: usize = 0;
    var total_bundles: u64 = 0;
    while (try packets.next()) |pkt| : (k += 1) {
        const pcm = player.feed(pkt) catch |e| blk: {
            if (failed < 5) std.debug.print("packet {d}: {s} (status {d})\n", .{ k, @errorName(e), player.status });
            failed += 1;
            break :blk silence;
        };
        max_bundles = @max(max_bundles, player.bundles);
        total_bundles += player.bundles;
        if (check) {
            const n = try twin.decode(pkt, want);
            if (firstDiff(want[0 .. n * nch], pcm)) |d| {
                if (bad < 20) std.debug.print("frame {d}: sample {d} (ch {d}) want {d} got {d}\n", .{ k, d.at / nch, d.at % nch, d.want, d.got });
                bad += 1;
            }
            continue;
        }
        for (0..pcm.len / nch) |i| for (0..2) |c| {
            try w.writeInt(i16, pcm[i * nch + @min(c, nch - 1)], .little);
        };
    }
    try w.flush();
    std.debug.print("{d} packets, {d} failed, worst {d} bundles, mean {d}\n", .{ k, failed, max_bundles, if (k == 0) 0 else total_bundles / k });
    if (check) {
        std.debug.print("{d} of {d} frames differ from ref/dsp/alac\n", .{ bad, k });
        if (bad != 0 or failed != 0) std.process.exit(1);
    }
}
