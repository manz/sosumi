//! Adaptive Golomb-Rice residual decoding: Apple's dyn_decomp (ag_dec.c, Apache 2.0). The mean
//! mb adapts per value; when it falls low, a run of zeros is coded with its own parameter.
//! Arithmetic is the reference's unsigned 32-bit, wraps included.
const std = @import("std");
const bits = @import("../bits.zig");

pub const Error = bits.Error || error{ RunTooLong, InvalidParams };

const qb_shift = 9;
const qb: u32 = 1 << qb_shift;
const max_prefix = 9;
const n_mean_clamp: u32 = 0xffff;

pub const Params = struct {
    mb: u32,
    pb: u32,
    kb: u32,
};

/// One codeword: a unary prefix of up to 9 ones; 9 ones mean an escaped `escape_bits` value.
/// Otherwise k bits v follow, and only k - 1 are consumed when v < 2.
fn get(r: *bits.BitReader, m: u32, k: u32, escape_bits: u6) Error!u32 {
    var pre: u32 = 0;
    while (pre < max_prefix) : (pre += 1) {
        if (!try r.readFlag()) break;
    }
    if (pre == max_prefix) return r.read(escape_bits);
    if (k == 0) return error.InvalidParams;
    const hi = try r.read(@intCast(k - 1));
    if (hi == 0) return pre *% m;
    const v = (hi << 1) | try r.read(1);
    return pre *% m +% v -% 1;
}

/// floor(log2(x + 3))
fn lg3a(x: u32) u32 {
    return 31 - @clz(x +% 3);
}

/// Decodes `out.len` residuals. `max_bits` is the channel width, the size of an escaped value.
pub fn decompress(r: *bits.BitReader, out: []i32, p: Params, max_bits: u6) Error!void {
    var mb = p.mb;
    const wb: u32 = (@as(u32, 1) << @intCast(p.kb)) - 1;
    var zmode: u32 = 0;
    var c: usize = 0;
    while (c < out.len) {
        var k = @min(lg3a(mb >> qb_shift), p.kb);
        const m = (@as(u32, 1) << @intCast(k)) - 1;
        const n = try get(r, m, k, max_bits);
        const nd = n +% zmode;
        const mag: i32 = @bitCast((nd +% 1) >> 1);
        out[c] = if (nd & 1 != 0) -%mag else mag;
        c += 1;
        mb = p.pb *% nd +% mb -% ((p.pb *% mb) >> qb_shift);
        if (n > n_mean_clamp) mb = n_mean_clamp;
        zmode = 0;
        if ((mb *% 4) < qb and c < out.len) {
            zmode = 1;
            k = @clz(mb) - 24 + ((mb + 16) >> 6);
            const mz = ((@as(u32, 1) << @intCast(k)) - 1) & wb;
            const run = try get(r, mz, k, 16);
            if (c + run > out.len) return error.RunTooLong;
            @memset(out[c .. c + run], 0);
            c += run;
            if (run >= 65535) zmode = 0;
            mb = 0;
        }
    }
}

const testing = std.testing;

test "small values at the initial mean decode as 1-bit-prefix codes" {
    // mb 10: k = lg3a(0) = 1, m = 1. "0" -> n 0 -> residual 0; then the mean stays low:
    // mb = 40*0 + 10 - 0 = 10, mb*4 < 512 -> zero run, k = clz(10) - 24 + 0 = 4, mz = 15.
    // run "0" + 3 bits "000" (hi 0) -> 0 zeros. Next value "10" -> pre 1, n 1; after a run
    // zmode adds 1: nd 2 -> residual +1.
    var buf = [_]u8{ 0b0_0_000_10_0, 0 };
    var r = bits.BitReader.init(&buf);
    var out: [2]i32 = undefined;
    try decompress(&r, &out, .{ .mb = 10, .pb = 40, .kb = 14 }, 16);
    try testing.expectEqualSlices(i32, &.{ 0, 1 }, &out);
    try testing.expectEqual(@as(usize, 7), r.pos);
}

test "nine ones escape to a raw value of the channel width" {
    // mb 10: escape: 9 ones then 16 bits 0x0005 -> n 5 -> residual -3
    var buf = [_]u8{ 0xFF, 0x80, 0x02, 0x80, 0 };
    var r = bits.BitReader.init(&buf);
    var out: [1]i32 = undefined;
    try decompress(&r, &out, .{ .mb = 10, .pb = 40, .kb = 14 }, 16);
    try testing.expectEqual(@as(i32, -3), out[0]);
}
