//! The hybrid filterbank in measured sm1 operations: the twin of `ref/mp3/hybrid.zig`, on Q21
//! words, every product one x02 rounded product (`ops.mulRound23`, Q23 constants).
//!
//!   - Alias reduction: each butterfly output is a two-term tap sum with Q23 cs, ca.
//!   - IMDCT-36 as minimp3's L3_imdct36 (lieff/minimp3, CC0; NOTICE): the 18 lines fold into
//!     two 9-point inputs, each through a 9-point DCT-III (`dct9`), then a twiddle rotation.
//!     Its second half stays unwindowed as 9 overlap words, windowed by the next block's
//!     window: the normal and stop windows' halves pair across blocks (ISO/IEC 11172-3
//!     2.4.3.4.10.3's block shapes), so 9 words per subband carry what ISO's 18 do.
//!   - IMDCT-12 per short window the same way with a 3-point stage (minimp3 L3_imdct12).
//!   - Every constant is a cosine of the ISO angles, Q23, 1.0 held as 2^23 - 1.
//!   - Overlap-add is folded into the rotation; the frequency inversion is a negation.
//! Words wrap at 24 bits, as sm1's do: Q21 leaves |value| < 4, the fixtures peak below 1.1.
const std = @import("std");
const ops = @import("../ops.zig");
const sideinfo = @import("../../mp3/sideinfo.zig");
const bands = @import("../../mp3/bands.zig");
const requant = @import("requant.zig");

const Word = ops.Word;
pub const Coefs = requant.Coefs;

fn q(comptime x: f64, comptime f: u5) Word {
    return @intFromFloat(@round(x * @as(f64, @floatFromInt(@as(u32, 1) << f))));
}

const c_alias = [8]f64{ -0.6, -0.535, -0.33, -0.185, -0.095, -0.041, -0.0142, -0.0037 };
pub const cs: [8]Word = blk: {
    var t: [8]Word = undefined;
    for (&t, c_alias) |*e, c| e.* = q(1.0 / @sqrt(1.0 + c * c), 23);
    break :blk t;
};
pub const ca: [8]Word = blk: {
    var t: [8]Word = undefined;
    for (&t, c_alias) |*e, c| e.* = q(c / @sqrt(1.0 + c * c), 23);
    break :blk t;
};

fn qw(comptime x: f64) Word {
    return if (x >= 1.0) (1 << 23) - 1 else q(x, 23);
}

fn cosPi(comptime num: f64, comptime den: f64) Word {
    return qw(@cos(std.math.pi * num / den));
}

fn sinPi(comptime num: f64, comptime den: f64) Word {
    return qw(@sin(std.math.pi * num / den));
}

/// dct9's constants: 1/2, cos(pi/9), cos(2pi/9), cos(4pi/9), cos(pi/6), cos(pi/18),
/// cos(7pi/18), cos(5pi/18).
pub const k9 = [8]Word{ 1 << 22, cosPi(1, 9), cosPi(2, 9), cosPi(4, 9), cosPi(1, 6), cosPi(1, 18), cosPi(7, 18), cosPi(5, 18) };

/// The IMDCT-36 rotation: tw[i] = cos((17 - 2i) pi / 72), tw[9 + i] = cos((19 + 2i) pi / 72).
pub const tw9: [18]Word = blk: {
    var t: [18]Word = undefined;
    for (0..9) |i| {
        t[i] = cosPi(@floatFromInt(17 - 2 * i), 72);
        t[9 + i] = cosPi(@floatFromInt(19 + 2 * i), 72);
    }
    break :blk t;
};

