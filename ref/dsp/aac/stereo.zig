//! M/S and intensity stereo in measured sm1 operations: the twin of `ref/aac/stereo.zig` on the
//! dequantiser's blocks (value = w * 2^e, one exponent a channel, |w| < 2^22.42).
//!
//! M/S: when any band uses it, both channels move to the exponent max(eL, eR) + 1 by rounded
//! right shifts, so m + s and m - s stay below 2^23 as plain 24-bit adds. Intensity: a right band
//! is the finished left band times +-2^(-pos/4) = +-2^(-q) 2^(-b/4) with pos = 4q + b: one
//! rounded multiply by T[b] = 2^(22 - b/4) (Q23, so the word halves) at the band exponent
//! eL + 1 - q. The right block takes the largest of its own exponent and its intensity bands',
//! and everything else shifts down to it. A shift of 24 or more gives 0.
//!
//! Control (books, masks, positions) is integer and comes from the parsed pair, as in the
//! reference. PNS is not here: its noise needs a square root and a reciprocal, a stage of its
//! own; a noise band stays zero.
const std = @import("std");
const ops = @import("../ops.zig");
const dequant = @import("dequant.zig");
const ics = @import("../../aac/ics.zig");

const Word = ops.Word;
const Block = dequant.Block;

/// round(2^(22 - b / 4)), b = 0..3.
pub const quarter: [4]Word = blk: {
    var t: [4]Word = undefined;
    for (&t, 0..) |*x, b| x.* = @intFromFloat(@round(std.math.pow(f64, 2.0, 22.0 - @as(f64, @floatFromInt(b)) / 4.0)));
    break :blk t;
};

/// w shifted right by n >= 0, rounded; 0 from 24 on.
fn down(w: Word, n: Word) Word {
    if (!ops.isNeg(ops.sub(n, 24))) return 0;
    return ops.rshr(w, @intCast(n));
}

/// The block re-expressed at exponent `to` (>= its own). A block that is not live holds only
/// zeros and an exponent that means nothing: it just takes `to`.
fn moveTo(b: *Block, to: Word, live: bool) void {
    if (!live) {
        b.e = to;
        return;
    }
    const n = ops.sub(to, b.e);
    for (&b.w) |*w| w.* = down(w.*, n);
    b.e = to;
}

fn spectral(cb: u4) bool {
    return cb >= 1 and cb <= 11;
}

fn anySpectral(ch: *const ics.Channel) bool {
    for (0..ch.info.num_window_groups) |g| for (0..ch.info.max_sfb) |sfb| {
        if (spectral(ch.sections.sfb_cb[g][sfb])) return true;
    };
    return false;
}

fn msUsed(pair: *const ics.ChannelPair, g: usize, sfb: usize) bool {
    const ms = pair.ms orelse return false;
    return ms.present != 0 and ms.used[g][sfb];
}

fn msBand(pair: *const ics.ChannelPair, g: usize, sfb: usize) bool {
    return msUsed(pair, g, sfb) and pair.left.sections.sfb_cb[g][sfb] < ics.noise_hcb and
        pair.right.sections.sfb_cb[g][sfb] < ics.noise_hcb;
}

fn intensityBand(cb: u4) bool {
    return cb == ics.intensity_hcb or cb == ics.intensity_hcb2;
}

/// Calls f(ctx, k) for every coefficient of band (g, sfb).
fn eachIndex(info: ics.IcsInfo, offsets: []const u16, g: usize, sfb: usize, ctx: anytype, comptime f: anytype) void {
    var first: usize = 0;
    for (0..g) |i| first += info.group_len[i];
    const win_len: usize = if (info.isShort()) 128 else 1024;
    for (first..first + info.group_len[g]) |w| {
        for (w * win_len + offsets[sfb]..w * win_len + offsets[sfb + 1]) |k| f(ctx, k);
    }
}

