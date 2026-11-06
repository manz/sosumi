//! Temporal noise shaping (ISO/IEC 14496-3): an all-pole filter run across the spectrum of a
//! window, between band limits, in either direction.
//!
//! Coefficient dequantisation: sin(c * pi / (2^bits - 1)) for c >= 0 and
//! sin(c * pi / (2^bits + 1)) for c < 0, with bits = coef_res + 3, as ISO states it and as
//! OpenCORE's tns_table holds it (checked below). Reflection coefficients become the
//! direct-form LPC by the step-up recursion. The filter runs in F24.
//!
//! TNS_MAX_BANDS per rate comes from OpenCORE's get_tns.cpp (Apache 2.0); 7350 Hz, missing
//! there, uses the 8 kHz values (INFERRED). TNS_MAX_ORDER for long windows is 12, ISO's AAC-LC
//! value as we read it; OpenCORE uses 20 at 32 kHz and below (OPEN).
const std = @import("std");
const fixed = @import("fixed.zig");
const ics = @import("ics.zig");
const iquant = @import("iquant.zig");

const F24 = fixed.F24;

pub const max_order_long = 12;
pub const max_order_short = 7;

const max_bands_long = [13]u8{ 31, 31, 34, 40, 42, 51, 46, 46, 42, 42, 42, 39, 39 };
const max_bands_short = [13]u8{ 9, 9, 10, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14 };

fn sinTable(comptime coef_res: u1) [16]F24 {
    @setEvalBranchQuota(10000);
    const bits = @as(u32, coef_res) + 3;
    const half: i32 = @as(i32, 1) << (bits - 1);
    var t: [16]F24 = @splat(F24.zero);
    var c: i32 = -half;
    while (c < half) : (c += 1) {
        const denom: f64 = if (c >= 0) std.math.pow(f64, 2, bits) - 1 else std.math.pow(f64, 2, bits) + 1;
        const v = @sin(@as(f64, @floatFromInt(c)) * std.math.pi / denom);
        const x = fixed.f24(@abs(v));
        t[@intCast(c + half)] = if (v < 0) x.negate() else x;
    }
    return t;
}

const sin_tables = [2][16]F24{ sinTable(0), sinTable(1) };

fn reflection(coef_res: u1, c: i4) F24 {
    const half: i32 = if (coef_res == 1) 8 else 4;
    return sin_tables[coef_res][@intCast(@as(i32, c) + half)];
}

/// Direct-form coefficients a[1..order] from the reflection coefficients (step-up).
pub fn lpcFromCoefs(coef_res: u1, codes: []const i4, out: []F24) void {
    var tmp: [31]F24 = undefined;
    for (codes, 0..) |c, m0| {
        const m = m0 + 1;
        const k = reflection(coef_res, c);
        for (1..m) |i| tmp[i] = fixed.fadd(out[i - 1], fixed.fmul(k, out[m - i - 1]));
        for (1..m) |i| out[i - 1] = tmp[i];
        out[m - 1] = k;
    }
}

/// y[n] = x[n] - sum a[i] y[n - i], over `spec` forwards or backwards.
pub fn arFilter(spec: []F24, lpc: []const F24, backwards: bool) void {
    var hist: [31]F24 = @splat(F24.zero); // hist[i] = y[n - 1 - i]
    for (0..spec.len) |step| {
        const n = if (backwards) spec.len - 1 - step else step;
        var y = spec[n];
        for (lpc, 0..) |a, i| y = fixed.fsub(y, fixed.fmul(a, hist[i]));
        std.mem.copyBackwards(F24, hist[1..lpc.len], hist[0 .. lpc.len - 1]);
        if (lpc.len > 0) hist[0] = y;
        spec[n] = y;
    }
}

