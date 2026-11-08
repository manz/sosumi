//! Plays the ALAC or AAC track of an .m4a, or an ADTS .aac stream, through sm1: each packet runs
//! alac_packet (dsp/lib/alac.sm) under x17's host model, or aac_packet (dsp/lib/aac.sm) in its
//! emulator, and the PCM goes to stdout as s16le stereo (a mono track on both channels).
//!
//!     dspplay in.m4a | ffplay -nodisp -autoexit -f s16le -ar 44100 -ch_layout stereo -
//!     dspplay in.m4a --check
//!
//! One emulator, packets in order, as the device runs them. The summary gives the device's
//! speed from the bundles run, at 37.4 ns a bundle (x17 handbook §1): below 1x real time the
//! program is too slow for the chip, and the emulator, about as fast, stutters with it.
//!
//! --check writes no audio: it decodes every packet with the ref/dsp twin too and reports each
//! frame whose samples differ, then a summary; it exits 1 on any difference.
const std = @import("std");
const ref = @import("ref");
const dsp = @import("dsp");

const mp4 = ref.alac.mp4;

const bundle_ns = 37.4;

/// One packet's PCM as s16le stereo, a mono channel on both sides.
fn writeStereo(w: *std.Io.Writer, pcm: []const i16, nch: usize) !void {
    for (0..pcm.len / nch) |i| for (0..2) |c| {
        try w.writeInt(i16, pcm[i * nch + @min(c, nch - 1)], .little);
    };
}

/// What a run counts, and the device's speed from it.
const Tally = struct {
    packets: usize = 0,
    failed: usize = 0,
    bad: usize = 0,
    frames: u64 = 0,
    bundles: u64 = 0,
    worst: usize = 0,
    worst_frames: usize = 0,

    fn add(self: *Tally, bundles: usize, frames: usize) void {
        self.packets += 1;
        self.bundles += bundles;
        self.frames += frames;
        if (bundles > self.worst) {
            self.worst = bundles;
            self.worst_frames = frames;
        }
    }

    fn report(self: *const Tally, rate: u32, check: bool, twin: []const u8) void {
        const n = self.packets;
        std.debug.print("{d} packets, {d} failed, worst {d} bundles, mean {d}\n", .{ n, self.failed, self.worst, if (n == 0) 0 else self.bundles / n });
        if (self.bundles != 0) {
            const audio = @as(f64, @floatFromInt(self.frames)) / @as(f64, @floatFromInt(rate));
            const chip = @as(f64, @floatFromInt(self.bundles)) * bundle_ns * 1e-9;
            const per = @as(f64, @floatFromInt(self.worst_frames)) / @as(f64, @floatFromInt(rate)) / (bundle_ns * 1e-9);
            std.debug.print("sm1: {d:.2}x real time ({d:.1} s of audio in {d:.1} s); real time allows {d:.0} bundles for the worst packet\n", .{ audio / chip, audio, chip, per });
        }
        if (check) {
            std.debug.print("{d} of {d} frames differ from {s}\n", .{ self.bad, n, twin });
            if (self.bad != 0 or self.failed != 0) std.process.exit(1);
        }
    }
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const check = args.len == 3 and std.mem.eql(u8, args[2], "--check");
    if (args.len < 2 or (args.len == 3 and !check) or args.len > 3) {
        std.debug.print("usage: dspplay in.m4a|in.aac [--check]\n", .{});
        std.process.exit(2);
    }
    const file = try std.Io.Dir.cwd().readFileAlloc(io, args[1], gpa, .limited(1 << 31));
    defer gpa.free(file);

    var obuf: [1 << 16]u8 = undefined;
    var ow = std.Io.File.stdout().writer(io, &obuf);
    const w = &ow.interface;
    defer w.flush() catch {};

    if (ref.aac.adts.parse(file)) |hd| {
        var u: Units = .{ .adts = .{ .file = file } };
        return playAac(gpa, w, &hd.config, &u, check);
    } else |_| {}
    var packets = try mp4.Packets.init(file);
    std.debug.print("{s}: {d} packets\n", .{ args[1], packets.t.count });
    if (packets.t.codec == .aac) {
        var u: Units = .{ .mp4 = &packets };
        return playAac(gpa, w, packets.t.cookie, &u, check);
    }
    return playAlac(gpa, w, &packets, check);
}