/// `left_live` / `right_live`: the channel has a spectral band, so its exponent means something.
fn msStereo(pair: *const ics.ChannelPair, left: *Block, right: *Block, offsets: []const u16, left_live: bool, right_live: bool) void {
    const info = pair.left.info;
    var any = false;
    for (0..info.num_window_groups) |g| for (0..info.max_sfb) |sfb| {
        any = any or msBand(pair, g, sfb);
    };
    if (!any or !(left_live or right_live)) return;
    var to: Word = if (left_live) left.e else right.e;
    if (right_live and ops.isNeg(ops.sub(to, right.e))) to = right.e;
    to = ops.add(to, 1);
    moveTo(left, to, left_live);
    moveTo(right, to, right_live);
    for (0..info.num_window_groups) |g| for (0..info.max_sfb) |sfb| {
        if (!msBand(pair, g, sfb)) continue;
        const Ms = struct {
            l: *Block,
            r: *Block,
            fn f(c: *@This(), k: usize) void {
                const m = c.l.w[k];
                c.l.w[k] = ops.add(m, c.r.w[k]);
                c.r.w[k] = ops.sub(m, c.r.w[k]);
            }
        };
        var c: Ms = .{ .l = left, .r = right };
        eachIndex(info, offsets, g, sfb, &c, Ms.f);
    };
}

fn intensityNegative(pair: *const ics.ChannelPair, cb: u4, g: usize, sfb: usize) bool {
    var negative = cb == ics.intensity_hcb2;
    if (pair.ms) |ms| {
        if (ms.present == 1 and ms.used[g][sfb]) negative = !negative;
    }
    return negative;
}

/// An intensity band's exponent: eL + 1 - floor(pos / 4).
fn bandExp(left_e: Word, pos: Word) Word {
    return ops.sub(ops.add(left_e, 1), ops.floorShr(pos, 2));
}

fn intensity(pair: *const ics.ChannelPair, left: *const Block, right: *Block, offsets: []const u16, left_live: bool, right_live: bool) void {
    const info = pair.right.info;
    if (!left_live) return; // the left is silent: so are its intensity copies
    // The right exponent: its own and every intensity band's eL + 1 - q.
    var to: ?Word = if (right_live) right.e else null;
    var any = false;
    for (0..info.num_window_groups) |g| for (0..info.max_sfb) |sfb| {
        if (!intensityBand(pair.right.sections.sfb_cb[g][sfb])) continue;
        any = true;
        const e = bandExp(left.e, pair.right.scalefactors[g][sfb]);
        if (to == null or ops.isNeg(ops.sub(to.?, e))) to = e;
    };
    if (!any) return;
    moveTo(right, to.?, right_live);
    for (0..info.num_window_groups) |g| for (0..info.max_sfb) |sfb| {
        const cb = pair.right.sections.sfb_cb[g][sfb];
        if (!intensityBand(cb)) continue;
        const pos: Word = pair.right.scalefactors[g][sfb];
        const q = ops.floorShr(pos, 2);
        const Is = struct {
            l: *const Block,
            r: *Block,
            t: Word,
            n: Word,
            neg: bool,
            fn f(c: *@This(), k: usize) void {
                const v = down(ops.mulRound23(c.l.w[k], c.t), c.n);
                c.r.w[k] = if (c.neg) ops.sub(0, v) else v;
            }
        };
        var c: Is = .{
            .l = left,
            .r = right,
            .t = quarter[@intCast(ops.sub(pos, ops.shl(q, 2)))],
            .n = ops.sub(right.e, bandExp(left.e, pos)),
            .neg = intensityNegative(pair, cb, g, sfb),
        };
        eachIndex(info, offsets, g, sfb, &c, Is.f);
    };
}

/// M/S then the right channel's intensity bands, in place.
pub fn applyPair(pair: *const ics.ChannelPair, left: *Block, right: *Block, left_offsets: []const u16, right_offsets: []const u16) void {
    const left_live = anySpectral(&pair.left);
    const right_live = anySpectral(&pair.right);
    msStereo(pair, left, right, left_offsets, left_live, right_live);
    intensity(pair, left, right, right_offsets, left_live, right_live or msTouchedRight(pair));
}

/// M/S writes the right channel's M/S bands from the left even when the right had no spectral
/// band of its own, so its exponent then means something.
fn msTouchedRight(pair: *const ics.ChannelPair) bool {
    const info = pair.left.info;
    for (0..info.num_window_groups) |g| for (0..info.max_sfb) |sfb| {
        if (msBand(pair, g, sfb)) return anySpectral(&pair.left);
    };
    return false;
}

const testing = std.testing;
const ref = @import("../../aac/stereo.zig");
const ref_iquant = @import("../../aac/iquant.zig");
const swb = @import("../../aac/tables/swb.zig");

