//! The MP3 program's data tables, from the reference model's rules.
const std = @import("std");
const ref = @import("ref");

const header = ref.mp3.header;

/// MP_FLEN: [MPEG-1, MPEG-2, MPEG-2.5][sr_index 0..2][bitrate_index 0..14] -> the frame's bytes
/// without padding (ref/mp3/header.zig frameLen, free format as 128 kbps).
pub const flen: [135]u16 = blk: {
    @setEvalBranchQuota(100000);
    var t: [135]u16 = undefined;
    for ([_]header.Version{ .mpeg1, .mpeg2, .mpeg25 }, 0..) |v, row| {
        for (0..3) |sr| for (0..15) |br| {
            const h: header.Header = .{ .version = v, .crc = false, .bitrate_index = br, .sr_index = sr, .padding = false, .mode = .stereo, .mode_ext = 0 };
            t[row * 45 + sr * 15 + br] = @intCast(h.frameLen());
        };
    }
    break :blk t;
};

/// The frames of an MP3 file: ID3v2 skipped, then header to header.
pub fn frames(gpa: std.mem.Allocator, file: []const u8) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(gpa);
    var pos: usize = 0;
    if (file.len > 10 and std.mem.eql(u8, file[0..3], "ID3")) {
        const size = (@as(usize, file[6]) << 21) | (@as(usize, file[7]) << 14) | (@as(usize, file[8]) << 7) | file[9];
        pos = 10 + size + @as(usize, if (file[5] & 0x10 != 0) 10 else 0);
    }
    while (pos + 4 <= file.len) {
        const h = header.parse(file[pos..]) catch {
            pos += 1;
            continue;
        };
        const len = h.frameLen();
        if (pos + len > file.len) break;
        try out.append(gpa, file[pos .. pos + len]);
        pos += len;
    }
    return out.toOwnedSlice(gpa);
}

const sfs = ref.mp3.scalefactors;

/// MP_SLEN: slen1[16] then slen2[16], by scalefac_compress.
pub const slen: [32]u16 = blk: {
    var t: [32]u16 = undefined;
    for (0..2) |r| for (0..16) |c| {
        t[r * 16 + c] = sfs.slen[r][c];
    };
    break :blk t;
};

/// MP_PART: entries per partition, [long, mixed, short][28].
pub const part: [84]u16 = blk: {
    var t: [84]u16 = undefined;
    for (0..3) |r| for (0..28) |c| {
        t[r * 28 + c] = sfs.partitions[r][c];
    };
    break :blk t;
};

/// MP_GMOD: the MPEG-2 partition radices.
pub const gmod: [24]u16 = blk: {
    var t: [24]u16 = undefined;
    for (&t, sfs.g_mod) |*d, v| d.* = v;
    break :blk t;
};

const tree = ref.dsp.huffman;
const ht = ref.mp3.tables.huffman;

fn ident(i: usize) u16 {
    return @intCast(i);
}

fn pairValue(comptime w: usize) fn (usize) u16 {
    return struct {
        fn f(i: usize) u16 {
            return @intCast((i / w) * 16 + i % w);
        }
    }.f;
}

/// The distinct pair codes (ISO/IEC 11172-3 Table B.7) and each one's root width, the smallest
/// tree's (lib/huffman.sm's format); count1 A and B after them.
pub const codes = [_]u8{ 1, 2, 3, 5, 6, 7, 8, 9, 10, 11, 12, 13, 15, 16, 24 };
const roots = [_]u4{ 3, 4, 4, 4, 4, 5, 5, 5, 6, 6, 5, 5, 6, 3, 7, 4, 4 };

/// Leaf values: x * 16 + y for a pair, vwxy for a quadruple.
pub const trees: [codes.len + 2]tree.Table = blk: {
    var t: [codes.len + 2]tree.Table = undefined;
    for (codes, 0..) |c, i| t[i] = tree.makeTable(ht.pair[c].?, roots[i], pairValue(ht.width[c]));
    t[codes.len] = tree.makeTable(&ht.count1_a, roots[codes.len], ident);
    t[codes.len + 1] = tree.makeTable(&ht.count1_b, roots[codes.len + 1], ident);
    break :blk t;
};

const bands = ref.mp3.bands;

