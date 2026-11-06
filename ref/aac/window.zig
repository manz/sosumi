//! Window shapes (ISO/IEC 14496-3): the rising half of the sine window (window_shape 0) and of
//! the Kaiser-Bessel-derived window (window_shape 1, alpha 4 long and 6 short), in Q23. The
//! falling half is the rising half reversed. 1.0 saturates to the largest Q23 word.
const std = @import("std");
const fixed = @import("../fixed.zig");

const Word = fixed.Word;

pub fn q23Sat(x: f64) Word {
    return @intFromFloat(std.math.clamp(@round(x * 0x1p23), -0x1p23, 0x1p23 - 1));
}

fn sineRise(comptime half: usize) [half]Word {
    @setEvalBranchQuota(100000);
    var t: [half]Word = undefined;
    const n: f64 = 2 * half;
    for (&t, 0..) |*e, i| e.* = q23Sat(@sin(std.math.pi / n * (@as(f64, @floatFromInt(i)) + 0.5)));
    return t;
}

fn besselI0(x: f64) f64 {
    var sum: f64 = 1;
    var term: f64 = 1;
    var k: f64 = 1;
    while (term > 1e-17 * sum) : (k += 1) {
        const r = x / (2 * k);
        term *= r * r;
        sum += term;
    }
    return sum;
}

fn kbdRise(comptime half: usize, comptime alpha: f64) [half]Word {
    @setEvalBranchQuota(10_000_000);
    var kernel: [half + 1]f64 = undefined;
    const q: f64 = @floatFromInt(half / 2);
    for (&kernel, 0..) |*k, p| {
        const r = (@as(f64, @floatFromInt(p)) - q) / q;
        k.* = besselI0(std.math.pi * alpha * @sqrt(1 - r * r));
    }
    var total: f64 = 0;
    for (kernel) |k| total += k;
    var t: [half]Word = undefined;
    var acc: f64 = 0;
    for (&t, 0..) |*e, i| {
        acc += kernel[i];
        e.* = q23Sat(@sqrt(acc / total));
    }
    return t;
}

pub const long = [2][1024]Word{ sineRise(1024), kbdRise(1024, 4) };
pub const short = [2][128]Word{ sineRise(128), kbdRise(128, 6) };

const testing = std.testing;

fn checkPowerComplementary(rise: []const Word) !void {
    for (rise, 0..) |r, i| {
        const a = @as(f64, @floatFromInt(r)) / 0x1p23;
        const b = @as(f64, @floatFromInt(rise[rise.len - 1 - i])) / 0x1p23;
        try testing.expectApproxEqAbs(@as(f64, 1), a * a + b * b, 1e-6);
    }
}

test "every window satisfies w[n]^2 + w[N/2-1-n]^2 = 1 (Princen-Bradley)" {
    for (0..2) |s| {
        try checkPowerComplementary(&long[s]);
        try checkPowerComplementary(&short[s]);
    }
}

test "the KBD window starts lower and ends higher than the sine window" {
    try testing.expect(long[1][0] < long[0][0]);
    try testing.expect(long[1][1023] > long[0][1023]);
}
