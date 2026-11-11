//! IMDCT in measured sm1 operations: the twin of `ref/aac/imdct.zig`.
//!
//! Input is the dequantiser's block-floating form, words w with value w * 2^e. The words are
//! first brought to a largest |x| in [2^21, 2^22), the shift found by comparisons (one rounded
//! halving above 2^22, doublings below 2^21). Then the reference's structure: a pre-twiddle, an
//! N/4-point FFT, a post-twiddle and the fold, with four changes:
//!
//!   - `cmul` is two rounded products summed (no 48-bit sum of products), so each part of a
//!     complex product carries up to one more LSB of rounding.
//!   - The FFT is radix 4 (a radix-2 first stage when log2 of its size is odd): a butterfly
//!     takes four points through three twiddle products, so a 512-point FFT is five stages, not
//!     nine.
//!   - Its block floating point scales the inputs of a stage rather than its sums. Every
//!     component lies in [-2^k, 2^k) for k = 23 - (the fewest redundant sign bits, x01's norm);
//!     a radix-4 stage shifts them right by k - 20 (rounded, when positive), a radix-2 stage by
//!     k - 21. Inputs are then at most 2^20 (2^21), so a radix-4 output stays below
//!     (1 + 3 sqrt 2) 2^20 < 2^22.4, a radix-2 one below (1 + sqrt 2) 2^21 < 2^22.3. Against
//!     the ffmpeg binary's PCM this costs at most 0.7 dB of SNR on the fixtures (mono.aac_at
//!     82.5 to 81.8 dB) and one LSB of max |diff|. (Halving the
//!     sums, the reference's rule, can grow past 2^23 over a few loud stages; a 24-bit add would
//!     wrap.)
//!   - The bit reversal is a table: sm1 shows no bit-reverse operation.
//!
//! Output, like the reference: N samples in PCM units as Q7 words, saturated by comparisons.
const std = @import("std");
const ops = @import("../ops.zig");
const ref = @import("../../aac/imdct.zig");
const sine = @import("sine.zig");

const Word = ops.Word;
const word_max: Word = std.math.maxInt(Word);
const word_min: Word = std.math.minInt(Word);

pub const pcm_frac = ref.pcm_frac;

pub const Cx = struct { re: Word, im: Word };

/// exp(-j m pi / 4096), from the shared sine table (m in [0, 4096]).
fn expk(m: usize) Cx {
    return .{ .re = sine.cos(m), .im = ops.sub(0, sine.sin(m)) };
}

/// (cos, sin) of m pi / 4096, m in [0, 2048].
fn cs(m: usize) Cx {
    return .{ .re = sine.cos(m), .im = sine.sin(m) };
}

/// exp(-j 2 pi a / b) for 0 <= a / b < 3/4, from the sine table (angles past pi negated back).
fn expTurn(a: usize, b: usize) Cx {
    const m = a * 8192 / b; // exact: b divides 8192 a for the sizes used
    if (m <= 4096) return expk(m);
    const e = expk(m - 4096);
    return .{ .re = ops.sub(0, e.re), .im = ops.sub(0, e.im) };
}

