//! IMDCT (ISO/IEC 14496-3): x[n] = 2/N * sum_k X[k] cos(2 pi / N (n + n0)(k + 1/2)),
//! n0 = (N/2 + 1) / 2.
//!
//! Our fixed-point design: the coefficients share one block exponent and become Q23 words with
//! one bit of headroom. The IMDCT is a DCT-IV of size N/2 folded out to N samples; the DCT-IV
//! runs as a pre-twiddle, an N/4-point radix-2 complex FFT, and a post-twiddle. The FFT is
//! block floating point: a stage halves only when its largest component could overflow, and
//! the halvings join the exponent. (Halving at every stage cost 9 bits on a pure tone.)
//! Output: samples in PCM units as Q7 words, saturated.
const std = @import("std");
const fixed = @import("fixed.zig");
const window = @import("window.zig");

const Word = fixed.Word;
const Acc = fixed.Acc;
const F24 = fixed.F24;

pub const Cx = struct { re: Word, im: Word };

/// Fraction bits of the time-domain words: PCM value * 2^7.
pub const pcm_frac = 7;

fn expj(comptime theta: f64) Cx {
    return .{ .re = window.q23Sat(@cos(theta)), .im = window.q23Sat(@sin(theta)) };
}

fn Twiddles(comptime n2: usize) type {
    return struct {
        const n4 = n2 / 2;
        const stages = std.math.log2_int(usize, n4);
        /// exp(-j pi (n + 1/4) / n2)
        const pre: [n4]Cx = blk: {
            @setEvalBranchQuota(100000);
            var t: [n4]Cx = undefined;
            for (&t, 0..) |*e, n| e.* = expj(-std.math.pi * (@as(f64, @floatFromInt(n)) + 0.25) / n2);
            break :blk t;
        };
        /// exp(-j pi k / n2)
        const post: [n4]Cx = blk: {
            @setEvalBranchQuota(100000);
            var t: [n4]Cx = undefined;
            for (&t, 0..) |*e, k| e.* = expj(-std.math.pi * @as(f64, @floatFromInt(k)) / n2);
            break :blk t;
        };
        /// exp(-j 2 pi k / n4)
        const fft: [n4 / 2]Cx = blk: {
            @setEvalBranchQuota(100000);
            var t: [n4 / 2]Cx = undefined;
            for (&t, 0..) |*e, k| e.* = expj(-2 * std.math.pi * @as(f64, @floatFromInt(k)) / n4);
            break :blk t;
        };
    };
}

/// Complex product in Q23, rounded and saturated.
pub fn cmul(a: Cx, b: Cx) Cx {
    return .{
        .re = fixed.sat(fixed.roundShift(fixed.mul(a.re, b.re) - fixed.mul(a.im, b.im), 23)),
        .im = fixed.sat(fixed.roundShift(fixed.mul(a.re, b.im) + fixed.mul(a.im, b.re), 23)),
    };
}

fn sum(a: Word, b: Word, sh: u6) Word {
    return @intCast(fixed.roundShift(@as(Acc, a) + b, sh));
}

/// Largest |re| or |im|.
fn maxComponent(z: []const Cx) u32 {
    var m: u32 = 0;
    for (z) |c| m = @max(m, @max(@abs(c.re), @abs(c.im)));
    return m;
}

/// In-place forward FFT of n4 points. Returns the number of halvings: the result is
/// FFT(z) / 2^return. A stage halves when any component reaches 2^21, which keeps |a + w b|
/// below 2^23.
fn fft(comptime n2: usize, z: []Cx) u5 {
    const T = Twiddles(n2);
    const n4 = T.n4;
    for (0..n4) |i| {
        const j = @bitReverse(@as(@Int(.unsigned, T.stages), @intCast(i)));
        if (j > i) std.mem.swap(Cx, &z[i], &z[j]);
    }
    var halvings: u5 = 0;
    var size: usize = 2;
    while (size <= n4) : (size *= 2) {
        const halve = maxComponent(z) >= 1 << 21;
        halvings += @intFromBool(halve);
        const sh: u6 = @intFromBool(halve);
        const half = size / 2;
        const step = n4 / size;
        var start: usize = 0;
        while (start < n4) : (start += size) {
            for (0..half) |j| {
                const a = z[start + j];
                const t = cmul(z[start + j + half], T.fft[j * step]);
                z[start + j] = .{ .re = sum(a.re, t.re, sh), .im = sum(a.im, t.im, sh) };
                z[start + j + half] = .{ .re = sum(a.re, -t.re, sh), .im = sum(a.im, -t.im, sh) };
            }
        }
    }
    return halvings;
}

/// u = DCT-IV(x) / 2^return. Inputs must stay within 2^22 in magnitude.
pub fn dct4(comptime n2: usize, x: *const [n2]Word, u: *[n2]Word) u5 {
    const T = Twiddles(n2);
    var z: [T.n4]Cx = undefined;
    for (&z, 0..) |*e, n| e.* = cmul(.{ .re = x[2 * n], .im = x[n2 - 1 - 2 * n] }, T.pre[n]);
    const halvings = fft(n2, &z);
    for (z, 0..) |e, k| {
        const c = cmul(e, T.post[k]);
        u[2 * k] = c.re;
        u[n2 - 1 - 2 * k] = -c.im;
    }
    return halvings;
}

