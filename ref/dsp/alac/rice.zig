//! ALAC's adaptive Golomb-Rice decoder (ref/alac/rice.zig) in measured sm1 operations.
//!
//! Two things the reference leans on are missing on sm1:
//! - No leading-zero count: floor(log2(x + 3)) and the zero run's clz become comparisons
//!   against powers of two (at most kb of them; the run's mean is below 128).
//! - The mean mb reaches about 2^25 (Q9 of a 16-bit magnitude), past one word: it is kept as
//!   `ops.Wide`, hi * 2^15 + lo, and pb * mb / 2^9 is formed from the two halves exactly.
//!
//! Supported: pb <= 127 (so the reference's 32-bit pb * mb never wraps), kb in 1..15 and
//! escapes of at most 22 bits. Apple's encoder writes pb 40, kb 14.
const std = @import("std");
const ops = @import("../ops.zig");
const bits = @import("../bits.zig");
const rice_ref = @import("../../alac/rice.zig");

const Word = ops.Word;

pub const Params = rice_ref.Params;
pub const Error = bits.Error || error{ RunTooLong, InvalidParams, Unsupported };

const max_prefix = 9;

pub fn supported(p: Params, max_bits: u6) bool {
    return p.pb <= 127 and p.kb >= 1 and p.kb <= 15 and max_bits <= 22 and p.mb < 1 << 22;
}

fn pow2(k: u5) Word {
    return if (k > 15) ops.shl(ops.shl(1, 15), @intCast(k - 15)) else ops.shl(1, @intCast(k));
}

/// a >= b, by the sign of the difference (both well inside a word).
fn atLeast(a: Word, b: Word) bool {
    return !ops.isNeg(ops.sub(a, b));
}

/// min(floor(log2(x + 3)), kb), x >= 0.
fn lg3aMin(x: Word, kb: u5) u5 {
    const y = ops.add(x, 3);
    var k: u5 = 1; // y >= 3
    var t: u5 = 2;
    while (t <= kb) : (t += 1) {
        if (!atLeast(y, pow2(t))) break;
        k = t;
    }
    return @min(k, kb);
}

/// Bit length of x in 0..127: the comparisons a clz would replace.
fn bitLen7(x: Word) u5 {
    var n: u5 = 0;
    while (n < 7 and atLeast(x, pow2(n))) n += 1;
    return n;
}

/// One codeword (see the reference's `get`).
fn get(r: *bits.Reader, m: Word, k: u5, escape_bits: u5) Error!Word {
    var pre: i16 = 0;
    while (pre < max_prefix) : (pre += 1) {
        if (!try r.readFlag()) break;
    }
    if (pre == max_prefix) return r.read(escape_bits);
    if (k == 0) return error.InvalidParams;
    const hi = try r.read(k - 1);
    const base = ops.wideValue(ops.mulWide(pre, m)); // pre * m < 2^18
    if (ops.isZero(hi)) return base;
    const v = ops.add(ops.shl(hi, 1), try r.read(1));
    return ops.sub(ops.add(base, v), 1);
}

fn wideOf(x: Word) ops.Wide {
    return ops.normalize(.{ .hi = 0, .lo = x });
}

/// floor(pb * mb / 2^9) for a normalized mb: (pb * hi) * 2^6 + floor(pb * lo / 2^9).
fn decay(pb: i16, mb: ops.Wide) ops.Wide {
    const a = ops.wideValue(ops.mulWide(pb, mb.hi)); // pb * hi < 2^18
    const b = ops.floorShr(ops.wideValue(ops.mulWide(pb, mb.lo)), 9); // pb * lo < 2^22
    const a_hi = ops.floorShr(a, 9);
    const a_lo = ops.sub(a, ops.shl(a_hi, 9));
    return ops.normalize(.{ .hi = a_hi, .lo = ops.add(ops.shl(a_lo, 6), b) });
}

