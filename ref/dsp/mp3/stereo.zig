//! Joint stereo in measured sm1 operations: the twin of `ref/mp3/stereo.zig`, the same band
//! logic on Q21 words.
//!
//! M/S is one tap sum per output: 2 (m c + s c) read back at 2^24 is (m + s) c / 2^23 with
//! c = 1/sqrt 2 in Q23, rounded once. The intensity gains reach 1, so they are Q22 and read
//! back at 2^23; MPEG-2's 2^(-n / 4) takes its quarter steps from a four-entry table and the
//! whole steps as a rounded shift after.
const std = @import("std");
const ops = @import("../ops.zig");
const header = @import("../../mp3/header.zig");
const sideinfo = @import("../../mp3/sideinfo.zig");
const bands = @import("../../mp3/bands.zig");
const scalefactors = @import("../../mp3/scalefactors.zig");
const requant = @import("requant.zig");

const Word = ops.Word;

fn q(comptime x: f64, comptime f: u5) Word {
    return @intFromFloat(@round(x * @as(f64, @floatFromInt(@as(u32, 1) << f))));
}

const inv_sqrt2: Word = q(0.7071067811865476, 23);

/// MPEG-1 intensity, Q22: kl = tan(p pi/12) / (1 + tan), kr = 1 / (1 + tan), p = 0..6.
pub const pan: [7][2]Word = blk: {
    var t: [7][2]Word = undefined;
    for (0..7) |p| {
        const a = @as(f64, @floatFromInt(p)) * std.math.pi / 12.0;
        const sn = @sin(a);
        const cs = @cos(a);
        t[p] = .{ q(sn / (sn + cs), 22), q(cs / (sn + cs), 22) };
    }
    break :blk t;
};

/// 2^(-k / 4), k = 0..3, Q22.
pub const quarter: [4]Word = .{ q(1.0, 22), q(0.8408964152537145, 22), q(0.7071067811865476, 22), q(0.5946035575013605, 22) };

const one22: Word = q(1.0, 22);

fn ms(l: []Word, r: []Word) void {
    for (l, r) |*a, *b| {
        const m = a.*;
        const s = b.*;
        a.* = ops.accRshr(ops.mac(ops.mac(0, m, inv_sqrt2), s, inv_sqrt2), 24);
        b.* = ops.accRshr(ops.mac(ops.mac(0, m, inv_sqrt2), ops.sub(0, s), inv_sqrt2), 24);
    }
}

/// x k / 2^22, then a rounded right shift by `down` (0 for none, 24 or more gives 0).
fn gain(x: Word, k: Word, down: u32) Word {
    const v = ops.accRshr(ops.mac(0, x, k), 23);
    if (down == 0) return v;
    return if (down >= 24) 0 else ops.rshr(v, @intCast(down));
}

fn intensity(l: []Word, r: []Word, kl: Word, dl: u32, kr: Word, dr: u32) void {
    for (l, r) |*a, *b| {
        const x = a.*;
        a.* = gain(x, kl, dl);
        b.* = gain(x, kr, dr);
    }
}

pub fn process(h: header.Header, gr: sideinfo.Granule, right_gr: sideinfo.Granule, right_sf: *const scalefactors.Scalefactors, left: *requant.Coefs, right: *requant.Coefs) void {
    const b = bands.of(h, gr);
    if (!h.intensityStereo()) {
        if (h.msStereo()) ms(left, right);
        return;
    }
    const n = b.len();
    var max_band: [3]i32 = .{ -1, -1, -1 };
    var k: usize = 0;
    for (b.widths, 0..) |w, e| {
        for (right[k .. k + w]) |c| {
            if (!ops.isZero(c)) {
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
                intensity(l, r, pan[p][0], 0, pan[p][1], 0);
            } else {
                const nq: u32 = (@as(u32, p) + 1) >> 1 << sh;
                const kv = quarter[nq & 3];
                const dv = nq >> 2;
                if (p & 1 != 0) intensity(l, r, kv, dv, one22, 0) else intensity(l, r, one22, 0, kv, dv);
            }
        } else if (h.msStereo()) {
            ms(l, r);
        }
    }
}

const testing = std.testing;

test "M/S: (3, 1) becomes (4, 2) / sqrt 2 in Q21" {
    var l: requant.Coefs = @splat(3 << 21);
    var r: requant.Coefs = @splat(1 << 21);
    const h = try header.parse(&.{ 0xFF, 0xFB, 0x90, 0x64 });
    process(h, .{}, .{}, &.{}, &l, &r);
    // c is 1/sqrt 2 rounded to Q23: one LSB of slack
    try testing.expectApproxEqAbs(4.0 / @sqrt(2.0) * (1 << 21), @as(f64, @floatFromInt(l[100])), 1.0);
    try testing.expectApproxEqAbs(2.0 / @sqrt(2.0) * (1 << 21), @as(f64, @floatFromInt(r[575])), 1.0);
}

test "intensity gain 1 is exact" {
    try testing.expectEqual(@as(Word, 12345), gain(12345, one22, 0));
    try testing.expectEqual(@as(Word, -12345), gain(-12345, one22, 0));
}
