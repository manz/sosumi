//! Inverse quantisation in measured sm1 operations: the twin of `ref/aac/iquant.zig`.
//!
//! x = sign(q) * |q|^(4/3) * 2^((sf - 100) / 4). The reference carries each value as an F24;
//! here a channel comes out as words with one exponent, value = w * 2^e, the block-floating
//! form the IMDCT takes. Each coefficient is a mantissa m * 2^em for |q|^(4/3):
//!
//!   - |q| <= 128: a direct table, m normalised to [2^22, 2^23).
//!   - above: |q| = j * 2^s + f, j in [64, 128), s found by comparisons (no leading-zero count);
//!     m = lo + round((hi - lo) * f / 2^s) on the reference's Q13 table, one rounded multiply
//!     with f * 2^(23 - s) as the second operand; em = floor(4s / 3) - 13, and the leftover
//!     2^((s mod 3) / 3) joins the gain.
//!
//! The gain 2^(rem / 3 + b / 4), b = (sf - 100) mod 4, is a 12-entry Q21 table and one rounded
//! multiply: P = round(m * G / 2^23), value = P * 2^(em + 2 + floor((sf - 100) / 4)), P below
//! 2^22.42. The channel exponent is the largest coefficient exponent, found from each band's
//! largest |q| (the exponent grows with |q|); every word is then P shifted right by the
//! difference, rounded, so |w| < 2^22.42.
const std = @import("std");
const ops = @import("../ops.zig");
const sections = @import("sections.zig");
const ref = @import("../../aac/iquant.zig");
const ics = @import("../../aac/ics.zig");

const Word = ops.Word;

pub const sf_offset = 100;

/// round(k^(4/3) * 2^(22 - floor(log2 k^(4/3)))): k^(4/3) = direct_m[k] * 2^direct_e[k].
const direct = blk: {
    @setEvalBranchQuota(100000);
    var m: [129]Word = @splat(0);
    var e: [129]Word = @splat(0);
    for (1..129) |k| {
        const v = std.math.pow(f64, @floatFromInt(k), 4.0 / 3.0);
        var ex: i32 = @intFromFloat(@floor(std.math.log2(v)));
        var r = @round(std.math.ldexp(v, 22 - ex));
        if (r >= 1 << 23) {
            r /= 2;
            ex += 1;
        }
        m[k] = @intFromFloat(r);
        e[k] = ex - 22;
    }
    break :blk .{ .m = m, .e = e };
};
pub const direct_m: [129]Word = direct.m;
pub const direct_e: [129]Word = direct.e;

/// round(j^(4/3) * 2^13), j = 64..128: the reference's interpolation table.
pub const interp: [65]Word = blk: {
    @setEvalBranchQuota(100000);
    var t: [65]Word = undefined;
    for (&t, 64..) |*x, j| x.* = @intFromFloat(@round(std.math.pow(f64, @floatFromInt(j), 4.0 / 3.0) * 8192.0));
    break :blk t;
};

/// round(2^(rem / 3 + b / 4) * 2^21), indexed rem * 4 + b: below 2^22.42.
pub const gain: [12]Word = blk: {
    var t: [12]Word = undefined;
    for (0..3) |rem| for (0..4) |b| {
        const x = @as(f64, @floatFromInt(rem)) / 3.0 + @as(f64, @floatFromInt(b)) / 4.0;
        t[rem * 4 + b] = @intFromFloat(@round(std.math.pow(f64, 2.0, x) * (1 << 21)));
    };
    break :blk t;
};

/// floor(4s / 3) - 13 and s mod 3, for s = 1..7.
pub const interp_e = [8]Word{ 0, 1 - 13, 2 - 13, 4 - 13, 5 - 13, 6 - 13, 8 - 13, 9 - 13 };
pub const interp_rem = [8]Word{ 0, 1, 2, 0, 1, 2, 0, 1 };

/// |q|^(4/3) as m * 2^e, and the third-power leftover for the gain index.
pub const Mant = struct { m: Word, e: Word, rem: Word };

