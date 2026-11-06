//! individual_channel_stream and channel_pair_element syntax (ISO/IEC 14496-3), AAC-LC.
//!
//! Parses everything that needs no codebook: ics_info, section_data, ms_mask, pulse_data,
//! tns_data. scale_factor_data and spectral_data need the Huffman tables; until they exist, a
//! channel whose sections use any codebook other than ZERO_HCB is refused.
const std = @import("std");
const bits = @import("bits.zig");

pub const Error = bits.Error || error{
    ReservedBitSet,
    PredictionNotInLc,
    GainControlNotInLc,
    ReservedCodebook,
    SectionOverrun,
    ReservedMsMask,
    PulseInShortWindow,
    TnsOrderTooHigh,
    NeedsHuffmanTables,
};

pub const WindowSequence = enum(u2) { only_long, long_start, eight_short, long_stop };

pub const max_groups = 8;
/// max_sfb is a 6-bit field.
pub const max_bands = 64;

pub const zero_hcb: u4 = 0;
pub const reserved_hcb: u4 = 12;

pub const IcsInfo = struct {
    window_sequence: WindowSequence,
    window_shape: u1,
    max_sfb: u6,
    num_window_groups: u4,
    group_len: [max_groups]u4,

    pub fn isShort(self: IcsInfo) bool {
        return self.window_sequence == .eight_short;
    }

    pub fn numWindows(self: IcsInfo) u4 {
        return if (self.isShort()) 8 else 1;
    }
};

pub fn readIcsInfo(r: *bits.BitReader) Error!IcsInfo {
    if (try r.readFlag()) return error.ReservedBitSet;
    var info: IcsInfo = .{
        .window_sequence = @enumFromInt(try r.read(2)),
        .window_shape = @intCast(try r.read(1)),
        .max_sfb = 0,
        .num_window_groups = 1,
        .group_len = @splat(0),
    };
    info.group_len[0] = 1;
    if (info.isShort()) {
        info.max_sfb = @intCast(try r.read(4));
        applyGrouping(&info, @intCast(try r.read(7)));
    } else {
        info.max_sfb = @intCast(try r.read(6));
        if (try r.readFlag()) return error.PredictionNotInLc;
    }
    return info;
}

/// scale_factor_grouping: bit (6 - i) set means window i + 1 joins the current group.
fn applyGrouping(info: *IcsInfo, grouping: u7) void {
    for (0..7) |i| {
        const joins = (grouping >> @intCast(6 - i)) & 1 == 1;
        if (joins) {
            info.group_len[info.num_window_groups - 1] += 1;
        } else {
            info.group_len[info.num_window_groups] = 1;
            info.num_window_groups += 1;
        }
    }
}

pub const Sections = struct {
    /// Codebook per group and band; bands at or past max_sfb stay ZERO_HCB.
    sfb_cb: [max_groups][max_bands]u4 = @splat(@splat(zero_hcb)),

    pub fn allZero(self: *const Sections, info: IcsInfo) bool {
        for (0..info.num_window_groups) |g| {
            for (0..info.max_sfb) |sfb| {
                if (self.sfb_cb[g][sfb] != zero_hcb) return false;
            }
        }
        return true;
    }
};

pub fn readSectionData(r: *bits.BitReader, info: IcsInfo) Error!Sections {
    const sect_bits: u6 = if (info.isShort()) 3 else 5;
    const esc: u32 = (@as(u32, 1) << @intCast(sect_bits)) - 1;
    var s: Sections = .{};
    for (0..info.num_window_groups) |g| {
        var k: u32 = 0;
        while (k < info.max_sfb) {
            const cb: u4 = @intCast(try r.read(4));
            if (cb == reserved_hcb) return error.ReservedCodebook;
            var len: u32 = 0;
            var incr = try r.read(sect_bits);
            while (incr == esc) : (incr = try r.read(sect_bits)) len += esc;
            len += incr;
            if (k + len > info.max_sfb) return error.SectionOverrun;
            for (k..k + len) |sfb| s.sfb_cb[g][sfb] = cb;
            k += len;
        }
    }
    return s;
}

