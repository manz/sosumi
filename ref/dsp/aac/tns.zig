//! Temporal noise shaping in measured sm1 operations: the twin of `ref/aac/tns.zig` on the
//! dequantiser's blocks (value = w * 2^e, one exponent a channel).
//!
//! The reference turns the reflection coefficients into direct-form LPC (step-up) and runs
//! y[n] = x[n] - sum a[i] y[n - i] in F24. Direct-form coefficients grow to C(order, i), past
//! any Q23 word, so here the same all-pole filter runs as a lattice on the reflection
//! coefficients themselves, |k| < 1 in Q23:
//!
//!   f_M = x;  f_(m-1) = f_m - k_m b_(m-1)[n-1];  b_m[n] = k_m f_(m-1) + b_(m-1)[n-1];  y = f_0 = b_0
//!
//! which is 1 / A(z) for the step-up's A (checked below), at two rounded multiplies a stage.
//! Every input, f and b is kept inside (-2^22, 2^22), so f_m - k b and k f + b stay below 2^23
//! as plain adds. A filter that would leave that range has its run put back, the whole block
//! halved (rounded, exponent + 1) and the run filtered again: the gain of 1 / A(z) is the
//! data's, so the headroom is found, not assumed.
const std = @import("std");
const ops = @import("../ops.zig");
const dequant = @import("dequant.zig");
const ics = @import("../../aac/ics.zig");
const ref = @import("../../aac/tns.zig");

const Word = ops.Word;
const Block = dequant.Block;

/// Reflection coefficients in Q23 by coef_res and code + 2^(bits - 1): sin(c pi / (2^bits -+ 1)).
pub const refl: [2][16]Word = blk: {
    @setEvalBranchQuota(10000);
    var t: [2][16]Word = @splat(@splat(0));
    for (0..2) |res| {
        const bits: u32 = @as(u32, @intCast(res)) + 3;
        const half: i32 = @as(i32, 1) << (bits - 1);
        var c: i32 = -half;
        while (c < half) : (c += 1) {
            const p: f64 = std.math.pow(f64, 2, @floatFromInt(bits));
            const denom: f64 = if (c >= 0) p - 1 else p + 1;
            t[res][@intCast(c + half)] = @intFromFloat(@round(@sin(@as(f64, @floatFromInt(c)) * std.math.pi / denom) * 0x1p23));
        }
    }
    break :blk t;
};

const limit: Word = 1 << 22;

/// -2^22 < v < 2^22.
fn small(v: Word) bool {
    return ops.isNeg(ops.sub(v, limit)) and !ops.isNeg(ops.add(v, limit - 1));
}

/// The lattice over w[start..end], forwards or backwards. False when a value leaves the range;
/// the run is then partly written.
fn lattice(w: []Word, k: []const Word, backwards: bool) bool {
    var b: [ref.max_order_long]Word = @splat(0); // b[m] = b_m[n - 1]
    const order = k.len;
    for (0..w.len) |step| {
        const n = if (backwards) w.len - 1 - step else step;
        var f = w[n];
        if (!small(f)) return false;
        var m = order;
        while (m > 0) : (m -= 1) {
            f = ops.sub(f, ops.mulRound23(k[m - 1], b[m - 1]));
            if (!small(f)) return false;
            if (m < order) {
                b[m] = ops.add(ops.mulRound23(k[m - 1], f), b[m - 1]);
                if (!small(b[m])) return false;
            }
        }
        b[0] = f;
        w[n] = f;
    }
    return true;
}

/// Rounded halving of every word, exponent + 1.
fn halve(blk: *Block, saved: []Word) void {
    for (&blk.w) |*x| x.* = ops.rshr(x.*, 1);
    for (saved) |*x| x.* = ops.rshr(x.*, 1);
    blk.e = ops.add(blk.e, 1);
}

pub const Stats = struct { halvings: u32 = 0, gave_up: u32 = 0 };

/// Halvings allowed for one run. The gain of 1 / A(z) at the largest reflection coefficients
/// (|k| = 0.9957, order 12) is below 2^94 only in theory; the random full-range filters below
/// need at most a few dozen, and rounding half up keeps a lone +1 at +1, so an unstable (corrupt)
/// filter would otherwise never stop.
pub const max_halvings = 48;

