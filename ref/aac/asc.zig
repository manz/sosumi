//! AudioSpecificConfig and GASpecificConfig (ISO/IEC 14496-3), AAC-LC only.
const std = @import("std");
const bits = @import("../bits.zig");

pub const Error = bits.Error || error{
    UnsupportedObjectType,
    ReservedFrequencyIndex,
    ProgramConfigNotSupported,
};

pub const aac_lc: u8 = 2;

/// samplingFrequencyIndex 0x0..0xC (ISO/IEC 14496-3); 0xD and 0xE are reserved, 0xF is explicit.
pub const sample_rates = [13]u32{
    96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350,
};

pub const Asc = struct {
    object_type: u8,
    freq_index: u4,
    sample_rate: u32,
    channel_config: u4,
    frame_length: u16,
    core_coder_delay: ?u14,
    extension_flag: bool,
};

pub fn parse(r: *bits.BitReader) Error!Asc {
    const object_type = try readObjectType(r);
    const freq_index: u4 = @intCast(try r.read(4));
    const sample_rate = try readSampleRate(r, freq_index);
    const channel_config: u4 = @intCast(try r.read(4));
    if (object_type != aac_lc) return error.UnsupportedObjectType;
    if (channel_config == 0) return error.ProgramConfigNotSupported;

    // GASpecificConfig
    const frame_length: u16 = if (try r.readFlag()) 960 else 1024;
    const core_coder_delay: ?u14 = if (try r.readFlag()) @intCast(try r.read(14)) else null;
    const extension_flag = try r.readFlag();
    return .{
        .object_type = object_type,
        .freq_index = freq_index,
        .sample_rate = sample_rate,
        .channel_config = channel_config,
        .frame_length = frame_length,
        .core_coder_delay = core_coder_delay,
        .extension_flag = extension_flag,
    };
}

/// The device's acceptance rule (specs/aac.md, "What the device accepts"): AAC-LC, and a
/// frequency index above 2 that is not reserved.
pub fn deviceAccepts(asc: Asc) bool {
    return asc.object_type == aac_lc and asc.freq_index > 2 and
        asc.freq_index != 0xD and asc.freq_index != 0xE;
}

fn readObjectType(r: *bits.BitReader) Error!u8 {
    const t: u8 = @intCast(try r.read(5));
    if (t != 31) return t;
    return 32 + @as(u8, @intCast(try r.read(6)));
}

fn readSampleRate(r: *bits.BitReader, index: u4) Error!u32 {
    return switch (index) {
        0xF => try r.read(24),
        0xD, 0xE => error.ReservedFrequencyIndex,
        else => sample_rates[index],
    };
}

const testing = std.testing;

fn parseBytes(bytes: []const u8) Error!Asc {
    var r = bits.BitReader.init(bytes);
    return parse(&r);
}

test "AAC-LC 44.1 kHz stereo" {
    const asc = try parseBytes(&.{ 0x12, 0x10 });
    try testing.expectEqual(aac_lc, asc.object_type);
    try testing.expectEqual(@as(u32, 44100), asc.sample_rate);
    try testing.expectEqual(@as(u4, 2), asc.channel_config);
    try testing.expectEqual(@as(u16, 1024), asc.frame_length);
    try testing.expectEqual(@as(?u14, null), asc.core_coder_delay);
    try testing.expect(deviceAccepts(asc));
}

test "AAC-LC 48 kHz stereo" {
    const asc = try parseBytes(&.{ 0x11, 0x90 });
    try testing.expectEqual(@as(u32, 48000), asc.sample_rate);
}

test "HE-AAC (object type 5) is refused" {
    try testing.expectError(error.UnsupportedObjectType, parseBytes(&.{ 0x2A, 0x10 }));
}

test "96 kHz parses but the device refuses it" {
    const asc = try parseBytes(&.{ 0x10, 0x10 });
    try testing.expectEqual(@as(u32, 96000), asc.sample_rate);
    try testing.expect(!deviceAccepts(asc));
}

test "reserved frequency index is an error" {
    // object type 2, index 0xD
    try testing.expectError(error.ReservedFrequencyIndex, parseBytes(&.{ 0x16, 0x90 }));
}
