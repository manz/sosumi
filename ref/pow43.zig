//! sign(q) * |q|^(4/3) * 2^(g / 4): the dequantiser AAC and MPEG Layer III share.
//!
//! Our fixed-point design: |q|^(4/3) comes from a direct table for |q| <= 128 and, above it,
//! from exact integer interpolation on a Q13 table over [64, 128] scaled by 2^(4s/3). The
//! fractional powers of two from that scaling and from the gain share one 12-entry table, so
//! each value costs one multiply. Relative error: below 2^-21 for |q| <= 128, below 2^-16
//! above (linear interpolation of x^(4/3) at x >= 64).
const std = @import("std");
const fixed = @import("fixed.zig");

const F24 = fixed.F24;

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

/// sign(q) * |q|^(4/3) * 2^(g / 4), for |q| up to 16383.
pub fn scaled(q: i16, g: i32) F24 {
    if (q == 0) return F24.zero;
    const mag: u16 = @abs(q);
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

const testing = std.testing;

fn exact(q: i16, g: i32) f64 {
    const mag: f64 = @floatFromInt(@abs(q));
    const v = std.math.pow(f64, mag, 4.0 / 3.0) * std.math.pow(f64, 2.0, @as(f64, @floatFromInt(g)) / 4.0);
    return if (q < 0) -v else v;
}

fn relErr(q: i16, g: i32) f64 {
    const want = exact(q, g);
    return @abs(scaled(q, g).toFloat() - want) / @abs(want);
}

test "every magnitude to 8206 (MP3's 15 + 2^13 - 1), at every gain phase, is within budget" {
    for (1..8207) |m| {
        const q: i16 = @intCast(m);
        const bound: f64 = if (m <= 128) std.math.ldexp(@as(f64, 1), -21) else std.math.ldexp(@as(f64, 1), -16);
        for ([_]i32{ 0, 1, 2, 3, -100, -338, 155 }) |g| {
            try testing.expect(relErr(q, g) < bound);
            try testing.expect(relErr(-q, g) < bound);
        }
    }
}

test "unit values are exact powers of two" {
    try testing.expectEqual(@as(f64, 1), scaled(1, 0).toFloat());
    try testing.expectEqual(@as(f64, -2), scaled(-1, 4).toFloat());
    try testing.expectEqual(@as(f64, 16), scaled(8, 0).toFloat());
    try testing.expectEqual(F24.zero, scaled(0, 50));
}