/// The tables an x17 routine loads: twiddles in Q23, all read from `sine` (docs/aac-mode0.md),
/// and the bit-reversal permutation.
pub fn Tables(comptime n2: usize) type {
    return struct {
        pub const n4 = n2 / 2;
        pub const stages = std.math.log2_int(usize, n4);
        /// (cos, sin) of pi (n + 1/4) / n2, m = (4n + 1) * 1024 / n2: the pre-twiddle is its
        /// conjugate, taken by `cmulc`, so both parts are sine table words as stored.
        pub const pre: [n4]Cx = blk: {
            @setEvalBranchQuota(200000);
            var t: [n4]Cx = undefined;
            for (&t, 0..) |*e, n| e.* = cs((4 * n + 1) * (1024 / n2));
            break :blk t;
        };
        /// (cos, sin) of pi k / n2, m = k * 4096 / n2, the post-twiddle's conjugate.
        pub const post: [n4]Cx = blk: {
            @setEvalBranchQuota(200000);
            var t: [n4]Cx = undefined;
            for (&t, 0..) |*e, k| e.* = cs(k * (4096 / n2));
            break :blk t;
        };
        /// A radix-2 first stage when `stages` is odd.
        pub const radix2_first = stages % 2 == 1;
        /// The radix-4 stages' twiddles in the order a butterfly reads them: for each stage
        /// combining four blocks of size l into 4 l (l = 1 or 2, then times 4), for j = 0 .. l - 1,
        /// exp(-j 2 pi m j / (4 l)) for m = 1, 2, 3: 1020 words long, 126 short, as many as the
        /// radix-2 twiddles they replace.
        pub const tw4_len: usize = blk: {
            var n: usize = 0;
            var l: usize = if (radix2_first) 2 else 1;
            while (4 * l <= n4) : (l *= 4) n += l;
            break :blk n;
        };
        pub const tw4: [tw4_len][3]Cx = blk: {
            @setEvalBranchQuota(400000);
            var t: [tw4_len][3]Cx = undefined;
            var i: usize = 0;
            var l: usize = if (radix2_first) 2 else 1;
            while (4 * l <= n4) : (l *= 4) {
                for (0..l) |j| {
                    for (0..3) |mm| t[i][mm] = expTurn((mm + 1) * j, 4 * l);
                    i += 1;
                }
            }
            break :blk t;
        };
        /// rev[i]: i with its `stages` bits reversed.
        pub const rev: [n4]u16 = blk: {
            @setEvalBranchQuota(200000);
            var t: [n4]u16 = undefined;
            for (&t, 0..) |*e, i| e.* = @bitReverse(@as(@Int(.unsigned, stages), @intCast(i)));
            break :blk t;
        };
    };
}

/// a * b, each part two rounded products summed.
pub fn cmul(a: Cx, b: Cx) Cx {
    return .{
        .re = ops.sub(ops.mulRound23(a.re, b.re), ops.mulRound23(a.im, b.im)),
        .im = ops.add(ops.mulRound23(a.re, b.im), ops.mulRound23(a.im, b.re)),
    };
}

/// a * conj(b): re = rnd(a.re b.re) + rnd(a.im b.im), im = rnd(a.im b.re) - rnd(a.re b.im).
pub fn cmulc(a: Cx, b: Cx) Cx {
    return .{
        .re = ops.add(ops.mulRound23(a.re, b.re), ops.mulRound23(a.im, b.im)),
        .im = ops.sub(ops.mulRound23(a.im, b.re), ops.mulRound23(a.re, b.im)),
    };
}

/// |a| >= 2^k, as the sign test on |a| - 2^k (|a| below 2^23 throughout).
fn atLeast(a: Word, k: u5) bool {
    const m = if (ops.isNeg(a)) ops.sub(0, a) else a;
    return !ops.isNeg(ops.sub(m, @as(Word, 1) << k));
}

/// The right shift that brings every component into [-2^lim, 2^lim]: k - lim when positive,
/// every |component| below 2^k with k = 23 - norm(the OR of the |components|). The OR stands
/// for a min over norms (one bitwise op per word on sm1); |a| makes it one step conservative
/// for a = -2^j, where norm(a) itself would allow 2^j.
fn stageShift(z: []const Cx, lim: u5) u5 {
    var m: Word = 0;
    for (z) |c| m = ops.bitOr(m, ops.bitOr(ops.abs(c.re), ops.abs(c.im)));
    const n = ops.norm(m);
    const k: i32 = 23 - @as(i32, n);
    return @intCast(@max(0, k - lim));
}

fn scale(z: []Cx, sh: u5) void {
    if (sh != 0) for (z) |*c| {
        c.* = .{ .re = ops.rshr(c.re, sh), .im = ops.rshr(c.im, sh) };
    };
}