/// Applies a channel's TNS data to its block, window by window, filters top down.
pub fn apply(tns: *const ics.Tns, info: ics.IcsInfo, freq_index: u4, blk: *Block) Stats {
    var st: Stats = .{};
    const short = info.isShort();
    const offsets = info.bandOffsets(freq_index);
    const num_swb: u32 = @intCast(offsets.len - 1);
    const top_band = @min(if (short) ref.max_bands_short[freq_index] else ref.max_bands_long[freq_index], info.max_sfb);
    const max_order: u32 = if (short) ref.max_order_short else ref.max_order_long;
    const win_len: usize = if (short) 128 else 1024;
    for (0..info.numWindows()) |wi| {
        const win = tns.windows[wi];
        var top: u32 = num_swb;
        for (win.filt[0..win.n_filt]) |f| {
            const bottom = top -| f.length;
            defer top = bottom;
            const order = @min(f.order, max_order);
            if (order == 0) continue;
            const start = wi * win_len + offsets[@min(bottom, top_band)];
            const end = wi * win_len + offsets[@min(top, top_band)];
            if (end <= start) continue;
            const half: i32 = if (win.coef_res == 1) 8 else 4;
            var k: [ref.max_order_long]Word = undefined;
            for (f.coef[0..order], 0..) |c, i| k[i] = refl[win.coef_res][@intCast(@as(i32, c) + half)];
            var saved: [1024]Word = undefined;
            const run = blk.w[start..end];
            @memcpy(saved[0..run.len], run);
            var tries: u32 = 0;
            while (!lattice(run, k[0..order], f.direction)) : (tries += 1) {
                @memcpy(run, saved[0..run.len]);
                if (tries == max_halvings) {
                    // no stable filter needs this many: the run is zeroed rather than looped on
                    @memset(run, 0);
                    st.gave_up += 1;
                    break;
                }
                halve(blk, saved[0..run.len]);
                st.halvings += 1;
            }
        }
    }
    return st;
}

const testing = std.testing;
const fixed = @import("../../fixed.zig");
const iquant = @import("../../aac/iquant.zig");

test "the Q23 reflection table is the reference's sine table" {
    for (0..2) |res| {
        for (0..16) |i| {
            const want = ref.sin_tables[res][i].toFloat();
            try testing.expectApproxEqAbs(want, @as(f64, @floatFromInt(refl[res][i])) / 0x1p23, 0x1p-23);
        }
    }
}

test "the lattice is the step-up's direct form" {
    // double precision on both sides: an impulse through random reflection coefficients
    var prng = std.Random.DefaultPrng.init(0x7E5);
    const rnd = prng.random();
    for (0..50) |_| {
        const order = rnd.intRangeAtMost(usize, 1, 12);
        var k: [12]f64 = undefined;
        for (k[0..order]) |*x| x.* = rnd.float(f64) * 1.9 - 0.95;
        var a: [12]f64 = undefined;
        var tmp: [12]f64 = undefined;
        for (0..order) |m0| {
            const m = m0 + 1;
            for (1..m) |i| tmp[i] = a[i - 1] + k[m0] * a[m - i - 1];
            for (1..m) |i| a[i - 1] = tmp[i];
            a[m - 1] = k[m0];
        }
        var yd: [40]f64 = undefined;
        var yl: [40]f64 = undefined;
        var b: [12]f64 = @splat(0);
        for (0..40) |n| {
            const x: f64 = if (n == 0) 1 else 0;
            var y = x;
            for (0..order) |i| if (n > i) {
                y -= a[i] * yd[n - 1 - i];
            };
            yd[n] = y;
            var f = x;
            var m = order;
            while (m > 0) : (m -= 1) {
                f -= k[m - 1] * b[m - 1];
                if (m < order) b[m] = k[m - 1] * f + b[m - 1];
            }
            b[0] = f;
            yl[n] = f;
        }
        for (yd, yl) |p, q| try testing.expectApproxEqAbs(p, q, 1e-9 * @max(1.0, @abs(p)));
    }
}

