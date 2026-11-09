//! sm1 operations, as x17's own probe programs measured them. The DSP-shaped models build on
//! these and nothing else, so each stage maps onto forms that exist (specs/dsp.md, Phase 1).
//!
//! Primitives cite the x17 probe that measured them (x17 `src/isa.toml`, `own-*` programs)
//! and say how far that probe reaches; every case the models lean on is gated (x17 e0aa7e7).
//! Helpers below the primitives are compositions, written only in primitives.
//!
//! What is not here because it is not measured: a persistent wide accumulator, a carry flag, a
//! wrapping arithmetic right shift other than the rounded one, bitwise AND/OR on data. A model
//! that wants one asks for a probe first.
const std = @import("std");

/// A register or X word: 24 bits, two's complement.
pub const Word = i24;

// ---------------------------------------------------------------------------
// Primitives
// ---------------------------------------------------------------------------

/// a + b, wrapping at 24 bits. 0x02 third slot, op a+b (own-x02x3, own-x02coll).
pub fn add(a: Word, b: Word) Word {
    return a +% b;
}

/// a - b, wrapping at 24 bits. 0x02 third slot, op a-b (own-x02x3).
pub fn sub(a: Word, b: Word) Word {
    return a -% b;
}

/// (a + b) << n, n in 0..15, wrapping at 24 bits. 0x02 third slot, shift w5[5:2]. own-x02x3
/// measured a negative difference shifted and wrapped: (0x222 - 0x333) << 2 = 0xFFFBBC.
pub fn addShl(a: Word, b: Word, n: u4) Word {
    const s: u24 = @bitCast(a +% b);
    return @bitCast(s << n);
}

/// Rounded arithmetic right shift: (a + 2^(n-1)) >> n, n in 0..23. 0x19 ALU op 23 with a
/// negative count. Gated: own-x19shr-round (0x708 >> 4 = 0x71), own-x19shr-neg (-0x708 >> 4
/// = -0x70, half up), own-x19shr-23.
pub fn rshr(a: Word, n: u5) Word {
    if (n == 0) return a;
    const half: i32 = @as(i32, 1) << (n - 1);
    return @intCast((@as(i32, a) + half) >> n);
}

/// round(a * b / 2^23), half up, signed operands. 0x02 multiply, w1[17] = 0, w1[15] = 1,
/// w1[16] = 0. Gated: own-x02mpy, own-x02mpy-neg, own-x02mpy-halfneg (-0.5 gives 0) and
/// own-x02mpy-halfpos (0.5 gives 1): the half-up rounding `mulWide` relies on.
pub fn mulRound23(a: Word, b: Word) Word {
    return @truncate((@as(i48, a) * b + (1 << 22)) >> 23);
}

/// (2 * a * b)[15:0], the multiply's low half beside `mulRound23`. 0x02 w4[10:7] (own-x02plo,
/// positive operands; the low half does not depend on the operands' signedness).
pub fn mulLo(a: Word, b: Word) u16 {
    return @truncate(@as(u48, @bitCast(@as(i48, a) * b *% 2)));
}

/// The redundant sign bits of a 24-bit word: x01's norm (x17 handbook §10 "Count leading
/// bits", facts 502, 666, 669): norm(0x100) = 14, norm(-0x100) = 15, norm(0) = 24, norm(-1) = 23.
/// So a lies in [-2^(23 - n), 2^(23 - n)).
pub fn norm(a: Word) u5 {
    if (a == 0) return 24;
    const m: u24 = @bitCast(if (a < 0) ~a else a);
    return @intCast(23 - (24 - @as(u32, @clz(m))));
}

/// The sign test: ptst condition "negative" (own-ptst, own-ptst-pos), the one predicate
/// condition measured.
pub fn isNeg(a: Word) bool {
    return a < 0;
}

/// x03.tap's running sum (x17 reference.md x03.tap; facts 672, 701, 702; exact on silicon over a
/// counted two-pointer chain, 792): {hi:lo} += 2ab, 24 x 24 into 48 bits, no rounding. Each step
/// saturates at 48 bits as x17's emulator does (mac48; OPEN on silicon).
pub const Acc = i48;