pub const MsMask = struct {
    /// ms_mask_present: 0 none, 1 per band, 2 all bands.
    present: u2,
    used: [max_groups][max_bands]bool = @splat(@splat(false)),
};

pub fn readMsMask(r: *bits.BitReader, info: IcsInfo) Error!MsMask {
    var ms: MsMask = .{ .present = @intCast(try r.read(2)) };
    switch (ms.present) {
        0 => {},
        1 => for (0..info.num_window_groups) |g| {
            for (0..info.max_sfb) |sfb| ms.used[g][sfb] = try r.readFlag();
        },
        2 => for (0..info.num_window_groups) |g| {
            for (0..info.max_sfb) |sfb| ms.used[g][sfb] = true;
        },
        3 => return error.ReservedMsMask,
    }
    return ms;
}

pub const Pulse = struct {
    count: u3,
    start_sfb: u6,
    offset: [4]u5 = @splat(0),
    amp: [4]u4 = @splat(0),
};

pub fn readPulse(r: *bits.BitReader, info: IcsInfo) Error!Pulse {
    if (info.isShort()) return error.PulseInShortWindow;
    var p: Pulse = .{
        .count = @intCast(try r.read(2) + 1),
        .start_sfb = @intCast(try r.read(6)),
    };
    for (0..p.count) |i| {
        p.offset[i] = @intCast(try r.read(5));
        p.amp[i] = @intCast(try r.read(4));
    }
    return p;
}

/// TNS_MAX_ORDER for AAC-LC: 12 for long windows, 7 for short.
pub const tns_max_order_long = 12;
pub const tns_max_order_short = 7;

pub const TnsFilter = struct {
    length: u6 = 0,
    order: u5 = 0,
    direction: bool = false,
    coef_compress: bool = false,
    coef: [tns_max_order_long]u4 = @splat(0),
};

pub const TnsWindow = struct {
    n_filt: u2 = 0,
    coef_res: u1 = 0,
    filt: [3]TnsFilter = @splat(.{}),
};

pub const Tns = struct {
    windows: [8]TnsWindow = @splat(.{}),
};

pub fn readTns(r: *bits.BitReader, info: IcsInfo) Error!Tns {
    const short = info.isShort();
    const n_filt_bits: u6 = if (short) 1 else 2;
    const length_bits: u6 = if (short) 4 else 6;
    const order_bits: u6 = if (short) 3 else 5;
    const max_order: u32 = if (short) tns_max_order_short else tns_max_order_long;
    var t: Tns = .{};
    for (0..info.numWindows()) |w| {
        const win = &t.windows[w];
        win.n_filt = @intCast(try r.read(n_filt_bits));
        if (win.n_filt == 0) continue;
        win.coef_res = @intCast(try r.read(1));
        for (win.filt[0..win.n_filt]) |*f| {
            f.length = @intCast(try r.read(length_bits));
            const order = try r.read(order_bits);
            if (order > max_order) return error.TnsOrderTooHigh;
            f.order = @intCast(order);
            if (order == 0) continue;
            f.direction = try r.readFlag();
            f.coef_compress = try r.readFlag();
            const coef_bits: u6 = @as(u6, win.coef_res) + 3 - @intFromBool(f.coef_compress);
            for (f.coef[0..order]) |*c| c.* = @intCast(try r.read(coef_bits));
        }
    }
    return t;
}

pub const Channel = struct {
    global_gain: u8,
    info: IcsInfo,
    sections: Sections,
    pulse: ?Pulse,
    tns: ?Tns,
};

