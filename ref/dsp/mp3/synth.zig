//! Polyphase synthesis in measured sm1 operations: the twin of `ref/mp3/synth.zig`.
//!
//! V = N S has 64 rows but 32 distinct ones: with a = 16 + i, row 32 - i is minus row i
//! (a' = 64 - a) and row 96 - i equals row i (a' = 128 - a), so rows 0..15 and 33..48 are
//! computed (row 16 is zero) as sums of Q21 subband words by a Q23 N, rounded once.
//! N never reaches +1 (only row 48, -1, which Q23 holds).
//!
//! Each distinct row is cos(n (2k + 1) pi / 64) for one n, and N[r][31 - k] = (-1)^n N[r][k]
//! (and within the first 16, N[r][15 - k] = (-1)^(n / 2) N[r][k] for even n), exactly in Q23.
//! So a row is a 16-term sum over g1 = s[k] + s[31 - k] or h1 = s[k] - s[31 - k], and an even
//! n's an 8-term sum over g2 = g1[k] + g1[15 - k] or h2 = g1[k] - g1[15 - k]: 384 products,
//! the same 48-bit sums as the 32-term ones while the g and h words (24-bit, wrapping) hold.
//!
//! The window D = d / 2^16 has integer d, so D in Q17 (2 d, below 2^18) is exact. An output
//! sample is one 16-tap sum of Q21 V by Q17 D: 2ab sits at 2^39, PCM units at 2^24, so one
//! rounded read of the sum is the sample; it saturates to 16 bits by comparisons. Sample 32 - j
//! (j < 16) reads V[j] by -D where the ISO window reads V[32 - j] = -V[j]: the same sum unless
//! V[j] = -2^23, whose negation wraps (sm1 reads the word once for both samples).
const std = @import("std");
const ops = @import("../ops.zig");
const window = @import("../../mp3/tables/synth_window.zig");

const Word = ops.Word;

fn q(comptime x: f64, comptime f: u5) Word {
    return @intFromFloat(@round(x * @as(f64, @floatFromInt(@as(u32, 1) << f))));
}

/// Rows 0..15 then 33..48 of N[i][k] = cos((16 + i)(2k + 1) pi / 64), Q23.
pub const n_rows: [32][32]Word = blk: {
    @setEvalBranchQuota(1000000);
    var t: [32][32]Word = undefined;
    for (0..32) |r| for (0..32) |k| {
        const i = if (r < 16) r else r + 17;
        const v = @cos(@as(f64, @floatFromInt((16 + i) * (2 * k + 1))) * std.math.pi / 64.0);
        t[r][k] = if (v <= -1.0) -(1 << 23) else q(v, 23);
    };
    break :blk t;
};

/// D[i] * 2^17 = 2 d[i], exact.
pub const d: [512]Word = blk: {
    var t: [512]Word = undefined;
    for (&t, window.d) |*e, v| e.* = @intCast(2 * v);
    break :blk t;
};

pub const State = struct {
    v: [1024]Word = @splat(0),
};

/// The DCT index n of distinct row r: rows 0..15 are n = 16 + r, rows 16..31 n = 15 - (r - 16).
pub fn rowN(r: usize) usize {
    return if (r < 16) 16 + r else 31 - r;
}

/// The words a row sums over: its level (1: 16 terms, 2: 8) and which of g / h.
pub const Split = struct { g1: [16]Word, h1: [16]Word, g2: [8]Word, h2: [8]Word };

pub fn split(s: *const [32]Word) Split {
    var o: Split = undefined;
    for (0..16) |k| {
        o.g1[k] = ops.add(s[k], s[31 - k]);
        o.h1[k] = ops.sub(s[k], s[31 - k]);
    }
    for (0..8) |k| {
        o.g2[k] = ops.add(o.g1[k], o.g1[15 - k]);
        o.h2[k] = ops.sub(o.g1[k], o.g1[15 - k]);
    }
    return o;
}

