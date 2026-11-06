//! Decodes an ADTS AAC-LC file with the reference model and compares it with a reference
//! decode (raw s16le, interleaved, same channel count), e.g. from the ffmpeg binary or
//! afconvert. Optionally writes our PCM as a WAV for listening.
//!
//!     compare in.aac ref.s16 [ours.wav]
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

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
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
    var dec: ?ref.aac.decoder.Decoder = null;
    var pos: usize = 0;
    var frames: usize = 0;
    var failed: usize = 0;
    var buf: [2048]i16 = undefined;
    while (pos + 7 <= aac.len) {
        const h = try parseAdts(aac[pos..]);
        if (dec == null) dec = try ref.aac.decoder.Decoder.init(&h.config);
        const au = aac[pos + h.header_len .. pos + h.frame_len];
        const n = @as(usize, dec.?.channels) * 1024;
        dec.?.decode(au, buf[0..n]) catch |e| {
            if (failed < 5) std.debug.print("frame {d}: {s}\n", .{ frames, @errorName(e) });
            failed += 1;
            @memset(buf[0..n], 0);
        };
        try ours.appendSlice(gpa, buf[0..n]);
        try stats.append(gpa, dec.?.last);
        pos += h.frame_len;
        frames += 1;
    }
    const d = dec orelse return error.Empty;
    const chans: usize = d.channels;

    // best alignment within +-2 frames (reference decoders may trim or pad the start)
    const got = ours.items;
    var best_off: isize = 0;
    var best_err: f64 = std.math.inf(f64);
    var off: isize = -2048;
    while (off <= 2048) : (off += 1) {
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
    std.debug.print("{s}: {d} frames, {d} failed, {d} ch, {d} Hz, offset {d}\n", .{ args[1], frames, failed, chans, d.config.sample_rate, best_off });
    std.debug.print("  vs {s}: SNR {d:.1} dB, max |diff| {d}, |diff|>1 in {d:.3}% of {d} samples\n", .{ args[2], snr, max_diff, 100 * @as(f64, @floatFromInt(over1)) / @as(f64, @floatFromInt(@max(count, 1))), count });

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
    if (init.environ_map.get("VERBOSE") != null) {
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
                f, fmax, @tagName(t.window[0]), @tagName(t.window[1]), t.common_window, t.ms, t.pns, t.intensity, t.tns[0], t.tns[1], t.pulse[0], t.pulse[1],
                @tagName(p.window[0]), @tagName(p.window[1]), p.pns, p.intensity, p.tns[0], p.tns[1],
            });
        }
    }

    if (args.len > 3) {
        const w = try wav(gpa, got, @intCast(chans), d.config.sample_rate);
        defer gpa.free(w);
        try cwd.writeFile(io, .{ .sub_path = args[3], .data = w });
    }
}