/// mag in 1..16383 (8191 plus pulses, and MP3's range).
pub fn mantissa(mag: Word) Mant {
    if (ops.isNeg(ops.sub(128, mag))) {
        var s: u5 = 1;
        var top: Word = 256;
        while (!ops.isNeg(ops.sub(mag, top))) : (top = ops.shl(top, 1)) s += 1;
        const j = ops.floorShr(mag, s);
        const f = ops.sub(mag, ops.shl(j, @intCast(s)));
        const lo = interp[@intCast(j - 64)];
        const d = ops.sub(interp[@intCast(j - 63)], lo);
        const fs = ops.shl(ops.shl(f, 8), @intCast(15 - @as(u32, s))); // f * 2^(23 - s)
        return .{ .m = ops.add(lo, ops.mulRound23(d, fs)), .e = interp_e[s], .rem = interp_rem[s] };
    }
    const k: usize = @intCast(mag);
    return .{ .m = direct_m[k], .e = direct_e[k], .rem = 0 };
}

fn abs(x: Word) Word {
    return if (ops.isNeg(x)) ops.sub(0, x) else x;
}

/// A channel's coefficients: value = w * 2^e.
pub const Block = struct {
    w: [1024]Word = @splat(0),
    e: Word = 0,
};

pub const Shape = struct {
    short: bool,
    groups: u4,
    group_len: [8]u4,
    max_sfb: u6,
};

/// Calls `f(ctx, k)` for every coefficient index of band (g, sfb), window by window.
fn bandIndices(s: Shape, offsets: []const u16, first_win: usize, g: usize, sfb: usize, ctx: anytype, comptime f: anytype) void {
    const win_len: usize = if (s.short) 128 else 1024;
    for (first_win..first_win + s.group_len[g]) |w| {
        for (w * win_len + offsets[sfb]..w * win_len + offsets[sfb + 1]) |k| f(ctx, k);
    }
}

/// Dequantises every band coded with a spectral book (1..11); noise, intensity and zero bands
/// stay zero for the tools after.
pub fn dequantChannel(spec: *const [1024]Word, s: Shape, b: *const sections.Bands, offsets: []const u16) Block {
    // Pass 1: the channel exponent, from each band's largest |q|.
    var e_max: ?Word = null;
    var first_win: usize = 0;
    for (0..s.groups) |g| {
        for (0..s.max_sfb) |sfb| {
            const i = g * s.max_sfb + sfb;
            if (!spectral(b.book[i])) continue;
            const Max = struct {
                spec: *const [1024]Word,
                v: Word = 0,
                fn see(self: *@This(), k: usize) void {
                    const a = abs(self.spec[k]);
                    if (ops.isNeg(ops.sub(self.v, a))) self.v = a;
                }
            };
            var mx: Max = .{ .spec = spec };
            bandIndices(s, offsets, first_win, g, sfb, &mx, Max.see);
            if (ops.isZero(mx.v)) continue;
            const e = ops.add(ops.add(mantissa(mx.v).e, 2), ops.floorShr(ops.sub(b.sf[i], sf_offset), 2));
            if (e_max == null or ops.isNeg(ops.sub(e_max.?, e))) e_max = e;
        }
        first_win += s.group_len[g];
    }
    var out: Block = .{};
    const big = e_max orelse return out;
    out.e = big;
    // Pass 2: each coefficient, shifted to the channel exponent.
    first_win = 0;
    for (0..s.groups) |g| {
        for (0..s.max_sfb) |sfb| {
            const i = g * s.max_sfb + sfb;
            if (!spectral(b.book[i])) continue;
            const t = ops.sub(b.sf[i], sf_offset);
            const sh = ops.floorShr(t, 2);
            const Put = struct {
                spec: *const [1024]Word,
                out: *Block,
                sh: Word,
                bph: Word,
                fn put(self: *@This(), k: usize) void {
                    const q = self.spec[k];
                    if (ops.isZero(q)) return;
                    const mt = mantissa(abs(q));
                    const p = ops.mulRound23(mt.m, gain[@intCast(ops.add(ops.shl(mt.rem, 2), self.bph))]);
                    const e = ops.add(ops.add(mt.e, 2), self.sh);
                    var n = ops.sub(self.out.e, e);
                    if (!ops.isNeg(ops.sub(n, 24))) n = 23;
                    const v = ops.rshr(p, @intCast(n));
                    self.out.w[k] = if (ops.isNeg(q)) ops.sub(0, v) else v;
                }
            };
            var pt: Put = .{ .spec = spec, .out = &out, .sh = sh, .bph = ops.sub(t, ops.shl(sh, 2)) };
            bandIndices(s, offsets, first_win, g, sfb, &pt, Put.put);
        }
        first_win += s.group_len[g];
    }
    return out;
}

