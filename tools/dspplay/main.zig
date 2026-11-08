//! Plays the ALAC or AAC track of an .m4a, or an ADTS .aac stream, through sm1: each packet runs
//! alac_packet (dsp/lib/alac.sm) under x17's host model, or aac_packet (dsp/lib/aac.sm) in its
//! emulator, and the PCM goes to stdout as s16le stereo (a mono track on both channels).
//!
//!     dspplay in.m4a | ffplay -nodisp -autoexit -f s16le -ar 44100 -ch_layout stereo -
//!     dspplay in.m4a --check
//!     dspplay in.m4a --profile[=rows]
//!
//! One emulator, packets in order, as the device runs them. The summary gives the device's
//! speed from the bundles run, at 37.4 ns a bundle (x17 handbook §1): below 1x real time the
//! program is too slow for the chip, and the emulator, about as fast, stutters with it.
//!
//! --profile writes no audio either: it counts the bundles run at each source line and prints
//! the busiest lines, the macro calls they sit in, and how full the bundles run are.
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

const Mode = enum { play, check, profile };

/// Rows per table in --profile's report (--profile=N).
var profile_rows: usize = 15;

fn usage() noreturn {
    std.debug.print("usage: dspplay in.m4a|in.aac [--check | --profile[=rows]]\n", .{});
    std.process.exit(2);
}