/// individual_channel_stream(common_window, scale_flag = 0). `common` is the CPE's shared
/// ics_info when common_window is set.
pub fn readChannel(r: *bits.BitReader, common: ?IcsInfo) Error!Channel {
    const global_gain: u8 = @intCast(try r.read(8));
    const info = common orelse try readIcsInfo(r);
    const sections = try readSectionData(r, info);
    // scale_factor_data, and later spectral_data, read nothing when every band is ZERO_HCB.
    if (!sections.allZero(info)) return error.NeedsHuffmanTables;
    const pulse: ?Pulse = if (try r.readFlag()) try readPulse(r, info) else null;
    const tns: ?Tns = if (try r.readFlag()) try readTns(r, info) else null;
    if (try r.readFlag()) return error.GainControlNotInLc;
    return .{ .global_gain = global_gain, .info = info, .sections = sections, .pulse = pulse, .tns = tns };
}

pub const ChannelPair = struct {
    common_window: bool,
    ms: ?MsMask,
    left: Channel,
    right: Channel,
};

/// channel_pair_element() body, after its tag.
pub fn readChannelPair(r: *bits.BitReader) Error!ChannelPair {
    const common_window = try r.readFlag();
    var common: ?IcsInfo = null;
    var ms: ?MsMask = null;
    if (common_window) {
        common = try readIcsInfo(r);
        ms = try readMsMask(r, common.?);
    }
    const left = try readChannel(r, common);
    const right = try readChannel(r, common);
    return .{ .common_window = common_window, .ms = ms, .left = left, .right = right };
}

const testing = std.testing;

/// Packs a string of '0'/'1' (spaces ignored) into `buf`, MSB first.
fn pack(buf: []u8, s: []const u8) []const u8 {
    @memset(buf, 0);
    var n: usize = 0;
    for (s) |c| {
        if (c == ' ') continue;
        if (c == '1') buf[n >> 3] |= @as(u8, 0x80) >> @intCast(n & 7);
        n += 1;
    }
    return buf[0 .. (n + 7) / 8];
}

fn longInfo(max_sfb: u6) IcsInfo {
    var info: IcsInfo = .{
        .window_sequence = .only_long,
        .window_shape = 0,
        .max_sfb = max_sfb,
        .num_window_groups = 1,
        .group_len = @splat(0),
    };
    info.group_len[0] = 1;
    return info;
}

test "short ics_info groups windows from scale_factor_grouping" {
    var buf: [8]u8 = undefined;
    var r = bits.BitReader.init(pack(&buf, "0 10 1 1010 1011000"));
    const info = try readIcsInfo(&r);
    try testing.expect(info.isShort());
    try testing.expectEqual(@as(u1, 1), info.window_shape);
    try testing.expectEqual(@as(u6, 10), info.max_sfb);
    try testing.expectEqual(@as(u4, 5), info.num_window_groups);
    try testing.expectEqualSlices(u4, &.{ 2, 3, 1, 1, 1 }, info.group_len[0..5]);
}

test "long ics_info with predictor_data_present is not LC" {
    var buf: [8]u8 = undefined;
    var r = bits.BitReader.init(pack(&buf, "0 00 0 000001 1"));
    try testing.expectError(error.PredictionNotInLc, readIcsInfo(&r));
}

test "ics_reserved_bit set is refused" {
    var buf: [8]u8 = undefined;
    var r = bits.BitReader.init(pack(&buf, "1 00 0 000001 0"));
    try testing.expectError(error.ReservedBitSet, readIcsInfo(&r));
}

test "section length escapes add up" {
    var buf: [8]u8 = undefined;
    // cb 1, length 31 + 9 = 40
    var r = bits.BitReader.init(pack(&buf, "0001 11111 01001"));
    const s = try readSectionData(&r, longInfo(40));
    try testing.expectEqual(@as(u4, 1), s.sfb_cb[0][0]);
    try testing.expectEqual(@as(u4, 1), s.sfb_cb[0][39]);
    try testing.expectEqual(@as(u4, 0), s.sfb_cb[0][40]);
}

test "a section running past max_sfb is refused" {
    var buf: [8]u8 = undefined;
    var r = bits.BitReader.init(pack(&buf, "0001 00100"));
    try testing.expectError(error.SectionOverrun, readSectionData(&r, longInfo(3)));
}