/// The reference's structure in double precision: step-up, then the direct form.
fn exact(t: *const ics.Tns, info: ics.IcsInfo, freq_index: u4, x: *[1024]f64) void {
    const short = info.isShort();
    const offsets = info.bandOffsets(freq_index);
    const num_swb: u32 = @intCast(offsets.len - 1);
    const top_band = @min(if (short) ref.max_bands_short[freq_index] else ref.max_bands_long[freq_index], info.max_sfb);
    const max_order: u32 = if (short) ref.max_order_short else ref.max_order_long;
    const win_len: usize = if (short) 128 else 1024;
    for (0..info.numWindows()) |wi| {
        const win = t.windows[wi];
        var top: u32 = num_swb;
        for (win.filt[0..win.n_filt]) |f| {
            const bottom = top -| f.length;
            defer top = bottom;
            const order = @min(f.order, max_order);
            if (order == 0) continue;
            const start = wi * win_len + offsets[@min(bottom, top_band)];
            const end = wi * win_len + offsets[@min(top, top_band)];
            if (end <= start) continue;
            const bits: f64 = @floatFromInt(@as(u32, win.coef_res) + 3);
            var a: [12]f64 = undefined;
            var tmp: [12]f64 = undefined;
            for (f.coef[0..order], 0..) |c, m0| {
                const p = std.math.pow(f64, 2, bits);
                const cf: f64 = @floatFromInt(c);
                const k = @sin(cf * std.math.pi / (if (c >= 0) p - 1 else p + 1));
                const m = m0 + 1;
                for (1..m) |i| tmp[i] = a[i - 1] + k * a[m - i - 1];
                for (1..m) |i| a[i - 1] = tmp[i];
                a[m - 1] = k;
            }
            var hist: [12]f64 = @splat(0);
            const run = x[start..end];
            for (0..run.len) |step| {
                const n = if (f.direction) run.len - 1 - step else step;
                var y = run[n];
                for (a[0..order], 0..) |ai, i| y -= ai * hist[i];
                std.mem.copyBackwards(f64, hist[1..order], hist[0 .. order - 1]);
                hist[0] = y;
                run[n] = y;
            }
        }
    }
}

fn randomChannel(rnd: std.Random, short: bool, wide: bool, t: *ics.Tns) ics.IcsInfo {
    var info: ics.IcsInfo = .{
        .window_sequence = if (short) .eight_short else .only_long,
        .window_shape = 0,
        .max_sfb = if (short) rnd.intRangeAtMost(u6, 1, 14) else rnd.intRangeAtMost(u6, 1, 49),
        .num_window_groups = 1,
        .group_len = @splat(0),
    };
    info.group_len[0] = if (short) 8 else 1;
    t.* = .{};
    for (0..info.numWindows()) |w| {
        const win = &t.windows[w];
        win.n_filt = if (short) rnd.intRangeAtMost(u2, 0, 1) else rnd.intRangeAtMost(u2, 0, 3);
        win.coef_res = rnd.int(u1);
        for (win.filt[0..win.n_filt]) |*f| {
            f.length = if (short) rnd.intRangeAtMost(u6, 1, 15) else rnd.intRangeAtMost(u6, 1, 49);
            f.order = if (short) rnd.intRangeAtMost(u5, 0, 7) else rnd.intRangeAtMost(u5, 0, 12);
            f.direction = rnd.boolean();
            const lo: i32 = if (win.coef_res == 1) -8 else -4;
            for (f.coef[0..f.order]) |*c| c.* = @intCast(if (wide) rnd.intRangeAtMost(i32, lo, -lo - 1) else rnd.intRangeAtMost(i32, -2, 2));
        }
    }
    return info;
}

