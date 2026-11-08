//! Plays the ALAC or AAC track of an .m4a, or an ADTS .aac stream, through sm1: each packet runs
//! alac_packet (dsp/lib/alac.sm) under x17's host model, or aac_packet (dsp/lib/aac.sm) in its
//! emulator, and the PCM goes to stdout as s16le stereo (a mono track on both channels).
//!
//!     dspplay in.m4a | ffplay -nodisp -autoexit -f s16le -ar 44100 -ch_layout stereo -
//!     dspplay in.m4a --check
//!
//! ALAC packets decode in parallel, one host model per core: they are independent. AAC access
//! units decode in order, each overlapping the one before.
//!
//! --check writes no audio: it decodes every packet with the ref/dsp twin too and reports each
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

/// One packet's PCM as s16le stereo, a mono channel on both sides.
fn writeStereo(w: *std.Io.Writer, pcm: []const i16, nch: usize) !void {
    for (0..pcm.len / nch) |i| for (0..2) |c| {
        try w.writeInt(i16, pcm[i * nch + @min(c, nch - 1)], .little);
    };
}

const max_workers = 32;
/// Workers allocate from the thread-safe allocator.
const wa = std.heap.smp_allocator;

/// One packet's result.
const Slot = struct {
    pcm: []i16,
    frames: usize = 0,
    bundles: usize = 0,
    status: u32 = 0,
    err: ?anyerror = null,
    diff: ?Diff = null,
};

const Job = struct { packets: []const []u8, slots: []Slot, first: usize, step: usize };

