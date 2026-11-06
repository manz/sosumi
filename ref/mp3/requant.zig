//! Requantisation (ISO/IEC 11172-3):
//!   x = sign(is) |is|^(4/3) 2^((global_gain - 210 - 8 subblock_gain[w]) / 4)
//!       2^(-(1 + scalefac_scale) / 2 (sf + preflag pretab[sfb]))
//! all in quarter steps of the exponent, through the shared dequantiser.
const std = @import("std");
const fixed = @import("../fixed.zig");
const pow43 = @import("../pow43.zig");
const sideinfo = @import("sideinfo.zig");
const bands = @import("bands.zig");
const scalefactors = @import("scalefactors.zig");
const spectrum = @import("spectrum.zig");

pub const Coefs = [576]fixed.F24;

pub const pretab = [22]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 3, 3, 3, 2, 0 };

pub fn requantise(g: sideinfo.Granule, b: bands.Bands, sf: *const scalefactors.Scalefactors, is: *const spectrum.Spectrum) Coefs {
    var out: Coefs = @splat(fixed.F24.zero);
    const shift: u5 = 1 + @as(u5, @intFromBool(g.scalefac_scale));
    const preflag = (g.preflag or sf.preflag) and b.n_short == 0;
    var k: usize = 0;
    for (b.widths, 0..) |w, e| {
        var q4: i32 = @as(i32, g.global_gain) - 210;
        if (b.window(e)) |win| q4 -= 8 * @as(i32, g.subblock_gain[win]);
        var s: i32 = sf.sf[e];
        if (preflag) s += pretab[e];
        q4 -= s << shift;
        for (k..k + w) |i| out[i] = pow43.scaled(is[i], q4);
        k += w;
    }
    return out;
}

const testing = std.testing;

test "global_gain 210 and no scale factors give |is|^(4/3)" {
    var is: spectrum.Spectrum = @splat(0);
    is[0] = 8;
    is[1] = -1;
    const sf: scalefactors.Scalefactors = .{};
    const b: bands.Bands = .{ .widths = &[_]u8{ 6, 6, 6, 6, 6, 6, 8, 10, 12, 14, 16, 20, 24, 28, 32, 38, 46, 52, 60, 68, 58, 54 }, .n_long = 22, .n_short = 0 };
    const c = requantise(.{ .global_gain = 210 }, b, &sf, &is);
    try testing.expectEqual(@as(f64, 16), c[0].toFloat());
    try testing.expectEqual(@as(f64, -1), c[1].toFloat());
}

test "a scale factor of 1 with scalefac_scale 0 halves the amplitude by sqrt 2" {
    var is: spectrum.Spectrum = @splat(0);
    is[0] = 1;
    var sf: scalefactors.Scalefactors = .{};
    sf.sf[0] = 2;
    const b: bands.Bands = .{ .widths = &[_]u8{ 6, 6, 6, 6, 6, 6, 8, 10, 12, 14, 16, 20, 24, 28, 32, 38, 46, 52, 60, 68, 58, 54 }, .n_long = 22, .n_short = 0 };
    const c = requantise(.{ .global_gain = 210 }, b, &sf, &is);
    try testing.expectEqual(@as(f64, 0.5), c[0].toFloat());
}
