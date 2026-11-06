//! The hybrid filterbank's frequency-to-subband half (ISO/IEC 11172-3): short-block reordering,
//! alias reduction, IMDCT (36 points, or three 12-point transforms), windowing, overlap-add and
//! frequency inversion. 576 coefficients in, 32 subbands x 18 time slots out (index sb*18 + t).
//! Direct transforms in F24; the sm1 port picks the fast ones.
const std = @import("std");
const fixed = @import("../fixed.zig");
const sideinfo = @import("sideinfo.zig");
const bands = @import("bands.zig");

const F24 = fixed.F24;
pub const Coefs = [576]F24;

fn fs(comptime x: f64) F24 {
    return if (x < 0) fixed.f24(-x).negate() else fixed.f24(x);
}

/// Alias reduction: c_i, then cs = 1 / sqrt(1 + c^2), ca = c / sqrt(1 + c^2).
const c_alias = [8]f64{ -0.6, -0.535, -0.33, -0.185, -0.095, -0.041, -0.0142, -0.0037 };
const cs: [8]F24 = blk: {
    var t: [8]F24 = undefined;
    for (&t, c_alias) |*e, c| e.* = fs(1.0 / @sqrt(1.0 + c * c));
    break :blk t;
};
const ca: [8]F24 = blk: {
    var t: [8]F24 = undefined;
    for (&t, c_alias) |*e, c| e.* = fs(c / @sqrt(1.0 + c * c));
    break :blk t;
};

/// Windows by block type: 0 normal, 1 start, 2 short (12 points), 3 stop.
const windows: [4][36]F24 = blk: {
    @setEvalBranchQuota(100000);
    var t: [4][36]F24 = @splat(@splat(F24.zero));
    const pi = std.math.pi;
    for (0..36) |i| {
        const x: f64 = @floatFromInt(i);
        const long = @sin(pi / 36.0 * (x + 0.5));
        t[0][i] = fs(long);
        t[1][i] = if (i < 18) fs(long) else if (i < 24) fs(1.0) else if (i < 30) fs(@sin(pi / 12.0 * (x - 18.0 + 0.5))) else F24.zero;
        t[3][i] = if (i < 6) F24.zero else if (i < 12) fs(@sin(pi / 12.0 * (x - 6.0 + 0.5))) else if (i < 18) fs(1.0) else fs(long);
        if (i < 12) t[2][i] = fs(@sin(pi / 12.0 * (x + 0.5)));
    }
    break :blk t;
};

/// cos(pi / 72 (2i + 1 + 18)(2k + 1))
const cos36: [36][18]F24 = blk: {
    @setEvalBranchQuota(1000000);
    var t: [36][18]F24 = undefined;
    for (0..36) |i| for (0..18) |k| {
        t[i][k] = fs(@cos(std.math.pi / 72.0 * @as(f64, @floatFromInt((2 * i + 1 + 18) * (2 * k + 1)))));
    };
    break :blk t;
};

/// cos(pi / 24 (2i + 1 + 6)(2k + 1))
const cos12: [12][6]F24 = blk: {
    @setEvalBranchQuota(100000);
    var t: [12][6]F24 = undefined;
    for (0..12) |i| for (0..6) |k| {
        t[i][k] = fs(@cos(std.math.pi / 24.0 * @as(f64, @floatFromInt((2 * i + 1 + 6) * (2 * k + 1)))));
    };
    break :blk t;
};

/// Short entries come band by band, window by window; the IMDCT wants them interleaved,
/// x[3 k + w] = window w, line k.
fn reorder(c: *Coefs, b: bands.Bands) void {
    var start: usize = 0;
    for (b.widths[0..b.n_long]) |w| start += w;
    var tmp: [576]F24 = undefined;
    var src = start;
    var dst: usize = 0;
    var e: usize = b.n_long;
    while (e < b.len()) : (e += 3) {
        const len = b.widths[e];
        for (0..len) |i| {
            for (0..3) |w| {
                tmp[dst] = c[src + w * len + i];
                dst += 1;
            }
        }
        src += 3 * len;
    }
    @memcpy(c[start .. start + dst], tmp[0..dst]);
}