/// Long windows' halves, [w(i), w(9 + i)]: normal cos / sin((2i + 1) pi / 72); stop (and so a
/// start block's second half): 1 then cos((2i - 11) pi / 24) for i = 6..8, 0 then sin.
pub const win: [2][18]Word = blk: {
    var t: [2][18]Word = undefined;
    for (0..9) |i| {
        t[0][i] = cosPi(@floatFromInt(2 * i + 1), 72);
        t[0][9 + i] = sinPi(@floatFromInt(2 * i + 1), 72);
        t[1][i] = if (i < 6) qw(1.0) else cosPi(@floatFromInt(2 * i - 11), 24);
        t[1][9 + i] = if (i < 6) 0 else sinPi(@floatFromInt(2 * i - 11), 24);
    }
    break :blk t;
};

/// The IMDCT-12 rotation and window: cos((5 - 2i) pi / 24), then sin, i = 0..2; and cos(pi/6).
pub const tw3: [6]Word = blk: {
    var t: [6]Word = undefined;
    for (0..3) |i| {
        t[i] = cosPi(@floatFromInt(5 - 2 * i), 24);
        t[3 + i] = sinPi(@floatFromInt(5 - 2 * i), 24);
    }
    break :blk t;
};
pub const c30 = cosPi(1, 6);

const add = ops.add;
const sub = ops.sub;
const mul = ops.mulRound23;

/// In-place 9-point DCT-III (minimp3 L3_dct3_9), products rounded one at a time.
pub fn dct9(y: *[9]Word) void {
    var s0 = y[0];
    var s2 = y[2];
    var s4 = y[4];
    var s6 = y[6];
    var s8 = y[8];
    var t0 = add(s0, mul(s6, k9[0]));
    s0 = sub(s0, s6);
    var t4 = mul(add(s4, s2), k9[1]);
    var t2 = mul(add(s8, s2), k9[2]);
    s6 = mul(sub(s4, s8), k9[3]);
    s4 = sub(add(s4, s8), s2);
    s2 = sub(s0, mul(s4, k9[0]));
    y[4] = add(s4, s0);
    s8 = add(sub(t0, t2), s6);
    s0 = add(sub(t0, t4), t2);
    s4 = sub(add(t0, t4), s6);
    var s1 = y[1];
    var s3 = y[3];
    var s5 = y[5];
    var s7 = y[7];
    s3 = mul(s3, k9[4]);
    t0 = mul(add(s5, s1), k9[5]);
    t4 = mul(sub(s5, s7), k9[6]);
    t2 = mul(add(s1, s7), k9[7]);
    s1 = mul(sub(sub(s1, s5), s7), k9[4]);
    s5 = sub(sub(t0, s3), t2);
    s7 = sub(sub(t4, s3), t0);
    s3 = sub(add(t4, s3), t2);
    y[0] = sub(s4, s7);
    y[1] = add(s2, s1);
    y[2] = sub(s0, s3);
    y[3] = add(s8, s5);
    y[5] = sub(s8, s5);
    y[6] = add(s0, s3);
    y[7] = sub(s2, s1);
    y[8] = add(s4, s7);
}

fn reorder(c: *Coefs, b: bands.Bands) void {
    var start: usize = 0;
    for (b.widths[0..b.n_long]) |w| start += w;
    var tmp: [576]Word = undefined;
    var src = start;
    var dst: usize = 0;
    var e: usize = b.n_long;
    while (e < b.len()) : (e += 3) {
        const len = b.widths[e];
        for (0..len) |i| for (0..3) |w| {
            tmp[dst] = c[src + w * len + i];
            dst += 1;
        };
        src += 3 * len;
    }
    @memcpy(c[start .. start + dst], tmp[0..dst]);
}

fn antialias(c: *Coefs, boundaries: usize) void {
    for (0..boundaries) |sb| for (0..8) |i| {
        const lo = sb * 18 + 17 - i;
        const hi = sb * 18 + 18 + i;
        const bu = c[lo];
        const bd = c[hi];
        c[lo] = ops.accRshr(ops.mac(ops.mac(0, bu, cs[i]), ops.sub(0, bd), ca[i]), 24);
        c[hi] = ops.accRshr(ops.mac(ops.mac(0, bd, cs[i]), bu, ca[i]), 24);
    };
}