fn cadd(a: Cx, b: Cx) Cx {
    return .{ .re = ops.add(a.re, b.re), .im = ops.add(a.im, b.im) };
}

fn csub(a: Cx, b: Cx) Cx {
    return .{ .re = ops.sub(a.re, b.re), .im = ops.sub(a.im, b.im) };
}

/// a - j b and a + j b.
fn cmj(a: Cx, b: Cx) Cx {
    return .{ .re = ops.add(a.re, b.im), .im = ops.sub(a.im, b.re) };
}

fn cpj(a: Cx, b: Cx) Cx {
    return .{ .re = ops.sub(a.re, b.im), .im = ops.add(a.im, b.re) };
}

/// In place: FFT(z) / 2^return over n4 points, z already in (radix-2) bit-reversed order.
/// Bit-reversed order puts the four blocks a radix-4 step combines as x[4m], x[4m + 2],
/// x[4m + 1], x[4m + 3] of the 4 l points it builds.
fn fft(comptime n2: usize, z: []Cx) u5 {
    const T = Tables(n2);
    var scaled: u5 = 0;
    var l: usize = 1;
    if (T.radix2_first) {
        const sh = stageShift(z, 21);
        scale(z, sh);
        scaled += sh;
        var i: usize = 0;
        while (i < T.n4) : (i += 2) {
            const a = z[i];
            z[i] = cadd(a, z[i + 1]);
            z[i + 1] = csub(a, z[i + 1]);
        }
        l = 2;
    }
    var t: usize = 0;
    while (4 * l <= T.n4) : (l *= 4) {
        const sh = stageShift(z, 20);
        scale(z, sh);
        scaled += sh;
        var start: usize = 0;
        while (start < T.n4) : (start += 4 * l) {
            for (0..l) |j| {
                const w = T.tw4[t + j];
                const b0 = z[start + j];
                const b1 = cmul(z[start + l + j], w[1]); // F2 W^2j
                const b2 = cmul(z[start + 2 * l + j], w[0]); // F1 W^j
                const b3 = cmul(z[start + 3 * l + j], w[2]); // F3 W^3j
                const p = cadd(b0, b1);
                const q = csub(b0, b1);
                const r = cadd(b2, b3);
                const s2 = csub(b2, b3);
                z[start + j] = cadd(p, r);
                z[start + l + j] = cmj(q, s2);
                z[start + 2 * l + j] = csub(p, r);
                z[start + 3 * l + j] = cpj(q, s2);
            }
        }
        t += l;
    }
    return scaled;
}

/// u = DCT-IV(x) / 2^return, |x| < 2^22.
pub fn dct4(comptime n2: usize, x: *const [n2]Word, u: *[n2]Word) u5 {
    const T = Tables(n2);
    var z: [T.n4]Cx = undefined;
    for (0..T.n4) |n| z[T.rev[n]] = cmulc(.{ .re = x[2 * n], .im = x[n2 - 1 - 2 * n] }, T.pre[n]);
    const scaled = fft(n2, &z);
    for (z, 0..) |e, k| {
        const c = cmulc(e, T.post[k]);
        u[2 * k] = c.re;
        u[n2 - 1 - 2 * k] = ops.sub(0, c.im);
    }
    return scaled;
}

/// v * 2^sh, rounded; saturated by comparisons when it would leave the word.
fn shiftSat(v: Word, sh: i32) Word {
    if (ops.isZero(v)) return 0;
    if (sh <= -24) return 0;
    if (sh < 0) return ops.rshr(v, @intCast(-sh));
    const top: Word = if (ops.isNeg(v)) word_min else word_max;
    if (sh >= 23) return top;
    // |v| >= 2^(23 - sh) overflows; v = -2^(23 - sh) exactly fits, which the test leaves out
    // (a one-LSB saturation, never reached by IMDCT outputs, which are rounded products).
    if (atLeast(v, @intCast(23 - sh))) return top;
    return shlLong(v, @intCast(sh));
}