/// Books 1..11: cb - 1 and 11 - cb both non-negative.
fn spectral(cb: Word) bool {
    return !ops.isNeg(ops.sub(cb, 1)) and !ops.isNeg(ops.sub(11, cb));
}

/// pulse_data, as the reference: offsets accumulate from pulse_start_sfb; a positive value
/// grows, anything else goes more negative.
pub fn applyPulse(spec: *[1024]Word, p: ics.Pulse, long_offsets: []const u16) void {
    var k: usize = long_offsets[p.start_sfb];
    for (0..p.count) |i| {
        k += p.offset[i];
        const a: Word = p.amp[i];
        spec[k] = if (ops.isNeg(ops.sub(0, spec[k]))) ops.add(spec[k], a) else ops.sub(spec[k], a);
    }
}

const testing = std.testing;
const swb = @import("../../aac/tables/swb.zig");

fn exact(q: Word, sf: Word) f64 {
    const v = std.math.pow(f64, @floatFromInt(@abs(q)), 4.0 / 3.0) * std.math.pow(f64, 2.0, @as(f64, @floatFromInt(sf - sf_offset)) / 4.0);
    return if (q < 0) -v else v;
}

test "every magnitude to 16383 at every gain phase is within budget" {
    // One band, one coefficient: the word carries the coefficient's own exponent.
    for (1..16384) |m| {
        const mt = mantissa(@intCast(m));
        const want = std.math.pow(f64, @floatFromInt(m), 4.0 / 3.0);
        const got = std.math.ldexp(@as(f64, @floatFromInt(mt.m)), @intCast(mt.e)) * std.math.pow(f64, 2.0, @as(f64, @floatFromInt(mt.rem)) / 3.0);
        const bound: f64 = if (m <= 128) std.math.ldexp(@as(f64, 1), -22) else std.math.ldexp(@as(f64, 1), -16);
        try testing.expect(@abs(got - want) / want < bound);
    }
}

fn randomShape(rnd: std.Random) Shape {
    const short = rnd.boolean();
    var s: Shape = .{ .short = short, .groups = 1, .group_len = @splat(0), .max_sfb = 0 };
    if (short) {
        var left: u4 = 8;
        s.groups = 0;
        while (left > 0) {
            const l = rnd.intRangeAtMost(u4, 1, left);
            s.group_len[s.groups] = l;
            s.groups += 1;
            left -= l;
        }
        s.max_sfb = rnd.intRangeAtMost(u6, 0, 14);
    } else {
        s.group_len[0] = 1;
        s.max_sfb = rnd.intRangeAtMost(u6, 0, 49);
    }
    return s;
}