/// Bundles run per source line, kept while a track plays.
const Profile = struct {
    sites: std.ArrayList(dsp.Site) = .empty,
    counts: []u64 = &.{},

    fn deinit(self: *Profile, gpa: std.mem.Allocator) void {
        self.sites.deinit(gpa);
        gpa.free(self.counts);
    }

    const Row = struct { key: []const u8, bundles: u64, syllables: u64, text: []const u8 };

    fn add(gpa: std.mem.Allocator, m: *std.StringArrayHashMapUnmanaged(Row), key: []u8, n: u64, len: u64, text: []const u8) !void {
        const g = try m.getOrPut(gpa, key);
        if (g.found_existing) gpa.free(key) else g.value_ptr.* = .{ .key = key, .bundles = 0, .syllables = 0, .text = text };
        g.value_ptr.bundles += n;
        g.value_ptr.syllables += n * len;
    }

    fn top(m: *std.StringArrayHashMapUnmanaged(Row), title: []const u8, total: u64, packets: usize, rows: usize) void {
        const Ctx = struct {
            v: []const Row,
            pub fn lessThan(c: @This(), a: usize, b: usize) bool {
                return c.v[a].bundles > c.v[b].bundles;
            }
        };
        m.sort(Ctx{ .v = m.values() });
        std.debug.print("\n{s}\n  bundles/pkt     %  syl/bundle  where\n", .{title});
        for (m.values()[0..@min(rows, m.count())]) |r| {
            if (r.bundles == 0) break;
            std.debug.print("  {d:>11} {d:>5.1}  {d:>10.2}  {s}  {s}\n", .{
                r.bundles / @max(1, packets),
                100 * @as(f64, @floatFromInt(r.bundles)) / @as(f64, @floatFromInt(total)),
                @as(f64, @floatFromInt(r.syllables)) / @as(f64, @floatFromInt(r.bundles)),
                r.key,
                r.text,
            });
        }
    }

    fn report(self: *Profile, gpa: std.mem.Allocator, packets: usize, rows: usize) !void {
        var lines: std.StringArrayHashMapUnmanaged(Row) = .empty;
        var calls: std.StringArrayHashMapUnmanaged(Row) = .empty;
        var idle: std.StringArrayHashMapUnmanaged(Row) = .empty;
        var files: std.StringArrayHashMapUnmanaged(Row) = .empty;
        var size_files: std.StringArrayHashMapUnmanaged(Row) = .empty;
        var size_calls: std.StringArrayHashMapUnmanaged(Row) = .empty;
        defer for ([_]*std.StringArrayHashMapUnmanaged(Row){ &lines, &calls, &idle, &files, &size_files, &size_calls }) |m| {
            for (m.keys()) |k| gpa.free(k);
            m.deinit(gpa);
        };
        var total: u64 = 0;
        var syl: u64 = 0;
        var nops: u64 = 0;
        const items = self.sites.items;
        var size: u64 = 0;
        var size_nops: u64 = 0;
        for (items, 0..) |*st, i| {
            const end = if (i + 1 < items.len) items[i + 1].pc else self.counts.len;
            const len: u64 = end - st.pc;
            // program size: syllables per file, and per the call that expanded them
            size += len;
            if (std.mem.startsWith(u8, std.mem.trimStart(u8, st.text.get(), " "), "alu s0, s0, s0, #0")) size_nops += len;
            try add(gpa, &size_files, try gpa.dupe(u8, st.file.get()), len, 1, "");
            const sk = if (st.call_line != 0) try std.fmt.allocPrint(gpa, "{s}:{d}", .{ st.call_file.get(), st.call_line }) else try std.fmt.allocPrint(gpa, "{s}:{d}", .{ st.file.get(), st.line });
            try add(gpa, &size_calls, sk, len, 1, "");
            const n = self.counts[st.pc];
            if (n == 0) continue;
            total += n;
            syl += n * len;
            const text = st.text.get();
            // nop() is `alu s0, s0, s0, #0` (bits.sm): a bundle that does nothing
            if (std.mem.startsWith(u8, std.mem.trimStart(u8, text, " "), "alu s0, s0, s0, #0")) {
                nops += n;
                try add(gpa, &idle, try std.fmt.allocPrint(gpa, "{s}:{d}", .{ st.call_file.get(), st.call_line }), n, len, "");
            }
            try add(gpa, &lines, try std.fmt.allocPrint(gpa, "{s}:{d}", .{ st.file.get(), st.line }), n, len, text);
            try add(gpa, &files, try gpa.dupe(u8, st.file.get()), n, len, "");
            const ck = if (st.call_line != 0) try std.fmt.allocPrint(gpa, "{s}:{d}", .{ st.call_file.get(), st.call_line }) else try std.fmt.allocPrint(gpa, "{s}:{d}", .{ st.file.get(), st.line });
            try add(gpa, &calls, ck, n, len, "");
        }
        if (total == 0) return;
        std.debug.print("\nprofile: {d} bundles/packet, {d:.2} syllables per bundle (7 at most), nop bundles {d:.1}%\n", .{
            total / @max(1, packets),
            @as(f64, @floatFromInt(syl)) / @as(f64, @floatFromInt(total)),
            100 * @as(f64, @floatFromInt(nops)) / @as(f64, @floatFromInt(total)),
        });
        top(&files, "by file", total, packets, 12);
        top(&lines, "busiest source lines", total, packets, 2 * rows);
        top(&calls, "busiest macro calls (the line that expanded them)", total, packets, rows);
        top(&idle, "nop bundles by the line that wrote them", total, packets, rows);
        std.debug.print("\nprogram: {d} syllables, {d} of them nops\n", .{ size, size_nops });
        top(&size_files, "syllables by file (first column; ignore the rest)", size, 1, 20);
        top(&size_calls, "syllables by the call that expanded them", size, 1, rows);
    }
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var mode: Mode = .play;
    if (args.len == 3) {
        mode = if (std.mem.eql(u8, args[2], "--check")) .check else if (std.mem.startsWith(u8, args[2], "--profile")) .profile else usage();
        if (std.mem.startsWith(u8, args[2], "--profile=")) profile_rows = std.fmt.parseInt(usize, args[2]["--profile=".len..], 10) catch usage();
    } else if (args.len != 2) usage();
    const file = try std.Io.Dir.cwd().readFileAlloc(io, args[1], gpa, .limited(1 << 31));
    defer gpa.free(file);

    var obuf: [1 << 16]u8 = undefined;
    var ow = std.Io.File.stdout().writer(io, &obuf);
    const w = &ow.interface;
    defer w.flush() catch {};

    if (ref.aac.adts.parse(file)) |hd| {
        var u: Units = .{ .adts = .{ .file = file } };
        return playAac(gpa, w, &hd.config, &u, mode);
    } else |_| {}
    var packets = try mp4.Packets.init(file);
    std.debug.print("{s}: {d} packets\n", .{ args[1], packets.t.count });
    if (packets.t.codec == .aac) {
        var u: Units = .{ .mp4 = &packets };
        return playAac(gpa, w, packets.t.cookie, &u, mode);
    }
    return playAlac(gpa, w, &packets, mode);
}

