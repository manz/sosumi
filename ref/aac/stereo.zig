//! Perceptual noise substitution, M/S stereo and intensity stereo (ISO/IEC 14496-3), in
//! OpenCORE's order: PNS on the left (or only) channel, M/S, then the right channel's noise and
//! intensity bands.
//!
//! PNS noise is ours: the Numerical Recipes LCG (1664525, 1013904223), one value per
//! coefficient, each window's band normalised to unit energy and scaled by 2^(nrg / 4). ISO
//! leaves the generator open, so PNS bands match no other decoder sample for sample.
const std = @import("std");
const fixed = @import("../fixed.zig");
const ics = @import("ics.zig");
const iquant = @import("iquant.zig");

const F24 = fixed.F24;
const Coefs = iquant.Coefs;

pub const Rng = struct {
    seed: u32 = 0,

    /// Next value in [-32768, 32767]: the top half of the LCG state.
    pub fn next(self: *Rng) i32 {
        self.seed = self.seed *% 1664525 +% 1013904223;
        return @as(i32, @bitCast(self.seed)) >> 16;
    }
};

/// 2^(b / 4) for b = 0..3.
const quarter_pow2 = [4]F24{ fixed.f24(1.0), fixed.f24(1.189207115002721), fixed.f24(1.4142135623730951), fixed.f24(1.681792830507429) };

/// 2^(x / 4) for any integer x.
fn pow2Quarter(x: i32) F24 {
    return fixed.scale2(quarter_pow2[@intCast(x & 3)], x >> 2);
}

/// Coefficient range of band `sfb` in window `w`.
fn band(info: ics.IcsInfo, offsets: []const u16, w: usize, sfb: usize) [2]usize {
    const base = w * @as(usize, if (info.isShort()) 128 else 1024);
    return .{ base + offsets[sfb], base + offsets[sfb + 1] };
}

/// First window of each group.
fn groupStarts(info: ics.IcsInfo) [ics.max_groups + 1]usize {
    var starts: [ics.max_groups + 1]usize = @splat(0);
    for (0..info.num_window_groups) |g| starts[g + 1] = starts[g] + info.group_len[g];
    return starts;
}

/// Fills `out` with noise of energy 2^(nrg / 2).
fn fillNoise(out: []F24, nrg: i16, rng: *Rng) void {
    var raw: [1024]i32 = undefined;
    var energy: u64 = 0;
    for (raw[0..out.len]) |*r| {
        r.* = rng.next();
        energy += @intCast(@as(i64, r.*) * r.*);
    }
    if (energy == 0) {
        @memset(out, F24.zero);
        return;
    }
    const root: u64 = std.math.sqrt(energy);
    const inv = fixed.normalize(@intCast(@divTrunc(@as(u64, 1) << 46, root)), -46);
    const scale = fixed.fmul(inv, pow2Quarter(nrg));
    for (out, raw[0..out.len]) |*o, r| o.* = fixed.fmul(fixed.normalize(r, 0), scale);
}

/// Noise for every NOISE_HCB band of a channel.
pub fn pns(ch: *const ics.Channel, coefs: *Coefs, offsets: []const u16, rng: *Rng) void {
    const starts = groupStarts(ch.info);
    for (0..ch.info.num_window_groups) |g| {
        for (0..ch.info.max_sfb) |sfb| {
            if (ch.sections.sfb_cb[g][sfb] != ics.noise_hcb) continue;
            for (starts[g]..starts[g + 1]) |w| {
                const r = band(ch.info, offsets, w, sfb);
                fillNoise(coefs[r[0]..r[1]], ch.scalefactors[g][sfb], rng);
            }
        }
    }
}

fn msUsed(pair: *const ics.ChannelPair, g: usize, sfb: usize) bool {
    const ms = pair.ms orelse return false;
    return ms.present != 0 and ms.used[g][sfb];
}

