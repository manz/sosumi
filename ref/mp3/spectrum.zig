//! Huffman-coded spectrum: big_values pairs in three regions, then count1 quadruples to the end
//! of part2_3_length (ISO/IEC 11172-3). Codewords go through the shared decoder.
const std = @import("std");
const bits = @import("../bits.zig");
const huffman = @import("../huffman.zig");
const tables = @import("tables/huffman.zig");
const sideinfo = @import("sideinfo.zig");
const bands = @import("bands.zig");

pub const Error = huffman.Error || error{InvalidTable};

pub const Spectrum = [576]i16;

fn value(r: *bits.BitReader, v: u16, linbits: u4) Error!i16 {
    var x: u16 = v;
    if (x == 15 and linbits > 0) x += @intCast(try r.read(linbits));
    if (x != 0 and try r.readFlag()) return -@as(i16, @intCast(x));
    return @intCast(x);
}

/// Decodes one granule-channel's spectrum. `limit` is the bit position where its part2_3 ends;
/// the reader is left there.
pub fn read(r: *bits.BitReader, g: sideinfo.Granule, b: bands.Bands, limit: usize) Error!Spectrum {
    var out: Spectrum = @splat(0);
    // region ends, in coefficients, from the band entries (minimp3's rule)
    var region_end: [3]usize = .{ 0, 0, 576 };
    var acc: usize = 0;
    for (b.widths, 0..) |w, e| {
        acc += w;
        if (e == g.region0_count) region_end[0] = acc;
        if (e == @as(usize, g.region0_count) + g.region1_count + 1) region_end[1] = acc;
    }
    if (region_end[0] == 0) region_end[0] = 576;
    if (region_end[1] == 0) region_end[1] = 576;

    const big = @as(usize, g.big_values) * 2;
    var i: usize = 0;
    while (i < big) : (i += 2) {
        const region: usize = if (i < region_end[0]) 0 else if (i < region_end[1]) 1 else 2;
        const t = g.table_select[region];
        const table = tables.pair[t] orelse {
            if (t == 0) continue;
            return error.InvalidTable;
        };
        const idx = try huffman.decode(r, table);
        const width = tables.width[t];
        out[i] = try value(r, idx / width, tables.linbits[t]);
        out[i + 1] = try value(r, idx % width, tables.linbits[t]);
    }

    const quad = if (g.count1_table_b) &tables.count1_b else &tables.count1_a;
    while (i + 4 <= 576 and r.pos < limit) : (i += 4) {
        const idx = try huffman.decode(r, quad);
        if (r.pos > limit) break; // a codeword straddling the end is discarded
        for (0..4) |k| {
            const bit = (idx >> @intCast(3 - k)) & 1;
            out[i + k] = if (bit == 0) 0 else if (try r.readFlag()) -1 else 1;
        }
    }
    r.pos = limit;
    return out;
}

const testing = std.testing;

test "every pair and count1 table is a complete prefix code" {
    for (tables.pair) |t| if (t) |table| try testing.expectEqual(@as(u64, 1) << huffman.max_len, huffman.kraft(table));
    try testing.expectEqual(@as(u64, 1) << huffman.max_len, huffman.kraft(&tables.count1_a));
    try testing.expectEqual(@as(u64, 1) << huffman.max_len, huffman.kraft(&tables.count1_b));
}

test "table 1 pair, sign, then a count1 quad to the limit" {
    // table1 (1,0) = "01", sign 1; (0,1) = "001", sign 0; count1 B "1110" (0,0,0,1) -> y, sign 1
    var buf: [4]u8 = .{ 0b01_1_001_0_1, 0b110_1_0000, 0, 0 };
    var r = bits.BitReader.init(&buf);
    const g: sideinfo.Granule = .{ .big_values = 2, .table_select = .{ 1, 1, 1 }, .region0_count = 15, .region1_count = 7, .count1_table_b = true };
    const s = try read(&r, g, .{ .widths = &[_]u8{ 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 246, 246 }, .n_long = 22, .n_short = 0 }, 12);
    try testing.expectEqualSlices(i16, &.{ -1, 0, 0, 1 }, s[0..4]);
    try testing.expectEqualSlices(i16, &.{ 0, 0, 0, -1 }, s[4..8]);
    try testing.expectEqual(@as(usize, 12), r.pos);
}
