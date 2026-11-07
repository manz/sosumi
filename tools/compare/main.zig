//! Decodes an ADTS AAC-LC file, or an MP3 file (by extension), with the reference model and compares it with a reference
//! decode (raw s16le, interleaved, same channel count), e.g. from the ffmpeg binary or
//! afconvert. Optionally writes our PCM as a WAV for listening.
//!
//!     compare in.aac|in.mp3 ref.s16 [ours.wav] [--dsp]
//!
//! --dsp decodes AAC with ref/dsp/aac, the decoder in measured sm1 operations.
const std = @import("std");
const ref = @import("ref");

const Adts = struct { config: [2]u8, header_len: usize, frame_len: usize };

fn parseAdts(b: []const u8) !Adts {
    if (b.len < 7 or b[0] != 0xFF or b[1] & 0xF6 != 0xF0) return error.NotAdts;
    const protection_absent = b[1] & 1 == 1;
    const profile: u8 = b[2] >> 6; // audio object type - 1
    const freq: u8 = (b[2] >> 2) & 0xF;
    const chans: u8 = ((b[2] & 1) << 2) | (b[3] >> 6);
    const frame_len: usize = (@as(usize, b[3] & 3) << 11) | (@as(usize, b[4]) << 3) | (b[5] >> 5);
    if (b[6] & 3 != 0) return error.MultipleRawBlocks;
    const aot = profile + 1;
    return .{
        .config = .{ (aot << 3) | (freq >> 1), ((freq & 1) << 7) | (chans << 3) },
        .header_len = if (protection_absent) 7 else 9,
        .frame_len = frame_len,
    };
}

fn wav(gpa: std.mem.Allocator, pcm: []const i16, channels: u16, rate: u32) ![]u8 {
    const data_len: u32 = @intCast(pcm.len * 2);
    var out = try gpa.alloc(u8, 44 + data_len);
    @memcpy(out[0..4], "RIFF");
    std.mem.writeInt(u32, out[4..8], 36 + data_len, .little);
    @memcpy(out[8..16], "WAVEfmt ");
    std.mem.writeInt(u32, out[16..20], 16, .little);
    std.mem.writeInt(u16, out[20..22], 1, .little);
    std.mem.writeInt(u16, out[22..24], channels, .little);
    std.mem.writeInt(u32, out[24..28], rate, .little);
    std.mem.writeInt(u32, out[28..32], rate * channels * 2, .little);
    std.mem.writeInt(u16, out[32..34], channels * 2, .little);
    std.mem.writeInt(u16, out[34..36], 16, .little);
    @memcpy(out[36..40], "data");
    std.mem.writeInt(u32, out[40..44], data_len, .little);
    @memcpy(out[44..], std.mem.sliceAsBytes(pcm));
    return out;
}