/// The band width lists, each ending in a 0 (ref/mp3/bands.zig, identical lists stored once),
/// and MP_BP: [version bits 0..3][sr_index][long, short, mixed] -> a list's offset in them.
const BandLists = struct { words: [800]u16, n: usize, at: [36]u16 };
pub const band_lists: BandLists = blk: {
    @setEvalBranchQuota(1_000_000);
    var b: BandLists = .{ .words = undefined, .n = 0, .at = @splat(0) };
    for ([_]u2{ 3, 2, 0 }) |vb| for (0..3) |sr| {
        const v: header.Version = switch (vb) {
            3 => .mpeg1,
            2 => .mpeg2,
            else => .mpeg25,
        };
        const h: header.Header = .{ .version = v, .crc = false, .bitrate_index = 9, .sr_index = sr, .padding = false, .mode = .stereo, .mode_ext = 0 };
        const row = h.sfbRow();
        const nl = if (v == .mpeg1) 8 else 6;
        const lists = [3][]const u8{ &bands.long[row], &bands.short[row], bands.mixed[row][0 .. nl + 30] };
        for (lists, 0..) |l, kind| {
            const off = find: {
                var s: usize = 0;
                while (s + l.len < b.n) : (s += 1) {
                    var same = b.words[s + l.len] == 0 and (s == 0 or b.words[s - 1] == 0);
                    for (l, 0..) |w, j| same = same and b.words[s + j] == w;
                    if (same) break :find s;
                }
                const s0 = b.n;
                for (l, 0..) |w, j| b.words[s0 + j] = w;
                b.words[s0 + l.len] = 0;
                b.n += l.len + 1;
                break :find s0;
            };
            b.at[(@as(usize, vb) * 3 + sr) * 3 + kind] = off;
        }
    };
    break :blk b;
};

/// Every table at its Y address (`at` maps a .const name to its address).
pub fn put(st: anytype, gpa: std.mem.Allocator, comptime at: fn (comptime []const u8) u32) !void {
    for (flen, 0..) |v, i| try st.y_mem.put(gpa, at("MP_FLEN") + @as(u32, @intCast(i)), v);
    for (slen, 0..) |v, i| try st.y_mem.put(gpa, at("MP_SLEN") + @as(u32, @intCast(i)), v);
    for (part, 0..) |v, i| try st.y_mem.put(gpa, at("MP_PART") + @as(u32, @intCast(i)), v);
    for (gmod, 0..) |v, i| try st.y_mem.put(gpa, at("MP_GMOD") + @as(u32, @intCast(i)), v);
    const bw = at("MP_BW");
    for (band_lists.words[0..band_lists.n], 0..) |v, i| try st.y_mem.put(gpa, bw + @as(u32, @intCast(i)), v);
    for (band_lists.at, 0..) |off, i| try st.y_mem.put(gpa, at("MP_BP") + @as(u32, @intCast(i)), bw + off);
    // trees from MP_HUFF; MP_HT / MP_HR per table_select (0 = no tree), 32 / 33 count1 A / B
    var addr: u32 = at("MP_HUFF");
    var base: [34]u32 = @splat(0);
    var root: [34]u32 = @splat(0);
    for (trees, 0..) |tr, i| {
        for (tr.words, 0..) |w, j| try st.y_mem.put(gpa, addr + @as(u32, @intCast(j)), w);
        if (i < codes.len) {
            for (0..32) |s| if (ht.pair[s] != null and ht.pair[s].?.ptr == ht.pair[codes[i]].?.ptr) {
                base[s] = addr;
                root[s] = tr.root;
            };
        } else {
            base[32 + i - codes.len] = addr;
            root[32 + i - codes.len] = tr.root;
        }
        addr += @intCast(tr.words.len);
    }
    std.debug.assert(addr <= at("MP_YEND"));
    for (0..34) |i| {
        try st.y_mem.put(gpa, at("MP_HT") + @as(u32, @intCast(i)), base[i]);
        try st.y_mem.put(gpa, at("MP_HR") + @as(u32, @intCast(i)), root[i]);
    }
    for (ht.linbits, 0..) |l, i| try st.y_mem.put(gpa, at("MP_LIN") + @as(u32, @intCast(i)), l);
}

test "the band lists and trees fit their Y" {
    const map = @import("../map.zig");
    var n: usize = 0;
    for (trees) |tr| n += tr.words.len;
    try std.testing.expect(map.at("MP_BW") + band_lists.n <= map.at("MP_HUFF"));
    try std.testing.expect(map.at("MP_HUFF") + n <= map.at("MP_YEND"));
}
