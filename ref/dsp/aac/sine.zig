//! One sine table for every twiddle and the sine window: sin(k pi / 4096) in Q23 (1.0
//! saturating), stored for the k the IMDCTs and windows read (docs/aac-mode0.md): the odd k up
//! to 2047 and the multiples of 4 up to 2048. The other quadrants are this one mirrored.
const std = @import("std");
const ops = @import("../ops.zig");
const ref_window = @import("../../aac/window.zig");

const Word = ops.Word;

/// Angles are k * pi / 4096, k in [0, 4096] covering [0, pi].
pub const quarter_k = 2048;

/// sin(k pi / 4096) for odd k: odd[(k - 1) / 2].
pub const odd: [1024]Word = blk: {
    @setEvalBranchQuota(100000);
    var t: [1024]Word = undefined;
    for (&t, 0..) |*e, i| e.* = at(2 * i + 1);
    break :blk t;
};

/// sin(k pi / 4096) for k = 4j: four[j], j in [0, 512].
pub const four: [513]Word = blk: {
    @setEvalBranchQuota(100000);
    var t: [513]Word = undefined;
    for (&t, 0..) |*e, j| e.* = at(4 * j);
    break :blk t;
};

fn at(comptime k: usize) Word {
    return ref_window.q23Sat(@sin(std.math.pi * @as(f64, @floatFromInt(k)) / 4096.0));
}

/// The stored sin(k pi / 4096), k in [0, 2048], odd or a multiple of 4.
fn stored(k: usize) Word {
    if (k % 2 == 1) return odd[(k - 1) / 2];
    std.debug.assert(k % 4 == 0);
    return four[k / 4];
}

/// sin(k pi / 4096), k in [0, 4096].
pub fn sin(k: usize) Word {
    return stored(if (k <= quarter_k) k else 2 * quarter_k - k);
}

/// cos(k pi / 4096), k in [0, 4096]: sin of the complement, negated past pi / 2.
pub fn cos(k: usize) Word {
    if (k <= quarter_k) return stored(quarter_k - k);
    return ops.sub(0, stored(k - quarter_k));
}

const testing = std.testing;

test "the table is sin(k pi / 4096) in Q23, every quadrant" {
    var k: usize = 0;
    while (k <= 4096) : (k += 1) {
        if (k % 2 == 0 and k % 4 != 0) continue;
        const t = std.math.pi * @as(f64, @floatFromInt(k)) / 4096.0;
        try testing.expect(@abs(@as(f64, @floatFromInt(sin(k))) - @sin(t) * 0x1p23) <= 1.0);
        if (k % 4 == 0 or k <= 2048) try testing.expect(@abs(@as(f64, @floatFromInt(cos(k))) - @cos(t) * 0x1p23) <= 1.0);
    }
}

test "the long sine window is the odd entries" {
    for (ref_window.long[0], 0..) |w, n| try testing.expectEqual(w, odd[n]);
}

test "1537 words" {
    try testing.expectEqual(@as(usize, 1537), odd.len + four.len);
}
