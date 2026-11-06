//! Adaptive linear prediction: Apple's unpc_block (dp_dec.c, Apache 2.0), general case. The
//! reference's 4- and 8-tap paths compute the same sums and updates. Coefficients adapt by
//! sign-sign LMS after every sample; the sum wraps at 32 bits and the output at `chan_bits`.
const std = @import("std");

fn sign(i: i32) i32 {
    return if (i > 0) 1 else if (i < 0) -1 else 0;
}

/// Sign-extends the low `chan_bits` bits (1..32).
fn wrap(x: i32, chan_bits: u6) i32 {
    const s: u5 = @intCast(32 - @as(u32, chan_bits));
    const u: u32 = @bitCast(x);
    return @as(i32, @bitCast(u << s)) >> s;
}

/// First-order integration in place, the numactive == 31 case.
pub fn integrate(buf: []i32, chan_bits: u6) void {
    var j: usize = 1;
    while (j < buf.len) : (j += 1) buf[j] = wrap(buf[j] +% buf[j - 1], chan_bits);
}

/// Residuals `pc` to samples `out` (distinct buffers), with `coefs` updated in place.
pub fn unpredict(pc: []const i32, out: []i32, coefs: []i16, chan_bits: u6, den_shift: u4) void {
    const n = pc.len;
    if (n == 0) return;
    out[0] = pc[0];
    const order = coefs.len;
    if (order == 0) {
        @memcpy(out[1..n], pc[1..n]);
        return;
    }
    const den_half: i32 = if (den_shift == 0) 0 else @as(i32, 1) << (den_shift - 1);
    var j: usize = 1;
    while (j <= order and j < n) : (j += 1) out[j] = wrap(pc[j] +% out[j - 1], chan_bits);
    const lim = order + 1;
    while (j < n) : (j += 1) {
        const top = out[j - lim];
        var sum: i32 = 0;
        for (0..order) |k| sum +%= @as(i32, coefs[k]) *% (out[j - 1 - k] -% top);
        var del = pc[j];
        var del0 = del;
        const sg = sign(del);
        del +%= top +% ((sum +% den_half) >> den_shift);
        out[j] = wrap(del, chan_bits);
        if (sg == 0) continue;
        var k = order;
        while (k > 0) {
            k -= 1;
            const dd = top -% out[j - 1 - k];
            const sgn = sign(dd);
            const w: i32 = @intCast(order - k);
            if (sg > 0) {
                coefs[k] -%= @intCast(sgn);
                del0 -%= w *% ((sgn *% dd) >> den_shift);
                if (del0 <= 0) break;
            } else {
                coefs[k] +%= @intCast(sgn);
                del0 -%= w *% ((-sgn *% dd) >> den_shift);
                if (del0 >= 0) break;
            }
        }
    }
}

const testing = std.testing;

test "integration wraps at the channel width" {
    var b = [_]i32{ 32767, 1, -2 };
    integrate(&b, 16);
    try testing.expectEqualSlices(i32, &.{ 32767, -32768, 32766 }, &b);
}

test "order 0 copies; zero residuals hold a constant" {
    const pc = [_]i32{ 5, 0, 0, 0, 0, 0 };
    var out: [6]i32 = undefined;
    var coefs = [_]i16{ 160, -190, 170, -130 };
    unpredict(&pc, &out, &coefs, 16, 9);
    try testing.expectEqualSlices(i32, &.{ 5, 5, 5, 5, 5, 5 }, &out);
    // zero residuals never adapt the coefficients
    try testing.expectEqualSlices(i16, &.{ 160, -190, 170, -130 }, &coefs);
}
