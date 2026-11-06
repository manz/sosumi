//! sm1 operations, as x17's own probe programs measured them. The DSP-shaped models build on
//! these and nothing else, so each stage maps onto forms that exist (specs/dsp.md, Phase 1).
//!
//! Primitives cite the x17 probe that measured them (x17 `src/isa.toml`, `own-*` programs).
//! Helpers below them are compositions, written only in primitives.
//!
//! What is not here because it is not measured: a persistent wide accumulator, a carry flag, a
//! wrapping arithmetic right shift other than the rounded one, bitwise AND/OR on data, leading
//! zero count. A model that wants one asks for a probe first.
const std = @import("std");

/// A register or X word: 24 bits, two's complement.
pub const Word = i24;

// ---------------------------------------------------------------------------
// Primitives
// ---------------------------------------------------------------------------

/// a + b, wrapping at 24 bits. 0x02 third slot, op a+b (own-x02x3).
pub fn add(a: Word, b: Word) Word {
    return a +% b;
}

/// a - b, wrapping at 24 bits. 0x02 third slot, op a-b (own-x02x3).
pub fn sub(a: Word, b: Word) Word {
    return a -% b;
}

/// (a + b) << n, n in 0..15, wrapping at 24 bits. 0x02 third slot, shift w5[5:2] (own-x02x3).
pub fn addShl(a: Word, b: Word, n: u4) Word {
    const s: u24 = @bitCast(a +% b);
    return @bitCast(s << n);
}

/// Rounded arithmetic right shift: (a + 2^(n-1)) >> n, n in 0..23. 0x19 ALU op 23 with a
/// negative count, "b < 0: rounded a >> -b" (own-x19alu).
pub fn rshr(a: Word, n: u5) Word {
    if (n == 0) return a;
    const half: i32 = @as(i32, 1) << (n - 1);
    return @intCast((@as(i32, a) + half) >> n);
}

/// floor(a * b / 2^24), signed operands. 0x02 multiply, w1[17] = 1, w1[15] = 1, w1[16] = 0
/// (own-x02mpy, own-x02u24).
pub fn mulFloor24(a: Word, b: Word) Word {
    return @intCast((@as(i48, a) * b) >> 24);
}

/// round(a * b / 2^23), half up. 0x02 multiply, w1[17] = 0 (own-x02mpy).
pub fn mulRound23(a: Word, b: Word) Word {
    return @truncate((@as(i48, a) * b + (1 << 22)) >> 23);
}

/// (2 * a * b)[15:0], the multiply's low half beside `mulRound23`. 0x02 w4[10:7] (own-x02plo).
pub fn mulLo(a: Word, b: Word) u16 {
    return @truncate(@as(u48, @bitCast(@as(i48, a) * b *% 2)));
}

/// Predicate tests on a word: ptst conditions (own-ptst programs).
pub fn isNeg(a: Word) bool {
    return a < 0;
}

pub fn isZero(a: Word) bool {
    return a == 0;
}

// ---------------------------------------------------------------------------
// Helpers, built only from the primitives
// ---------------------------------------------------------------------------

pub fn shl(a: Word, n: u4) Word {
    return addShl(a, 0, n);
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

const testing = std.testing;

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
