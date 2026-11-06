//! Scale factor band offsets (swb_offset), 1024-sample long and 128-sample short windows.
//!
//! Converted from the OpenCORE AAC decoder's `sfb.cpp` (Apache 2.0, third_party/opencore-aac):
//! PV stores band end offsets; these carry the leading 0, so band b spans [t[b], t[b + 1]).
//! PV has no 7350 Hz entry; index 12 uses the 8 kHz tables (INFERRED).

const long_96 = [_]u16{ 0, 4, 8, 12, 16, 20, 24, 28, 32, 36, 40, 44, 48, 52, 56, 64, 72, 80, 88, 96, 108, 120, 132, 144, 156, 172, 188, 212, 240, 276, 320, 384, 448, 512, 576, 640, 704, 768, 832, 896, 960, 1024 };
const long_64 = [_]u16{ 0, 4, 8, 12, 16, 20, 24, 28, 32, 36, 40, 44, 48, 52, 56, 64, 72, 80, 88, 100, 112, 124, 140, 156, 172, 192, 216, 240, 268, 304, 344, 384, 424, 464, 504, 544, 584, 624, 664, 704, 744, 784, 824, 864, 904, 944, 984, 1024 };
const long_48 = [_]u16{ 0, 4, 8, 12, 16, 20, 24, 28, 32, 36, 40, 48, 56, 64, 72, 80, 88, 96, 108, 120, 132, 144, 160, 176, 196, 216, 240, 264, 292, 320, 352, 384, 416, 448, 480, 512, 544, 576, 608, 640, 672, 704, 736, 768, 800, 832, 864, 896, 928, 1024 };
const long_32 = [_]u16{ 0, 4, 8, 12, 16, 20, 24, 28, 32, 36, 40, 48, 56, 64, 72, 80, 88, 96, 108, 120, 132, 144, 160, 176, 196, 216, 240, 264, 292, 320, 352, 384, 416, 448, 480, 512, 544, 576, 608, 640, 672, 704, 736, 768, 800, 832, 864, 896, 928, 960, 992, 1024 };
const long_24 = [_]u16{ 0, 4, 8, 12, 16, 20, 24, 28, 32, 36, 40, 44, 52, 60, 68, 76, 84, 92, 100, 108, 116, 124, 136, 148, 160, 172, 188, 204, 220, 240, 260, 284, 308, 336, 364, 396, 432, 468, 508, 552, 600, 652, 704, 768, 832, 896, 960, 1024 };
const long_16 = [_]u16{ 0, 8, 16, 24, 32, 40, 48, 56, 64, 72, 80, 88, 100, 112, 124, 136, 148, 160, 172, 184, 196, 212, 228, 244, 260, 280, 300, 320, 344, 368, 396, 424, 456, 492, 532, 572, 616, 664, 716, 772, 832, 896, 960, 1024 };
const long_8 = [_]u16{ 0, 12, 24, 36, 48, 60, 72, 84, 96, 108, 120, 132, 144, 156, 172, 188, 204, 220, 236, 252, 268, 288, 308, 328, 348, 372, 396, 420, 448, 476, 508, 544, 580, 620, 664, 712, 764, 820, 880, 944, 1024 };

const short_64 = [_]u16{ 0, 4, 8, 12, 16, 20, 24, 32, 40, 48, 64, 92, 128 };
const short_48 = [_]u16{ 0, 4, 8, 12, 16, 20, 28, 36, 44, 56, 68, 80, 96, 112, 128 };
const short_24 = [_]u16{ 0, 4, 8, 12, 16, 20, 24, 28, 36, 44, 52, 64, 76, 92, 108, 128 };
const short_16 = [_]u16{ 0, 4, 8, 12, 16, 20, 24, 28, 32, 40, 48, 60, 72, 88, 108, 128 };
const short_8 = [_]u16{ 0, 4, 8, 12, 16, 20, 24, 28, 36, 44, 52, 60, 72, 88, 108, 128 };

/// Long-window offsets by samplingFrequencyIndex 0..12.
pub const long = [13][]const u16{ &long_96, &long_96, &long_64, &long_48, &long_48, &long_32, &long_24, &long_24, &long_16, &long_16, &long_16, &long_8, &long_8 };

/// Short-window offsets by samplingFrequencyIndex 0..12.
pub const short = [13][]const u16{ &short_64, &short_64, &short_64, &short_48, &short_48, &short_48, &short_24, &short_24, &short_16, &short_16, &short_16, &short_8, &short_8 };

const std = @import("std");

test "band counts match PV's samp_rate_info" {
    const nl = [12]usize{ 41, 41, 47, 49, 49, 51, 47, 47, 43, 43, 43, 40 };
    const ns = [12]usize{ 12, 12, 12, 14, 14, 14, 15, 15, 15, 15, 15, 15 };
    for (0..12) |i| {
        try std.testing.expectEqual(nl[i], long[i].len - 1);
        try std.testing.expectEqual(ns[i], short[i].len - 1);
    }
}

test "every table is strictly increasing and closes the window" {
    for (long ++ short) |t| {
        for (t[0 .. t.len - 1], t[1..]) |a, b| try std.testing.expect(a < b);
    }
    for (long) |t| try std.testing.expectEqual(@as(u16, 1024), t[t.len - 1]);
    for (short) |t| try std.testing.expectEqual(@as(u16, 128), t[t.len - 1]);
}