test "codebook 12 is reserved" {
    var buf: [8]u8 = undefined;
    var r = bits.BitReader.init(pack(&buf, "1100 00011"));
    try testing.expectError(error.ReservedCodebook, readSectionData(&r, longInfo(3)));
}

test "ms_mask per band, and the reserved value" {
    var buf: [8]u8 = undefined;
    var r = bits.BitReader.init(pack(&buf, "01 1 0"));
    const ms = try readMsMask(&r, longInfo(2));
    try testing.expect(ms.used[0][0]);
    try testing.expect(!ms.used[0][1]);
    var r2 = bits.BitReader.init(pack(&buf, "11"));
    try testing.expectError(error.ReservedMsMask, readMsMask(&r2, longInfo(2)));
}

test "pulse_data reads count + 1 pulses and is refused in short windows" {
    var buf: [8]u8 = undefined;
    var r = bits.BitReader.init(pack(&buf, "01 000101 00011 0010 00001 0001"));
    const p = try readPulse(&r, longInfo(10));
    try testing.expectEqual(@as(u3, 2), p.count);
    try testing.expectEqual(@as(u6, 5), p.start_sfb);
    try testing.expectEqual(@as(u5, 3), p.offset[0]);
    try testing.expectEqual(@as(u4, 1), p.amp[1]);
    var short = longInfo(10);
    short.window_sequence = .eight_short;
    var r2 = bits.BitReader.init(pack(&buf, "00 000000"));
    try testing.expectError(error.PulseInShortWindow, readPulse(&r2, short));
}

test "tns_data long filter with 4-bit coefficients" {
    var buf: [8]u8 = undefined;
    // n_filt 1, coef_res 1, length 20, order 2, direction 1, compress 0, coefs 7 and 9
    var r = bits.BitReader.init(pack(&buf, "01 1 010100 00010 1 0 0111 1001"));
    const t = try readTns(&r, longInfo(10));
    const f = t.windows[0].filt[0];
    try testing.expectEqual(@as(u6, 20), f.length);
    try testing.expectEqual(@as(u5, 2), f.order);
    try testing.expect(f.direction);
    try testing.expectEqualSlices(u4, &.{ 7, 9 }, f.coef[0..2]);
    try testing.expectEqual(@as(usize, 0), r.bitsLeft()); // all 24 bits consumed
}

test "tns order above the LC limit is refused" {
    var buf: [8]u8 = undefined;
    var r = bits.BitReader.init(pack(&buf, "01 1 010100 01101"));
    try testing.expectError(error.TnsOrderTooHigh, readTns(&r, longInfo(10)));
}

test "a channel with a non-zero codebook needs the Huffman tables" {
    var buf: [8]u8 = undefined;
    // global_gain 100, long ics_info max_sfb 1, section cb 1 length 1
    var r = bits.BitReader.init(pack(&buf, "01100100 0 00 0 000001 0 0001 00001"));
    try testing.expectError(error.NeedsHuffmanTables, readChannel(&r, null));
}

test "the device's priming access unit is a silent common-window CPE" {
    var r = bits.BitReader.init(&.{ 0x21, 0x00, 0x03, 0x40, 0x68, 0x1c });
    try r.skip(7); // CPE header, tag 0
    const cpe = try readChannelPair(&r);
    try testing.expect(cpe.common_window);
    try testing.expectEqual(@as(u2, 0), cpe.ms.?.present);
    try testing.expectEqual(WindowSequence.only_long, cpe.left.info.window_sequence);
    try testing.expectEqual(@as(u6, 0), cpe.left.info.max_sfb);
    try testing.expectEqual(@as(u8, 104), cpe.left.global_gain);
    try testing.expectEqual(@as(u8, 104), cpe.right.global_gain);
    try testing.expectEqual(@as(?Pulse, null), cpe.right.pulse);
    try testing.expectEqual(@as(u32, 0b111), try r.read(3)); // END
}
