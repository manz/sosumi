//! Windowing, overlap-add and PCM output in measured sm1 operations: the twin of
//! `ref/aac/filterbank.zig` from the IMDCT's Q7 words on.
//!
//! The windows are stored as w / 4 in Q23, so one rounded multiply turns a Q7 IMDCT word into a
//! Q5 word. The two bits of headroom cover any position's sum: at most three windowed terms (a
//! long-only block followed by eight short ones, an illegal sequence, overlaps two short halves
//! with the previous tail), each below 2^21, so the plain 24-bit adds never wrap and need no
//! saturation. PCM is one rounded shift by 5, then a clamp by comparisons.
const std = @import("std");
const ops = @import("../ops.zig");
const ref_window = @import("../../aac/window.zig");
const ics = @import("../../aac/ics.zig");

const Word = ops.Word;

/// The Q7 words' fraction bits after windowing.
pub const frac = 5;

fn quarter(comptime n: usize, rise: [n]Word) [n]Word {
    @setEvalBranchQuota(100000);
    var t: [n]Word = undefined;
    for (&t, rise) |*d, w| d.* = ops.rshr(w, 2);
    return t;
}

/// Rising halves, w / 4 in Q23, by window_shape.
pub const long = [2][1024]Word{ quarter(1024, ref_window.long[0]), quarter(1024, ref_window.long[1]) };
pub const short = [2][128]Word{ quarter(128, ref_window.short[0]), quarter(128, ref_window.short[1]) };

pub const State = struct {
    overlap: [1024]Word = @splat(0),
    prev_shape: u1 = 0,
};

/// One block's input: the long IMDCT's 2048 words, or the eight short IMDCTs' 256 each.
pub const Imdct = union(enum) {
    long: *const [2048]Word,
    short: *const [8][256]Word,
};

/// The windowed 2048-word block, Q5.
pub fn block(prev: u1, cur: u1, seq: ics.WindowSequence, t: Imdct, buf: *[2048]Word) void {
    const m = ops.mulRound23;
    if (seq == .eight_short) {
        @memset(buf, 0);
        for (t.short, 0..) |*s, w| {
            const left: u1 = if (w == 0) prev else cur;
            for (0..128) |n| {
                const o = 448 + 128 * w + n;
                buf[o] = ops.add(buf[o], m(s[n], short[left][n]));
                buf[o + 128] = ops.add(buf[o + 128], m(s[128 + n], short[cur][127 - n]));
            }
        }
        return;
    }
    const x = t.long;
    switch (seq) {
        .only_long => {
            for (0..1024) |n| buf[n] = m(x[n], long[prev][n]);
            for (1024..2048) |n| buf[n] = m(x[n], long[cur][2047 - n]);
        },
        .long_start => {
            for (0..1024) |n| buf[n] = m(x[n], long[prev][n]);
            for (1024..1472) |n| buf[n] = ops.rshr(x[n], 2);
            for (1472..1600) |n| buf[n] = m(x[n], short[cur][1599 - n]);
            @memset(buf[1600..2048], 0);
        },
        .long_stop => {
            @memset(buf[0..448], 0);
            for (448..576) |n| buf[n] = m(x[n], short[prev][n - 448]);
            for (576..1024) |n| buf[n] = ops.rshr(x[n], 2);
            for (1024..2048) |n| buf[n] = m(x[n], long[cur][2047 - n]);
        },
        .eight_short => unreachable,
    }
}

/// PCM from the overlap and the block's first half; the second half becomes the overlap. The
/// rounded shift comes first: its result is within 2^18, so the clamp's comparisons cannot wrap.
pub fn synth(st: *State, cur: u1, buf: *const [2048]Word, out: *[1024]i16) void {
    for (out, st.overlap, buf[0..1024]) |*o, a, b| {
        var v = ops.rshr(ops.add(a, b), frac);
        if (ops.isNeg(ops.sub(32767, v))) v = 32767;
        if (ops.isNeg(ops.sub(v, -32768))) v = -32768;
        o.* = @intCast(v);
    }
    st.overlap = buf[1024..2048].*;
    st.prev_shape = cur;
}

const testing = std.testing;

