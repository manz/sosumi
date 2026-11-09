//! Polyphase synthesis in measured sm1 operations: the twin of `ref/mp3/synth.zig`.
//!
//! V = N S has 64 rows but 32 distinct ones: with a = 16 + i, row 32 - i is minus row i
//! (a' = 64 - a) and row 96 - i equals row i (a' = 128 - a), so rows 0..15 and 33..48 are
//! computed (row 16 is zero) as 32-tap sums of Q21 subband words by a Q23 N, rounded once.
//! N never reaches +1 (only row 48, -1, which Q23 holds).
//!
//! The window D = d / 2^16 has integer d, so D in Q17 (2 d, below 2^18) is exact. An output
//! sample is one 16-tap sum of Q21 V by Q17 D: 2ab sits at 2^39, PCM units at 2^24, so one
//! rounded read of the sum is the sample; it saturates to 16 bits by comparisons.
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

fn row(s: *const [32]Word, n: *const [32]Word) Word {
    var acc: ops.Acc = 0;
    for (s, n) |x, c| acc = ops.mac(acc, x, c);
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
    for (0..16) |i| {
        const a = row(s, &n_rows[i]);
        st.v[i] = a;
        st.v[32 - i] = ops.sub(0, a);
        const b = row(s, &n_rows[16 + i]);
        st.v[33 + i] = b;
        st.v[96 - 33 - i] = b;
    }
    st.v[16] = 0;
    for (0..32) |j| {
        var acc: ops.Acc = 0;
        for (0..8) |i| {
            acc = ops.mac(acc, st.v[i * 128 + j], d[i * 64 + j]);
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