/// v << s for s in 0..22: two shifts, since one takes 0..15.
fn shlLong(v: Word, s: u5) Word {
    const a: u4 = @intCast(@min(s, 15));
    return ops.shl(ops.shl(v, a), @intCast(s - a));
}

/// x = w scaled so the largest |x| (big = the largest |w|, not 0) is in [2^21, 2^22); returns
/// x's exponent.
fn normalise(comptime n2: usize, w: *const [n2]Word, big: Word, e: i32, x: *[n2]Word) i32 {
    if (atLeast(big, 22)) {
        for (x, w) |*d, v| d.* = ops.rshr(v, 1);
        return e + 1;
    }
    var s: u5 = 0;
    var b = big;
    while (!atLeast(b, 21)) : (s += 1) b = ops.shl(b, 1);
    for (x, w) |*d, v| d.* = shlLong(v, s);
    return e - s;
}

/// N = 2 * n2 samples (PCM * 2^7) from n2 words with value w * 2^e.
pub fn imdct(comptime n2: usize, w: *const [n2]Word, e: i32, out: *[2 * n2]Word) void {
    // The largest |w|, by comparisons.
    var big: Word = 0;
    for (w) |v| {
        const m = if (ops.isNeg(v)) ops.sub(0, v) else v;
        if (ops.isNeg(ops.sub(big, m))) big = m;
    }
    if (ops.isZero(big)) {
        @memset(out, 0);
        return;
    }
    var x: [n2]Word = undefined;
    const ex = normalise(n2, w, big, e, &x);
    var u: [n2]Word = undefined;
    const scaled = dct4(n2, &x, &u);
    // y = (2 / N) fold(DCT-IV(x)) * 2^ex = fold(u) * 2^(scaled + ex) / n2, then * 2^7 for Q7
    const sh = @as(i32, scaled) + ex - @as(i32, std.math.log2_int(usize, n2)) + pcm_frac;
    const n4 = n2 / 2;
    for (out, 0..) |*o, n| {
        const m = n + n4;
        const v: Word = if (m < n2) u[m] else if (m < 2 * n2) ops.sub(0, u[2 * n2 - 1 - m]) else ops.sub(0, u[m - 2 * n2]);
        o.* = shiftSat(v, sh);
    }
}

const testing = std.testing;
const fixed = @import("../../fixed.zig");

/// The double-precision IMDCT of value w * 2^e, in Q7.
fn direct(comptime n2: usize, w: *const [n2]Word, e: i32, out: *[2 * n2]f64) void {
    const n = 2 * n2;
    const ct = ref.CosTable(n).init();
    for (out, 0..) |*o, i| {
        var y: f64 = 0;
        for (0..n2) |k| y += std.math.ldexp(@as(f64, @floatFromInt(w[k])), e) * ct.at(i, k);
        o.* = y * 2.0 / @as(f64, @floatFromInt(n)) * (1 << pcm_frac);
    }
}

const Err = struct { exact: f64, refd: f64, peak: f64 };

fn compare(comptime n2: usize, w: *const [n2]Word, e: i32) Err {
    var out: [2 * n2]Word = undefined;
    imdct(n2, w, e, &out);
    var want: [2 * n2]f64 = undefined;
    direct(n2, w, e, &want);
    var coefs: [n2]fixed.F24 = undefined;
    for (&coefs, w) |*c, v| c.* = fixed.normalize(v, e);
    var r: [2 * n2]Word = undefined;
    ref.imdct(n2, &coefs, &r);
    var err: Err = .{ .exact = 0, .refd = 0, .peak = 0 };
    for (out, want, r) |o, y, rv| {
        err.peak = @max(err.peak, @abs(y));
        err.exact = @max(err.exact, @abs(@as(f64, @floatFromInt(o)) - y));
        err.refd = @max(err.refd, @abs(@as(f64, @floatFromInt(o)) - @as(f64, @floatFromInt(rv))));
    }
    return err;
}

