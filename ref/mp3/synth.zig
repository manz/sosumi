//! Polyphase synthesis (ISO/IEC 11172-3): per time slot, shift V by 64, V = N S, build U from
//! V, window with D, sum 16 taps per output. D comes from PDMP3's copy of the standard's table.
const std = @import("std");
const fixed = @import("../fixed.zig");
const window = @import("tables/synth_window.zig");

const F24 = fixed.F24;

fn fs(comptime x: f64) F24 {
    return if (x < 0) fixed.f24(-x).negate() else fixed.f24(x);
}

/// N[i][k] = cos((16 + i)(2k + 1) pi / 64)
const n_matrix: [64][32]F24 = blk: {
    @setEvalBranchQuota(1000000);
    var t: [64][32]F24 = undefined;
    for (0..64) |i| for (0..32) |k| {
        t[i][k] = fs(@cos(@as(f64, @floatFromInt((16 + i) * (2 * k + 1))) * std.math.pi / 64.0));
    };
    break :blk t;
};

/// D[i] = d[i] / 2^16, exact.
const d: [512]F24 = blk: {
    @setEvalBranchQuota(100000);
    var t: [512]F24 = undefined;
    for (&t, window.d) |*e, v| e.* = fixed.normalize(v, -16);
    break :blk t;
};

pub const State = struct {
    v: [1024]F24 = @splat(F24.zero),
};

/// F24 in [-1, 1) scale to a 16-bit sample, rounded half away from zero, saturated.
pub fn toPcm(x: F24) i16 {
    if (x.m == 0) return 0;
    const e: i32 = @as(i32, x.e) + 15;
    const mag: i64 = @intCast(@abs(@as(i64, x.m)));
    var r: i64 = undefined;
    if (e >= 0) {
        if (e > 16) return if (x.m < 0) std.math.minInt(i16) else std.math.maxInt(i16);
        r = mag << @intCast(e);
    } else {
        if (e < -40) return 0;
        const s: u6 = @intCast(-e);
        r = (mag + (@as(i64, 1) << (s - 1))) >> s;
    }
    const v: i64 = if (x.m < 0) -r else r;
    return @intCast(std.math.clamp(v, std.math.minInt(i16), std.math.maxInt(i16)));
}

/// 32 subband samples of one time slot in, 32 PCM samples out.
pub fn slot(st: *State, s: *const [32]F24, out: *[32]i16) void {
    std.mem.copyBackwards(F24, st.v[64..], st.v[0 .. 1024 - 64]);
    for (0..64) |i| {
        var acc = F24.zero;
        for (0..32) |k| acc = fixed.fadd(acc, fixed.fmul(n_matrix[i][k], s[k]));
        st.v[i] = acc;
    }
    for (0..32) |j| {
        var acc = F24.zero;
        for (0..8) |i| {
            acc = fixed.fadd(acc, fixed.fmul(st.v[i * 128 + j], d[i * 64 + j]));
            acc = fixed.fadd(acc, fixed.fmul(st.v[i * 128 + 96 + j], d[i * 64 + 32 + j]));
        }
        out[j] = toPcm(acc);
    }
}

const testing = std.testing;

test "the window table is ISO's: D[256] = 1.144989014 (75038 / 65536)" {
    try testing.expectEqual(@as(i32, 75038), window.d[256]);
    try testing.expectApproxEqAbs(@as(f64, 1.144989014), d[256].toFloat(), 1e-9);
}

test "toPcm rounds and saturates" {
    try testing.expectEqual(@as(i16, 16384), toPcm(fixed.f24(0.5)));
    try testing.expectEqual(@as(i16, 32767), toPcm(fixed.f24(1.5)));
    try testing.expectEqual(@as(i16, -32768), toPcm(fixed.f24(1.5).negate()));
    try testing.expectEqual(@as(i16, 1), toPcm(fixed.f24(1.0 / 32768.0 * 0.75)));
}
