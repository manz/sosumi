//! Requantisation in measured sm1 operations: the twin of `ref/mp3/requant.zig`.
//!
//! Every coefficient leaves as a Q20 word (value * 2^20, so |value| < 8; a louder one
//! saturates). The magnitude is AAC's dequantiser (`../aac/dequant.zig`): |q|^(4/3) as m * 2^e
//! and one rounded multiply by the 12-entry gain table, P = m G / 2^23 below 2^22.42 with value
//! P * 2^(e + 2 + floor(t / 4)), t the quarter-step exponent. The Q20 word is P shifted by
//! that exponent + 20: right with rounding, or left, saturating when x01's norm shows no room.
const std = @import("std");
const ops = @import("../ops.zig");
const dequant = @import("../aac/dequant.zig");
const ref = @import("../../mp3/requant.zig");
const sideinfo = @import("../../mp3/sideinfo.zig");
const bands = @import("../../mp3/bands.zig");
const scalefactors = @import("../../mp3/scalefactors.zig");
const spectrum = @import("../../mp3/spectrum.zig");

const Word = ops.Word;
const word_max: Word = std.math.maxInt(Word);

/// Fraction bits of a coefficient word, here and through the filterbanks.
pub const frac = 20;

pub const Coefs = [576]Word;

/// sign(q) |q|^(4/3) 2^(t / 4) as a Q20 word, q in -16383..16383.
pub fn value(q: Word, t: Word) Word {
    if (ops.isZero(q)) return 0;
    const neg = ops.isNeg(q);
    const mag = if (neg) ops.sub(0, q) else q;
    const mt = dequant.mantissa(mag);
    const sh = ops.floorShr(t, 2);
    const b = ops.sub(t, ops.shl(sh, 2));
    const p = ops.mulRound23(mt.m, dequant.gain[@intCast(ops.add(ops.shl(mt.rem, 2), b))]);
    // value = p * 2^x, x = e + 2 + sh; the Q20 word is p * 2^(x + 20)
    const up = ops.add(ops.add(ops.add(mt.e, 2), sh), frac);
    var v: Word = undefined;
    if (ops.isNeg(up)) {
        const n = ops.sub(0, up);
        v = if (ops.isNeg(ops.sub(n, 24))) ops.rshr(p, @intCast(n)) else 0;
    } else {
        // p < 2^23 has norm(p) redundant bits: a left shift by more saturates
        v = if (ops.isNeg(ops.sub(@as(Word, ops.norm(p)), up))) word_max else ops.shl(p, @intCast(up));
    }
    return if (neg) ops.sub(0, v) else v;
}

/// One granule of one channel, as the reference's `requantise`.
pub fn requantise(g: sideinfo.Granule, b: bands.Bands, sf: *const scalefactors.Scalefactors, is: *const spectrum.Spectrum) Coefs {
    var out: Coefs = @splat(0);
    const shift: u4 = 1 + @as(u4, @intFromBool(g.scalefac_scale));
    const preflag = (g.preflag or sf.preflag) and b.n_short == 0;
    var k: usize = 0;
    for (b.widths, 0..) |w, e| {
        var t: Word = ops.sub(g.global_gain, 210);
        if (b.window(e)) |win| t = ops.sub(t, ops.shl(g.subblock_gain[win], 3));
        var s: Word = sf.sf[e];
        if (preflag) s = ops.add(s, ref.pretab[e]);
        t = ops.sub(t, ops.shl(s, shift));
        for (k..k + w) |i| out[i] = value(is[i], t);
        k += w;
    }
    return out;
}

const testing = std.testing;
const pow43 = @import("../../pow43.zig");

test "value tracks the reference's dequantiser to its rounding" {
    var prng = std.Random.DefaultPrng.init(0x3333);
    const rnd = prng.random();
    for (0..200_000) |_| {
        const q = rnd.intRangeAtMost(i16, -8206, 8206);
        const t = rnd.intRangeAtMost(Word, -200, 10);
        const want = pow43.scaled(q, t).toFloat() * (1 << frac);
        const got: f64 = @floatFromInt(value(q, t));
        if (@abs(want) >= word_max) continue;
        // P carries 2^-21 relative error; the shift rounds by half an LSB
        try testing.expect(@abs(got - want) <= 0.5 + @abs(want) * 3e-5);
    }
}

test "loud values saturate, tiny ones vanish" {
    try testing.expectEqual(word_max, value(8206, 10));
    try testing.expectEqual(-word_max, value(-8206, 10));
    try testing.expectEqual(@as(Word, 0), value(1, -200));
}
