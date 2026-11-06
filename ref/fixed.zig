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
