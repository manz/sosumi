//! Layer III side information: MPEG-1 (two granules, scfsi) and MPEG-2 / 2.5 (one granule,
//! 9-bit scalefac_compress).
const std = @import("std");
const bits = @import("../bits.zig");
const header = @import("header.zig");

pub const Error = bits.Error || error{ BigValuesTooLarge, ReservedBlockType };

pub const short_block = 2;

pub const Granule = struct {
    part2_3_length: u12 = 0,
    big_values: u9 = 0,
    global_gain: u8 = 0,
    scalefac_compress: u9 = 0,
    window_switching: bool = false,
    block_type: u2 = 0,
    mixed: bool = false,
    table_select: [3]u5 = @splat(0),
    subblock_gain: [3]u3 = @splat(0),
    region0_count: u4 = 0,
    region1_count: u5 = 0,
    preflag: bool = false,
    scalefac_scale: bool = false,
    count1_table_b: bool = false,

    pub fn isShort(g: Granule) bool {
        return g.window_switching and g.block_type == short_block;
    }
};

pub const SideInfo = struct {
    main_data_begin: u9 = 0,
    /// MPEG-1 only, per channel: reuse granule 0's scale factors in granule 1, per group.
    scfsi: [2]u4 = @splat(0),
    gr: [2][2]Granule = @splat(@splat(.{})),
};

fn readGranule(r: *bits.BitReader, mpeg1: bool) Error!Granule {
    var g: Granule = .{};
    g.part2_3_length = @intCast(try r.read(12));
    g.big_values = @intCast(try r.read(9));
    if (g.big_values > 288) return error.BigValuesTooLarge;
    g.global_gain = @intCast(try r.read(8));
    g.scalefac_compress = @intCast(try r.read(if (mpeg1) 4 else 9));
    g.window_switching = try r.readFlag();
    if (g.window_switching) {
        g.block_type = @intCast(try r.read(2));
        if (g.block_type == 0) return error.ReservedBlockType;
        g.mixed = try r.readFlag();
        for (g.table_select[0..2]) |*t| t.* = @intCast(try r.read(5));
        for (&g.subblock_gain) |*s| s.* = @intCast(try r.read(3));
        // implicit region counts: 36 samples (9 short entries, 8 long or mixed), then the rest
        g.region0_count = if (g.block_type == short_block and !g.mixed) 8 else 7;
        g.region1_count = 31;
    } else {
        for (&g.table_select) |*t| t.* = @intCast(try r.read(5));
        g.region0_count = @intCast(try r.read(4));
        g.region1_count = @intCast(try r.read(3));
    }
    // MPEG-2 has no preflag bit; the scale factor decoder derives it
    if (mpeg1) g.preflag = try r.readFlag();
    g.scalefac_scale = try r.readFlag();
    g.count1_table_b = try r.readFlag();
    return g;
}

pub fn read(r: *bits.BitReader, h: header.Header) Error!SideInfo {
    var si: SideInfo = .{};
    const nch = h.channels();
    const mpeg1 = h.version == .mpeg1;
    if (mpeg1) {
        si.main_data_begin = @intCast(try r.read(9));
        try r.skip(if (nch == 1) 5 else 3);
        for (0..nch) |ch| si.scfsi[ch] = @intCast(try r.read(4));
    } else {
        si.main_data_begin = @intCast(try r.read(8));
        try r.skip(if (nch == 1) 1 else 2);
    }
    for (0..h.granules()) |gr| {
        for (0..nch) |ch| si.gr[gr][ch] = try readGranule(r, mpeg1);
    }
    return si;
}

const testing = std.testing;

test "side information lengths add up to the header's count" {
    // MPEG-1 stereo: 9 + 3 + 2*4 + 2 granules * 2 channels * 59 bits = 256 bits = 32 bytes
    var zero: [32]u8 = @splat(0);
    var r = bits.BitReader.init(&zero);
    const h = try header.parse(&.{ 0xFF, 0xFB, 0x90, 0x04 });
    _ = try read(&r, h);
    try testing.expectEqual(h.sideInfoLen() * 8, r.pos);
}

test "MPEG-2 mono side information is 9 bytes" {
    var zero: [9]u8 = @splat(0);
    var r = bits.BitReader.init(&zero);
    const h = try header.parse(&.{ 0xFF, 0xF3, 0x90, 0xC4 });
    _ = try read(&r, h);
    try testing.expectEqual(@as(usize, 72), r.pos);
}
