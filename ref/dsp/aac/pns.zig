//! Perceptual noise substitution in measured sm1 operations: the twin of `ref/aac/stereo.zig`'s
//! `pns` and the right channel's noise bands, on the dequantiser's blocks.
//!
//! ISO leaves the generator open, and the reference's 32-bit LCG costs multi-word arithmetic
//! here, so the noise is our own 24-bit LCG: x = a x + c mod 2^24 with a 16-bit multiplier
//! (`mulWide` gives a x exactly, `wideValue` its low 24 bits), a = 1 mod 4 and c odd for the full
//! period; a sample is v = rshr(x, 1), |v| <= 2^22. Bands therefore match the reference in
//! energy, not sample for sample.
//!
//! A band of energy 2^(nrg / 2) is v_k 2^(nrg / 4) / sqrt(sum v^2):
//!
//!   - sum v^2 ~ acc 2^(23 + s): acc = sum rshr(rnd(v^2 / 2^23), s), s even and just large enough
//!     for the band length that acc stays below 2^23.
//!   - acc 4^p = m in [2^21, 2^23) by comparisons; 1 / sqrt(sum v^2) = 4z 2^(p - 23 - s/2) with
//!     z ~ 1 / (4 sqrt(m / 2^23)) in (1/4, 1/2]: a 6-entry seed by m's top bits, then three
//!     Newton steps z' = 4 z (3/8 - 2 m z^2), every product a rounded Q23 multiply.
//!   - nrg = 4q + b: g = rnd(z T[b]), T[b] = 2^(22 + b/4); the word is rnd(v g), and the band
//!     exponent p + q - 20 - s/2.
//!
//! Correlated right noise (M/S used, both books noise) is the left band times 2^((sfR - sfL)/4):
//! rnd(l T[b]) at exponent eL + q + 1, as intensity does. Each channel then moves to the largest
//! of its exponent (when it has a spectral band) and its noise bands', like the right channel in
//! intensity stereo; a shift of 24 or more gives 0.
const std = @import("std");
const ops = @import("../ops.zig");
const dequant = @import("dequant.zig");
const ics = @import("../../aac/ics.zig");

const Word = ops.Word;
const Block = dequant.Block;

pub const lcg_a: i16 = 0x7655;
pub const lcg_c: Word = 0x3C6EF3;

pub const Rng = struct {
    x: Word = 0,

    /// The next sample, |v| <= 2^22.
    pub fn next(self: *Rng) Word {
        self.x = ops.add(ops.wideValue(ops.mulWide(lcg_a, self.x)), lcg_c);
        return ops.rshr(self.x, 1);
    }
};

/// round(2^(22 + b / 4)), b = 0..3.
pub const quarter: [4]Word = blk: {
    var t: [4]Word = undefined;
    for (&t, 0..) |*x, b| x.* = @intFromFloat(@round(std.math.pow(f64, 2.0, 22.0 + @as(f64, @floatFromInt(b)) / 4.0)));
    break :blk t;
};

/// z seeds: 1 / (4 sqrt(m)) at the middle of m's eighth, m = (i + 2.5) / 8, i = 0..5.
pub const seed: [6]Word = blk: {
    var t: [6]Word = undefined;
    for (&t, 0..) |*x, i| x.* = @intFromFloat(@round(0x1p23 / (4.0 * @sqrt((@as(f64, @floatFromInt(i)) + 2.5) / 8.0))));
    break :blk t;
};

const three_eighths: Word = 3 << 20;

/// z ~ 1 / (4 sqrt(m / 2^23)) for m in [2^21, 2^23).
pub fn invSqrtQuarter(m: Word) Word {
    var z = seed[@intCast(ops.sub(ops.floorShr(m, 20), 2))];
    for (0..3) |_| {
        const u = ops.mulRound23(m, ops.mulRound23(z, z));
        z = ops.shl(ops.mulRound23(z, ops.sub(three_eighths, ops.shl(u, 1))), 2);
    }
    return z;
}