/// Decodes `out.len` residuals; same contract as the reference.
pub fn decompress(r: *bits.Reader, out: []i32, p: Params, max_bits: u6) Error!void {
    if (!supported(p, max_bits)) return error.Unsupported;
    const pb: i16 = @intCast(p.pb);
    const kb: u5 = @intCast(p.kb);
    var mb = wideOf(@intCast(p.mb));
    var zmode: Word = 0;
    var c: usize = 0;
    while (c < out.len) {
        // k = min(lg3a(mb >> 9), kb)
        const q = ops.add(ops.shl(mb.hi, 6), ops.floorShr(mb.lo, 9));
        const k = lg3aMin(q, kb);
        const m = ops.sub(pow2(k), 1);
        const n = try get(r, m, k, @intCast(max_bits));
        const nd = ops.add(n, zmode);
        const half = ops.floorShr(nd, 1);
        const odd = !ops.isZero(ops.sub(nd, ops.shl(half, 1)));
        const mag = ops.floorShr(ops.add(nd, 1), 1);
        out[c] = if (odd) ops.sub(0, mag) else mag;
        c += 1;
        if (atLeast(n, 0x10000)) {
            mb = wideOf(0xffff);
        } else {
            const grow = ops.mulWide(pb, nd);
            const d = decay(pb, mb);
            mb = ops.normalize(.{ .hi = ops.sub(ops.add(grow.hi, mb.hi), d.hi), .lo = ops.sub(ops.add(grow.lo, mb.lo), d.lo) });
        }
        zmode = 0;
        // mb * 4 < 2^9
        if (ops.isZero(mb.hi) and !atLeast(mb.lo, 128) and c < out.len) {
            zmode = 1;
            // clz32(mb) - 24 + ((mb + 16) >> 6), mb < 128
            const kz: u5 = @intCast(8 - @as(u32, bitLen7(mb.lo)) + @as(u32, @intCast(ops.floorShr(ops.add(mb.lo, 16), 6))));
            const mz = ops.sub(pow2(@min(kz, kb)), 1);
            const run_w = try get(r, mz, kz, 16);
            const run: usize = @intCast(run_w);
            if (c + run > out.len) return error.RunTooLong;
            @memset(out[c .. c + run], 0);
            c += run;
            if (atLeast(run_w, 65535)) zmode = 0;
            mb = .{ .hi = 0, .lo = 0 };
        }
    }
}

const testing = std.testing;
const ref_bits = @import("../../bits.zig");

test "the reference's hand-built codewords" {
    var buf = [_]u8{ 0b0_0_000_10_0, 0 };
    var r = bits.Reader.init(&buf);
    var out: [2]i32 = undefined;
    try decompress(&r, &out, .{ .mb = 10, .pb = 40, .kb = 14 }, 16);
    try testing.expectEqualSlices(i32, &.{ 0, 1 }, &out);
    try testing.expectEqual(@as(usize, 7), r.pos);

    var esc = [_]u8{ 0xFF, 0x80, 0x02, 0x80, 0 };
    var r2 = bits.Reader.init(&esc);
    var one: [1]i32 = undefined;
    try decompress(&r2, &one, .{ .mb = 10, .pb = 40, .kb = 14 }, 16);
    try testing.expectEqual(@as(i32, -3), one[0]);
}

test "random bitstreams decode as the reference does, errors included" {
    var prng = std.Random.DefaultPrng.init(0x41CE);
    const rnd = prng.random();
    var buf: [512]u8 = undefined;
    for (0..3000) |_| {
        // biased bits: mostly zeros, so means stay low and zero runs appear
        const density = rnd.intRangeAtMost(u8, 1, 255);
        for (&buf) |*b| {
            var v: u8 = 0;
            for (0..8) |_| v = (v << 1) | @intFromBool(rnd.int(u8) < density);
            b.* = v;
        }
        const p: Params = .{ .mb = rnd.intRangeAtMost(u32, 0, 255), .pb = rnd.intRangeAtMost(u32, 0, 127), .kb = rnd.intRangeAtMost(u32, 1, 15) };
        const max_bits = rnd.intRangeAtMost(u6, 8, 22);
        const n = rnd.intRangeAtMost(usize, 1, 300);
        var want: [300]i32 = undefined;
        var got: [300]i32 = undefined;
        var a = ref_bits.BitReader.init(&buf);
        var b = bits.Reader.init(&buf);
        const ra = rice_ref.decompress(&a, want[0..n], p, max_bits);
        const rb = decompress(&b, got[0..n], p, max_bits);
        if (ra) |_| {
            try rb;
            try testing.expectEqualSlices(i32, want[0..n], got[0..n]);
            try testing.expectEqual(a.pos, b.pos);
        } else |e| {
            try testing.expectError(e, rb);
        }
    }
}