fn playAlac(gpa: std.mem.Allocator, w: *std.Io.Writer, packets: *mp4.Packets, check: bool) !void {
    const cfg = try ref.alac.config.parse(packets.t.cookie);
    const nch: usize = cfg.channels;
    std.debug.print("ALAC, {d} ch, {d} bit, {d} Hz, frame {d}\n", .{ nch, cfg.bit_depth, cfg.sample_rate, cfg.frame_length });
    if (!dsp.supported(cfg)) {
        std.debug.print("alac_packet decodes 16-bit, 1 or 2 channel tracks with frames up to 4096\n", .{});
        std.process.exit(1);
    }
    if (!check) std.debug.print("play: | ffplay -nodisp -autoexit -f s16le -ar {d} -ch_layout stereo -\n", .{cfg.sample_rate});

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

    var t: Tally = .{};
    while (try packets.next()) |pkt| {
        const k = t.packets;
        const pcm = player.feed(pkt) catch |e| blk: {
            if (t.failed < 5) std.debug.print("packet {d}: {s} (status {d})\n", .{ k, @errorName(e), player.status });
            t.failed += 1;
            break :blk silence;
        };
        t.add(player.bundles, pcm.len / nch);
        if (check) {
            const n = try twin.decode(pkt, want);
            const got = want[0 .. n * nch];
            const diff: ?usize = if (got.len != pcm.len) @min(got.len, pcm.len) else for (got, pcm, 0..) |a, b, i| {
                if (a != b) break i;
            } else null;
            if (diff) |d| {
                if (t.bad < 20) std.debug.print("frame {d}: sample {d} (ch {d}) want {d} got {d}\n", .{ k, d / nch, d % nch, if (d < got.len) got[d] else 0, if (d < pcm.len) pcm[d] else 0 });
                t.bad += 1;
            }
            continue;
        }
        // the player went away (a closed pipe): stop quietly
        writeStereo(w, pcm, nch) catch break;
    }
    t.report(cfg.sample_rate, check, "ref/dsp/alac");
}

/// An AAC track's access units in order, from an .m4a's packets or an ADTS stream's frames.
const Units = union(enum) {
    mp4: *mp4.Packets,
    adts: struct { file: []const u8, pos: usize = 0 },

    fn next(self: *Units) !?[]const u8 {
        switch (self.*) {
            .mp4 => |p| return p.next(),
            .adts => |*a| {
                if (a.pos + 7 > a.file.len) return null;
                const hd = try ref.aac.adts.parse(a.file[a.pos..]);
                if (a.pos + hd.frame_len > a.file.len) return null;
                defer a.pos += hd.frame_len;
                return a.file[a.pos + hd.header_len .. a.pos + hd.frame_len];
            },
        }
    }
};

fn playAac(gpa: std.mem.Allocator, w: *std.Io.Writer, config: []const u8, units: *Units, check: bool) !void {
    var r = ref.bits.BitReader.init(config);
    const asc = try ref.aac.asc.parse(&r);
    const nch: usize = asc.channel_config;
    std.debug.print("AAC-LC, {d} ch, {d} Hz\n", .{ nch, asc.sample_rate });
    if (!dsp.aac.supported(asc)) {
        std.debug.print("aac_packet decodes AAC-LC, 1 or 2 channels, 1024-sample frames, rates from 48 kHz down\n", .{});
        std.process.exit(1);
    }
    if (!check) std.debug.print("play: | ffplay -nodisp -autoexit -f s16le -ar {d} -ch_layout stereo -\n", .{asc.sample_rate});
    const n = dsp.aac.frame_len * nch;

    const prog = try dsp.aac.program(gpa);
    defer gpa.free(prog);
    var player = try dsp.aac.Player.init(gpa, prog, asc);
    defer player.deinit();
    var twin = try ref.dsp.aac.decoder.Decoder.init(config);
    var want: [2 * dsp.aac.frame_len]i16 = undefined;
    const silence = try gpa.alloc(i16, n);
    defer gpa.free(silence);
    @memset(silence, 0);

    var t: Tally = .{};
    while (try units.next()) |au| {
        const k = t.packets;
        const pcm = player.feed(au) catch |e| blk: {
            if (t.failed < 5) std.debug.print("unit {d}: {s} (status {d})\n", .{ k, @errorName(e), player.status });
            t.failed += 1;
            break :blk silence;
        };
        t.add(player.bundles, dsp.aac.frame_len);
        if (check) {
            twin.decode(au, want[0..n]) catch |e| {
                if (t.bad < 20) std.debug.print("frame {d}: twin {s}\n", .{ k, @errorName(e) });
                t.bad += 1;
                continue;
            };
            if (std.mem.indexOfDiff(i16, want[0..n], pcm)) |at| {
                if (t.bad < 20) std.debug.print("frame {d}: sample {d} (ch {d}) want {d} got {d}\n", .{ k, at / nch, at % nch, want[at], pcm[at] });
                t.bad += 1;
            }
            continue;
        }
        writeStereo(w, pcm, nch) catch break;
    }
    t.report(asc.sample_rate, check, "ref/dsp/aac");
}