test "random filters: within 2^-15 of the peak from double precision, never behind the reference" {
    var prng = std.Random.DefaultPrng.init(0x7E55);
    const rnd = prng.random();
    var worst: [2]f64 = .{ 0, 0 };
    var worst_ref: [2]f64 = .{ 0, 0 };
    var gave_up: u32 = 0;
    var halvings: [2]u32 = .{ 0, 0 };
    for (0..300) |trial| {
        const short = trial % 3 == 0;
        var t: ics.Tns = undefined;
        const wide = trial % 2 == 1;
        const info = randomChannel(rnd, short, wide, &t);
        var blk: Block = .{ .e = rnd.intRangeAtMost(Word, -30, 10) };
        const amp: i32 = rnd.intRangeAtMost(i32, 1 << 10, 5600000);
        for (&blk.w) |*x| x.* = @intCast(rnd.intRangeAtMost(i32, -amp, amp));
        var coefs: iquant.Coefs = undefined;
        for (&coefs, blk.w) |*c, x| c.* = fixed.normalize(x, blk.e);
        const ch: ics.Channel = .{
            .global_gain = 100,
            .info = info,
            .sections = .{},
            .scalefactors = @splat(@splat(0)),
            .pulse = null,
            .tns = t,
            .spectrum = @splat(0),
        };
        var truth: [1024]f64 = undefined;
        for (&truth, blk.w) |*d, x| d.* = std.math.ldexp(@as(f64, @floatFromInt(x)), blk.e);
        exact(&t, info, 4, &truth);
        ref.apply(&ch, &coefs, 4);
        const st = apply(&t, info, 4, &blk);
        halvings[@intFromBool(wide)] += st.halvings;
        gave_up += st.gave_up;
        var peak: f64 = 0;
        for (truth) |c| peak = @max(peak, @abs(c));
        for (coefs, blk.w, truth) |c, x, d| {
            const got = std.math.ldexp(@as(f64, @floatFromInt(x)), blk.e);
            const i = @intFromBool(wide);
            worst[i] = @max(worst[i], @abs(got - d) / peak);
            worst_ref[i] = @max(worst_ref[i], @abs(c.toFloat() - d) / peak);
        }
    }
    // mild (encoder-like) filters within 2^-15 of the peak; full-range ones, ill-conditioned for
    // any 24-bit arithmetic, no further from the truth than the reference's F24
    try testing.expect(worst[0] <= 0x1p-15);
    try testing.expect(worst[0] <= worst_ref[0]);
    try testing.expect(worst[1] <= worst_ref[1]);
    try testing.expect(halvings[0] > 0 and halvings[1] > 0); // the overflow path ran
    try testing.expectEqual(@as(u32, 0), gave_up);
}

test "a filter that leaves the range halves the block and keeps its values" {
    // one stage at k = -0.9957 on a constant run: y[n] = x + 0.9957 y[n - 1] grows to ~230 x
    var t: ics.Tns = .{};
    t.windows[0].n_filt = 1;
    t.windows[0].coef_res = 1;
    t.windows[0].filt[0] = .{ .length = 49, .order = 1 };
    t.windows[0].filt[0].coef[0] = -8;
    var info: ics.IcsInfo = .{ .window_sequence = .only_long, .window_shape = 0, .max_sfb = 49, .num_window_groups = 1, .group_len = @splat(0) };
    info.group_len[0] = 1;
    var blk: Block = .{ .e = 0 };
    blk.w = @splat(1 << 20);
    const st = apply(&t, info, 4, &blk);
    try testing.expect(st.halvings >= 6);
    try testing.expectEqual(@as(Word, @intCast(st.halvings)), blk.e);
    try testing.expectEqual(@as(Word, @as(Word, 1 << 20) >> @intCast(st.halvings)), blk.w[1023]); // above TNS_MAX_BANDS
    for (blk.w) |x| try testing.expect(small(x));
}

test "a filter past max_halvings zeroes its run instead of looping" {
    // twelve stages at k = -0.9957 on a constant run: a DC gain near 2^94
    var t: ics.Tns = .{};
    t.windows[0].n_filt = 1;
    t.windows[0].coef_res = 1;
    t.windows[0].filt[0] = .{ .length = 49, .order = 12 };
    for (t.windows[0].filt[0].coef[0..12]) |*c| c.* = -8;
    var info: ics.IcsInfo = .{ .window_sequence = .only_long, .window_shape = 0, .max_sfb = 49, .num_window_groups = 1, .group_len = @splat(0) };
    info.group_len[0] = 1;
    var blk: Block = .{ .e = 0 };
    blk.w = @splat(1 << 21);
    const st = apply(&t, info, 4, &blk);
    try testing.expectEqual(@as(u32, 1), st.gave_up);
    try testing.expectEqual(@as(u32, max_halvings), st.halvings);
    for (blk.w[0..736]) |x| try testing.expectEqual(@as(Word, 0), x);
}