/// A falling spectrum, like music, at block-floating scale: the largest word near 2^22.
fn music(comptime n2: usize, rnd: std.Random, w: *[n2]Word) void {
    const top = rnd.float(f64) * 0.42 + 21.6;
    for (w, 0..) |*v, k| {
        const amp = std.math.pow(f64, 2, top) / (1.0 + @as(f64, @floatFromInt(k)) / 8.0);
        v.* = @intFromFloat(@round((rnd.float(f64) * 2 - 1) * amp));
    }
}

/// The exponent that puts the block's double-precision peak near 2^target in Q7.
fn exponentFor(comptime n2: usize, w: *const [n2]Word, target: f64) i32 {
    var y: [2 * n2]f64 = undefined;
    direct(n2, w, 0, &y);
    var peak: f64 = 0;
    for (y) |v| peak = @max(peak, @abs(v));
    return @intFromFloat(@floor(target - std.math.log2(peak)));
}

test "long and short blocks stay near one PCM step of double precision" {
    var prng = std.Random.DefaultPrng.init(0x1D);
    const rnd = prng.random();
    var worst: Err = .{ .exact = 0, .refd = 0, .peak = 0 };
    for (0..14) |i| {
        // peaks from 2^10 to 2^22.5 in Q7 (8 PCM to near full scale)
        const target = 10.0 + @as(f64, @floatFromInt(i)) * 0.9;
        var wl: [1024]Word = undefined;
        music(1024, rnd, &wl);
        const a = compare(1024, &wl, exponentFor(1024, &wl, target));
        var ws: [128]Word = undefined;
        music(128, rnd, &ws);
        const b = compare(128, &ws, exponentFor(128, &ws, target));
        worst.exact = @max(worst.exact, @max(a.exact, b.exact));
        worst.refd = @max(worst.refd, @max(a.refd, b.refd));
        worst.peak = @max(worst.peak, @max(a.peak, b.peak));
    }
    // One 16-bit PCM step is 2^7 in Q7. Measured: 143 against double precision at a 2^21.7
    // peak (the reference: 41; the radix-2 FFT: 73), 102 against the reference; the error grows
    // with loudness. Bounds with headroom, to catch a regression:
    try testing.expect(worst.exact < 160);
    try testing.expect(worst.refd < 112);
    try testing.expect(worst.peak > 1 << 21);
}

test "a lone coefficient and a full-scale square keep their precision" {
    var w: [1024]Word = @splat(0);
    w[5] = 3;
    const a = compare(1024, &w, 0);
    try testing.expect(a.exact < 1);
    for (&w, 0..) |*v, k| v.* = if (k % 2 == 0) (1 << 22) + 1000 else -(1 << 22) - 1000;
    const b = compare(1024, &w, -14);
    try testing.expect(b.exact < 128);
}

test "normalising puts the largest word in [2^21, 2^22) and keeps the value" {
    var prng = std.Random.DefaultPrng.init(0x4E);
    const rnd = prng.random();
    for (0..2000) |_| {
        var w: [8]Word = undefined;
        const top = rnd.intRangeAtMost(u5, 0, 22);
        var big: Word = 0;
        for (&w) |*v| {
            v.* = rnd.intRangeAtMost(Word, -(@as(Word, 1) << top), (@as(Word, 1) << top) + (@as(Word, 1) << top >> 2));
            big = @max(big, @as(Word, @intCast(@abs(v.*))));
        }
        if (big == 0) continue;
        var x: [8]Word = undefined;
        const ex = normalise(8, &w, big, 3, &x);
        var xbig: Word = 0;
        for (x) |v| xbig = @max(xbig, @as(Word, @intCast(@abs(v))));
        try testing.expect(xbig >= 1 << 21 and xbig < 1 << 22);
        for (w, x) |v, d| {
            const want = std.math.ldexp(@as(f64, @floatFromInt(v)), 3 - ex);
            try testing.expect(@abs(@as(f64, @floatFromInt(d)) - want) <= 0.5);
        }
    }
}

