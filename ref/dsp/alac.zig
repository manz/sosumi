//! ALAC's adaptive predictor (ref/alac/predictor.zig) in measured sm1 operations (ops.zig).
//!
//! The reference sums 32-bit products and wraps at 32 bits; sm1 has 24-bit words, a multiply
//! that returns slices, and no wide accumulator. Here each product is exact as hi * 2^15 + lo
//! (two multiplies, `ops.mulWide`); the lo parts and the hi parts add in separate words and the
//! lo sum carries once at the end. Only the low `chan_bits` bits of the prediction reach the
//! output, and those are exact whenever den_shift + chan_bits <= 32, wrap or no wrap.
//!
//! Supported: chan_bits <= 23, den_shift + chan_bits <= 32 and chan_bits <= 18 + den_shift
//! (the adaptation's weight times the shifted difference stays below 2^23). Every 16-bit
//! stream (chan_bits <= 17) qualifies; the rest returns `error.Unsupported`.
const std = @import("std");
const ops = @import("ops.zig");

const Word = ops.Word;

pub const Error = error{Unsupported};

pub fn supported(chan_bits: u6, den_shift: u4) bool {
    return chan_bits <= 23 and @as(u32, den_shift) + chan_bits <= 32 and chan_bits <= 18 + @as(u32, den_shift);
}

fn word(x: i32) Error!Word {
    return std.math.cast(Word, x) orelse error.Unsupported;
}

/// First-order integration in place (mode != 0).
pub fn integrate(buf: []i32, chan_bits: u6) Error!void {
    if (chan_bits > 23) return error.Unsupported;
    const cb: u5 = @intCast(chan_bits);
    var j: usize = 1;
    while (j < buf.len) : (j += 1) buf[j] = ops.signExtend(ops.add(try word(buf[j]), try word(buf[j - 1])), cb);
}

/// Residuals `pc` to samples `out`, `coefs` adapted in place; same contract as the reference.
pub fn unpredict(pc: []const i32, out: []i32, coefs: []i16, chan_bits: u6, den_shift: u4) Error!void {
    if (!supported(chan_bits, den_shift)) return error.Unsupported;
    const cb: u5 = @intCast(chan_bits);
    const n = pc.len;
    if (n == 0) return;
    out[0] = try word(pc[0]);
    const order = coefs.len;
    if (order == 0) {
        for (pc[1..n], out[1..n]) |p, *o| o.* = try word(p);
        return;
    }
    var j: usize = 1;
    while (j <= order and j < n) : (j += 1) out[j] = ops.signExtend(ops.add(try word(pc[j]), @intCast(out[j - 1])), cb);
    const lim = order + 1;
    while (j < n) : (j += 1) {
        const top: Word = @intCast(out[j - lim]);
        var acc: ops.Wide = .{ .hi = 0, .lo = 0 };
        for (0..order) |k| {
            const d = ops.sub(@intCast(out[j - 1 - k]), top);
            acc = ops.wideAdd(acc, ops.mulWide(coefs[k], d));
        }
        const s = ops.normalize(acc);
        // floor((hi * 2^15 + lo + 2^(ds-1)) / 2^ds) = hi * 2^(15-ds) + rshr(lo, ds)
        const pred = ops.add(ops.shl(s.hi, @intCast(15 - @as(u5, den_shift))), ops.rshr(s.lo, den_shift));
        const res = try word(pc[j]);
        out[j] = ops.signExtend(ops.add(ops.add(res, top), pred), cb);
        if (ops.isZero(res)) continue;

        const positive = !ops.isNeg(res);
        var del0 = res;
        var k = order;
        while (k > 0) {
            k -= 1;
            const dd = ops.sub(top, @intCast(out[j - 1 - k]));
            const sgn = ops.sign(dd);
            const mag = if (ops.isNeg(dd)) ops.sub(0, dd) else dd; // sgn * dd
            const w: i16 = @intCast(order - k);
            const c: Word = coefs[k];
            if (positive) {
                coefs[k] = @intCast(ops.signExtend(ops.sub(c, sgn), 16));
                del0 = ops.sub(del0, ops.wideValue(ops.mulWide(w, ops.floorShr(mag, den_shift))));
                if (ops.isNeg(del0) or ops.isZero(del0)) break;
            } else {
                coefs[k] = @intCast(ops.signExtend(ops.add(c, sgn), 16));
                del0 = ops.sub(del0, ops.wideValue(ops.mulWide(w, ops.floorShr(ops.sub(0, mag), den_shift))));
                if (!ops.isNeg(del0)) break;
            }
        }
    }
}

const testing = std.testing;
const ref = @import("../alac/predictor.zig");

fn compare(rnd: std.Random, order: usize, chan_bits: u6, den_shift: u4, n: usize, spread: u5) !void {
    var pc: [256]i32 = undefined;
    const lim: i32 = @as(i32, 1) << spread;
    for (pc[0..n]) |*p| p.* = rnd.intRangeAtMost(i32, -lim, lim);
    var c_ref: [31]i16 = undefined;
    for (c_ref[0..order]) |*c| c.* = rnd.int(i16) >> rnd.intRangeAtMost(u4, 0, 12);
    var c_dsp = c_ref;
    var o_ref: [256]i32 = undefined;
    var o_dsp: [256]i32 = undefined;
    ref.unpredict(pc[0..n], o_ref[0..n], c_ref[0..order], chan_bits, den_shift);
    try unpredict(pc[0..n], o_dsp[0..n], c_dsp[0..order], chan_bits, den_shift);
    try testing.expectEqualSlices(i32, o_ref[0..n], o_dsp[0..n]);
    try testing.expectEqualSlices(i16, c_ref[0..order], c_dsp[0..order]);
}

test "bit-exact with the reference predictor on random blocks" {
    var prng = std.Random.DefaultPrng.init(0xA1AC);
    const rnd = prng.random();
    for (0..4000) |_| {
        const chan_bits = rnd.intRangeAtMost(u6, 8, 23);
        const den_shift = rnd.intRangeAtMost(u4, 0, 15);
        if (!supported(chan_bits, den_shift)) continue;
        const order = rnd.intRangeAtMost(usize, 0, 31);
        const n = rnd.intRangeAtMost(usize, 1, 256);
        const spread = rnd.intRangeAtMost(u5, 0, @intCast(chan_bits - 1));
        try compare(rnd, order, chan_bits, den_shift, n, spread);
    }
}

test "16-bit stereo widths, full-range coefficients" {
    var prng = std.Random.DefaultPrng.init(17);
    const rnd = prng.random();
    for (0..2000) |_| {
        const chan_bits: u6 = if (rnd.boolean()) 16 else 17;
        try compare(rnd, rnd.intRangeAtMost(usize, 1, 31), chan_bits, rnd.int(u4), 256, @intCast(chan_bits - 1));
    }
}

test "integration matches the reference" {
    var a = [_]i32{ 32767, 1, -2, 40000, -70000 };
    var b = a;
    ref.integrate(&a, 16);
    try integrate(&b, 16);
    try testing.expectEqualSlices(i32, &a, &b);
}

test "out-of-range widths are refused" {
    try testing.expect(!supported(24, 0));
    try testing.expect(!supported(20, 0)); // 20 > 18 + 0
    try testing.expect(supported(17, 0));
    try testing.expect(supported(20, 2));
}
