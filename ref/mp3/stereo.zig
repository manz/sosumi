//! Joint stereo (ISO/IEC 11172-3, 13818-3), structured as minimp3 does it (CC0): intensity
//! stereo above the highest non-zero band of the right channel (per window in short blocks),
//! M/S below it. Without folding the M/S 1/sqrt 2 into the gain, intensity needs no sqrt 2.
const std = @import("std");
const fixed = @import("../fixed.zig");
const header = @import("header.zig");
const sideinfo = @import("sideinfo.zig");
const bands = @import("bands.zig");
const scalefactors = @import("scalefactors.zig");
const requant = @import("requant.zig");

const F24 = fixed.F24;

const inv_sqrt2 = fixed.f24(0.7071067811865476);

/// MPEG-1 intensity: kl = tan(p pi/12) / (1 + tan), kr = 1 / (1 + tan), for p = 0..6.
const pan: [7][2]F24 = blk: {
    var t: [7][2]F24 = undefined;
    for (0..7) |p| {
        const a = @as(f64, @floatFromInt(p)) * std.math.pi / 12.0;
        const sn = @sin(a);
        const cs = @cos(a);
        t[p] = .{ fixed.f24(sn / (sn + cs)), fixed.f24(cs / (sn + cs)) };
    }
    break :blk t;
};

/// 2^(-n / 4) for any n >= 0.
fn pow2NegQuarter(n: u32) F24 {
    const frac = [4]F24{ fixed.f24(1.0), fixed.f24(0.8408964152537145), fixed.f24(0.7071067811865476), fixed.f24(0.5946035575013605) };
    return fixed.scale2(frac[n & 3], -@as(i32, @intCast(n >> 2)));
}

fn ms(l: []F24, r: []F24) void {
    for (l, r) |*a, *b| {
        const m = a.*;
        a.* = fixed.fmul(fixed.fadd(m, b.*), inv_sqrt2);
        b.* = fixed.fmul(fixed.fsub(m, b.*), inv_sqrt2);
    }
}

fn intensity(l: []F24, r: []F24, kl: F24, kr: F24) void {
    for (l, r) |*a, *b| {
        const x = a.*;
        a.* = fixed.fmul(x, kl);
        b.* = fixed.fmul(x, kr);
    }
}

pub fn process(h: header.Header, gr: sideinfo.Granule, right_gr: sideinfo.Granule, right_sf: *const scalefactors.Scalefactors, left: *requant.Coefs, right: *requant.Coefs) void {
    const b = bands.of(h, gr);
    if (!h.intensityStereo()) {
        if (h.msStereo()) ms(left, right);
        return;
    }
    const n = b.len();
    // highest entry per window that carries a non-zero right coefficient
    var max_band: [3]i32 = .{ -1, -1, -1 };
    var k: usize = 0;
    for (b.widths, 0..) |w, e| {
        for (right[k .. k + w]) |c| {
            if (c.m != 0) {
                max_band[e % 3] = @intCast(e);
                break;
            }
        }
        k += w;
    }
    if (b.n_long != 0) {
        const m = @max(max_band[0], @max(max_band[1], max_band[2]));
        max_band = .{ m, m, m };
    }
    var pos: [scalefactors.max_entries]u8 = right_sf.sf;
    var illegal = right_sf.illegal;
    const mpeg1 = h.version == .mpeg1;
    const blocks: usize = if (b.n_short != 0) 3 else 1;
    // the top band carries no scale factor: it inherits the band below, or the default
    for (0..blocks) |i| {
        const top = n - blocks + i;
        const prev = top - blocks;
        if (max_band[i] >= @as(i32, @intCast(prev))) {
            pos[top] = if (mpeg1) 3 else 0;
            illegal[top] = false;
        } else {
            pos[top] = pos[prev];
            illegal[top] = illegal[prev];
        }
    }
    const sh: u5 = @intFromBool(right_gr.scalefac_compress & 1 != 0);
    k = 0;
    for (b.widths, 0..) |w, e| {
        const l = left[k .. k + w];
        const r = right[k .. k + w];
        k += w;
        const p = pos[e];
        const legal = if (mpeg1) p < 7 else !illegal[e];
        if (@as(i32, @intCast(e)) > max_band[e % 3] and legal) {
            if (mpeg1) {
                intensity(l, r, pan[p][0], pan[p][1]);
            } else {
                const v = pow2NegQuarter((@as(u32, p) + 1) >> 1 << sh);
                if (p & 1 != 0) intensity(l, r, v, fixed.f24(1.0)) else intensity(l, r, fixed.f24(1.0), v);
            }
        } else if (h.msStereo()) {
            ms(l, r);
        }
    }
}

const testing = std.testing;

test "M/S: (3, 1) becomes (4, 2) / sqrt 2" {
    var l: requant.Coefs = @splat(fixed.f24(3.0));
    var r: requant.Coefs = @splat(fixed.f24(1.0));
    const h = try header.parse(&.{ 0xFF, 0xFB, 0x90, 0x64 }); // joint stereo, M/S on
    process(h, .{}, .{}, &.{}, &l, &r);
    try testing.expectApproxEqRel(4.0 / @sqrt(2.0), l[100].toFloat(), 1e-6);
    try testing.expectApproxEqRel(2.0 / @sqrt(2.0), r[575].toFloat(), 1e-6);
}

test "MPEG-1 intensity position 0 sends everything right, 6 everything left" {
    try testing.expectEqual(F24.zero, pan[0][0]);
    try testing.expectEqual(@as(f64, 1), pan[0][1].toFloat());
    try testing.expectApproxEqAbs(@as(f64, 0.5), pan[3][0].toFloat(), 1e-7);
    try testing.expectApproxEqAbs(@as(f64, 1), pan[6][0].toFloat(), 1e-7);
}
