//! Inverse quantisation (ISO/IEC 14496-3): x = sign(q) * |q|^(4/3) * 2^((sf - 100) / 4), after
//! the pulse data is added to the quantised values.
//!
//! Our fixed-point design: |q|^(4/3) comes from a direct table for |q| <= 128 and, above it,
//! from exact integer interpolation on a Q13 table over [64, 128] scaled by 2^(4s/3). The
//! fractional powers of two from that scaling and from the gain share one 12-entry table, so
//! each coefficient costs one multiply. Relative error: below 2^-21 for |q| <= 128, below 2^-16
//! above (linear interpolation of x^(4/3) at x >= 64).
const std = @import("std");
const fixed = @import("fixed.zig");
const ics = @import("ics.zig");

const F24 = fixed.F24;

pub const sf_offset = 100;

/// k^(4/3) for k = 0..128.
const direct: [129]F24 = blk: {
    @setEvalBranchQuota(100000);
    var t: [129]F24 = undefined;
    for (&t, 0..) |*e, k| e.* = fixed.f24(std.math.pow(f64, @floatFromInt(k), 4.0 / 3.0));
    break :blk t;
};

/// round(j^(4/3) * 2^13) for j = 64..128: 2.1M..5.3M, inside a 24-bit word.
const interp: [65]fixed.Word = blk: {
    @setEvalBranchQuota(100000);
    var t: [65]fixed.Word = undefined;
    for (&t, 64..) |*e, j| e.* = @intFromFloat(@round(std.math.pow(f64, @floatFromInt(j), 4.0 / 3.0) * 8192.0));
    break :blk t;
};

/// 2^(rem / 3 + b / 4), indexed rem * 4 + b.
const gain: [12]F24 = blk: {
    var t: [12]F24 = undefined;
    for (0..3) |rem| for (0..4) |b| {
        const x = @as(f64, @floatFromInt(rem)) / 3.0 + @as(f64, @floatFromInt(b)) / 4.0;
        t[rem * 4 + b] = fixed.f24(std.math.pow(f64, 2.0, x));
    };
    break :blk t;
};

/// One dequantised coefficient.
pub fn dequant(q: i16, sf: i16) F24 {
    if (q == 0) return F24.zero;
    const mag: u16 = @abs(q);
    const g = @as(i32, sf) - sf_offset;
    const a = g >> 2;
    const b: usize = @intCast(g & 3);
    var base: F24 = undefined;
    var rem: usize = 0;
    if (mag <= 128) {
        base = direct[mag];
        base.e = @intCast(@as(i32, base.e) + a);
    } else {
        // mag = j * 2^s + f with j in [64, 128)
        const s: u4 = @intCast(16 - @clz(mag) - 7);
        const j = mag >> s;
        const f = mag & ((@as(u16, 1) << s) - 1);
        const lo: fixed.Acc = interp[j - 64];
        const hi: fixed.Acc = interp[j - 64 + 1];
        const l = (lo << s) + (hi - lo) * @as(fixed.Acc, f);
        const four_s: i32 = 4 * @as(i32, s);
        rem = @intCast(@mod(four_s, 3));
        base = fixed.normalize(l, @divFloor(four_s, 3) - 13 - @as(i32, s) + a);
    }
    const x = fixed.fmul(base, gain[rem * 4 + b]);
    return if (q < 0) x.negate() else x;
}

/// pulse_data: offsets accumulate from the start of pulse_start_sfb; a positive value grows,
/// anything else (zero included) goes more negative.
pub fn applyPulse(spec: *ics.Spectrum, p: ics.Pulse, long_offsets: []const u16) void {
    var k: usize = long_offsets[p.start_sfb];
    for (0..p.count) |i| {
        k += p.offset[i];
        if (spec[k] > 0) spec[k] += p.amp[i] else spec[k] -= p.amp[i];
    }
}

pub const Coefs = [1024]F24;

/// Dequantises every band coded with a spectral book. Noise and intensity bands stay zero;
/// the stereo and noise tools fill them.
pub fn dequantChannel(ch: *const ics.Channel, freq_index: u4) Coefs {
    var spec = ch.spectrum;
    const offsets = ch.info.bandOffsets(freq_index);
    if (ch.pulse) |p| applyPulse(&spec, p, offsets);
    var out: Coefs = @splat(F24.zero);
    const win_len: usize = if (ch.info.isShort()) 128 else 1024;
    var first_win: usize = 0;
    for (0..ch.info.num_window_groups) |g| {
        for (0..ch.info.max_sfb) |sfb| {
            const cb = ch.sections.sfb_cb[g][sfb];
            if (cb == ics.zero_hcb or cb > 11) continue;
            const sf = ch.scalefactors[g][sfb];
            for (first_win..first_win + ch.info.group_len[g]) |w| {
                for (w * win_len + offsets[sfb]..w * win_len + offsets[sfb + 1]) |k| {
                    out[k] = dequant(spec[k], sf);
                }
            }
        }
        first_win += ch.info.group_len[g];
    }
    return out;
}

const testing = std.testing;

fn exact(q: i16, sf: i16) f64 {
    const mag: f64 = @floatFromInt(@abs(q));
    const v = std.math.pow(f64, mag, 4.0 / 3.0) * std.math.pow(f64, 2.0, @as(f64, @floatFromInt(sf - sf_offset)) / 4.0);
    return if (q < 0) -v else v;
}

fn relErr(q: i16, sf: i16) f64 {
    const want = exact(q, sf);
    return @abs(dequant(q, sf).toFloat() - want) / @abs(want);
}

test "every quantised magnitude, at every gain phase, is within the error budget" {
    for (1..8207) |m| {
        const q: i16 = @intCast(m);
        const bound: f64 = if (m <= 128) std.math.ldexp(@as(f64, 1), -21) else std.math.ldexp(@as(f64, 1), -16);
        for ([_]i16{ 100, 101, 102, 103, 0, 255 }) |sf| {
            try testing.expect(relErr(q, sf) < bound);
            try testing.expect(relErr(-q, sf) < bound);
        }
    }
}

test "unit values are exact powers of two" {
    try testing.expectEqual(@as(f64, 1), dequant(1, 100).toFloat());
    try testing.expectEqual(@as(f64, -2), dequant(-1, 104).toFloat());
    try testing.expectEqual(@as(f64, 16), dequant(8, 100).toFloat());
    try testing.expectEqual(F24.zero, dequant(0, 150));
}

test "pulses accumulate offsets and push zero negative" {
    var spec: ics.Spectrum = @splat(0);
    spec[5] = 2;
    const offsets = [_]u16{ 0, 4, 8, 12 };
    const p: ics.Pulse = .{ .count = 2, .start_sfb = 1, .offset = .{ 1, 2, 0, 0 }, .amp = .{ 3, 4, 0, 0 } };
    applyPulse(&spec, p, &offsets);
    try testing.expectEqual(@as(i16, 5), spec[5]); // 4 + 1
    try testing.expectEqual(@as(i16, -4), spec[7]); // 5 + 2, was zero
}
