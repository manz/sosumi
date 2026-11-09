//! Scale factors, one per band entry (bands.zig). MPEG-1: slen1 / slen2 from scalefac_compress,
//! scfsi reuse in granule 1 (ISO/IEC 11172-3). MPEG-2 / 2.5: the partition tables of ISO/IEC
//! 13818-3, decoded the way minimp3 does (CC0): g_mod gives the slen of each partition,
//! g_scf_partitions the number of entries in it.
const std = @import("std");
const bits = @import("../bits.zig");
const header = @import("header.zig");
const sideinfo = @import("sideinfo.zig");
const bands = @import("bands.zig");

pub const max_entries = 40;

pub const Scalefactors = struct {
    sf: [max_entries]u8 = @splat(0),
    /// MPEG-2 intensity positions: the value was the largest its slen allows (no intensity).
    illegal: [max_entries]bool = @splat(false),
    /// MPEG-2 derives preflag from scalefac_compress.
    preflag: bool = false,
};

pub const slen = [2][16]u3{
    .{ 0, 0, 0, 0, 3, 1, 1, 1, 2, 2, 2, 3, 3, 3, 4, 4 },
    .{ 0, 1, 2, 3, 0, 1, 2, 3, 1, 2, 3, 1, 2, 3, 2, 3 },
};

/// Entries per partition: row 0 long, 1 mixed, 2 short; group 0 is MPEG-1, groups 1..3 MPEG-2,
/// groups 4..6 MPEG-2 intensity right channel.
pub const partitions = [3][28]u8{
    .{ 6, 5, 5, 5, 6, 5, 5, 5, 6, 5, 7, 3, 11, 10, 0, 0, 7, 7, 7, 0, 6, 6, 6, 3, 8, 8, 5, 0 },
    .{ 8, 9, 6, 12, 6, 9, 9, 9, 6, 9, 12, 6, 15, 18, 0, 0, 6, 15, 12, 0, 6, 12, 9, 6, 6, 18, 9, 0 },
    .{ 9, 9, 6, 12, 9, 9, 9, 9, 9, 9, 12, 6, 18, 18, 0, 0, 12, 12, 12, 0, 12, 9, 9, 6, 15, 12, 9, 0 },
};

pub const g_mod = [24]u8{ 5, 5, 4, 4, 5, 5, 4, 1, 4, 3, 1, 1, 5, 6, 6, 1, 4, 4, 4, 1, 4, 3, 1, 1 };

/// Reads one channel's scale factors. `prev` holds the channel's previous granule values (scfsi
/// source) and receives this granule's. `use_scfsi` is the channel's scfsi in MPEG-1 granule 1.
pub fn read(r: *bits.BitReader, h: header.Header, g: sideinfo.Granule, ch: usize, use_scfsi: u4, prev: *[max_entries]u8) bits.Error!Scalefactors {
    const b = bands.of(h, g);
    const row: usize = @as(usize, @intFromBool(b.n_short != 0)) + @intFromBool(b.n_long == 0);
    var sizes: [4]u3 = undefined;
    var counts: []const u8 = undefined;
    var scfsi: u4 = 0;
    var mpeg2 = false;
    var out: Scalefactors = .{};
    if (h.version == .mpeg1) {
        const c = g.scalefac_compress;
        sizes = .{ slen[0][c], slen[0][c], slen[1][c], slen[1][c] };
        counts = partitions[row][0..4];
        if (!g.isShort()) scfsi = use_scfsi;
    } else {
        mpeg2 = true;
        const ist = h.intensityStereo() and ch == 1;
        var sfc: i32 = g.scalefac_compress >> @intFromBool(ist);
        var k: usize = if (ist) 12 else 0;
        var group: usize = 0;
        while (sfc >= 0) : ({
            k += 4;
            group += 1;
        }) {
            var modprod: i32 = 1;
            var i: usize = 4;
            while (i > 0) {
                i -= 1;
                sizes[i] = @intCast(@mod(@divTrunc(sfc, modprod), g_mod[k + i]));
                modprod *= g_mod[k + i];
            }
            sfc -= modprod;
        }
        counts = partitions[row][k .. k + 4];
        // ISO/IEC 13818-3: the third partition set of a non-intensity channel implies preflag
        out.preflag = !ist and group == 3;
    }
    var e: usize = 0;
    for (0..4) |part| {
        const cnt = counts[part];
        if (cnt == 0) break;
        const reuse = scfsi & (@as(u4, 8) >> @intCast(part)) != 0;
        for (0..cnt) |_| {
            if (reuse) {
                out.sf[e] = prev[e];
            } else if (sizes[part] == 0) {
                out.sf[e] = 0;
            } else {
                const v: u8 = @intCast(try r.read(sizes[part]));
                out.sf[e] = v;
                if (mpeg2) out.illegal[e] = v == (@as(u8, 1) << sizes[part]) - 1;
            }
            prev[e] = out.sf[e];
            e += 1;
        }
    }
    return out;
}

const testing = std.testing;

test "MPEG-1 long block: 11 slen1 values then 10 slen2, the last band zero" {
    // scalefac_compress 15: slen1 4, slen2 3; all ones
    var buf: [16]u8 = @splat(0xFF);
    var r = bits.BitReader.init(&buf);
    const h = try header.parse(&.{ 0xFF, 0xFB, 0x90, 0xC4 });
    var prev: [max_entries]u8 = @splat(0);
    const s = try read(&r, h, .{ .scalefac_compress = 15 }, 0, 0, &prev);
    try testing.expectEqual(@as(usize, 11 * 4 + 10 * 3), r.pos);
    try testing.expectEqual(@as(u8, 15), s.sf[10]);
    try testing.expectEqual(@as(u8, 7), s.sf[11]);
    try testing.expectEqual(@as(u8, 0), s.sf[21]);
}

test "scfsi reuses granule 0's group and reads nothing for it" {
    var buf: [16]u8 = @splat(0);
    var r = bits.BitReader.init(&buf);
    const h = try header.parse(&.{ 0xFF, 0xFB, 0x90, 0xC4 });
    var prev: [max_entries]u8 = @splat(9);
    const s = try read(&r, h, .{ .scalefac_compress = 15 }, 0, 0b1000, &prev);
    try testing.expectEqual(@as(u8, 9), s.sf[5]);
    try testing.expectEqual(@as(usize, 5 * 4 + 10 * 3), r.pos);
}

test "MPEG-2 scalefac_compress 500 picks the third partition set and preflag" {
    var buf: [16]u8 = @splat(0);
    var r = bits.BitReader.init(&buf);
    const h = try header.parse(&.{ 0xFF, 0xF3, 0x90, 0xC4 });
    var prev: [max_entries]u8 = @splat(0);
    const s = try read(&r, h, .{ .scalefac_compress = 500 }, 0, 0, &prev);
    try testing.expect(s.preflag);
    // 500: slen 0, 0, 0, 0 (sfc 0 in group 3 -> sizes from g_mod 4,3,1,1 all 0)
    try testing.expectEqual(@as(usize, 0), r.pos);
}