/// One long subband in place: 18 lines in, 18 samples out, overlap ov updated (L3_imdct36).
fn imdct36(x: *[18]Word, ov: *[9]Word, w: *const [18]Word) void {
    var co: [9]Word = undefined;
    var si: [9]Word = undefined;
    co[0] = sub(0, x[0]);
    si[0] = x[17];
    for (0..4) |i| {
        si[8 - 2 * i] = sub(x[4 * i + 1], x[4 * i + 2]);
        co[1 + 2 * i] = add(x[4 * i + 1], x[4 * i + 2]);
        si[7 - 2 * i] = sub(x[4 * i + 4], x[4 * i + 3]);
        co[2 + 2 * i] = sub(0, add(x[4 * i + 3], x[4 * i + 4]));
    }
    dct9(&co);
    dct9(&si);
    for (0..9) |i| {
        const s = if (i & 1 == 1) sub(0, si[i]) else si[i];
        const o = ov[i];
        const sum = add(mul(co[i], tw9[9 + i]), mul(s, tw9[i]));
        ov[i] = sub(mul(co[i], tw9[i]), mul(s, tw9[9 + i]));
        x[i] = sub(mul(o, w[i]), mul(sum, w[9 + i]));
        x[17 - i] = add(mul(o, w[9 + i]), mul(sum, w[i]));
    }
}

/// A 3-point IDCT (minimp3 L3_idct3).
fn idct3(x0: Word, x1: Word, x2: Word) [3]Word {
    const m1 = mul(x1, c30);
    const a1 = sub(x0, mul(x2, k9[0]));
    return .{ add(a1, m1), add(x0, x2), sub(a1, m1) };
}

/// One short window (L3_imdct12): x[3k] of its lines, 6 samples to dst, overlap ov[0..3].
fn imdct12(x: []const Word, dst: []Word, ov: []Word) void {
    const co = idct3(sub(0, x[0]), add(x[6], x[3]), add(x[12], x[9]));
    var si = idct3(x[15], sub(x[12], x[9]), sub(x[6], x[3]));
    si[1] = sub(0, si[1]);
    for (0..3) |i| {
        const o = ov[i];
        const sum = add(mul(co[i], tw3[3 + i]), mul(si[i], tw3[i]));
        ov[i] = sub(mul(co[i], tw3[i]), mul(si[i], tw3[3 + i]));
        dst[i] = sub(mul(o, tw3[2 - i]), mul(sum, tw3[5 - i]));
        dst[5 - i] = add(mul(o, tw3[5 - i]), mul(sum, tw3[2 - i]));
    }
}

/// One short subband in place (L3_imdct_short): the overlap's first 6 words out as they are,
/// then the three windows overlapping by 6.
fn imdctShort(x: *[18]Word, ov: *[9]Word) void {
    const t = x.*;
    @memcpy(x[0..6], ov[0..6]);
    imdct12(t[0..], x[6..12], ov[6..9]);
    imdct12(t[1..], x[12..18], ov[6..9]);
    imdct12(t[2..], ov[0..6], ov[6..9]);
}

pub const State = struct {
    overlap: [32][9]Word = @splat(@splat(0)),
};

/// One granule of one channel: coefficients in, subband samples out (index sb * 18 + t).
pub fn run(st: *State, g: sideinfo.Granule, b: bands.Bands, long_subbands_if_mixed: u8, c: *Coefs) void {
    const short = g.isShort();
    const n_long_sb: usize = if (!short) 32 else if (g.mixed) long_subbands_if_mixed else 0;
    if (short) reorder(c, b);
    antialias(c, if (n_long_sb == 0) 0 else n_long_sb - 1);
    const w = &win[@intFromBool(!short and g.block_type == 3)];
    for (0..32) |sb| {
        const x = c[sb * 18 ..][0..18];
        if (sb < n_long_sb) imdct36(x, &st.overlap[sb], w) else imdctShort(x, &st.overlap[sb]);
        if (sb & 1 == 1) for (0..9) |i| {
            x[2 * i + 1] = sub(0, x[2 * i + 1]);
        };
    }
}