/// v * 2^sh, rounded and saturated to a word.
fn shiftSat(v: Word, sh: i32) Word {
    if (v == 0) return 0;
    if (sh >= 0) {
        if (sh > 24) return if (v < 0) fixed.word_min else fixed.word_max;
        return fixed.sat(@as(Acc, v) << @intCast(sh));
    }
    if (sh <= -25) return 0;
    return @intCast(fixed.roundShift(v, @intCast(-sh)));
}

/// N = 2 * n2 time samples (PCM * 2^7) from n2 coefficients.
pub fn imdct(comptime n2: usize, coefs: *const [n2]F24, out: *[2 * n2]Word) void {
    var emax: i32 = std.math.minInt(i32);
    for (coefs) |c| {
        if (c.m != 0) emax = @max(emax, @as(i32, c.e) + 23);
    }
    if (emax == std.math.minInt(i32)) {
        @memset(out, 0);
        return;
    }
    // |x| <= 2^22: value = x * 2^(emax - 22)
    var x: [n2]Word = undefined;
    for (&x, coefs) |*w, c| {
        const s = emax - 22 - c.e;
        w.* = if (c.m == 0 or s >= 47) 0 else @intCast(fixed.roundShift(c.m, @intCast(s)));
    }
    var u: [n2]Word = undefined;
    const halvings = dct4(n2, &x, &u);
    // y = (2 / N) fold(DCT-IV) = fold(u) * 2^(halvings + emax - 22) / n2, then * 2^7 for Q7
    const sh = @as(i32, halvings) + emax - 22 - @as(i32, std.math.log2_int(usize, n2)) + pcm_frac;
    const n4 = n2 / 2;
    for (out, 0..) |*o, n| {
        const m = n + n4;
        const v: Word = if (m < n2) u[m] else if (m < 2 * n2) -u[2 * n2 - 1 - m] else -u[m - 2 * n2];
        o.* = shiftSat(v, sh);
    }
}

const testing = std.testing;

/// cos(2 pi i / (4N)) for i in 0..4N: every IMDCT/MDCT phase is one of these.
pub fn CosTable(comptime n: usize) type {
    return struct {
        t: [4 * n]f64,
        pub fn init() @This() {
            var s: @This() = undefined;
            for (&s.t, 0..) |*e, i| e.* = @cos(2 * std.math.pi * @as(f64, @floatFromInt(i)) / (4 * n));
            return s;
        }
        /// cos(2 pi / N (i + n0)(k + 1/2))
        pub fn at(self: *const @This(), i: usize, k: usize) f64 {
            return self.t[((2 * i + n / 2 + 1) * (2 * k + 1)) % (4 * n)];
        }
    };
}

fn checkAgainstDirect(comptime n2: usize, seed: u64) !void {
    const n = 2 * n2;
    const ct = CosTable(n).init();
    var prng = std.Random.DefaultPrng.init(seed);
    const rnd = prng.random();
    var coefs: [n2]F24 = undefined;
    var vals: [n2]f64 = undefined;
    for (&coefs, &vals, 0..) |*c, *v, k| {
        // a falling spectrum, like music: loud lows, quiet highs
        const amp = 2.0e6 / (1.0 + @as(f64, @floatFromInt(k)) / 8.0);
        c.* = fixed.normalize(@intFromFloat(@round((rnd.float(f64) * 2 - 1) * amp * 256)), -8);
        v.* = c.toFloat();
    }
    var out: [n]Word = undefined;
    imdct(n2, &coefs, &out);
    var err: f64 = 0;
    var peak: f64 = 0;
    for (0..n) |i| {
        var y: f64 = 0;
        for (0..n2) |k| y += vals[k] * ct.at(i, k);
        y *= 2.0 / @as(f64, @floatFromInt(n));
        peak = @max(peak, @abs(y));
        err = @max(err, @abs(@as(f64, @floatFromInt(out[i])) / (1 << pcm_frac) - y));
    }
    // within one 16-bit PCM step of the double-precision transform
    try testing.expect(err < 1.0);
    try testing.expect(peak > 1000);
}

test "the fast fixed-point DCT-IV matches the definition" {
    var prng = std.Random.DefaultPrng.init(1);
    const rnd = prng.random();
    var x: [128]Word = undefined;
    for (&x) |*v| v.* = rnd.intRangeAtMost(Word, -(1 << 22), 1 << 22);
    var u: [128]Word = undefined;
    const h = dct4(128, &x, &u);
    for (0..128) |i| {
        var want: f64 = 0;
        for (0..128) |k| want += @as(f64, @floatFromInt(x[k])) * @cos(std.math.pi / 128.0 * (@as(f64, @floatFromInt(i)) + 0.5) * (@as(f64, @floatFromInt(k)) + 0.5));
        try testing.expectApproxEqAbs(want / std.math.ldexp(@as(f64, 1), h), @as(f64, @floatFromInt(u[i])), 8);
    }
}

test "long and short IMDCT stay within one PCM step of double precision" {
    try checkAgainstDirect(1024, 7);
    try checkAgainstDirect(128, 8);
}

test "an all-zero spectrum gives silence" {
    const coefs: [128]F24 = @splat(F24.zero);
    var out: [256]Word = @splat(1);
    imdct(128, &coefs, &out);
    for (out) |o| try testing.expectEqual(@as(Word, 0), o);
}

test "a lone coefficient keeps full precision through the block-floating FFT" {
    var x: [128]Word = @splat(0);
    x[5] = 1 << 22;
    var u: [128]Word = undefined;
    const h = dct4(128, &x, &u);
    try testing.expect(h <= 1);
}