/// A noise band: its words (into `out`) and exponent, or null when its energy rounds to 0.
pub fn noiseBand(out: []Word, nrg: Word, rng: *Rng) ?Word {
    var s: Word = 0;
    var cap: Word = 4;
    const len: Word = @intCast(out.len);
    while (!ops.isNeg(ops.sub(len, cap))) {
        cap = ops.shl(cap, 2);
        s = ops.add(s, 2);
    }
    // the samples, scaled up until the largest is at least 2^21 (the result does not depend on
    // their scale, the energy's precision does)
    var big: Word = 0;
    for (out) |*o| {
        o.* = rng.next();
        const a = if (ops.isNeg(o.*)) ops.sub(0, o.*) else o.*;
        if (ops.isNeg(ops.sub(big, a))) big = a;
    }
    if (ops.isZero(big)) return null;
    var k: u4 = 0;
    while (ops.isNeg(ops.sub(big, 1 << 21))) {
        big = ops.shl(big, 1);
        k += 1;
    }
    var acc: Word = 0;
    for (out) |*o| {
        o.* = ops.shl(o.*, k);
        acc = ops.add(acc, ops.rshr(ops.mulRound23(o.*, o.*), @intCast(s)));
    }
    if (ops.isZero(acc)) {
        @memset(out, 0);
        return null;
    }
    var p: Word = 0;
    while (ops.isNeg(ops.sub(acc, 1 << 21))) {
        acc = ops.shl(acc, 2);
        p = ops.add(p, 1);
    }
    const z = invSqrtQuarter(acc);
    const q = ops.floorShr(nrg, 2);
    const g = ops.mulRound23(z, quarter[@intCast(ops.sub(nrg, ops.shl(q, 2)))]);
    for (out) |*o| o.* = ops.mulRound23(o.*, g);
    return ops.sub(ops.add(p, q), ops.add(20, ops.rshr(s, 1)));
}

fn down(w: Word, n: Word) Word {
    if (!ops.isNeg(ops.sub(n, 24))) return 0;
    return ops.rshr(w, @intCast(n));
}

fn spectral(cb: u4) bool {
    return cb >= 1 and cb <= 11;
}

fn msUsed(pair: *const ics.ChannelPair, g: usize, sfb: usize) bool {
    const ms = pair.ms orelse return false;
    return ms.present != 0 and ms.used[g][sfb];
}

/// The noise bands of one channel, collected before the block moves.
const Pending = struct {
    words: [1024]Word = @splat(0),
    runs: [8 * 64]struct { start: u16, len: u16, e: Word } = undefined,
    n: usize = 0,
    top: ?Word = null,

    fn add(self: *Pending, start: usize, len: usize, e: ?Word) void {
        const x = e orelse return;
        self.runs[self.n] = .{ .start = @intCast(start), .len = @intCast(len), .e = x };
        self.n += 1;
        if (self.top == null or ops.isNeg(ops.sub(self.top.?, x))) self.top = x;
    }

    /// The block to the largest exponent, then the noise words shifted into place.
    fn land(self: *const Pending, ch: *const ics.Channel, blk: *Block) void {
        const top = self.top orelse return;
        var live = false;
        for (0..ch.info.num_window_groups) |g| {
            for (0..ch.info.max_sfb) |sfb| live = live or spectral(ch.sections.sfb_cb[g][sfb]);
        }
        var to = top;
        if (live and ops.isNeg(ops.sub(to, blk.e))) to = blk.e;
        if (live) for (&blk.w) |*x| {
            x.* = down(x.*, ops.sub(to, blk.e));
        };
        blk.e = to;
        for (self.runs[0..self.n]) |r| {
            for (r.start..r.start + r.len) |k| blk.w[k] = down(self.words[k], ops.sub(to, r.e));
        }
    }
};

fn eachNoiseBand(ch: *const ics.Channel, offsets: []const u16, ctx: anytype, comptime f: anytype) void {
    const win_len: usize = if (ch.info.isShort()) 128 else 1024;
    var first: usize = 0;
    for (0..ch.info.num_window_groups) |g| {
        for (0..ch.info.max_sfb) |sfb| {
            if (ch.sections.sfb_cb[g][sfb] != ics.noise_hcb) continue;
            for (first..first + ch.info.group_len[g]) |w| f(ctx, g, sfb, w * win_len + offsets[sfb], w * win_len + offsets[sfb + 1]);
        }
        first += ch.info.group_len[g];
    }
}

/// Noise for every NOISE_HCB band of a channel (an SCE, or a pair's left).
pub fn channel(ch: *const ics.Channel, offsets: []const u16, blk: *Block, rng: *Rng) void {
    var pend: Pending = .{};
    const C = struct {
        p: *Pending,
        ch: *const ics.Channel,
        rng: *Rng,
        fn f(c: *@This(), g: usize, sfb: usize, a: usize, b: usize) void {
            c.p.add(a, b - a, noiseBand(c.p.words[a..b], c.ch.scalefactors[g][sfb], c.rng));
        }
    };
    var c: C = .{ .p = &pend, .ch = ch, .rng = rng };
    eachNoiseBand(ch, offsets, &c, C.f);
    pend.land(ch, blk);
}