/// Applies a channel's TNS data to its coefficients, window by window.
pub fn apply(ch: *const ics.Channel, coefs: *iquant.Coefs, freq_index: u4) void {
    const tns = ch.tns orelse return;
    const info = ch.info;
    const short = info.isShort();
    const offsets = info.bandOffsets(freq_index);
    const num_swb: u32 = @intCast(offsets.len - 1);
    const limit = @min(if (short) max_bands_short[freq_index] else max_bands_long[freq_index], info.max_sfb);
    const max_order: u32 = if (short) max_order_short else max_order_long;
    const win_len: usize = if (short) 128 else 1024;
    for (0..info.numWindows()) |w| {
        const win = tns.windows[w];
        var top: u32 = num_swb;
        for (win.filt[0..win.n_filt]) |f| {
            const bottom = top -| f.length;
            defer top = bottom;
            const order = @min(f.order, max_order);
            if (order == 0) continue;
            const start = w * win_len + offsets[@min(bottom, limit)];
            const end = w * win_len + offsets[@min(top, limit)];
            if (end <= start) continue;
            var lpc: [31]F24 = undefined;
            lpcFromCoefs(win.coef_res, f.coef[0..order], lpc[0..order]);
            arFilter(coefs[start..end], lpc[0..order], f.direction);
        }
    }
}

const testing = std.testing;

test "the sine tables match OpenCORE's tns_table" {
    const pv = [2][16]i64{
        .{ -2114858546, -1859775393, -1380375881, -734482665, 0, 931758235, 1678970324, 2093641749, 0, 0, 0, 0, 0, 0, 0, 0 },
        .{ -2138322861, -2065504841, -1922348530, -1713728946, -1446750378, -1130504462, -775760571, -394599085, 0, 446486956, 873460290, 1262259218, 1595891361, 1859775393, 2042378317, 2135719508 },
    };
    for (0..2) |res| {
        const n: usize = if (res == 1) 16 else 8;
        for (0..n) |i| {
            const want = @as(f64, @floatFromInt(pv[res][i])) / 0x1p31;
            try testing.expectApproxEqAbs(want, sin_tables[res][i].toFloat(), 1e-7);
        }
    }
}

test "step-up recursion for order 2" {
    var a: [2]F24 = undefined;
    lpcFromCoefs(1, &.{ 1, 2 }, &a);
    const k1 = reflection(1, 1).toFloat();
    const k2 = reflection(1, 2).toFloat();
    try testing.expectApproxEqRel(k1 + k2 * k1, a[0].toFloat(), 1e-6);
    try testing.expectApproxEqRel(k2, a[1].toFloat(), 1e-6);
}

test "first-order filter impulse response, both directions" {
    const half = [_]F24{fixed.f24(0.5)};
    var x: [4]F24 = .{ fixed.f24(1.0), F24.zero, F24.zero, F24.zero };
    arFilter(&x, &half, false);
    try testing.expectEqual(@as(f64, -0.5), x[1].toFloat());
    try testing.expectEqual(@as(f64, -0.125), x[3].toFloat());
    var y: [4]F24 = .{ F24.zero, F24.zero, F24.zero, fixed.f24(1.0) };
    arFilter(&y, &half, true);
    try testing.expectEqual(@as(f64, 0.25), y[1].toFloat());
    try testing.expectEqual(@as(f64, 1.0), y[3].toFloat());
}

test "TNS stops at TNS_MAX_BANDS and leaves the bands above alone" {
    var ch: ics.Channel = .{
        .global_gain = 100,
        .info = .{ .window_sequence = .only_long, .window_shape = 0, .max_sfb = 49, .num_window_groups = 1, .group_len = @splat(0) },
        .sections = .{},
        .scalefactors = @splat(@splat(0)),
        .pulse = null,
        .tns = .{},
        .spectrum = @splat(0),
    };
    ch.info.group_len[0] = 1;
    ch.tns.?.windows[0].n_filt = 1;
    ch.tns.?.windows[0].coef_res = 1;
    ch.tns.?.windows[0].filt[0] = .{ .length = 49, .order = 1, .coef = @splat(0) };
    ch.tns.?.windows[0].filt[0].coef[0] = 4;
    var c: iquant.Coefs = @splat(fixed.f24(1.0));
    apply(&ch, &c, 4); // 44.1 kHz: TNS_MAX_BANDS 42 -> coefficient 736
    try testing.expectEqual(@as(f64, 1.0), c[0].toFloat()); // first sample of the run
    try testing.expect(c[1].toFloat() != 1.0);
    try testing.expect(c[735].toFloat() != 1.0);
    try testing.expectEqual(@as(f64, 1.0), c[736].toFloat());
    try testing.expectEqual(@as(f64, 1.0), c[1023].toFloat());
}
