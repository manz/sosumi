//! Windowing and overlap-add (ISO/IEC 14496-3): one 2048-sample block per frame, the first half
//! added to the previous block's second half. The left half of each window uses the previous
//! frame's window_shape, the right half the current one.
const std = @import("std");
const fixed = @import("../fixed.zig");
const ics = @import("ics.zig");
const iquant = @import("iquant.zig");
const imdct = @import("imdct.zig");
const window = @import("window.zig");

const Word = fixed.Word;
const Acc = fixed.Acc;

pub const State = struct {
    overlap: [1024]Word = @splat(0),
    prev_shape: u1 = 0,
};

fn addSat(a: Word, b: Word) Word {
    return fixed.sat(@as(Acc, a) + b);
}

/// The windowed 2048-sample block for one frame.
pub fn block(st: *const State, info: ics.IcsInfo, coefs: *const iquant.Coefs, buf: *[2048]Word) void {
    const prev = st.prev_shape;
    const cur = info.window_shape;
    const L = &window.long;
    const S = &window.short;
    const m = fixed.mulQ23;
    if (info.window_sequence == .eight_short) {
        @memset(buf, 0);
        for (0..8) |w| {
            var t: [256]Word = undefined;
            imdct.imdct(128, coefs[w * 128 ..][0..128], &t);
            const left: u1 = if (w == 0) prev else cur;
            for (0..128) |n| {
                const o = 448 + 128 * w + n;
                buf[o] = addSat(buf[o], m(t[n], S[left][n]));
                buf[o + 128] = addSat(buf[o + 128], m(t[128 + n], S[cur][127 - n]));
            }
        }
        return;
    }
    imdct.imdct(1024, coefs, buf);
    switch (info.window_sequence) {
        .only_long => {
            for (0..1024) |n| buf[n] = m(buf[n], L[prev][n]);
            for (1024..2048) |n| buf[n] = m(buf[n], L[cur][2047 - n]);
        },
        .long_start => {
            for (0..1024) |n| buf[n] = m(buf[n], L[prev][n]);
            for (1472..1600) |n| buf[n] = m(buf[n], S[cur][1599 - n]);
            @memset(buf[1600..2048], 0);
        },
        .long_stop => {
            @memset(buf[0..448], 0);
            for (448..576) |n| buf[n] = m(buf[n], S[prev][n - 448]);
            for (1024..2048) |n| buf[n] = m(buf[n], L[cur][2047 - n]);
        },
        .eight_short => unreachable,
    }
}

/// One frame of 16-bit PCM for one channel.
pub fn synth(st: *State, info: ics.IcsInfo, coefs: *const iquant.Coefs, out: *[1024]i16) void {
    var buf: [2048]Word = undefined;
    block(st, info, coefs, &buf);
    for (out, st.overlap, buf[0..1024]) |*o, a, b| {
        const v = fixed.roundShift(@as(Acc, a) + b, imdct.pcm_frac);
        o.* = @intCast(std.math.clamp(v, std.math.minInt(i16), std.math.maxInt(i16)));
    }
    st.overlap = buf[1024..2048].*;
    st.prev_shape = info.window_shape;
}

const testing = std.testing;

fn wf(w: Word) f64 {
    return @as(f64, @floatFromInt(w)) / 0x1p23;
}

/// The analysis window an encoder pairs with `block` (doubles, same tables).
fn analysisWindow(seq: ics.WindowSequence, prev: u1, cur: u1, n: usize) f64 {
    const L = &window.long;
    const S = &window.short;
    return switch (seq) {
        .only_long => if (n < 1024) wf(L[prev][n]) else wf(L[cur][2047 - n]),
        .long_start => if (n < 1024) wf(L[prev][n]) else if (n < 1472) 1 else if (n < 1600) wf(S[cur][1599 - n]) else 0,
        .long_stop => if (n < 448) 0 else if (n < 576) wf(S[prev][n - 448]) else if (n < 1024) 1 else wf(L[cur][2047 - n]),
        .eight_short => unreachable,
    };
}

/// Forward MDCT in doubles, X[k] = 2 sum z[n] cos(...), so that the IMDCT inverts it.
fn mdct(comptime n: usize, ct: *const imdct.CosTable(n), z: []const f64, out: []fixed.F24) void {
    for (0..n / 2) |k| {
        var x: f64 = 0;
        for (0..n) |i| x += z[i] * ct.at(i, k);
        x *= 2;
        const q: Acc = @intFromFloat(@round(x * 256));
        out[k] = fixed.normalize(q, -8);
    }
}

fn signal(i: usize) f64 {
    const t: f64 = @floatFromInt(i);
    return 9000 * @sin(0.031 * t) + 4000 * @sin(0.71 * t + 1) + (if (i % 3000 == 1700) @as(f64, 6000) else 0);
}

// Measured: worst sample 1.06 steps (mid-overlap), added noise about 0.06 RMS
// over ideal rounding (0.29 RMS), so roughly -114 dB re full scale.
test "a long, start, short, stop sequence reconstructs the input at the 16-bit noise floor" {
    const seqs = [_]ics.WindowSequence{ .only_long, .only_long, .long_start, .eight_short, .long_stop, .only_long, .long_start, .eight_short, .eight_short, .long_stop, .only_long };
    const shapes = [_]u1{ 0, 1, 1, 0, 1, 0, 0, 1, 1, 0, 1 };
    const ct_long = imdct.CosTable(2048).init();
    const ct_short = imdct.CosTable(256).init();
    var st: State = .{};
    var prev: u1 = 0;
    var worst: f64 = 0;
    var excess: f64 = 0;
    for (seqs, shapes, 0..) |seq, shape, f| {
        var coefs: iquant.Coefs = undefined;
        if (seq == .eight_short) {
            for (0..8) |w| {
                const left: u1 = if (w == 0) prev else shape;
                var z: [256]f64 = undefined;
                for (&z, 0..) |*v, n| {
                    const win = if (n < 128) wf(window.short[left][n]) else wf(window.short[shape][255 - n]);
                    v.* = signal(f * 1024 + 448 + 128 * w + n) * win;
                }
                mdct(256, &ct_short, &z, coefs[w * 128 ..][0..128]);
            }
        } else {
            var z: [2048]f64 = undefined;
            for (&z, 0..) |*v, n| v.* = signal(f * 1024 + n) * analysisWindow(seq, prev, shape, n);
            mdct(2048, &ct_long, &z, &coefs);
        }
        var info: ics.IcsInfo = .{ .window_sequence = seq, .window_shape = shape, .max_sfb = 0, .num_window_groups = 1, .group_len = @splat(0) };
        info.group_len[0] = 1;
        var out: [1024]i16 = undefined;
        synth(&st, info, &coefs, &out);
        prev = shape;
        if (f == 0) continue; // nothing to overlap with yet
        var ss: f64 = 0;
        var ss_round: f64 = 0;
        for (out, 0..) |o, n| {
            const x = signal(f * 1024 + n);
            const e = @as(f64, @floatFromInt(o)) - x;
            worst = @max(worst, @abs(e));
            ss += e * e;
            ss_round += (@round(x) - x) * (@round(x) - x);
        }
        excess = @max(excess, @sqrt(@max(0, ss - ss_round) / 1024));
    }
    // fixed-point noise added on top of rounding to 16 bits, RMS
    try testing.expect(excess < 0.1);
    try testing.expect(worst < 1.5);
}