test "random channels match the exact value and the reference, within a word's LSB" {
    var prng = std.Random.DefaultPrng.init(0xDE0);
    const rnd = prng.random();
    const rate = 4; // 44.1 kHz
    var checked: usize = 0;
    var big: usize = 0;
    for (0..400) |_| {
        const s = randomShape(rnd);
        const offsets: []const u16 = if (s.short) swb.short[rate] else swb.long[rate];
        var b: sections.Bands = .{};
        var ch: ics.Channel = undefined;
        ch.info = .{
            .window_sequence = if (s.short) .eight_short else .only_long,
            .window_shape = 0,
            .max_sfb = s.max_sfb,
            .num_window_groups = s.groups,
            .group_len = s.group_len,
        };
        ch.sections = .{};
        ch.scalefactors = @splat(@splat(0));
        ch.pulse = null;
        ch.spectrum = @splat(0);
        b.n = @as(usize, s.groups) * s.max_sfb;
        const base_sf = rnd.intRangeAtMost(i16, 60, 200);
        for (0..s.groups) |g| for (0..s.max_sfb) |sfb| {
            const cb = rnd.intRangeAtMost(u4, 0, 15);
            const sf: i16 = std.math.clamp(base_sf + rnd.intRangeAtMost(i16, -30, 30), 0, 255);
            ch.sections.sfb_cb[g][sfb] = if (cb == 12) 0 else cb;
            ch.scalefactors[g][sfb] = sf;
            b.book[g * s.max_sfb + sfb] = ch.sections.sfb_cb[g][sfb];
            b.sf[g * s.max_sfb + sfb] = sf;
        };
        var spec: [1024]Word = @splat(0);
        for (&ch.spectrum, &spec) |*q, *w| {
            const r = rnd.uintLessThan(u8, 100);
            const mag: i16 = if (r < 40) 0 else if (r < 90) rnd.intRangeAtMost(i16, 1, 16) else if (r < 98) rnd.intRangeAtMost(i16, 17, 1000) else rnd.intRangeAtMost(i16, 1001, 8191);
            q.* = if (rnd.boolean()) -mag else mag;
            w.* = q.*;
        }
        const got = dequantChannel(&spec, s, &b, offsets);
        const want = ref.dequantChannel(&ch, rate);
        const lsb = std.math.ldexp(@as(f64, 1), @intCast(got.e));
        var top: Word = 0;
        for (0..1024) |k| {
            const g_v = @as(f64, @floatFromInt(got.w[k])) * lsb;
            const r_v = want[k].toFloat();
            top = @max(top, @as(Word, @intCast(@abs(got.w[k]))));
            try testing.expect(@abs(g_v - r_v) <= 2 * lsb + @abs(r_v) * std.math.ldexp(@as(f64, 1), -15));
            if (r_v != 0) checked += 1;
        }
        // the exponent is tight: the largest word uses the top of the range
        if (top != 0) {
            try testing.expect(top >= 1 << 19);
            try testing.expect(top < 1 << 23);
            big += 1;
        }
        // and against the exact value, band by band
        var first_win: usize = 0;
        const win_len: usize = if (s.short) 128 else 1024;
        for (0..s.groups) |g| {
            for (0..s.max_sfb) |sfb| {
                const cb = ch.sections.sfb_cb[g][sfb];
                for (first_win..first_win + s.group_len[g]) |w| {
                    for (w * win_len + offsets[sfb]..w * win_len + offsets[sfb + 1]) |k| {
                        const x: f64 = if (cb == 0 or cb > 11) 0 else exact(spec[k], b.sf[g * s.max_sfb + sfb]);
                        const g_v = @as(f64, @floatFromInt(got.w[k])) * lsb;
                        try testing.expect(@abs(g_v - x) <= 2 * lsb + @abs(x) * std.math.ldexp(@as(f64, 1), -15));
                    }
                }
            }
            first_win += s.group_len[g];
        }
    }
    try testing.expect(checked > 50000);
    try testing.expect(big > 300);
}

test "pulses move values as the reference's do" {
    var prng = std.Random.DefaultPrng.init(0x9015E);
    const rnd = prng.random();
    for (0..500) |_| {
        var a: ics.Spectrum = undefined;
        var b: [1024]Word = undefined;
        for (&a, &b) |*x, *y| {
            x.* = rnd.intRangeAtMost(i16, -3, 3);
            y.* = x.*;
        }
        var p: ics.Pulse = .{ .count = rnd.intRangeAtMost(u3, 1, 4), .start_sfb = rnd.intRangeAtMost(u6, 0, 40) };
        for (0..p.count) |i| {
            p.offset[i] = rnd.int(u5);
            p.amp[i] = rnd.int(u4);
        }
        ref.applyPulse(&a, p, swb.long[4]);
        applyPulse(&b, p, swb.long[4]);
        for (a, b) |x, y| try testing.expectEqual(@as(Word, x), y);
    }
}