/// The right channel's noise bands, after the left's: a copy of the left band where M/S marks
/// it correlated, its own noise otherwise.
pub fn right(pair: *const ics.ChannelPair, left: *const Block, offsets: []const u16, blk: *Block, rng: *Rng) void {
    var pend: Pending = .{};
    const C = struct {
        p: *Pending,
        pair: *const ics.ChannelPair,
        left: *const Block,
        rng: *Rng,
        fn f(c: *@This(), g: usize, sfb: usize, a: usize, b: usize) void {
            const sf = c.pair.right.scalefactors[g][sfb];
            if (msUsed(c.pair, g, sfb) and c.pair.left.sections.sfb_cb[g][sfb] == ics.noise_hcb) {
                const d = ops.sub(sf, c.pair.left.scalefactors[g][sfb]);
                const q = ops.floorShr(d, 2);
                const t = quarter[@intCast(ops.sub(d, ops.shl(q, 2)))];
                for (a..b) |k| c.p.words[k] = ops.mulRound23(c.left.w[k], t);
                c.p.add(a, b - a, ops.add(ops.add(c.left.e, q), 1));
            } else {
                c.p.add(a, b - a, noiseBand(c.p.words[a..b], sf, c.rng));
            }
        }
    };
    var c: C = .{ .p = &pend, .pair = pair, .left = left, .rng = rng };
    eachNoiseBand(&pair.right, offsets, &c, C.f);
    pend.land(&pair.right, blk);
}

const testing = std.testing;

test "the LCG has the full period's first property: no early repeat, both signs" {
    var r: Rng = .{};
    var neg: usize = 0;
    const x0 = r.x;
    for (0..1 << 16) |_| {
        if (ops.isNeg(r.next())) neg += 1;
        try testing.expect(r.x != x0);
    }
    try testing.expect(neg > 30000 and neg < 35500);
}

test "the LCG is a x + c mod 2^24 exactly" {
    var r: Rng = .{ .x = 12345 };
    for (0..1000) |_| {
        const want: i64 = @mod(@as(i64, lcg_a) * r.x + lcg_c, 1 << 24);
        _ = r.next();
        try testing.expectEqual(want, @as(i64, @as(u24, @bitCast(r.x))));
    }
}

test "invSqrtQuarter within 4 LSB over the whole range" {
    var m: i32 = 1 << 21;
    var worst: f64 = 0;
    while (m < 1 << 23) : (m += 997) {
        const want = 0x1p23 / (4.0 * @sqrt(@as(f64, @floatFromInt(m)) / 0x1p23));
        const got: f64 = @floatFromInt(invSqrtQuarter(@intCast(m)));
        worst = @max(worst, @abs(got - want));
    }
    // the last step's x4 makes rounding errors 4 LSB wide (about 2e-6 of z)
    try testing.expect(worst <= 4.0);
}

fn energy(w: []const Word, e: Word) f64 {
    var s: f64 = 0;
    for (w) |x| s += std.math.pow(f64, std.math.ldexp(@as(f64, @floatFromInt(x)), e), 2);
    return s;
}

test "a noise band carries energy 2^(nrg/2) within 2e-5, every length and nrg" {
    var r: Rng = .{};
    var buf: [1024]Word = undefined;
    var worst: f64 = 0;
    for ([_]usize{ 1, 3, 4, 15, 16, 36, 96, 255, 256, 1023, 1024 }) |len| {
        for ([_]Word{ -100, -7, -1, 0, 1, 2, 3, 10, 99, 200 }) |nrg| {
            const e = noiseBand(buf[0..len], nrg, &r).?;
            const want = std.math.pow(f64, 2.0, @as(f64, @floatFromInt(nrg)) / 2.0);
            worst = @max(worst, @abs(energy(buf[0..len], e) / want - 1));
            for (buf[0..len]) |x| try testing.expect(@abs(x) < 1 << 22);
        }
    }
    // 1.5e-5 measured; prescaling only to 2^18 would give 4.1e-5
    try testing.expect(worst <= 2e-5);
}