test "a stage's shift brings every component within 2^lim" {
    var z = [_]Cx{ .{ .re = 0, .im = (1 << 20) - 1 }, .{ .re = 5, .im = 0 } };
    try testing.expectEqual(@as(u5, 0), stageShift(&z, 20));
    z[1].re = -(1 << 20) + 1;
    try testing.expectEqual(@as(u5, 0), stageShift(&z, 20));
    z[1].re = -(1 << 20); // |a| = 2^20: one step conservative
    try testing.expectEqual(@as(u5, 1), stageShift(&z, 20));
    z[1].re = 1 << 20;
    try testing.expectEqual(@as(u5, 1), stageShift(&z, 20));
    z[0].im = (1 << 23) - 1;
    try testing.expectEqual(@as(u5, 3), stageShift(&z, 20));
    try testing.expectEqual(@as(u5, 2), stageShift(&z, 21));
    // the largest input after the shift, rounded up, is 2^20: a radix-4 output is at most
    // (1 + 3 sqrt 2) 2^20 + 3 rounding LSBs, below 2^22.4
    try testing.expect(ops.rshr((1 << 23) - 1, 3) <= 1 << 20);
}

test "the radix-4 FFT matches a direct DFT" {
    const n2 = 1024;
    const T = Tables(n2);
    var prng = std.Random.DefaultPrng.init(0xF4);
    const rnd = prng.random();
    var x: [T.n4]Cx = undefined;
    for (&x) |*c| c.* = .{ .re = rnd.intRangeAtMost(Word, -(1 << 20), 1 << 20), .im = rnd.intRangeAtMost(Word, -(1 << 20), 1 << 20) };
    var z: [T.n4]Cx = undefined;
    for (0..T.n4) |n| z[T.rev[n]] = x[n];
    const sc = fft(n2, &z);
    var worst: f64 = 0;
    for (0..T.n4) |k| {
        var re: f64 = 0;
        var im: f64 = 0;
        for (0..T.n4) |n| {
            const a = -2.0 * std.math.pi * @as(f64, @floatFromInt(n * k % T.n4)) / T.n4;
            const xr: f64 = @floatFromInt(x[n].re);
            const xi: f64 = @floatFromInt(x[n].im);
            re += xr * @cos(a) - xi * @sin(a);
            im += xr * @sin(a) + xi * @cos(a);
        }
        const f = std.math.ldexp(@as(f64, 1), -@as(i32, sc));
        worst = @max(worst, @abs(re * f - @as(f64, @floatFromInt(z[k].re))));
        worst = @max(worst, @abs(im * f - @as(f64, @floatFromInt(z[k].im))));
    }
    // the output is ~2^20 * sqrt(512) / 2^sc; a few LSBs of rounding per stage
    try testing.expect(worst < 16);
}

test "an all-zero block gives silence" {
    const w: [128]Word = @splat(0);
    var out: [256]Word = @splat(1);
    imdct(128, &w, 5, &out);
    for (out) |o| try testing.expectEqual(@as(Word, 0), o);
}

test "outputs past the word saturate, as the reference's do" {
    var w: [128]Word = @splat(0);
    w[0] = 1 << 21;
    var out: [256]Word = undefined;
    imdct(128, &w, 20, &out);
    var hit = false;
    for (out) |o| {
        if (o == word_max or o == word_min) hit = true;
    }
    try testing.expect(hit);
}

test "left shifts past 15 saturate or shift exactly" {
    try testing.expectEqual(@as(Word, 3 << 18), shiftSat(3, 18));
    try testing.expectEqual(@as(Word, -5 << 20), shiftSat(-5, 20));
    try testing.expectEqual(word_max, shiftSat(8, 20));
    try testing.expectEqual(word_min, shiftSat(-9, 20));
    try testing.expectEqual(@as(Word, 1 << 22), shiftSat(1, 22));
}