/// The same in double precision from the same Q7 words.
fn direct(st: *[1024]f64, prev: u1, cur: u1, seq: ics.WindowSequence, t: Imdct, out: *[1024]f64) void {
    const L = &ref_window.long;
    const S = &ref_window.short;
    const q = struct {
        fn f(v: anytype) f64 {
            return @as(f64, @floatFromInt(v)) / 0x1p23;
        }
    }.f;
    var buf: [2048]f64 = @splat(0);
    if (seq == .eight_short) {
        for (t.short, 0..) |*s, w| {
            const left: u1 = if (w == 0) prev else cur;
            for (0..128) |n| {
                const o = 448 + 128 * w + n;
                buf[o] += @as(f64, @floatFromInt(s[n])) * q(S[left][n]);
                buf[o + 128] += @as(f64, @floatFromInt(s[128 + n])) * q(S[cur][127 - n]);
            }
        }
    } else {
        const x = t.long;
        for (0..2048) |n| {
            const v: f64 = @floatFromInt(x[n]);
            buf[n] = switch (seq) {
                .only_long => v * (if (n < 1024) q(L[prev][n]) else q(L[cur][2047 - n])),
                .long_start => if (n < 1024) v * q(L[prev][n]) else if (n < 1472) v else if (n < 1600) v * q(S[cur][1599 - n]) else 0,
                .long_stop => if (n < 448) 0 else if (n < 576) v * q(S[prev][n - 448]) else if (n < 1024) v else v * q(L[cur][2047 - n]),
                .eight_short => unreachable,
            };
        }
    }
    for (out, st, buf[0..1024]) |*o, a, b| o.* = std.math.clamp((a + b) / 128, -32768, 32767);
    st.* = buf[1024..2048].*;
}

fn randomBlock(rnd: std.Random, amp: i32, seq: ics.WindowSequence, l: *[2048]Word, s: *[8][256]Word) Imdct {
    if (seq == .eight_short) {
        for (s) |*w| for (w) |*v| {
            v.* = @intCast(rnd.intRangeAtMost(i32, -amp, amp));
        };
        return .{ .short = s };
    }
    for (l) |*v| v.* = @intCast(rnd.intRangeAtMost(i32, -amp, amp));
    return .{ .long = l };
}

test "window and overlap within 1 PCM step of double precision" {
    var prng = std.Random.DefaultPrng.init(0x3D1);
    const rnd = prng.random();
    // every transition, legal or not, both shapes, loud enough to clip
    const seqs = [_]ics.WindowSequence{ .only_long, .long_start, .eight_short, .eight_short, .long_stop, .only_long, .eight_short, .only_long, .long_stop, .long_start, .only_long };
    var st: State = .{};
    var dst: [1024]f64 = @splat(0);
    var l: [2048]Word = undefined;
    var s: [8][256]Word = undefined;
    var worst: f64 = 0;
    for (seqs, 0..) |seq, f| {
        const cur: u1 = @intCast(f & 1);
        const amp: i32 = if (f == 9) (1 << 23) - 1 else 1 << 21; // one clipping frame
        const t = randomBlock(rnd, amp, seq, &l, &s);
        var buf: [2048]Word = undefined;
        block(st.prev_shape, cur, seq, t, &buf);
        var pcm: [1024]i16 = undefined;
        const prev = st.prev_shape;
        synth(&st, cur, &buf, &pcm);
        var want: [1024]f64 = undefined;
        direct(&dst, prev, cur, seq, t, &want);
        for (pcm, want) |p, w| worst = @max(worst, @abs(@as(f64, @floatFromInt(p)) - w));
    }
    try testing.expect(worst <= 1.0);
}

test "the worst-case sum fits 24 bits" {
    // full-scale words of one sign in every window, long-only then eight short: three terms
    var full_l: [2048]Word = @splat((1 << 23) - 1);
    var full_s: [8][256]Word = @splat(@splat((1 << 23) - 1));
    for (0..2) |shape| {
        const sh: u1 = @intCast(shape);
        var a: [2048]Word = undefined;
        block(sh, sh, .only_long, .{ .long = &full_l }, &a);
        var b: [2048]Word = undefined;
        block(sh, sh, .eight_short, .{ .short = &full_s }, &b);
        for (a[1024..2048], b[0..1024]) |x, y| {
            const sum: i32 = @as(i32, x) + y;
            try testing.expect(sum < 1 << 23);
        }
        for (b) |v| try testing.expect(v < 1 << 22);
    }
}

test "pcm clamps at both ends" {
    var st: State = .{};
    var buf: [2048]Word = @splat(0);
    buf[0] = (1 << 23) - 1;
    buf[1] = -(1 << 23);
    buf[2] = (32767 << frac) + (1 << (frac - 1)) - 1; // just below rounding up to 32768
    buf[3] = -(32768 << frac) - (1 << (frac - 1)); // rounds to -32768.5 + 0.5
    var pcm: [1024]i16 = undefined;
    synth(&st, 0, &buf, &pcm);
    try testing.expectEqual(@as(i16, 32767), pcm[0]);
    try testing.expectEqual(@as(i16, -32768), pcm[1]);
    try testing.expectEqual(@as(i16, 32767), pcm[2]);
    try testing.expectEqual(@as(i16, -32768), pcm[3]);
}