/// STAGES=<frame>: one access unit through both AAC pipelines, the DSP block's distance from
/// the reference's coefficients after each stage, relative to the reference's peak (noise bands
/// differ by design), then the windowed blocks in PCM steps. Pairs only.
fn stages(au: []const u8, fi: u4) !void {
    const A = ref.aac;
    const D = ref.dsp.aac;
    var r = ref.bits.BitReader.init(au);
    while (true) {
        const h = try A.raw.readHeader(&r);
        switch (h.id) {
            .end => return,
            .dse => try A.raw.skipDse(&r),
            .fil => try A.raw.skipFil(&r),
            .cpe => {
                const pair = try A.ics.readChannelPair(&r, fi);
                const lo = pair.left.info.bandOffsets(fi);
                const ro = pair.right.info.bandOffsets(fi);
                var rl = A.iquant.dequantChannel(&pair.left, fi);
                var rr = A.iquant.dequantChannel(&pair.right, fi);
                var dl = D.decoder.dequantise(&pair.left, lo);
                var dr = D.decoder.dequantise(&pair.right, ro);
                report("dequant", &rl, &dl, &rr, &dr);
                var rng: A.stereo.Rng = .{};
                A.stereo.applyPair(&pair, &rl, &rr, lo, ro, &rng);
                var drng: D.pns.Rng = .{};
                D.pns.channel(&pair.left, lo, &dl, &drng);
                D.stereo.applyPair(&pair, &dl, &dr, lo, ro);
                D.pns.right(&pair, &dl, ro, &dr, &drng);
                report("stereo", &rl, &dl, &rr, &dr);
                if (pair.left.tns) |*t| {
                    A.tns.apply(&pair.left, &rl, fi);
                    _ = D.tns.apply(t, pair.left.info, fi, &dl);
                }
                if (pair.right.tns) |*t| {
                    A.tns.apply(&pair.right, &rr, fi);
                    _ = D.tns.apply(t, pair.right.info, fi, &dr);
                }
                report("tns", &rl, &dl, &rr, &dr);
                for ([_]*const A.ics.Channel{ &pair.left, &pair.right }, [_]*const A.iquant.Coefs{ &rl, &rr }, [_]*const D.dequant.Block{ &dl, &dr }) |ch, rc, dc| {
                    const shape = ch.info.window_shape;
                    var rb: [2048]ref.fixed.Word = undefined;
                    A.filterbank.block(&.{ .prev_shape = shape }, ch.info, rc, &rb);
                    var db: [2048]ref.dsp.ops.Word = undefined;
                    if (ch.info.isShort()) {
                        var t: [8][256]ref.dsp.ops.Word = undefined;
                        for (&t, 0..) |*o, w| D.imdct.imdct(128, dc.w[w * 128 ..][0..128], dc.e, o);
                        D.window.block(shape, shape, ch.info.window_sequence, .{ .short = &t }, &db);
                    } else {
                        var t: [2048]ref.dsp.ops.Word = undefined;
                        D.imdct.imdct(1024, &dc.w, dc.e, &t);
                        D.window.block(shape, shape, ch.info.window_sequence, .{ .long = &t }, &db);
                    }
                    var worst: f64 = 0;
                    var at: usize = 0;
                    var peak: f64 = 0;
                    for (rb, db, 0..) |a, b, k| {
                        const d = @abs(@as(f64, @floatFromInt(a)) / 128 - @as(f64, @floatFromInt(b)) / 32);
                        peak = @max(peak, @abs(@as(f64, @floatFromInt(a)) / 128));
                        if (d > worst) {
                            worst = d;
                            at = k;
                        }
                    }
                    std.debug.print("  window {s}: max {d:.1} PCM at {d}, peak {d:.0}\n", .{ @tagName(ch.info.window_sequence), worst, at, peak });
                }
            },
            else => return,
        }
    }
}