/// l = m + s, r = m - s where the mask is set and neither channel's band is noise or intensity.
fn msStereo(pair: *const ics.ChannelPair, left: *Coefs, right: *Coefs, offsets: []const u16) void {
    const info = pair.left.info;
    const starts = groupStarts(info);
    for (0..info.num_window_groups) |g| {
        for (0..info.max_sfb) |sfb| {
            if (!msUsed(pair, g, sfb)) continue;
            if (pair.left.sections.sfb_cb[g][sfb] >= ics.noise_hcb) continue;
            if (pair.right.sections.sfb_cb[g][sfb] >= ics.noise_hcb) continue;
            for (starts[g]..starts[g + 1]) |w| {
                const r = band(info, offsets, w, sfb);
                for (left[r[0]..r[1]], right[r[0]..r[1]]) |*l, *rr| {
                    const m = l.*;
                    l.* = fixed.fadd(m, rr.*);
                    rr.* = fixed.fsub(m, rr.*);
                }
            }
        }
    }
}

/// invert_intensity as ISO/IEC 14496-3 states it, as we read it: the M/S mask flips the sign
/// only when ms_mask_present is 1. OpenCORE also flips it for ms_mask_present 2. OPEN until a
/// conformance stream decides.
fn intensitySign(pair: *const ics.ChannelPair, cb: u4, g: usize, sfb: usize) bool {
    var negative = cb == ics.intensity_hcb2;
    if (pair.ms) |ms| {
        if (ms.present == 1 and ms.used[g][sfb]) negative = !negative;
    }
    return negative;
}

/// The right channel's noise and intensity bands, from the finished left channel.
fn rightTools(pair: *const ics.ChannelPair, left: *const Coefs, right: *Coefs, offsets: []const u16, rng: *Rng) void {
    const info = pair.right.info;
    const starts = groupStarts(info);
    for (0..info.num_window_groups) |g| {
        for (0..info.max_sfb) |sfb| {
            const cb = pair.right.sections.sfb_cb[g][sfb];
            const sf = pair.right.scalefactors[g][sfb];
            if (cb == ics.noise_hcb) {
                const correlated = msUsed(pair, g, sfb) and pair.left.sections.sfb_cb[g][sfb] == ics.noise_hcb;
                const k = pow2Quarter(@as(i32, sf) - pair.left.scalefactors[g][sfb]);
                for (starts[g]..starts[g + 1]) |w| {
                    const r = band(info, offsets, w, sfb);
                    if (correlated) {
                        for (right[r[0]..r[1]], left[r[0]..r[1]]) |*o, l| o.* = fixed.fmul(l, k);
                    } else {
                        fillNoise(right[r[0]..r[1]], sf, rng);
                    }
                }
            } else if (cb == ics.intensity_hcb or cb == ics.intensity_hcb2) {
                // 0.5^(is_position / 4)
                var k = pow2Quarter(-@as(i32, sf));
                if (intensitySign(pair, cb, g, sfb)) k = k.negate();
                for (starts[g]..starts[g + 1]) |w| {
                    const r = band(info, offsets, w, sfb);
                    for (right[r[0]..r[1]], left[r[0]..r[1]]) |*o, l| o.* = fixed.fmul(l, k);
                }
            }
        }
    }
}

/// All three tools on a channel pair, in place. Without common_window the two channels may
/// use different window sequences, so each brings its own band offsets; M/S and correlated
/// noise only exist with common_window.
pub fn applyPair(pair: *const ics.ChannelPair, left: *Coefs, right: *Coefs, left_offsets: []const u16, right_offsets: []const u16, rng: *Rng) void {
    pns(&pair.left, left, left_offsets, rng);
    msStereo(pair, left, right, left_offsets);
    rightTools(pair, left, right, right_offsets, rng);
}

const testing = std.testing;

const offsets_4 = [_]u16{ 0, 4, 8, 12, 16 };

fn channel(cbs: []const u4, sfs: []const i16) ics.Channel {
    var ch: ics.Channel = .{
        .global_gain = 100,
        .info = .{ .window_sequence = .only_long, .window_shape = 0, .max_sfb = @intCast(cbs.len), .num_window_groups = 1, .group_len = @splat(0) },
        .sections = .{},
        .scalefactors = @splat(@splat(0)),
        .pulse = null,
        .tns = null,
        .spectrum = @splat(0),
    };
    ch.info.group_len[0] = 1;
    for (cbs, sfs, 0..) |cb, sf, i| {
        ch.sections.sfb_cb[0][i] = cb;
        ch.scalefactors[0][i] = sf;
    }
    return ch;
}

fn pairOf(l: ics.Channel, r: ics.Channel, present: u2, used: []const bool) ics.ChannelPair {
    var ms: ics.MsMask = .{ .present = present };
    for (used, 0..) |u, i| ms.used[0][i] = u;
    return .{ .common_window = true, .ms = ms, .left = l, .right = r };
}

