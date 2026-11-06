//! Layer III frame header (ISO/IEC 11172-3, 13818-3), with the device's rules where they differ
//! (specs/mp3.md, "What the device accepts"): sync on 11 bits, free format played as 128 kbps.
const std = @import("std");

pub const Error = error{ NoSync, ReservedVersion, NotLayer3, BadBitrate, ReservedSampleRate, Truncated };

pub const Version = enum { mpeg1, mpeg2, mpeg25 };
pub const Mode = enum(u2) { stereo, joint_stereo, dual_channel, single_channel };

const bitrates = [2][15]u16{
    .{ 0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160 }, // MPEG-2 and 2.5
    .{ 0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320 }, // MPEG-1
};
const base_rates = [3]u32{ 44100, 48000, 32000 };

pub const Header = struct {
    version: Version,
    crc: bool,
    bitrate_index: u4,
    sr_index: u2,
    padding: bool,
    mode: Mode,
    mode_ext: u2,

    pub fn sampleRate(h: Header) u32 {
        return switch (h.version) {
            .mpeg1 => base_rates[h.sr_index],
            .mpeg2 => base_rates[h.sr_index] / 2,
            .mpeg25 => base_rates[h.sr_index] / 4,
        };
    }

    pub fn channels(h: Header) u2 {
        return if (h.mode == .single_channel) 1 else 2;
    }

    pub fn granules(h: Header) u2 {
        return if (h.version == .mpeg1) 2 else 1;
    }

    pub fn samples(h: Header) u16 {
        return 576 * @as(u16, h.granules());
    }

    pub fn msStereo(h: Header) bool {
        return h.mode == .joint_stereo and h.mode_ext & 2 != 0;
    }

    pub fn intensityStereo(h: Header) bool {
        return h.mode == .joint_stereo and h.mode_ext & 1 != 0;
    }

    pub fn sideInfoLen(h: Header) usize {
        const mono = h.mode == .single_channel;
        return if (h.version == .mpeg1) (if (mono) 17 else 32) else (if (mono) 9 else 17);
    }

    /// Bytes before main data: header, CRC word, side information.
    pub fn mainDataOffset(h: Header) usize {
        return 4 + @as(usize, if (h.crc) 2 else 0) + h.sideInfoLen();
    }

    /// Free format (index 0) counts as 128 kbps, as the device's reader does.
    pub fn bitrateKbps(h: Header) u32 {
        if (h.bitrate_index == 0) return 128;
        return bitrates[@intFromBool(h.version == .mpeg1)][h.bitrate_index];
    }

    pub fn frameLen(h: Header) usize {
        const slots: u32 = if (h.version == .mpeg1) 144 else 72;
        return slots * h.bitrateKbps() * 1000 / h.sampleRate() + @intFromBool(h.padding);
    }

    /// Row of the scale factor band tables (minimp3's numbering: 2.5 at 11.025 and 12 kHz, 2.5
    /// at 8 kHz, 2 at 22.05, 24, 16 kHz, 1 at 44.1, 48, 32 kHz).
    pub fn sfbRow(h: Header) u3 {
        const v: u32 = switch (h.version) {
            .mpeg25 => 0,
            .mpeg2 => 1,
            .mpeg1 => 2,
        };
        const my = @as(u32, h.sr_index) + 3 * v;
        return @intCast(my - @intFromBool(my != 0));
    }
};

pub fn parse(b: []const u8) Error!Header {
    if (b.len < 4) return error.Truncated;
    if (b[0] != 0xFF or b[1] & 0xE0 != 0xE0) return error.NoSync;
    const version: Version = switch ((b[1] >> 3) & 3) {
        0 => .mpeg25,
        1 => return error.ReservedVersion,
        2 => .mpeg2,
        else => .mpeg1,
    };
    if ((b[1] >> 1) & 3 != 1) return error.NotLayer3;
    const bitrate_index: u4 = @intCast(b[2] >> 4);
    if (bitrate_index == 15) return error.BadBitrate;
    const sr_index: u2 = @intCast((b[2] >> 2) & 3);
    if (sr_index == 3) return error.ReservedSampleRate;
    return .{
        .version = version,
        .crc = b[1] & 1 == 0,
        .bitrate_index = bitrate_index,
        .sr_index = sr_index,
        .padding = b[2] & 2 != 0,
        .mode = @fromBackingInt(@intCast(b[3] >> 6)),
        .mode_ext = @intCast((b[3] >> 4) & 3),
    };
}

const testing = std.testing;

test "the podcast's header: MPEG-1, 128 kbps, 44.1 kHz, 417 and 418 bytes" {
    const h = try parse(&.{ 0xFF, 0xFB, 0x90, 0x64 });
    try testing.expectEqual(Version.mpeg1, h.version);
    try testing.expectEqual(@as(u32, 44100), h.sampleRate());
    try testing.expectEqual(@as(usize, 417), h.frameLen());
    try testing.expectEqual(@as(usize, 418), (try parse(&.{ 0xFF, 0xFB, 0x92, 0x64 })).frameLen());
    try testing.expectEqual(@as(u3, 5), h.sfbRow());
    try testing.expectEqual(Mode.joint_stereo, h.mode);
}

test "MPEG-2.5 at 8 kHz, free format as 128 kbps, and the rejections" {
    const h = try parse(&.{ 0xFF, 0xE3, 0x08, 0xC0 });
    try testing.expectEqual(@as(u32, 8000), h.sampleRate());
    try testing.expectEqual(@as(u32, 128), h.bitrateKbps());
    try testing.expectEqual(@as(u3, 1), h.sfbRow());
    try testing.expectEqual(@as(u2, 1), h.channels());
    try testing.expectError(error.NotLayer3, parse(&.{ 0xFF, 0xFD, 0x90, 0x64 }));
    try testing.expectError(error.BadBitrate, parse(&.{ 0xFF, 0xFB, 0xF0, 0x64 }));
    try testing.expectError(error.ReservedVersion, parse(&.{ 0xFF, 0xEB, 0x90, 0x64 }));
}
