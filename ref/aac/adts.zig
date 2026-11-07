//! ADTS framing (ISO/IEC 13818-7 6.2, 14496-3 1.A.2): the fixed and variable header, enough to
//! cut a file into raw access units and to rebuild its AudioSpecificConfig.
const std = @import("std");

pub const Error = error{ NotAdts, MultipleRawBlocks };

pub const Header = struct {
    /// The two-byte AudioSpecificConfig the header implies.
    config: [2]u8,
    header_len: usize,
    frame_len: usize,

    pub fn freqIndex(self: Header) u4 {
        return @intCast((self.config[0] & 7) << 1 | self.config[1] >> 7);
    }

    pub fn channelConfig(self: Header) u4 {
        return @intCast(self.config[1] >> 3 & 0xF);
    }
};

pub fn parse(b: []const u8) Error!Header {
    if (b.len < 7 or b[0] != 0xFF or b[1] & 0xF6 != 0xF0) return error.NotAdts;
    const protection_absent = b[1] & 1 == 1;
    const profile: u8 = b[2] >> 6; // audio object type - 1
    const freq: u8 = (b[2] >> 2) & 0xF;
    const chans: u8 = ((b[2] & 1) << 2) | (b[3] >> 6);
    const frame_len: usize = (@as(usize, b[3] & 3) << 11) | (@as(usize, b[4]) << 3) | (b[5] >> 5);
    if (b[6] & 3 != 0) return error.MultipleRawBlocks;
    const aot = profile + 1;
    return .{
        .config = .{ (aot << 3) | (freq >> 1), ((freq & 1) << 7) | (chans << 3) },
        .header_len = if (protection_absent) 7 else 9,
        .frame_len = frame_len,
    };
}

const testing = std.testing;

test "an LC 44.1 kHz stereo header gives ASC 12 10" {
    // FFF1, LC, index 4, 2 channels, frame length 0x2AA + 7, one raw block
    const len: usize = 0x2AA + 7;
    const h = try parse(&.{ 0xFF, 0xF1, 0x50, 0x80 | @as(u8, @intCast(len >> 11)), @intCast(len >> 3 & 0xFF), @intCast((len & 7) << 5 | 0x1F), 0xFC });
    try testing.expectEqual([2]u8{ 0x12, 0x10 }, h.config);
    try testing.expectEqual(@as(usize, 7), h.header_len);
    try testing.expectEqual(len, h.frame_len);
    try testing.expectEqual(@as(u4, 4), h.freqIndex());
    try testing.expectEqual(@as(u4, 2), h.channelConfig());
}

test "a missing sync word is not ADTS" {
    try testing.expectError(error.NotAdts, parse(&.{ 0xFF, 0xE1, 0x50, 0x80, 0, 0, 0 }));
}

test "two raw blocks in one frame are refused" {
    try testing.expectError(error.MultipleRawBlocks, parse(&.{ 0xFF, 0xF1, 0x50, 0x80, 0, 0x1F, 0xFD }));
}