fn report(tag: []const u8, rl: *const ref.aac.iquant.Coefs, dl: *const ref.dsp.aac.dequant.Block, rr: *const ref.aac.iquant.Coefs, dr: *const ref.dsp.aac.dequant.Block) void {
    std.debug.print("  {s}:", .{tag});
    for ([_]*const ref.aac.iquant.Coefs{ rl, rr }, [_]*const ref.dsp.aac.dequant.Block{ dl, dr }) |a, b| {
        var peak: f64 = 0;
        var err: f64 = 0;
        var at: usize = 0;
        for (a, b.w, 0..) |x, w, k| {
            const v = x.toFloat();
            const d = std.math.ldexp(@as(f64, @floatFromInt(w)), b.e);
            peak = @max(peak, @abs(v));
            if (@abs(v - d) > err) {
                err = @abs(v - d);
                at = k;
            }
        }
        std.debug.print("  e {d} rel {e:.2} at {d}", .{ b.e, err / @max(peak, 1e-30), at });
    }
    std.debug.print("\n", .{});
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const all = try init.minimal.args.toSlice(init.arena.allocator());
    var kept: std.ArrayList([:0]const u8) = .empty;
    var use_dsp = false;
    for (all) |a| {
        if (std.mem.eql(u8, a, "--dsp")) use_dsp = true else try kept.append(init.arena.allocator(), a);
    }
    const args = kept.items;
    if (args.len < 3) {
        std.debug.print("usage: compare in.aac ref.s16 [ours.wav]\n", .{});
        std.process.exit(2);
    }
    const cwd = std.Io.Dir.cwd();
    const aac = try cwd.readFileAlloc(io, args[1], gpa, .limited(1 << 30));
    defer gpa.free(aac);
    const ref_bytes = try cwd.readFileAlloc(io, args[2], gpa, .limited(1 << 30));
    defer gpa.free(ref_bytes);
    const want: []const i16 = @alignCast(std.mem.bytesAsSlice(i16, ref_bytes[0 .. ref_bytes.len & ~@as(usize, 1)]));

    var stats: std.ArrayList(ref.aac.decoder.ToolStats) = .empty;
    defer stats.deinit(gpa);
    var ours: std.ArrayList(i16) = .empty;
    defer ours.deinit(gpa);
    var mp3_stats: [7]usize = @splat(0);
    var chans: usize = 0;
    var rate: u32 = 0;
    var frames: usize = 0;
    var failed: usize = 0;
    if (std.mem.endsWith(u8, args[1], ".mp3")) {
        var mp3: ref.mp3.decoder.Decoder = .{};
        var pos: usize = 0;
        if (aac.len > 10 and std.mem.eql(u8, aac[0..3], "ID3")) {
            const size = (@as(usize, aac[6]) << 21) | (@as(usize, aac[7]) << 14) | (@as(usize, aac[8]) << 7) | aac[9];
            pos = 10 + size + @as(usize, if (aac[5] & 0x10 != 0) 10 else 0);
        }
        var pcm: [2304]i16 = undefined;
        while (pos + 4 <= aac.len) {
            const h = ref.mp3.header.parse(aac[pos..]) catch {
                pos += 1;
                continue;
            };
            const len = h.frameLen();
            if (pos + len > aac.len) break;
            const n = @as(usize, h.samples()) * h.channels();
            chans = h.channels();
            rate = h.sampleRate();
            const f = mp3.decode(aac[pos .. pos + len], &pcm) catch |e| blk: {
                if (failed < 5) std.debug.print("frame {d}: {s}\n", .{ frames, @errorName(e) });
                failed += 1;
                @memset(pcm[0..n], 0);
                break :blk null;
            };
            if (f) |fr| {
                if (!fr.decoded) failed += 1;
                const t = mp3.last;
                inline for (.{ t.short, t.mixed, t.ms, t.intensity, t.scfsi, t.preflag, t.scalefac_scale }, 0..) |b, k| mp3_stats[k] += @intFromBool(b);
            }
            try ours.appendSlice(gpa, pcm[0..n]);
            pos += len;
            frames += 1;
        }
    }
    var dec: ?ref.aac.decoder.Decoder = null;
    var dsp: ?ref.dsp.aac.decoder.Decoder = null;
    var pos: usize = 0;
    var buf: [2048]i16 = undefined;
    while (chans == 0 and pos + 7 <= aac.len) {
        const h = try parseAdts(aac[pos..]);
        if (dec == null) dec = try ref.aac.decoder.Decoder.init(&h.config);
        if (use_dsp and dsp == null) dsp = try ref.dsp.aac.decoder.Decoder.init(&h.config);
        const au = aac[pos + h.header_len .. pos + h.frame_len];
        if (init.environ_map.get("STAGES")) |sf| {
            if (frames == try std.fmt.parseInt(usize, sf, 10)) try stages(au, @intCast((h.config[0] & 7) << 1 | h.config[1] >> 7));
        }
        const n = @as(usize, dec.?.channels) * 1024;
        const res = if (dsp) |*d| d.decode(au, buf[0..n]) else dec.?.decode(au, buf[0..n]);
        res catch |e| {
            if (failed < 5) std.debug.print("frame {d}: {s}\n", .{ frames, @errorName(e) });
            failed += 1;
            @memset(buf[0..n], 0);
        };
        try ours.appendSlice(gpa, buf[0..n]);
        try stats.append(gpa, if (dsp) |d| d.last else dec.?.last);
        pos += h.frame_len;
        frames += 1;
    }
    if (dec) |d| {
        chans = d.channels;
        rate = rate;
    }
    if (chans == 0) return error.Empty;

    // best alignment within +-4096 samples (reference decoders trim encoder delay and LAME's
    // Info frame: 2257 samples for an MPEG-1 LAME file)
    const got = ours.items;
    var best_off: isize = 0;
    var best_err: f64 = std.math.inf(f64);
    var off: isize = -4096;
    while (off <= 4096) : (off += 1) {
        var e: f64 = 0;
        var i: usize = 0;
        const step = chans * 64;
        while (i + step < 8 * 44100) : (i += step) {
            const gi = @as(isize, @intCast(i)) + off * @as(isize, @intCast(chans));
            if (gi < 0 or gi >= got.len or i >= want.len) continue;
            const diff = @as(f64, @floatFromInt(got[@intCast(gi)])) - @as(f64, @floatFromInt(want[i]));
            e += diff * diff;
        }
        if (e < best_err) {
            best_err = e;
            best_off = off;
        }
    }

    var sig: f64 = 0;
    var noise: f64 = 0;
    var max_diff: u32 = 0;
    var over1: usize = 0;
    var count: usize = 0;
    for (want, 0..) |w, i| {
        const gi = @as(isize, @intCast(i)) + best_off * @as(isize, @intCast(chans));
        if (gi < 0 or gi >= got.len) continue;
        const g = got[@intCast(gi)];
        const diff: i32 = @as(i32, g) - w;
        sig += @as(f64, @floatFromInt(w)) * @as(f64, @floatFromInt(w));
        noise += @as(f64, @floatFromInt(diff)) * @as(f64, @floatFromInt(diff));
        max_diff = @max(max_diff, @abs(diff));
        if (@abs(diff) > 1) over1 += 1;
        count += 1;
    }
    const snr = if (noise == 0) std.math.inf(f64) else 10 * std.math.log10(sig / noise);
    std.debug.print("{s}: {d} frames, {d} failed, {d} ch, {d} Hz, offset {d}\n", .{ args[1], frames, failed, chans, rate, best_off });
    std.debug.print("  vs {s}: SNR {d:.1} dB, max |diff| {d}, |diff|>1 in {d:.3}% of {d} samples\n", .{ args[2], snr, max_diff, 100 * @as(f64, @floatFromInt(over1)) / @as(f64, @floatFromInt(@max(count, 1))), count });

    if (stats.items.len == 0) {
        std.debug.print("  mp3 tools: short {d}, mixed {d}, ms {d}, intensity {d}, scfsi {d}, preflag {d}, scalefac_scale {d} frames\n", .{ mp3_stats[0], mp3_stats[1], mp3_stats[2], mp3_stats[3], mp3_stats[4], mp3_stats[5], mp3_stats[6] });
    }
    // tool coverage, and the level match on frames with noise bands (their waveforms are
    // decoder-specific by design)
    var n_short: usize = 0;
    var n_ms: usize = 0;
    var n_is: usize = 0;
    var n_tns: usize = 0;
    var n_pulse: usize = 0;
    var n_pns: usize = 0;
    var level_worst: f64 = 0;
    var level_sum: f64 = 0;
    for (stats.items, 0..) |t, f| {
        n_short += @intFromBool(t.window[0] == .eight_short or t.window[1] == .eight_short);
        n_ms += @intFromBool(t.ms != 0);
        n_is += @intFromBool(t.intensity);
        n_tns += @intFromBool(t.tns[0] or t.tns[1]);
        n_pulse += @intFromBool(t.pulse[0] or t.pulse[1]);
        if (!t.pns) continue;
        n_pns += 1;
        var eg: f64 = 0;
        var ew: f64 = 0;
        for (0..1024 * chans) |k| {
            const i = f * 1024 * chans + k;
            const gi = @as(isize, @intCast(i)) + best_off * @as(isize, @intCast(chans));
            if (i >= want.len or gi < 0 or gi >= got.len) continue;
            const g: f64 = @floatFromInt(got[@intCast(gi)]);
            const w: f64 = @floatFromInt(want[i]);
            eg += g * g;
            ew += w * w;
        }
        if (eg < 1e3 or ew < 1e3) continue;
        const db = 10 * std.math.log10(eg / ew);
        level_worst = @max(level_worst, @abs(db));
        level_sum += db;
    }
    std.debug.print("  tools: short {d}, ms {d}, intensity {d}, tns {d}, pulse {d}, pns {d} frames", .{ n_short, n_ms, n_is, n_tns, n_pulse, n_pns });
    if (n_pns > 0) std.debug.print("; pns frame level vs ref: mean {d:.2} dB, worst {d:.2} dB", .{ level_sum / @as(f64, @floatFromInt(n_pns)), level_worst });
    std.debug.print("\n", .{});

    // the worst frames, with the tools they used (frame f's PCM depends on frames f and f - 1)
    if (init.environ_map.get("VERBOSE") != null and stats.items.len > 0) {
        var shown: usize = 0;
        for (0..frames) |f| {
            var fmax: u32 = 0;
            for (0..1024 * chans) |k| {
                const i = f * 1024 * chans + k;
                const gi = @as(isize, @intCast(i)) + best_off * @as(isize, @intCast(chans));
                if (i >= want.len or gi < 0 or gi >= got.len) continue;
                fmax = @max(fmax, @abs(@as(i32, got[@intCast(gi)]) - want[i]));
            }
            if (fmax <= 2 or shown >= 20) continue;
            shown += 1;
            const t = stats.items[f];
            const p = if (f > 0) stats.items[f - 1] else t;
            std.debug.print("  frame {d}: max {d}  win {s}/{s} cw {} ms {d} pns {} is {} tns {}/{} pulse {}/{}  (prev win {s}/{s} pns {} is {} tns {}/{})\n", .{
                f,                     fmax,                  @tagName(t.window[0]), @tagName(t.window[1]), t.common_window, t.ms,     t.pns, t.intensity, t.tns[0], t.tns[1], t.pulse[0], t.pulse[1],
                @tagName(p.window[0]), @tagName(p.window[1]), p.pns,                 p.intensity,           p.tns[0],        p.tns[1],
            });
        }
    }

    if (args.len > 3) {
        const w = try wav(gpa, got, @intCast(chans), rate);
        defer gpa.free(w);
        try cwd.writeFile(io, .{ .sub_path = args[3], .data = w });
    }
}
