//! The hybrid filterbank in measured sm1 operations: the twin of `ref/mp3/hybrid.zig`, on Q21
//! words. Every sum of products is one tap sum (`ops.mac`, exact to 48 bits) rounded once.
//!
//!   - Alias reduction: each butterfly output is a two-term tap sum with Q23 cs, ca.
//!   - IMDCT-36: out[i] = sum_k x[k] cos(pi/72 (2i + 19)(2k + 1)). Only 18 rows are distinct:
//!     out[17 - i] = -out[i] (i < 9) and out[53 - i] = out[i] (18 <= i < 27), the angle's
//!     factor being 72 - a and 144 - a. 324 taps, a 324-word table.
//!   - IMDCT-12, per short window: out[i] = sum_k x[3k + w] cos(pi/24 (2i + 7)(2k + 1)), six
//!     distinct rows the same way (out[5 - i] = -out[i], out[17 - i] = out[i]).
//!   - Windows are Q23, 1.0 held as 2^23 - 1 (the start and stop blocks), one x02 rounded
//!     product each (`ops.mulRound23`): exact for |v| < 2^22, a Q21 value below 2.
//!   - Overlap-add and the frequency inversion are plain adds and negations.
//! Words wrap at 24 bits, as sm1's do: Q21 leaves |value| < 4, the fixtures peak below 1.1.
const std = @import("std");
const ops = @import("../ops.zig");
const sideinfo = @import("../../mp3/sideinfo.zig");
const bands = @import("../../mp3/bands.zig");
const requant = @import("requant.zig");

const Word = ops.Word;
pub const Coefs = requant.Coefs;

fn q(comptime x: f64, comptime f: u5) Word {
    return @intFromFloat(@round(x * @as(f64, @floatFromInt(@as(u32, 1) << f))));
}

const c_alias = [8]f64{ -0.6, -0.535, -0.33, -0.185, -0.095, -0.041, -0.0142, -0.0037 };
pub const cs: [8]Word = blk: {
    var t: [8]Word = undefined;
    for (&t, c_alias) |*e, c| e.* = q(1.0 / @sqrt(1.0 + c * c), 23);
    break :blk t;
};
pub const ca: [8]Word = blk: {
    var t: [8]Word = undefined;
    for (&t, c_alias) |*e, c| e.* = q(c / @sqrt(1.0 + c * c), 23);
    break :blk t;
};

/// Windows by block type, Q23 (1.0 as 2^23 - 1): 0 normal, 1 start, 2 short (12 points), 3 stop.
pub const windows: [4][36]Word = blk: {
    @setEvalBranchQuota(100000);
    var t: [4][36]Word = @splat(@splat(0));
    const pi = std.math.pi;
    for (0..36) |i| {
        const x: f64 = @floatFromInt(i);
        const long = @sin(pi / 36.0 * (x + 0.5));
        t[0][i] = qw(long);
        t[1][i] = if (i < 18) qw(long) else if (i < 24) qw(1.0) else if (i < 30) qw(@sin(pi / 12.0 * (x - 18.0 + 0.5))) else 0;
        t[3][i] = if (i < 6) 0 else if (i < 12) qw(@sin(pi / 12.0 * (x - 6.0 + 0.5))) else if (i < 18) qw(1.0) else qw(long);
        if (i < 12) t[2][i] = qw(@sin(pi / 12.0 * (x + 0.5)));
    }
    break :blk t;
};

/// The distinct IMDCT-36 rows, i = 0..8 then 18..26, Q23.
pub const cos36: [18][18]Word = blk: {
    @setEvalBranchQuota(1000000);
    var t: [18][18]Word = undefined;
    for (0..18) |r| for (0..18) |k| {
        const i = if (r < 9) r else r + 9;
        t[r][k] = q(@cos(std.math.pi / 72.0 * @as(f64, @floatFromInt((2 * i + 19) * (2 * k + 1)))), 23);
    };
    break :blk t;
};

/// The distinct IMDCT-12 rows, i = 0..2 then 6..8, Q23.
pub const cos12: [6][6]Word = blk: {
    @setEvalBranchQuota(100000);
    var t: [6][6]Word = undefined;
    for (0..6) |r| for (0..6) |k| {
        const i = if (r < 3) r else r + 3;
        t[r][k] = q(@cos(std.math.pi / 24.0 * @as(f64, @floatFromInt((2 * i + 7) * (2 * k + 1)))), 23);
    };
    break :blk t;
};

fn reorder(c: *Coefs, b: bands.Bands) void {
    var start: usize = 0;
    for (b.widths[0..b.n_long]) |w| start += w;
    var tmp: [576]Word = undefined;
    var src = start;
    var dst: usize = 0;
    var e: usize = b.n_long;
    while (e < b.len()) : (e += 3) {
        const len = b.widths[e];
        for (0..len) |i| for (0..3) |w| {
            tmp[dst] = c[src + w * len + i];
            dst += 1;
        };
        src += 3 * len;
    }
    @memcpy(c[start .. start + dst], tmp[0..dst]);
}