const Worker = struct {
    player: dsp.Player,
    twin: ?ref.dsp.alac.decoder.Decoder,
    want: []i32,
    nch: usize,

    fn init(prog: []const u32, cfg: ref.alac.config.Config, check: bool) !Worker {
        return .{
            .player = try dsp.Player.init(wa, prog, cfg),
            .twin = if (check) try ref.dsp.alac.decoder.Decoder.init(wa, cfg) else null,
            .want = try wa.alloc(i32, @as(usize, cfg.frame_length) * cfg.channels),
            .nch = cfg.channels,
        };
    }

    fn deinit(self: *Worker) void {
        self.player.deinit();
        if (self.twin) |*t| t.deinit();
        wa.free(self.want);
    }

    fn run(self: *Worker, job: Job) void {
        var i = job.first;
        while (i < job.packets.len) : (i += job.step) self.one(job.packets[i], &job.slots[i]);
    }

    fn one(self: *Worker, pkt: []const u8, sl: *Slot) void {
        sl.err = null;
        sl.diff = null;
        const pcm = self.player.feed(pkt) catch |e| {
            sl.err = e;
            sl.status = self.player.status;
            sl.frames = sl.pcm.len / self.nch;
            @memset(sl.pcm, 0);
            return;
        };
        sl.bundles = self.player.bundles;
        sl.frames = pcm.len / self.nch;
        @memcpy(sl.pcm[0..pcm.len], pcm);
        if (self.twin) |*t| {
            const n = t.decode(pkt, self.want) catch |e| {
                sl.err = e;
                return;
            };
            sl.diff = firstDiff(self.want[0 .. n * self.nch], pcm);
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
    if (ref.aac.adts.parse(file)) |_| return playAdts(gpa, io, file, check) else |_| {}
    var packets = try mp4.Packets.init(file);
    if (packets.t.codec == .aac) return playAac(gpa, io, args[1], &packets, check);
    return playAlac(gpa, io, args[1], &packets, check);
}

fn playAlac(gpa: std.mem.Allocator, io: std.Io, name: []const u8, packets: *mp4.Packets, check: bool) !void {
    const cfg = try ref.alac.config.parse(packets.t.cookie);
    const nch: usize = cfg.channels;
    std.debug.print("{s}: {d} packets, {d} ch, {d} bit, {d} Hz, frame {d}\n", .{ name, packets.t.count, nch, cfg.bit_depth, cfg.sample_rate, cfg.frame_length });
    if (!dsp.supported(cfg)) {
        std.debug.print("alac_packet decodes 16-bit, 1 or 2 channel tracks with frames up to 4096\n", .{});
        std.process.exit(1);
    }
    if (!check) std.debug.print("play: | ffplay -nodisp -autoexit -f s16le -ar {d} -ch_layout stereo -\n", .{cfg.sample_rate});

    const prog = try dsp.program(gpa);
    defer gpa.free(prog);

    // ALAC packets carry no state from one to the next, so each worker decodes its share of a
    // batch on its own host model; the batch is then written in order.
    var all: std.ArrayList([]u8) = .empty;
    defer all.deinit(gpa);
    while (try packets.next()) |pkt| try all.append(gpa, pkt);
    const workers: usize = @max(1, @min(std.Thread.getCpuCount() catch 1, max_workers));
    const batch = 2 * workers;
    const frame = @as(usize, cfg.frame_length) * nch;
    const slots = try gpa.alloc(Slot, batch);
    defer gpa.free(slots);
    for (slots) |*sl| sl.* = .{ .pcm = try gpa.alloc(i16, frame) };
    defer for (slots) |sl| gpa.free(sl.pcm);
    const ctx = try gpa.alloc(Worker, workers);
    defer gpa.free(ctx);
    for (ctx) |*c| c.* = try Worker.init(prog, cfg, check);
    defer for (ctx) |*c| c.deinit();
    std.debug.print("{d} workers\n", .{workers});

    var obuf: [1 << 16]u8 = undefined;
    var ow = std.Io.File.stdout().writer(io, &obuf);
    const w = &ow.interface;

    var bad: usize = 0;
    var failed: usize = 0;
    var max_bundles: usize = 0;
    var total_bundles: u64 = 0;
    var base: usize = 0;
    out: while (base < all.items.len) : (base += batch) {
        const n = @min(batch, all.items.len - base);
        var threads: [max_workers]?std.Thread = @splat(null);
        for (ctx, 0..) |*c, t| {
            const job: Job = .{ .packets = all.items[base .. base + n], .slots = slots[0..n], .first = t, .step = workers };
            threads[t] = std.Thread.spawn(.{}, Worker.run, .{ c, job }) catch blk: {
                c.run(job);
                break :blk null;
            };
        }
        for (threads[0..workers]) |th| if (th) |t| t.join();
        for (slots[0..n], 0..) |*sl, i| {
            const k = base + i;
            if (sl.err) |e| {
                if (failed < 5) std.debug.print("packet {d}: {s} (status {d})\n", .{ k, @errorName(e), sl.status });
                failed += 1;
            }
            max_bundles = @max(max_bundles, sl.bundles);
            total_bundles += sl.bundles;
            if (sl.diff) |d| {
                if (bad < 20) std.debug.print("frame {d}: sample {d} (ch {d}) want {d} got {d}\n", .{ k, d.at / nch, d.at % nch, d.want, d.got });
                bad += 1;
            }
            if (check) continue;
            // the player went away (a closed pipe): stop quietly
            writeStereo(w, sl.pcm[0 .. sl.frames * nch], nch) catch break :out;
        }
    }
    w.flush() catch {};
    const k = all.items.len;
    std.debug.print("{d} packets, {d} failed, worst {d} bundles, mean {d}\n", .{ k, failed, max_bundles, if (k == 0) 0 else total_bundles / k });
    if (check) {
        std.debug.print("{d} of {d} frames differ from ref/dsp/alac\n", .{ bad, k });
        if (bad != 0 or failed != 0) std.process.exit(1);
    }
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

fn playAdts(gpa: std.mem.Allocator, io: std.Io, file: []const u8, check: bool) !void {
    const hd = try ref.aac.adts.parse(file);
    var u: Units = .{ .adts = .{ .file = file } };
    return decodeAac(gpa, io, &hd.config, &u, check);
}

fn playAac(gpa: std.mem.Allocator, io: std.Io, name: []const u8, packets: *mp4.Packets, check: bool) !void {
    std.debug.print("{s}: {d} access units\n", .{ name, packets.t.count });
    var u: Units = .{ .mp4 = packets };
    return decodeAac(gpa, io, packets.t.cookie, &u, check);
}

/// Access units per worker chunk. A chunk's worker decodes the unit before it first and drops
/// its PCM: that unit rewrites the overlap and the previous shape (ISO/IEC 14496-3 4.6.11 and
/// 4.6.18.4), so only the PNS generator's word has to come in from outside, from the twin.
const chunk = 16;

const AacJob = struct {
    units: []const []const u8,
    /// First unit of the chunk, its PCM into out[from - base ..].
    from: usize,
    base: usize,
    seed: ref.dsp.ops.Word,
    out: []AacSlot,
};

const AacSlot = struct { pcm: []i16, err: ?anyerror = null, status: u32 = 0, bundles: usize = 0 };

fn aacChunk(player: *dsp.aac.Player, job: AacJob) void {
    const end = @min(job.from + chunk, job.units.len);
    // the seed is the PNS word before the first unit this worker runs
    player.seed(job.seed) catch {};
    if (job.from > 0) _ = player.feed(job.units[job.from - 1]) catch {};
    for (job.from..end) |k| {
        const sl = &job.out[k - job.base];
        sl.err = null;
        const pcm = player.feed(job.units[k]) catch |e| {
            sl.err = e;
            sl.status = player.status;
            @memset(sl.pcm, 0);
            continue;
        };
        sl.bundles = player.bundles;
        @memcpy(sl.pcm, pcm);
    }
}

fn decodeAac(gpa: std.mem.Allocator, io: std.Io, config: []const u8, units: *Units, check: bool) !void {
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

    var all: std.ArrayList([]const u8) = .empty;
    defer all.deinit(gpa);
    while (try units.next()) |au| try all.append(gpa, au);
    const count = all.items.len;

    // The twin's pass: the PNS word before each chunk's warm-up unit, and with --check its PCM.
    var twin = try ref.dsp.aac.decoder.Decoder.init(config);
    const seeds = try gpa.alloc(ref.dsp.ops.Word, (count + chunk - 1) / chunk);
    defer gpa.free(seeds);
    const want = try gpa.alloc(i16, if (check) count * n else n);
    defer gpa.free(want);
    const twin_bad = try gpa.alloc(bool, count);
    defer gpa.free(twin_bad);
    for (all.items, 0..) |au, k| {
        // chunk c's worker starts at unit c chunk - 1 (unit 0 for chunk 0)
        if (k == 0) seeds[0] = twin.rng.x;
        if ((k + 1) % chunk == 0 and k + 1 < count) seeds[(k + 1) / chunk] = twin.rng.x;
        const dst = if (check) want[k * n ..][0..n] else want[0..n];
        twin_bad[k] = false;
        twin.decode(au, dst) catch {
            twin_bad[k] = true;
        };
    }

    const prog = try dsp.aac.program(gpa);
    defer gpa.free(prog);
    const workers: usize = @max(1, @min(std.Thread.getCpuCount() catch 1, max_workers));
    const players = try gpa.alloc(dsp.aac.Player, workers);
    defer gpa.free(players);
    for (players) |*p| p.* = try dsp.aac.Player.init(wa, prog, asc);
    defer for (players) |*p| p.deinit();
    const batch = workers * chunk;
    const slots = try gpa.alloc(AacSlot, batch);
    defer gpa.free(slots);
    for (slots) |*sl| sl.* = .{ .pcm = try gpa.alloc(i16, n) };
    defer for (slots) |sl| gpa.free(sl.pcm);
    std.debug.print("{d} access units, {d} workers\n", .{ count, workers });

    var obuf: [1 << 16]u8 = undefined;
    var ow = std.Io.File.stdout().writer(io, &obuf);
    const w = &ow.interface;

    var bad: usize = 0;
    var failed: usize = 0;
    var max_bundles: usize = 0;
    var total_bundles: u64 = 0;
    var base: usize = 0;
    out: while (base < count) : (base += batch) {
        var threads: [max_workers]?std.Thread = @splat(null);
        for (players, 0..) |*p, t| {
            const from = base + t * chunk;
            if (from >= count) break;
            const job: AacJob = .{ .units = all.items, .from = from, .base = base, .seed = seeds[from / chunk], .out = slots };
            threads[t] = std.Thread.spawn(.{}, aacChunk, .{ p, job }) catch blk: {
                aacChunk(p, job);
                break :blk null;
            };
        }
        for (threads[0..workers]) |th| if (th) |t| t.join();
        for (base..@min(base + batch, count)) |k| {
            const sl = &slots[k - base];
            if (sl.err) |e| {
                if (failed < 5) std.debug.print("unit {d}: {s} (status {d})\n", .{ k, @errorName(e), sl.status });
                failed += 1;
            }
            max_bundles = @max(max_bundles, sl.bundles);
            total_bundles += sl.bundles;
            if (check) {
                if (twin_bad[k]) {
                    if (bad < 20) std.debug.print("frame {d}: the twin fails\n", .{k});
                    bad += 1;
                } else if (std.mem.indexOfDiff(i16, want[k * n ..][0..n], sl.pcm)) |at| {
                    if (bad < 20) std.debug.print("frame {d}: sample {d} (ch {d}) want {d} got {d}\n", .{ k, at / nch, at % nch, want[k * n + at], sl.pcm[at] });
                    bad += 1;
                }
                continue;
            }
            writeStereo(w, sl.pcm, nch) catch break :out;
        }
    }
    w.flush() catch {};
    std.debug.print("{d} units, {d} failed, worst {d} bundles, mean {d}\n", .{ count, failed, max_bundles, if (count == 0) 0 else total_bundles / count });
    if (check) {
        std.debug.print("{d} of {d} frames differ from ref/dsp/aac\n", .{ bad, count });
        if (bad != 0 or failed != 0) std.process.exit(1);
    }
}