const testing = std.testing;

/// ISO/IEC 11172-3's IMDCT-36 and windowing in f64, for one long subband with a fixed window.
fn isoLong(x: [18]f64, wt: usize, out: *[36]f64) void {
    const pi = std.math.pi;
    for (0..36) |i| {
        var a: f64 = 0;
        for (0..18) |k| a += x[k] * @cos(pi / 72.0 * @as(f64, @floatFromInt((2 * i + 19) * (2 * k + 1))));
        const fi: f64 = @floatFromInt(i);
        const wv: f64 = switch (wt) {
            0 => @sin(pi / 36.0 * (fi + 0.5)),
            else => if (i < 6) 0 else if (i < 12) @sin(pi / 12.0 * (fi - 6.0 + 0.5)) else if (i < 18) 1.0 else @sin(pi / 36.0 * (fi + 0.5)),
        };
        out[i] = a * wv;
    }
}

test "imdct36 over two blocks overlap-adds as ISO's IMDCT and windows" {
    var prng = std.Random.DefaultPrng.init(0x36);
    const rnd = prng.random();
    for (0..2000) |_| {
        var ov: [9]Word = @splat(0);
        var prev: [36]f64 = @splat(0);
        for (0..3) |_| {
            var xf: [18]f64 = undefined;
            var x: [18]Word = undefined;
            for (&x, &xf) |*v, *f| {
                v.* = rnd.intRangeAtMost(Word, -(1 << 20), 1 << 20);
                f.* = @as(f64, @floatFromInt(v.*)) / (1 << 21);
            }
            var cur: [36]f64 = undefined;
            isoLong(xf, 0, &cur);
            imdct36(&x, &ov, &win[0]);
            for (0..18) |i| {
                const want = cur[i] + prev[18 + i];
                try testing.expectApproxEqAbs(want, @as(f64, @floatFromInt(x[i])) / (1 << 21), 24.0 / @as(f64, 1 << 21));
            }
            prev = cur;
        }
    }
}

test "a start block's second half then a stop block overlap-add as ISO's windows" {
    var prng = std.Random.DefaultPrng.init(0x13);
    const rnd = prng.random();
    for (0..2000) |_| {
        var ov: [9]Word = @splat(0);
        var xf: [18]f64 = undefined;
        var x: [18]Word = undefined;
        for (&x, &xf) |*v, *f| {
            v.* = rnd.intRangeAtMost(Word, -(1 << 20), 1 << 20);
            f.* = @as(f64, @floatFromInt(v.*)) / (1 << 21);
        }
        // the start block's raw second half, as ISO's: y[18 + i] W_start[18 + i]
        var a: [36]f64 = undefined;
        isoLong(xf, 0, &a); // normal-windowed: undo the window to get the raw IMDCT
        const pi = std.math.pi;
        var raw: [36]f64 = undefined;
        for (0..36) |i| raw[i] = a[i] / @sin(pi / 36.0 * (@as(f64, @floatFromInt(i)) + 0.5));
        imdct36(&x, &ov, &win[0]); // start: the first half takes the normal window
        var y: [18]Word = @splat(0); // then a silent stop block
        imdct36(&y, &ov, &win[1]);
        for (0..18) |i| {
            const fi: f64 = @floatFromInt(18 + i);
            const ws: f64 = if (i < 6) 1.0 else if (i < 12) @sin(pi / 12.0 * (fi - 18.0 + 0.5)) else 0;
            try testing.expectApproxEqAbs(raw[18 + i] * ws, @as(f64, @floatFromInt(y[i])) / (1 << 21), 24.0 / @as(f64, 1 << 21));
        }
    }
}
