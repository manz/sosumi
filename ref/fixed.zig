//! Arithmetic at sm1's widths, so the model overflows where the DSP would.
//!
//! Widths come from x17's ISA: X memory holds 24-bit words, the multiplier produces 48 bits.
//! The Q format (Q23 for X words) and the rounding mode (round half up) are our choices.
const std = @import("std");

pub const Word = i24;
pub const Acc = i48;

pub const word_max: Word = std.math.maxInt(Word);
pub const word_min: Word = std.math.minInt(Word);

/// Full 24x24 product. Exact: the largest magnitude, (-2^23)^2 = 2^46, fits 48 bits.
pub fn mul(a: Word, b: Word) Acc {
    return @as(Acc, a) * @as(Acc, b);
}

/// Saturate an accumulator to a word.
pub fn sat(x: Acc) Word {
    return @intCast(std.math.clamp(x, word_min, word_max));
}

/// Arithmetic right shift with round half up. Saturates instead of wrapping on the add.
pub fn roundShift(x: Acc, s: u6) Acc {
    if (s == 0) return x;
    const half: Acc = @as(Acc, 1) << @intCast(s - 1);
    return (x +| half) >> @intCast(s);
}

/// Q23 x Q23 -> Q23, rounded and saturated.
pub fn mulQ23(a: Word, b: Word) Word {
    return sat(roundShift(mul(a, b), 23));
}

/// Q23 constant from a real in [-1, 1), at compile time.
pub fn q23(comptime x: comptime_float) Word {
    const scaled = @round(x * (1 << 23));
    if (scaled > word_max or scaled < word_min) @compileError("q23 constant out of range");
    return @intFromFloat(scaled);
}

/// Normalised 24-bit float: value = m * 2^e, with m == 0 or 2^22 <= |m| < 2^23.
/// Our format for the stages before the block exponent (dequantisation, stereo tools).
pub const F24 = struct {
    m: Word,
    e: i16,

    pub const zero: F24 = .{ .m = 0, .e = 0 };

    pub fn toFloat(self: F24) f64 {
        return std.math.ldexp(@as(f64, @floatFromInt(self.m)), self.e);
    }

    pub fn negate(self: F24) F24 {
        return normalize(-@as(Acc, self.m), self.e);
    }
};

/// acc * 2^e as an F24. The magnitude is rounded half away from zero, so x and -x stay mirror
/// images.
pub fn normalize(acc: Acc, e: i32) F24 {
    if (acc == 0) return F24.zero;
    var mag: u64 = @abs(acc);
    var exp: i32 = e;
    const shift: i32 = @as(i32, 64 - @clz(mag)) - 23;
    if (shift > 0) {
        mag = (mag + (@as(u64, 1) << @intCast(shift - 1))) >> @intCast(shift);
        exp += shift;
        if (mag == 1 << 23) {
            mag >>= 1;
            exp += 1;
        }
    } else if (shift < 0) {
        mag <<= @intCast(-shift);
        exp += shift;
    }
    const m: Word = @intCast(mag);
    return .{ .m = if (acc < 0) -m else m, .e = @intCast(exp) };
}

pub fn fmul(a: F24, b: F24) F24 {
    if (a.m == 0 or b.m == 0) return F24.zero;
    return normalize(mul(a.m, b.m), @as(i32, a.e) + b.e);
}

/// F24 constant from a positive real, at compile time.
pub fn f24(comptime x: f64) F24 {
    @setEvalBranchQuota(10000);
    if (x == 0) return F24.zero;
    const e: i32 = @as(i32, @intFromFloat(@floor(std.math.log2(x)))) - 22;
    const m: Acc = @intFromFloat(@round(std.math.ldexp(x, -e)));
    return normalize(m, e);
}

const testing = std.testing;

test "the extreme product is exact" {
    try testing.expectEqual(@as(Acc, 1) << 46, mul(word_min, word_min));
}

test "sat clamps both ways" {
    try testing.expectEqual(word_max, sat(@as(Acc, 1) << 30));
    try testing.expectEqual(word_min, sat(-(@as(Acc, 1) << 30)));
    try testing.expectEqual(@as(Word, -5), sat(-5));
}

test "roundShift rounds half up" {
    try testing.expectEqual(@as(Acc, 2), roundShift(3, 1));
    try testing.expectEqual(@as(Acc, -1), roundShift(-3, 1));
    try testing.expectEqual(@as(Acc, 7), roundShift(7, 0));
}

test "mulQ23 halves by one half, and -1 x -1 saturates" {
    try testing.expectEqual(q23(0.25), mulQ23(q23(0.5), q23(0.5)));
    try testing.expectEqual(word_max, mulQ23(word_min, word_min));
}

test "normalize keeps 24 significant bits and rounds the magnitude" {
    const a = normalize(3, 0);
    try testing.expectEqual(@as(Word, 3 << 21), a.m);
    try testing.expectEqual(@as(f64, 3), a.toFloat());
    // 2^24 + 1 rounds to 2^24; 2^24 + 3 rounds up by one unit of 2^2
    try testing.expectEqual(@as(f64, 1 << 24), normalize((1 << 24) + 1, 0).toFloat());
    try testing.expectEqual(@as(f64, (1 << 24) + 4), normalize((1 << 24) + 3, 0).toFloat());
    try testing.expectEqual(-normalize(12345678, -3).toFloat(), normalize(-12345678, -3).toFloat());
}

test "normalize carries a rounding overflow into the exponent" {
    const a = normalize((1 << 24) - 1, 0);
    try testing.expectEqual(@as(Word, 1 << 22), a.m);
    try testing.expectEqual(@as(f64, 1 << 24), a.toFloat());
}

test "fmul and f24 agree with doubles" {
    const x = fmul(f24(1.5), f24(0.75));
    try testing.expectApproxEqRel(@as(f64, 1.125), x.toFloat(), 1e-6);
    try testing.expectEqual(F24.zero, fmul(F24.zero, f24(3.0)));
}
