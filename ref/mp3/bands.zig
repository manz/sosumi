//! Scale factor bands as minimp3 lays them out (CC0, third_party/minimp3): one entry per band
//! of a long block, one entry per band per window of a short block (band-major, window-minor),
//! widths in coefficients. Rows follow header.sfbRow().
const std = @import("std");
const header = @import("header.zig");
const sideinfo = @import("sideinfo.zig");

pub const long = [8][22]u8{
    .{ 6, 6, 6, 6, 6, 6, 8, 10, 12, 14, 16, 20, 24, 28, 32, 38, 46, 52, 60, 68, 58, 54 },
    .{ 12, 12, 12, 12, 12, 12, 16, 20, 24, 28, 32, 40, 48, 56, 64, 76, 90, 2, 2, 2, 2, 2 },
    .{ 6, 6, 6, 6, 6, 6, 8, 10, 12, 14, 16, 20, 24, 28, 32, 38, 46, 52, 60, 68, 58, 54 },
    .{ 6, 6, 6, 6, 6, 6, 8, 10, 12, 14, 16, 18, 22, 26, 32, 38, 46, 54, 62, 70, 76, 36 },
    .{ 6, 6, 6, 6, 6, 6, 8, 10, 12, 14, 16, 20, 24, 28, 32, 38, 46, 52, 60, 68, 58, 54 },
    .{ 4, 4, 4, 4, 4, 4, 6, 6, 8, 8, 10, 12, 16, 20, 24, 28, 34, 42, 50, 54, 76, 158 },
    .{ 4, 4, 4, 4, 4, 4, 6, 6, 6, 8, 10, 12, 16, 18, 22, 28, 34, 40, 46, 54, 54, 192 },
    .{ 4, 4, 4, 4, 4, 4, 6, 6, 8, 10, 12, 16, 20, 24, 30, 38, 46, 56, 68, 84, 102, 26 },
};

pub const short = [8][39]u8{
    .{ 4, 4, 4, 4, 4, 4, 4, 4, 4, 6, 6, 6, 8, 8, 8, 10, 10, 10, 12, 12, 12, 14, 14, 14, 18, 18, 18, 24, 24, 24, 30, 30, 30, 40, 40, 40, 18, 18, 18 },
    .{ 8, 8, 8, 8, 8, 8, 8, 8, 8, 12, 12, 12, 16, 16, 16, 20, 20, 20, 24, 24, 24, 28, 28, 28, 36, 36, 36, 2, 2, 2, 2, 2, 2, 2, 2, 2, 26, 26, 26 },
    .{ 4, 4, 4, 4, 4, 4, 4, 4, 4, 6, 6, 6, 6, 6, 6, 8, 8, 8, 10, 10, 10, 14, 14, 14, 18, 18, 18, 26, 26, 26, 32, 32, 32, 42, 42, 42, 18, 18, 18 },
    .{ 4, 4, 4, 4, 4, 4, 4, 4, 4, 6, 6, 6, 8, 8, 8, 10, 10, 10, 12, 12, 12, 14, 14, 14, 18, 18, 18, 24, 24, 24, 32, 32, 32, 44, 44, 44, 12, 12, 12 },
    .{ 4, 4, 4, 4, 4, 4, 4, 4, 4, 6, 6, 6, 8, 8, 8, 10, 10, 10, 12, 12, 12, 14, 14, 14, 18, 18, 18, 24, 24, 24, 30, 30, 30, 40, 40, 40, 18, 18, 18 },
    .{ 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 6, 6, 6, 8, 8, 8, 10, 10, 10, 12, 12, 12, 14, 14, 14, 18, 18, 18, 22, 22, 22, 30, 30, 30, 56, 56, 56 },
    .{ 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 6, 6, 6, 6, 6, 6, 10, 10, 10, 12, 12, 12, 14, 14, 14, 16, 16, 16, 20, 20, 20, 26, 26, 26, 66, 66, 66 },
    .{ 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 6, 6, 6, 8, 8, 8, 12, 12, 12, 16, 16, 16, 20, 20, 20, 26, 26, 26, 34, 34, 34, 42, 42, 42, 12, 12, 12 },
};