fn randomChannel(rnd: std.Random, info: ics.IcsInfo, right: bool) ics.Channel {
    var ch: ics.Channel = undefined;
    ch.global_gain = 100;
    ch.info = info;
    ch.sections = .{};
    ch.scalefactors = @splat(@splat(0));
    ch.pulse = null;
    ch.tns = null;
    const base_sf = rnd.intRangeAtMost(i16, 60, 200);
    for (0..info.num_window_groups) |g| for (0..info.max_sfb) |sfb| {
        // books 0..11, and on the right intensity 14/15 (no noise: PNS is a later stage)
        var cb = rnd.intRangeAtMost(u4, 0, if (right) 13 else 11);
        if (cb == 12) cb = ics.intensity_hcb;
        if (cb == 13) cb = ics.intensity_hcb2;
        ch.sections.sfb_cb[g][sfb] = cb;
        ch.scalefactors[g][sfb] = if (intensityBand(cb)) rnd.intRangeAtMost(i16, -24, 60) else std.math.clamp(base_sf + rnd.intRangeAtMost(i16, -30, 30), 0, 255);
    };
    for (&ch.spectrum) |*q| {
        const r = rnd.uintLessThan(u8, 100);
        const mag: i16 = if (r < 40) 0 else if (r < 95) rnd.intRangeAtMost(i16, 1, 16) else rnd.intRangeAtMost(i16, 17, 2000);
        q.* = if (rnd.boolean()) -mag else mag;
    }
    // intensity bands carry no spectral values
    return ch;
}

fn bandsOf(ch: *const ics.Channel) dequant.Shape {
    return .{ .short = ch.info.isShort(), .groups = ch.info.num_window_groups, .group_len = ch.info.group_len, .max_sfb = ch.info.max_sfb };
}

fn dspDequant(ch: *const ics.Channel, offsets: []const u16) Block {
    const sections = @import("sections.zig");
    var b: sections.Bands = .{};
    const s = bandsOf(ch);
    b.n = @as(usize, s.groups) * s.max_sfb;
    for (0..s.groups) |g| for (0..s.max_sfb) |sfb| {
        b.book[g * s.max_sfb + sfb] = ch.sections.sfb_cb[g][sfb];
        b.sf[g * s.max_sfb + sfb] = ch.scalefactors[g][sfb];
    };
    var spec: [1024]Word = undefined;
    for (&spec, ch.spectrum) |*w, q| w.* = q;
    return dequant.dequantChannel(&spec, s, &b, offsets);
}

test "random pairs match the reference within a few LSB of the result" {
    var prng = std.Random.DefaultPrng.init(0x57E);
    const rnd = prng.random();
    const rate = 4;
    var ms_seen: usize = 0;
    var is_seen: usize = 0;
    for (0..300) |_| {
        const short = rnd.boolean();
        var info: ics.IcsInfo = .{ .window_sequence = if (short) .eight_short else .only_long, .window_shape = 0, .max_sfb = 0, .num_window_groups = 1, .group_len = @splat(0) };
        if (short) {
            var left: u4 = 8;
            info.num_window_groups = 0;
            while (left > 0) {
                const l = rnd.intRangeAtMost(u4, 1, left);
                info.group_len[info.num_window_groups] = l;
                info.num_window_groups += 1;
                left -= l;
            }
            info.max_sfb = rnd.intRangeAtMost(u6, 1, 14);
        } else {
            info.group_len[0] = 1;
            info.max_sfb = rnd.intRangeAtMost(u6, 1, 49);
        }
        const offsets: []const u16 = if (short) swb.short[rate] else swb.long[rate];
        var pair: ics.ChannelPair = .{ .common_window = true, .ms = null, .left = randomChannel(rnd, info, false), .right = randomChannel(rnd, info, true) };
        var ms: ics.MsMask = .{ .present = rnd.intRangeAtMost(u2, 0, 2) };
        for (0..info.num_window_groups) |g| for (0..info.max_sfb) |sfb| {
            ms.used[g][sfb] = ms.present == 2 or rnd.boolean();
        };
        pair.ms = ms;
        // the reference's coefficients, then its tools
        var rl = ref_iquant.dequantChannel(&pair.left, rate);
        var rr = ref_iquant.dequantChannel(&pair.right, rate);
        var in_mag: [1024]f64 = undefined;
        for (&in_mag, rl, rr) |*m, a, b| m.* = @abs(a.toFloat()) + @abs(b.toFloat());
        var rng: ref.Rng = .{};
        ref.applyPair(&pair, &rl, &rr, offsets, offsets, &rng);
        var dl = dspDequant(&pair.left, offsets);
        var dr = dspDequant(&pair.right, offsets);
        applyPair(&pair, &dl, &dr, offsets, offsets);
        for ([_]struct { d: *const Block, r: *const ref_iquant.Coefs }{ .{ .d = &dl, .r = &rl }, .{ .d = &dr, .r = &rr } }) |c| {
            const lsb = std.math.ldexp(@as(f64, 1), @intCast(c.d.e));
            for (0..1024) |k| {
                const got = @as(f64, @floatFromInt(c.d.w[k])) * lsb;
                const want = c.r[k].toFloat();
                // dequant's 2 LSB and 2^-15, plus a rounding per tool; intensity scales the
                // left's error by up to its gain, which the band exponent absorbs
                const bound = 4 * lsb + (@abs(want) + in_mag[k] * 4) * std.math.ldexp(@as(f64, 1), -14);
                if (!(@abs(got - want) <= bound)) {
                    std.debug.print("k {d}: got {d} want {d} bound {d}\n", .{ k, got, want, bound });
                    return error.TestUnexpectedResult;
                }
            }
        }
        for (0..info.num_window_groups) |g| for (0..info.max_sfb) |sfb| {
            if (msBand(&pair, g, sfb)) ms_seen += 1;
            if (intensityBand(pair.right.sections.sfb_cb[g][sfb])) is_seen += 1;
        };
    }
    try testing.expect(ms_seen > 1000);
    try testing.expect(is_seen > 500);
}