fn antialias(c: *Coefs, boundaries: usize) void {
    for (0..boundaries) |sb| for (0..8) |i| {
        const lo = sb * 18 + 17 - i;
        const hi = sb * 18 + 18 + i;
        const bu = c[lo];
        const bd = c[hi];
        c[lo] = ops.accRshr(ops.mac(ops.mac(0, bu, cs[i]), ops.sub(0, bd), ca[i]), 24);
        c[hi] = ops.accRshr(ops.mac(ops.mac(0, bd, cs[i]), bu, ca[i]), 24);
    };
}

fn row(x: []const Word, stride: usize, cos: []const Word) Word {
    var acc: ops.Acc = 0;
    for (cos, 0..) |cv, k| acc = ops.mac(acc, x[k * stride], cv);
    return ops.accRshr(acc, 24);
}

fn imdct36(x: []const Word, out: *[36]Word) void {
    for (0..9) |i| {
        const a = row(x, 1, &cos36[i]);
        out[i] = a;
        out[17 - i] = ops.sub(0, a);
        const b = row(x, 1, &cos36[9 + i]);
        out[18 + i] = b;
        out[35 - i] = b;
    }
}

fn win(v: Word, w: Word) Word {
    return ops.mulRound23(v, w);
}

fn qw(comptime x: f64) Word {
    return if (x >= 1.0) (1 << 23) - 1 else q(x, 23);
}

fn imdctShort(x: []const Word, out: *[36]Word) void {
    out.* = @splat(0);
    for (0..3) |w| {
        var y: [12]Word = undefined;
        for (0..3) |i| {
            const a = row(x[w..], 3, &cos12[i]);
            y[i] = a;
            y[5 - i] = ops.sub(0, a);
            const b = row(x[w..], 3, &cos12[3 + i]);
            y[6 + i] = b;
            y[11 - i] = b;
        }
        for (0..12) |i| {
            const o = 6 + 6 * w + i;
            out[o] = ops.add(out[o], win(y[i], windows[2][i]));
        }
    }
}

pub const State = struct {
    overlap: [32][18]Word = @splat(@splat(0)),
};

/// One granule of one channel: coefficients in, subband samples out (index sb * 18 + t).
pub fn run(st: *State, g: sideinfo.Granule, b: bands.Bands, long_subbands_if_mixed: u8, c: *Coefs) void {
    const short = g.isShort();
    const n_long_sb: usize = if (!short) 32 else if (g.mixed) long_subbands_if_mixed else 0;
    if (short) reorder(c, b);
    antialias(c, if (n_long_sb == 0) 0 else n_long_sb - 1);
    for (0..32) |sb| {
        var y: [36]Word = undefined;
        const x = c[sb * 18 .. sb * 18 + 18];
        if (sb < n_long_sb) {
            imdct36(x, &y);
            const wt: usize = if (short) 0 else g.block_type;
            for (&y, windows[wt]) |*v, w| v.* = win(v.*, w);
        } else {
            imdctShort(x, &y);
        }
        for (0..18) |i| {
            var v = ops.add(y[i], st.overlap[sb][i]);
            if (sb & 1 == 1 and i & 1 == 1) v = ops.sub(0, v);
            c[sb * 18 + i] = v;
            st.overlap[sb][i] = y[18 + i];
        }
    }
}

const testing = std.testing;

test "the IMDCT-36 symmetries hold for the full cosine matrix" {
    for (0..36) |i| for (0..18) |k| {
        const a = @cos(std.math.pi / 72.0 * @as(f64, @floatFromInt((2 * i + 19) * (2 * k + 1))));
        const want: f64 = if (i < 9) 1 else if (i < 18) -1 else if (i < 27) 1 else 1;
        const r: usize = if (i < 9) i else if (i < 18) 17 - i else if (i < 27) i - 9 else 53 - i - 9;
        try testing.expectApproxEqAbs(a, want * @as(f64, @floatFromInt(cos36[r][k])) / (1 << 23), 1e-6);
    };
}

test "the IMDCT-12 symmetries hold for the full cosine matrix" {
    for (0..12) |i| for (0..6) |k| {
        const a = @cos(std.math.pi / 24.0 * @as(f64, @floatFromInt((2 * i + 7) * (2 * k + 1))));
        const want: f64 = if (i < 3) 1 else if (i < 6) -1 else 1;
        const r: usize = if (i < 3) i else if (i < 6) 5 - i else if (i < 9) i - 3 else 17 - i - 3;
        try testing.expectApproxEqAbs(a, want * @as(f64, @floatFromInt(cos12[r][k])) / (1 << 23), 1e-6);
    };
}