/// Long entries first (8 for MPEG-1, 6 otherwise), then 30 short entries.
pub const mixed = [8][38]u8{
    .{ 6, 6, 6, 6, 6, 6, 6, 6, 6, 8, 8, 8, 10, 10, 10, 12, 12, 12, 14, 14, 14, 18, 18, 18, 24, 24, 24, 30, 30, 30, 40, 40, 40, 18, 18, 18, 0, 0 },
    .{ 12, 12, 12, 4, 4, 4, 8, 8, 8, 12, 12, 12, 16, 16, 16, 20, 20, 20, 24, 24, 24, 28, 28, 28, 36, 36, 36, 2, 2, 2, 2, 2, 2, 2, 2, 2, 26, 26 },
    .{ 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 8, 8, 8, 10, 10, 10, 14, 14, 14, 18, 18, 18, 26, 26, 26, 32, 32, 32, 42, 42, 42, 18, 18, 18, 0, 0 },
    .{ 6, 6, 6, 6, 6, 6, 6, 6, 6, 8, 8, 8, 10, 10, 10, 12, 12, 12, 14, 14, 14, 18, 18, 18, 24, 24, 24, 32, 32, 32, 44, 44, 44, 12, 12, 12, 0, 0 },
    .{ 6, 6, 6, 6, 6, 6, 6, 6, 6, 8, 8, 8, 10, 10, 10, 12, 12, 12, 14, 14, 14, 18, 18, 18, 24, 24, 24, 30, 30, 30, 40, 40, 40, 18, 18, 18, 0, 0 },
    .{ 4, 4, 4, 4, 4, 4, 6, 6, 4, 4, 4, 6, 6, 6, 8, 8, 8, 10, 10, 10, 12, 12, 12, 14, 14, 14, 18, 18, 18, 22, 22, 22, 30, 30, 30, 56, 56, 56 },
    .{ 4, 4, 4, 4, 4, 4, 6, 6, 4, 4, 4, 6, 6, 6, 6, 6, 6, 10, 10, 10, 12, 12, 12, 14, 14, 14, 16, 16, 16, 20, 20, 20, 26, 26, 26, 66, 66, 66 },
    .{ 4, 4, 4, 4, 4, 4, 6, 6, 4, 4, 4, 6, 6, 6, 8, 8, 8, 12, 12, 12, 16, 16, 16, 20, 20, 20, 26, 26, 26, 34, 34, 34, 42, 42, 42, 12, 12, 12 },
};

pub const Bands = struct {
    widths: []const u8,
    n_long: u8,
    n_short: u8,

    pub fn len(b: Bands) usize {
        return b.widths.len;
    }

    /// Window of entry e (0..2), or null for a long entry.
    pub fn window(b: Bands, e: usize) ?u2 {
        return if (e < b.n_long) null else @intCast((e - b.n_long) % 3);
    }
};

pub fn of(h: header.Header, g: sideinfo.Granule) Bands {
    const row = h.sfbRow();
    if (!g.isShort()) return .{ .widths = &long[row], .n_long = 22, .n_short = 0 };
    if (!g.mixed) return .{ .widths = &short[row], .n_long = 0, .n_short = 39 };
    const nl: u8 = if (h.version == .mpeg1) 8 else 6;
    return .{ .widths = mixed[row][0 .. nl + 30], .n_long = nl, .n_short = 30 };
}

/// Long subbands (of 18 coefficients) at the bottom of a mixed block: 2, or 4 at MPEG-2.5 8 kHz
/// (minimp3's rule).
pub fn mixedLongSubbands(h: header.Header) u8 {
    return if (h.version == .mpeg25 and h.sr_index == 2) 4 else 2;
}

const testing = std.testing;

fn sum(w: []const u8) usize {
    var s: usize = 0;
    for (w) |x| s += x;
    return s;
}

test "long and short rows cover 576 coefficients" {
    for (0..8) |row| {
        try testing.expectEqual(@as(usize, 576), sum(&long[row]));
        try testing.expectEqual(@as(usize, 576), sum(&short[row]));
    }
}

test "mixed rows cover 576 coefficients, and the long part is 36, except at 8 kHz" {
    for (0..8) |row| {
        const nl: usize = if (row >= 5) 8 else 6;
        const w = mixed[row][0 .. nl + 30];
        if (row == 1) continue; // MPEG-2.5 8 kHz: see the next test
        try testing.expectEqual(@as(usize, 576), sum(w));
        try testing.expectEqual(@as(usize, 36), sum(w[0..nl]));
    }
}

test "MPEG-2.5 8 kHz mixed row as minimp3 has it: 36 + 12 in its first six entries (OPEN)" {
    try testing.expectEqual(@as(usize, 48), sum(mixed[1][0..6]));
}