pub fn mac(acc: Acc, a: Word, b: Word) Acc {
    const s: i64 = @as(i64, acc) + 2 * @as(i64, a) * b;
    return @intCast(std.math.clamp(s, std.math.minInt(Acc), std.math.maxInt(Acc)));
}

/// The sum read back as one word, (acc + 2^(s-1)) / 2^s floored, wrapped to 24 bits, s in 1..24:
/// hi and lo come out as words, and with L = lo read signed and H = hi + [L < 0] the value is
/// H 2^(24 - s) + rshr(L, s) (the ALAC predictor's readout, predictor.sm `hpos`).
pub fn accRshr(acc: Acc, s: u5) Word {
    const hi: Word = @truncate(acc >> 24);
    const l: Word = @bitCast(@as(u24, @truncate(@as(u48, @bitCast(acc)))));
    const h = if (isNeg(l)) add(hi, 1) else hi;
    const low = if (s == 24) @as(Word, 0) else rshr(l, s);
    const up: u5 = @intCast(24 - @as(u32, s));
    const hs = if (up > 15) shl(shl(h, 15), @intCast(up - 15)) else shl(h, @intCast(up));
    return add(hs, low);
}

// ---------------------------------------------------------------------------
// Helpers, built only from the primitives
// ---------------------------------------------------------------------------

pub fn shl(a: Word, n: u4) Word {
    return addShl(a, 0, n);
}

/// a == 0: neither a nor -a is negative (-(-2^23) wraps to itself, still negative).
pub fn isZero(a: Word) bool {
    return !isNeg(a) and !isNeg(sub(0, a));
}

/// floor(a / 2^n): the rounded shift of a - 2^(n-1). Exact while a - 2^(n-1) does not wrap.
pub fn floorShr(a: Word, n: u5) Word {
    if (n == 0) return a;
    return rshr(sub(a, @intCast(@as(i32, 1) << (n - 1))), n);
}

/// The low `b` bits of a, sign-extended, b in 1..24. Left shifts wrap the bits above away;
/// the rounded right shift is exact on a word whose low bits are zero.
pub fn signExtend(a: Word, b: u5) Word {
    if (b >= 24) return a;
    const n: u5 = @intCast(24 - @as(u32, b));
    const up = if (n > 15) shl(shl(a, 15), @intCast(n - 15)) else shl(a, @intCast(n));
    return rshr(up, n);
}

/// -1, 0 or 1.
pub fn sign(a: Word) Word {
    return if (isZero(a)) 0 else if (isNeg(a)) -1 else 1;
}

/// The exact product of a 16-bit a and any word b, as hi * 2^15 + lo with lo in [0, 2^15).
/// `hi` is floor(a * b / 2^15) wrapped at 24 bits, enough for any sum taken modulo 2^24 * 2^15.
pub const Wide = struct { hi: Word, lo: Word };

/// Two multiplies: the low half gives bits 14..0; the rounded product of (a << 8) * b is
/// round(a * b / 2^15), one too big exactly when bit 14 is set.
pub fn mulWide(a: i16, b: Word) Wide {
    const lo16: Word = mulLo(a, b); // (2ab)[15:0], even
    const lo = rshr(lo16, 1); // exact on an even word
    const bit14 = floorShr(lo, 14);
    const r = mulRound23(shl(a, 8), b);
    return .{ .hi = sub(r, bit14), .lo = lo };
}

/// The value of a Wide that fits a word.
pub fn wideValue(w: Wide) Word {
    return addShl(w.hi, 0, 15) +% w.lo;
}

/// Sum of Wides: hi parts and lo parts add separately; `normalize` carries lo into hi.
pub fn wideAdd(x: Wide, y: Wide) Wide {
    return .{ .hi = add(x.hi, y.hi), .lo = add(x.lo, y.lo) };
}

/// Carries lo into hi (floor, so a negative lo borrows), leaving lo in [0, 2^15).
pub fn normalize(w: Wide) Wide {
    const carry = floorShr(w.lo, 15);
    return .{ .hi = add(w.hi, carry), .lo = sub(w.lo, shl(carry, 15)) };
}

