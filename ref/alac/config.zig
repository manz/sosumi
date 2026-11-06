//! ALACSpecificConfig: 24 big-endian bytes, optionally behind 'frma' and 'alac' atom headers
//! (Apple's ALACMagicCookieDescription.txt; the reference decoder's Init skips both).
const std = @import("std");

pub const Error = error{ Truncated, UnsupportedVersion, UnsupportedFormat };

/// Largest frame length the model accepts; Apple's description calls larger ones unsupported.
pub const max_frame_length = 16384;

pub const Config = struct {
    frame_length: u32,
    compatible_version: u8,
    bit_depth: u8,
    pb: u8,
    mb: u8,
    kb: u8,
    channels: u8,
    max_run: u16,
    max_frame_bytes: u32,
    avg_bit_rate: u32,
    sample_rate: u32,
};

fn be32(b: []const u8) u32 {
    return std.mem.readInt(u32, b[0..4], .big);
}

pub fn parse(cookie: []const u8) Error!Config {
    var c = cookie;
    if (c.len >= 12 and std.mem.eql(u8, c[4..8], "frma")) c = c[12..];
    if (c.len >= 12 and std.mem.eql(u8, c[4..8], "alac")) c = c[12..];
    if (c.len < 24) return error.Truncated;
    const cfg: Config = .{
        .frame_length = be32(c[0..]),
        .compatible_version = c[4],
        .bit_depth = c[5],
        .pb = c[6],
        .mb = c[7],
        .kb = c[8],
        .channels = c[9],
        .max_run = std.mem.readInt(u16, c[10..12], .big),
        .max_frame_bytes = be32(c[12..]),
        .avg_bit_rate = be32(c[16..]),
        .sample_rate = be32(c[20..]),
    };
    if (cfg.compatible_version > 0) return error.UnsupportedVersion;
    switch (cfg.bit_depth) {
        16, 20, 24, 32 => {},
        else => return error.UnsupportedFormat,
    }
    if (cfg.channels == 0 or cfg.channels > 8) return error.UnsupportedFormat;
    if (cfg.frame_length == 0 or cfg.frame_length > max_frame_length) return error.UnsupportedFormat;
    return cfg;
}

const testing = std.testing;

test "a bare config and one behind its atom header parse alike" {
    const bare = [24]u8{ 0, 0, 0x10, 0, 0, 16, 40, 10, 14, 2, 0, 255, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xAC, 0x44 };
    const a = try parse(&bare);
    try testing.expectEqual(@as(u32, 4096), a.frame_length);
    try testing.expectEqual(@as(u8, 16), a.bit_depth);
    try testing.expectEqual(@as(u8, 40), a.pb);
    try testing.expectEqual(@as(u16, 255), a.max_run);
    try testing.expectEqual(@as(u32, 44100), a.sample_rate);
    const boxed = [_]u8{ 0, 0, 0, 36, 'a', 'l', 'a', 'c', 0, 0, 0, 0 } ++ bare;
    try testing.expectEqual(a, try parse(&boxed));
}