/// Distinct row r over the split words, rshr(sum, 24).
pub fn row(sp: *const Split, r: usize) Word {
    const n = rowN(r);
    const c = &n_rows[r];
    const x: []const Word = if (n & 1 == 1) &sp.h1 else if (n & 2 == 2) &sp.h2 else &sp.g2;
    var acc: ops.Acc = 0;
    for (x, 0..) |v, k| acc = ops.mac(acc, v, c[k]);
    return ops.accRshr(acc, 24);
}

/// A sample in [-32768, 32767] by comparisons.
fn clamp16(x: Word) i16 {
    if (ops.isNeg(ops.sub(32767, x))) return 32767;
    if (ops.isNeg(ops.add(x, 32768))) return -32768;
    return @intCast(x);
}

/// 32 subband samples (Q21) of one time slot in, 32 PCM samples out.
pub fn slot(st: *State, s: *const [32]Word, out: *[32]i16) void {
    std.mem.copyBackwards(Word, st.v[64..], st.v[0 .. 1024 - 64]);
    const sp = split(s);
    for (0..16) |i| {
        const a = row(&sp, i);
        st.v[i] = a;
        st.v[32 - i] = ops.sub(0, a);
        const b = row(&sp, 16 + i);
        st.v[33 + i] = b;
        st.v[96 - 33 - i] = b;
    }
    st.v[16] = 0;
    for (0..32) |j| {
        var acc: ops.Acc = 0;
        for (0..8) |i| {
            // sample 32 - j shares V[j] with sample j (V[32 - j] = -V[j]): sm1 reads it once
            acc = if (j > 16)
                ops.mac(acc, st.v[i * 128 + 32 - j], ops.sub(0, d[i * 64 + j]))
            else
                ops.mac(acc, st.v[i * 128 + j], d[i * 64 + j]);
            acc = ops.mac(acc, st.v[i * 128 + 96 + j], d[i * 64 + 32 + j]);
        }
        out[j] = clamp16(ops.accRshr(acc, 24));
    }
}

const testing = std.testing;

test "the 32 rows rebuild all 64 of N" {
    for (0..64) |i| for (0..32) |k| {
        const a = @cos(@as(f64, @floatFromInt((16 + i) * (2 * k + 1))) * std.math.pi / 64.0);
        const got: f64 = if (i < 16) @floatFromInt(n_rows[i][k]) else if (i == 16) 0 else if (i <= 32) -@as(f64, @floatFromInt(n_rows[32 - i][k])) else if (i <= 48) @floatFromInt(n_rows[i - 17][k]) else @floatFromInt(n_rows[96 - i - 17][k]);
        try testing.expectApproxEqAbs(a, got / (1 << 23), 1e-6);
    };
}

test "N's rows fold exactly: N[r][31 - k] = (-1)^n N[r][k], N[r][15 - k] = (-1)^(n/2) N[r][k]" {
    for (0..32) |r| {
        const n = rowN(r);
        for (0..16) |k| {
            const sgn: Word = if (n & 1 == 1) -1 else 1;
            try testing.expectEqual(n_rows[r][k] * sgn, n_rows[r][31 - k]);
        }
        if (n & 1 == 0) for (0..8) |k| {
            const sgn: Word = if (n & 2 == 2) -1 else 1;
            try testing.expectEqual(n_rows[r][k] * sgn, n_rows[r][15 - k]);
        };
    }
}

test "the split rows equal the 32-term sums" {
    var prng = std.Random.DefaultPrng.init(0x384);
    const rnd = prng.random();
    for (0..20_000) |_| {
        var s: [32]Word = undefined;
        for (&s) |*x| x.* = rnd.intRangeAtMost(Word, -(1 << 17), 1 << 17); // V in range: 32 * 2^17 < 2^23
        const sp = split(&s);
        for (0..32) |r| {
            var acc: ops.Acc = 0;
            for (s, n_rows[r]) |x, c| acc = ops.mac(acc, x, c);
            try testing.expectEqual(ops.accRshr(acc, 24), row(&sp, r));
        }
    }
}