test "M/S never wraps at the largest words" {
    // both channels at the dequantiser's largest |w| and one sign: m + s needs the extra bit
    var pair: ics.ChannelPair = .{ .common_window = true, .ms = .{ .present = 2 }, .left = undefined, .right = undefined };
    inline for (.{ &pair.left, &pair.right }) |ch| {
        ch.info = .{ .window_sequence = .only_long, .window_shape = 0, .max_sfb = 1, .num_window_groups = 1, .group_len = @splat(0) };
        ch.info.group_len[0] = 1;
        ch.sections = .{};
        ch.sections.sfb_cb[0][0] = 1;
    }
    pair.ms.?.used[0][0] = true;
    var l: Block = .{ .e = 3 };
    var r: Block = .{ .e = 3 };
    l.w[0] = 5600000; // 2^22.42
    r.w[0] = 5600000;
    l.w[1] = -5600000;
    r.w[1] = 5600000;
    applyPair(&pair, &l, &r, &.{ 0, 4 }, &.{ 0, 4 });
    try testing.expectEqual(@as(Word, 4), l.e);
    try testing.expectEqual(@as(Word, 5600000), l.w[0]);
    try testing.expectEqual(@as(Word, 0), r.w[0]);
    try testing.expectEqual(@as(Word, 0), l.w[1]);
    try testing.expectEqual(@as(Word, -5600000), r.w[1]);
}

test "a right channel with only M/S and intensity bands keeps its M/S values" {
    // band 0: M/S from a left-only spectrum; band 1: intensity, position -8 (gain 4) on a
    // quiet left band, which raises the right exponent past M/S's
    var pair: ics.ChannelPair = .{ .common_window = true, .ms = .{ .present = 1 }, .left = undefined, .right = undefined };
    inline for (.{ &pair.left, &pair.right }) |ch| {
        ch.info = .{ .window_sequence = .only_long, .window_shape = 0, .max_sfb = 2, .num_window_groups = 1, .group_len = @splat(0) };
        ch.info.group_len[0] = 1;
        ch.sections = .{};
        ch.scalefactors = @splat(@splat(0));
    }
    pair.left.sections.sfb_cb[0][0] = 1;
    pair.left.sections.sfb_cb[0][1] = 1;
    pair.right.sections.sfb_cb[0][0] = 0;
    pair.right.sections.sfb_cb[0][1] = ics.intensity_hcb;
    pair.right.scalefactors[0][1] = -8;
    pair.ms.?.used[0][0] = true;
    var l: Block = .{ .e = 0 };
    var r: Block = .{ .e = 0 };
    l.w[0] = 4000000;
    l.w[4] = 4000000;
    applyPair(&pair, &l, &r, &.{ 0, 4, 8 }, &.{ 0, 4, 8 });
    const v = struct {
        fn f(b: *const Block, k: usize) f64 {
            return std.math.ldexp(@as(f64, @floatFromInt(b.w[k])), @intCast(b.e));
        }
    }.f;
    try testing.expectApproxEqAbs(@as(f64, 4000000), v(&r, 0), 8); // m - s, s = 0
    try testing.expectApproxEqAbs(@as(f64, 16000000), v(&r, 4), 32); // 4 l
}
