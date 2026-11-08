//! Plays the ALAC track of an .m4a through sm1: each packet runs alac_packet (dsp/lib/alac.sm)
//! in x17's emulator under its host model, and the drained PCM goes to stdout as s16le stereo
//! (a mono track on both channels).
//!
//!     dspplay in.m4a | ffplay -nodisp -autoexit -f s16le -ar 44100 -ch_layout stereo -
//!     dspplay in.m4a --check
//!
//! Packets decode in parallel, one host model per core: ALAC packets are independent.
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
    if (!check) std.debug.print("play: | ffplay -nodisp -autoexit -f s16le -ar {d} -ch_layout stereo -\n", .{cfg.sample_rate});

    const prog = try dsp.program(gpa);
    defer gpa.free(prog);

    // ALAC packets carry no state from one to the next, so each worker decodes its share of a
    // batch on its own host model; the batch is then written in order.
    var all: std.ArrayList([]u8) = .empty;
    defer all.deinit(gpa);
    while (try packets.next()) |pkt| try all.append(gpa, pkt);
    const workers = @max(1, @min(std.Thread.getCpuCount() catch 1, max_workers));
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