test "norm counts the redundant sign bits as x01 does" {
    try std.testing.expectEqual(@as(u5, 14), norm(0x100));
    try std.testing.expectEqual(@as(u5, 15), norm(-0x100));
    try std.testing.expectEqual(@as(u5, 24), norm(0));
    try std.testing.expectEqual(@as(u5, 23), norm(-1));
    try std.testing.expectEqual(@as(u5, 22), norm(-2));
    try std.testing.expectEqual(@as(u5, 8), norm(0x7FFF));
    try std.testing.expectEqual(@as(u5, 0), norm(0x400000));
    try std.testing.expectEqual(@as(u5, 1), norm(-0x400000));
}

const testing = std.testing;

test "isZero from the sign test alone" {
    for ([_]Word{ 0, 1, -1, std.math.maxInt(Word), std.math.minInt(Word) }) |x| try testing.expectEqual(x == 0, isZero(x));
}

test "the rounded shift rounds half up; floorShr floors both signs" {
    try testing.expectEqual(@as(Word, 2), rshr(3, 1));
    try testing.expectEqual(@as(Word, -1), rshr(-3, 1));
    try testing.expectEqual(@as(Word, 1), floorShr(3, 1));
    try testing.expectEqual(@as(Word, -2), floorShr(-3, 1));
    try testing.expectEqual(@as(Word, -1), floorShr(-1, 15));
}

test "signExtend keeps the low bits" {
    try testing.expectEqual(@as(Word, -32768), signExtend(32768, 16));
    try testing.expectEqual(@as(Word, 32767), signExtend(32767, 16));
    try testing.expectEqual(@as(Word, -1), signExtend(0x1FFFF, 17));
    try testing.expectEqual(@as(Word, -0x800000), signExtend(-0x800000, 24));
    try testing.expectEqual(@as(Word, -128), signExtend(0x180, 8));
}

test "mulWide is exact over the whole 16 x 24 range" {
    var prng = std.Random.DefaultPrng.init(0x5050);
    const rnd = prng.random();
    const edges_a = [_]i16{ -32768, -32767, -1, 0, 1, 32767 };
    const edges_b = [_]Word{ -0x800000, -0x7FFFFF, -1, 0, 1, 0x7FFFFF, 0x4000, -0x4000 };
    for (edges_a) |a| for (edges_b) |b| try expectWide(a, b);
    for (0..200_000) |_| try expectWide(rnd.int(i16), rnd.int(Word));
}

fn expectWide(a: i16, b: Word) !void {
    const w = mulWide(a, b);
    const p: i64 = @as(i64, a) * b;
    try testing.expect(w.lo >= 0 and w.lo < 1 << 15);
    try testing.expectEqual(@as(i24, @truncate(@divFloor(p, 1 << 15))), w.hi);
    try testing.expectEqual(@mod(p, 1 << 15), w.lo);
}

test "accRshr is the rounded shift of the 48-bit sum, wrapped" {
    var prng = std.Random.DefaultPrng.init(0x792);
    const rnd = prng.random();
    for (0..100_000) |_| {
        var acc: Acc = 0;
        for (0..rnd.intRangeAtMost(usize, 1, 36)) |_| acc = mac(acc, rnd.int(Word), rnd.intRangeAtMost(Word, -(1 << 21), 1 << 21));
        const s: u5 = rnd.intRangeAtMost(u5, 1, 24);
        const want: Word = @truncate((@as(i64, acc) + (@as(i64, 1) << (s - 1))) >> s);
        try testing.expectEqual(want, accRshr(acc, s));
    }
}

test "Wide sums carry into hi" {
    var acc: Wide = .{ .hi = 0, .lo = 0 };
    var want: i64 = 0;
    var prng = std.Random.DefaultPrng.init(7);
    const rnd = prng.random();
    for (0..31) |_| {
        const a = rnd.int(i16);
        const b = rnd.intRangeAtMost(Word, -(1 << 17), 1 << 17);
        acc = wideAdd(acc, mulWide(a, b));
        want += @as(i64, a) * b;
    }
    const n = normalize(acc);
    try testing.expectEqual(@mod(want, 1 << 15), n.lo);
    try testing.expectEqual(@as(i24, @truncate(@divFloor(want, 1 << 15))), n.hi);
}