fn filled(comptime v: f64) Coefs {
    var c: Coefs = @splat(F24.zero);
    for (c[0..16]) |*x| x.* = fixed.f24(v);
    return c;
}

test "M/S turns mid and side into left and right where the mask is set" {
    const p = pairOf(channel(&.{ 1, 1 }, &.{ 100, 100 }), channel(&.{ 1, 1 }, &.{ 100, 100 }), 1, &.{ true, false });
    var l = filled(3.0);
    var r = filled(1.0);
    var rng: Rng = .{};
    applyPair(&p, &l, &r, &offsets_4, &offsets_4, &rng);
    try testing.expectEqual(@as(f64, 4), l[0].toFloat());
    try testing.expectEqual(@as(f64, 2), r[3].toFloat());
    try testing.expectEqual(@as(f64, 3), l[4].toFloat()); // band 1: mask clear
    try testing.expectEqual(@as(f64, 1), r[4].toFloat());
}

test "intensity scales the left band by 0.5^(pos/4) with the codebook's sign" {
    var rng: Rng = .{};
    const l = filled(4.0);
    // book 15 (+), position 4 -> 2.0; book 14 (-), position 4 -> -2.0
    for ([_]struct { cb: u4, want: f64 }{ .{ .cb = 15, .want = 2 }, .{ .cb = 14, .want = -2 } }) |c| {
        const p = pairOf(channel(&.{1}, &.{100}), channel(&.{c.cb}, &.{4}), 0, &.{false});
        var ll = l;
        var r: Coefs = @splat(F24.zero);
        applyPair(&p, &ll, &r, &offsets_4, &offsets_4, &rng);
        try testing.expectEqual(c.want, r[2].toFloat());
    }
}

test "the M/S mask flips the intensity sign only when ms_mask_present is 1" {
    var rng: Rng = .{};
    for ([_]struct { present: u2, want: f64 }{ .{ .present = 1, .want = -2 }, .{ .present = 2, .want = 2 } }) |c| {
        const p = pairOf(channel(&.{1}, &.{100}), channel(&.{15}, &.{4}), c.present, &.{true});
        var l = filled(4.0);
        var r: Coefs = @splat(F24.zero);
        applyPair(&p, &l, &r, &offsets_4, &offsets_4, &rng);
        try testing.expectEqual(c.want, r[0].toFloat());
        try testing.expectEqual(@as(f64, 4), l[0].toFloat()); // intensity bands skip M/S
    }
}

fn bandEnergy(c: []const F24) f64 {
    var e: f64 = 0;
    for (c) |x| e += x.toFloat() * x.toFloat();
    return e;
}

test "a noise band carries energy 2^(nrg/2)" {
    var rng: Rng = .{};
    const ch = channel(&.{ ics.noise_hcb, 0 }, &.{ 10, 0 });
    var c: Coefs = @splat(F24.zero);
    pns(&ch, &c, &offsets_4, &rng);
    try testing.expectApproxEqRel(@as(f64, 32), bandEnergy(c[0..4]), 1e-4);
    try testing.expectEqual(@as(f64, 0), bandEnergy(c[4..8]));
}

test "correlated noise copies the left band; otherwise the right gets its own" {
    var rng: Rng = .{};
    const l = channel(&.{ics.noise_hcb}, &.{10});
    const r = channel(&.{ics.noise_hcb}, &.{14});
    var cl: Coefs = @splat(F24.zero);
    var cr: Coefs = @splat(F24.zero);
    applyPair(&pairOf(l, r, 1, &.{true}), &cl, &cr, &offsets_4, &offsets_4, &rng);
    for (0..4) |i| try testing.expectApproxEqRel(cl[i].toFloat() * 2, cr[i].toFloat(), 1e-6);

    cl = @splat(F24.zero);
    cr = @splat(F24.zero);
    applyPair(&pairOf(l, r, 0, &.{false}), &cl, &cr, &offsets_4, &offsets_4, &rng);
    try testing.expect(cr[0].toFloat() != cl[0].toFloat() * 2);
    try testing.expectApproxEqRel(@as(f64, 128), bandEnergy(cr[0..4]), 1e-4);
}