fn antialias(c: *Coefs, boundaries: usize) void {
    for (0..boundaries) |sb| {
        for (0..8) |i| {
            const lo = sb * 18 + 17 - i;
            const hi = sb * 18 + 18 + i;
            const bu = c[lo];
            const bd = c[hi];
            c[lo] = fixed.fsub(fixed.fmul(bu, cs[i]), fixed.fmul(bd, ca[i]));
            c[hi] = fixed.fadd(fixed.fmul(bd, cs[i]), fixed.fmul(bu, ca[i]));
        }
    }
}

fn imdct36(x: []const F24, out: *[36]F24) void {
    for (out, 0..) |*o, i| {
        var acc = F24.zero;
        for (x, 0..) |v, k| acc = fixed.fadd(acc, fixed.fmul(v, cos36[i][k]));
        o.* = acc;
    }
}

fn imdctShort(x: []const F24, out: *[36]F24) void {
    out.* = @splat(F24.zero);
    for (0..3) |w| {
        for (0..12) |i| {
            var acc = F24.zero;
            for (0..6) |k| acc = fixed.fadd(acc, fixed.fmul(x[3 * k + w], cos12[i][k]));
            const o = 6 + 6 * w + i;
            out[o] = fixed.fadd(out[o], fixed.fmul(acc, windows[2][i]));
        }
    }
}

pub const State = struct {
    overlap: [32][18]F24 = @splat(@splat(F24.zero)),
};

/// One granule of one channel: coefficients in, subband samples out.
pub fn run(st: *State, g: sideinfo.Granule, b: bands.Bands, long_subbands_if_mixed: u8, c: *Coefs) void {
    const short = g.isShort();
    const n_long_sb: usize = if (!short) 32 else if (g.mixed) long_subbands_if_mixed else 0;
    if (short) reorder(c, b);
    antialias(c, if (n_long_sb == 0) 0 else n_long_sb - 1);
    for (0..32) |sb| {
        var y: [36]F24 = undefined;
        const x = c[sb * 18 .. sb * 18 + 18];
        if (sb < n_long_sb) {
            imdct36(x, &y);
            const wt: usize = if (short) 0 else g.block_type;
            for (&y, windows[wt]) |*v, w| v.* = fixed.fmul(v.*, w);
        } else {
            imdctShort(x, &y);
        }
        for (0..18) |i| {
            var v = fixed.fadd(y[i], st.overlap[sb][i]);
            if (sb & 1 == 1 and i & 1 == 1) v = v.negate();
            c[sb * 18 + i] = v;
            st.overlap[sb][i] = y[18 + i];
        }
    }
}

const testing = std.testing;

test "alias coefficients match minimp3's g_aa" {
    const want_cs = [8]f64{ 0.85749293, 0.88174200, 0.94962865, 0.98331459, 0.99551782, 0.99916056, 0.99989920, 0.99999316 };
    const want_ca = [8]f64{ 0.51449576, 0.47173197, 0.31337745, 0.18191320, 0.09457419, 0.04096558, 0.01419856, 0.00369997 };
    for (0..8) |i| {
        try testing.expectApproxEqAbs(want_cs[i], cs[i].toFloat(), 1e-7);
        try testing.expectApproxEqAbs(-want_ca[i], ca[i].toFloat(), 1e-7);
    }
}

test "windows satisfy w[i]^2 + w[i + 18]^2 = 1 for the normal block" {
    for (0..18) |i| {
        const a = windows[0][i].toFloat();
        const b = windows[0][i + 18].toFloat();
        try testing.expectApproxEqAbs(@as(f64, 1), a * a + b * b, 1e-6);
    }
}

test "reorder interleaves the three windows of a band" {
    var c: Coefs = @splat(F24.zero);
    const b: bands.Bands = .{ .widths = &[_]u8{ 2, 2, 2 }, .n_long = 0, .n_short = 3 };
    for (0..6) |i| c[i] = fixed.normalize(@intCast(i + 1), 0);
    reorder(&c, b);
    // window 0 lines (1, 2), window 1 (3, 4), window 2 (5, 6) -> 1 3 5 2 4 6
    const want = [_]f64{ 1, 3, 5, 2, 4, 6 };
    for (want, 0..) |w, i| try testing.expectEqual(w, c[i].toFloat());
}