fn testChannel(books: []const u4, sfs: []const i16) ics.Channel {
    var ch: ics.Channel = .{
        .global_gain = 100,
        .info = .{ .window_sequence = .only_long, .window_shape = 0, .max_sfb = @intCast(books.len), .num_window_groups = 1, .group_len = @splat(0) },
        .sections = .{},
        .scalefactors = @splat(@splat(0)),
        .pulse = null,
        .tns = null,
        .spectrum = @splat(0),
    };
    ch.info.group_len[0] = 1;
    for (books, sfs, 0..) |b, s, i| {
        ch.sections.sfb_cb[0][i] = b;
        ch.scalefactors[0][i] = s;
    }
    return ch;
}

const offsets_test = [_]u16{ 0, 4, 12, 28, 60, 124 };

test "noise beside spectral bands: the block moves, both keep their values" {
    var prng = std.Random.DefaultPrng.init(0x9E5);
    const rnd = prng.random();
    var r: Rng = .{};
    for (0..200) |_| {
        var books: [5]u4 = undefined;
        var sfs: [5]i16 = undefined;
        for (&books, &sfs) |*b, *s| {
            b.* = switch (rnd.uintLessThan(u8, 3)) {
                0 => 0,
                1 => ics.noise_hcb,
                else => rnd.intRangeAtMost(u4, 1, 11),
            };
            s.* = rnd.intRangeAtMost(i16, -60, 120);
        }
        const ch = testChannel(&books, &sfs);
        var blk: Block = .{ .e = rnd.intRangeAtMost(Word, -40, 30) };
        for (books, 0..) |b, i| {
            for (offsets_test[i]..offsets_test[i + 1]) |k| blk.w[k] = if (spectral(b)) @intCast(rnd.intRangeAtMost(i32, -5600000, 5600000)) else 0;
        }
        const before = blk;
        channel(&ch, &offsets_test, &blk, &r);
        // spectral words: only shifted down to the new exponent
        for (books, 0..) |b, i| {
            if (!spectral(b)) continue;
            for (offsets_test[i]..offsets_test[i + 1]) |k| try testing.expectEqual(down(before.w[k], blk.e - before.e), blk.w[k]);
        }
        // noise bands: their energy, within the block exponent's quantisation
        for (books, sfs, 0..) |b, s, i| {
            if (b != ics.noise_hcb) continue;
            const run = blk.w[offsets_test[i]..offsets_test[i + 1]];
            const want = std.math.pow(f64, 2.0, @as(f64, @floatFromInt(s)) / 2.0);
            const lsb = std.math.ldexp(@as(f64, 1), blk.e);
            const n: f64 = @floatFromInt(run.len);
            const tol = 1e-4 * want + 2 * @sqrt(want * n) * lsb + n * lsb * lsb;
            try testing.expect(@abs(energy(run, blk.e) - want) <= tol);
        }
    }
}

test "correlated right noise is the left band times 2^((sfR - sfL) / 4)" {
    var r: Rng = .{};
    const l = testChannel(&.{ ics.noise_hcb, 1 }, &.{ 10, 100 });
    const rt = testChannel(&.{ ics.noise_hcb, ics.noise_hcb }, &.{ 17, 40 });
    var ms: ics.MsMask = .{ .present = 1 };
    ms.used[0][0] = true;
    ms.used[0][1] = true; // M/S on band 1, but the left band is spectral: the right's own noise
    const pair: ics.ChannelPair = .{ .common_window = true, .ms = ms, .left = l, .right = rt };
    var lb: Block = .{ .e = -10 };
    for (offsets_test[1]..offsets_test[2]) |k| lb.w[k] = 1 << 20;
    channel(&pair.left, &offsets_test, &lb, &r);
    var rb: Block = .{ .e = 0 };
    right(&pair, &lb, &offsets_test, &rb, &r);
    const k = std.math.pow(f64, 2.0, 7.0 / 4.0);
    const lsb = std.math.ldexp(@as(f64, 1), rb.e);
    for (0..4) |i| {
        const lv = std.math.ldexp(@as(f64, @floatFromInt(lb.w[i])), lb.e);
        const rv = std.math.ldexp(@as(f64, @floatFromInt(rb.w[i])), rb.e);
        try testing.expect(@abs(rv - lv * k) <= @abs(lv * k) * 0x1p-20 + lsb);
    }
    // band 1 is not correlated (the left is spectral): its own noise of energy 2^20
    const run = rb.w[offsets_test[1]..offsets_test[2]];
    try testing.expectApproxEqRel(@as(f64, 0x1p20), energy(run, rb.e), 1e-3);
}