fn playAlac(gpa: std.mem.Allocator, w: *std.Io.Writer, packets: *mp4.Packets, mode: Mode) !void {
    const cfg = try ref.alac.config.parse(packets.t.cookie);
    const nch: usize = cfg.channels;
    std.debug.print("ALAC, {d} ch, {d} bit, {d} Hz, frame {d}\n", .{ nch, cfg.bit_depth, cfg.sample_rate, cfg.frame_length });
    if (!dsp.supported(cfg)) {
        std.debug.print("alac_packet decodes 16-bit, 1 or 2 channel tracks with frames up to 4096\n", .{});
        std.process.exit(1);
    }
    const check = mode == .check;
    if (mode == .play) std.debug.print("play: | ffplay -nodisp -autoexit -f s16le -ar {d} -ch_layout stereo -\n", .{cfg.sample_rate});

    var prof: Profile = .{};
    defer prof.deinit(gpa);
    const prog = try dsp.programSites(gpa, if (mode == .profile) &prof.sites else null);
    defer gpa.free(prog);
    var player = try dsp.Player.init(gpa, prog, cfg);
    defer player.deinit();
    if (mode == .profile) {
        prof.counts = try gpa.alloc(u64, prog.len);
        @memset(prof.counts, 0);
        player.profile(prof.counts);
    }
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
        if (mode == .profile) continue;
        // the player went away (a closed pipe): stop quietly
        writeStereo(w, pcm, nch) catch break;
    }
    t.report(cfg.sample_rate, check, "ref/dsp/alac");
    if (mode == .profile) try prof.report(gpa, t.packets, profile_rows);
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

fn playAac(gpa: std.mem.Allocator, w: *std.Io.Writer, config: []const u8, units: *Units, mode: Mode) !void {
    var r = ref.bits.BitReader.init(config);
    const asc = try ref.aac.asc.parse(&r);
    const nch: usize = asc.channel_config;
    std.debug.print("AAC-LC, {d} ch, {d} Hz\n", .{ nch, asc.sample_rate });
    if (!dsp.aac.supported(asc)) {
        std.debug.print("aac_packet decodes AAC-LC, 1 or 2 channels, 1024-sample frames, rates from 48 kHz down\n", .{});
        std.process.exit(1);
    }
    const check = mode == .check;
    if (mode == .play) std.debug.print("play: | ffplay -nodisp -autoexit -f s16le -ar {d} -ch_layout stereo -\n", .{asc.sample_rate});
    const n = dsp.aac.frame_len * nch;

    var prof: Profile = .{};
    defer prof.deinit(gpa);
    const prog = try dsp.aac.programSites(gpa, if (mode == .profile) &prof.sites else null);
    defer gpa.free(prog);
    var player = try dsp.aac.Player.init(gpa, prog, asc);
    defer player.deinit();
    if (mode == .profile) {
        prof.counts = try gpa.alloc(u64, prog.len);
        @memset(prof.counts, 0);
        player.profile(prof.counts);
    }
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
        if (mode == .profile) continue;
        writeStereo(w, pcm, nch) catch break;
    }
    t.report(asc.sample_rate, check, "ref/dsp/aac");
    if (mode == .profile) try prof.report(gpa, t.packets, profile_rows);
}
