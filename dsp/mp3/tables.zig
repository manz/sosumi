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

/// The distinct pair codes (ISO/IEC 11172-3 Table B.7); count1 A and B after them.
pub const codes = [_]u8{ 1, 2, 3, 5, 6, 7, 8, 9, 10, 11, 12, 13, 15, 16, 24 };

/// Leaf values: x * 16 + y for a pair, vwxy for a quadruple. Laid out once, at run time (the
/// width search overflows the compiler's comptime stack).
pub fn trees() *const [codes.len + 2]tree.Table {
    if (!built) {
        inline for (codes, 0..) |c, i| tabs[i] = smallest(&lays[i], ht.pair[c].?, pairValue(ht.width[c]));
        tabs[codes.len] = smallest(&lays[codes.len], &ht.count1_a, ident);
        tabs[codes.len + 1] = smallest(&lays[codes.len + 1], &ht.count1_b, ident);
        built = true;
    }
    return &tabs;
}

var lays: [codes.len + 2]Lay = undefined;
var tabs: [codes.len + 2]tree.Table = undefined;
var built = false;

/// A code in lib/huffman.sm's format (ref/dsp/huffman.zig), every table's width (root and
/// subtables, 1..8) the one that makes its subtree smallest: mode 1's Y (specs/mp3.md).
fn smallest(lay: *Lay, cs: []const ref.huffman.Code, value: fn (usize) u16) tree.Table {
    var syms: [300]Sym = undefined;
    for (cs, 0..) |c, i| syms[i] = .{ .code = c.code, .len = c.len, .v = value(i) };
    lay.* = .{};
    memo.clearRetainingCapacity();
    const root = best(syms[0..cs.len], 0).w;
    _ = lay.build(syms[0..cs.len], 0, root);
    return .{ .words = lay.t[0..lay.n], .root = root };
}

const Sym = struct { code: u32, len: u5, v: u16 };

/// The syms below prefix p of a w-wide table at depth, and the longest remainder past it.
fn group(syms: []const Sym, depth: u5, w: u4, p: usize, out: []Sym) struct { n: usize, rem: u5 } {
    var n: usize = 0;
    var rem: u5 = 0;
    for (syms) |s| {
        const r = s.len - depth;
        if (r <= w) continue;
        if ((s.code & ((@as(u32, 1) << r) - 1)) >> @intCast(r - w) != p) continue;
        out[n] = s;
        n += 1;
        rem = @max(rem, r - w);
    }
    return .{ .n = n, .rem = rem };
}

/// The width (1..8, at most the longest remainder) with the least words + step_cost x the
/// expected lookups (a codeword of length l taken as 2^-l likely): each table a codeword
/// passes through is one huff_decode step. At 100 the trees take 1990 words (2832 with the
/// smallest root and full-depth subtables), the worst corpus frame 5K bundles more.
const step_cost: f64 = 100;
const Best = struct { w: u4, cost: f64 };
var memo: std.AutoHashMapUnmanaged(u64, Best) = .empty;

/// Memoised by (depth, the prefix the syms share): the search revisits every subtree per width.
fn best(syms: []const Sym, depth: u5) Best {
    const key = (@as(u64, depth) << 32) | (syms[0].code >> @intCast(syms[0].len - depth));
    if (memo.get(key)) |b| return b;
    const b = search(syms, depth);
    memo.put(std.heap.page_allocator, key, b) catch {};
    return b;
}

fn search(syms: []const Sym, depth: u5) Best {
    var top: u5 = 0;
    var mass: f64 = 0;
    for (syms) |s| {
        top = @max(top, s.len - depth);
        mass += std.math.pow(f64, 2, -@as(f64, @floatFromInt(s.len)));
    }
    var r: Best = .{ .w = 1, .cost = std.math.inf(f64) };
    var w: u4 = 1;
    while (w <= @min(top, tree.max_width)) : (w += 1) {
        var cost: f64 = @floatFromInt(@as(usize, 1) << w);
        cost += step_cost * mass;
        for (0..@as(usize, 1) << w) |p| {
            var g: [300]Sym = undefined;
            const k = group(syms, depth, w, p, &g);
            if (k.n > 0) cost += best(g[0..k.n], depth + w).cost;
        }
        if (cost < r.cost) r = .{ .w = w, .cost = cost };
        if (w == tree.max_width) break;
    }
    return r;
}

/// ref/dsp/huffman.zig's layout with `best`'s widths.
const Lay = struct {
    t: [4096]u16 = undefined,
    n: usize = 0,

    fn build(self: *Lay, syms: []const Sym, depth: u5, width: u4) usize {
        const base = self.n;
        const size = @as(usize, 1) << width;
        self.n += size;
        @memset(self.t[base..][0..size], 0);
        for (syms) |s| {
            const r = s.len - depth;
            if (r > width) continue;
            const start = @as(usize, s.code & ((@as(u32, 1) << r) - 1)) << @intCast(width - r);
            for (0..@as(usize, 1) << @intCast(width - r)) |j| self.t[base + start + j] = (s.v << tree.field_shift) + r;
        }
        for (0..size) |p| {
            var g: [300]Sym = undefined;
            const k = group(syms, depth, width, p, &g);
            if (k.n == 0) continue;
            const w2 = best(g[0..k.n], depth + width).w;
            const sub = self.build(g[0..k.n], depth + width, w2);
            std.debug.assert(sub < 1 << (16 - tree.field_shift));
            self.t[base + p] = @intCast((sub << tree.field_shift) + tree.ptr_flag + w2);
        }
        return base;
    }
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
    for (trees(), 0..) |tr, i| {
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
    for (ref.mp3.requant.pretab, 0..) |v, i| try st.y_mem.put(gpa, at("MP_PRET") + @as(u32, @intCast(i)), v);
    for (0..40) |i| try st.y_mem.put(gpa, at("MP_QZ") + @as(u32, @intCast(i)), 0);
    const S = ref.dsp.mp3.stereo;
    for (S.pan, 0..) |kk, i| for (kk, 0..) |v, j| try st.x_mem.put(gpa, at("MP_XST") + @as(u32, @intCast(2 * i + j)), @as(u24, @bitCast(v)));
    for (S.quarter, 0..) |v, i| try st.x_mem.put(gpa, at("MP_XST") + 14 + @as(u32, @intCast(i)), @as(u24, @bitCast(v)));
    try st.x_mem.put(gpa, at("MP_XST") + 18, @as(u24, @bitCast(S.inv_sqrt2)));
    const H = ref.dsp.mp3.hybrid;
    for (H.cos36, 0..) |rw, r| for (rw, 0..) |v, k| try st.x_mem.put(gpa, at("MP_XC36") + @as(u32, @intCast(18 * r + k)), @as(u24, @bitCast(v)));
    for (H.cos12, 0..) |rw, r| for (rw, 0..) |v, k| try st.x_mem.put(gpa, at("MP_XC12") + @as(u32, @intCast(6 * r + k)), @as(u24, @bitCast(v)));
    for (H.windows, 0..) |w, j| for (w, 0..) |v, i| try st.x_mem.put(gpa, at("MP_XWIN") + @as(u32, @intCast(36 * j + i)), @as(u24, @bitCast(v)));
    for (H.cs, H.ca, 0..) |c, a, i| {
        try st.x_mem.put(gpa, at("MP_XAL") + @as(u32, @intCast(3 * i)), @as(u24, @bitCast(c)));
        try st.x_mem.put(gpa, at("MP_XAL") + @as(u32, @intCast(3 * i + 1)), @as(u24, @bitCast(a)));
        try st.x_mem.put(gpa, at("MP_XAL") + @as(u32, @intCast(3 * i + 2)), @as(u24, @bitCast(-a)));
    }
    const Y = ref.dsp.mp3.synth;
    var xn = at("MP_XN");
    var b: usize = 0;
    while (b < synth_rows.len) : (b += 4) {
        // a block of 4 rows over the same split words, column by column (mp3_mgrp)
        const blk = synth_rows[b..][0..4];
        const nt: usize = if (Y.rowN(blk[0]) & 1 == 1) 16 else 8;
        for (0..nt) |k| for (blk) |r| {
            try st.x_mem.put(gpa, xn, @as(u24, @bitCast(Y.n_rows[r][k])));
            xn += 1;
        };
    }
    std.debug.assert(xn == at("MP_XN") + 384);
    // D paired for mp3_wpair, per age a (twice over): d[32a], then for j = 1..15 d[32a + j] and
    // d[32a + 32 - j] negated for even a (V[32 - j] = -V[j] there, V[64 - j] = V[32 + j] odd),
    // then d[32a + 16]
    for (0..1024) |i| {
        const a = (i / 32) % 16;
        const c = i % 32;
        const v: i24 = if (c == 0) Y.d[32 * a] else if (c == 31) Y.d[32 * a + 16] else if (c & 1 == 1)
            Y.d[32 * a + (c + 1) / 2]
        else if (a & 1 == 0) -Y.d[32 * a + 32 - c / 2] else Y.d[32 * a + 32 - c / 2];
        try st.x_mem.put(gpa, at("MP_XD") + @as(u32, @intCast(i)), @as(u24, @bitCast(v)));
    }
}

/// The synthesis rows (ref/dsp/mp3/synth.zig n_rows) in mp3_synth's blocks of 4 (mp3_mgrp).
pub const synth_rows = [_]usize{
    1, 3, 5, 7, 9, 11, 13, 15, // h1
    16, 18, 20, 22, 24, 26, 28, 30, // h1
    2, 6, 10, 14, // h2
    17, 21, 25, 29, // h2
    0, 4, 8, 12, // g2
    19, 23, 27, 31, // g2
};

test "the band lists and trees fit their Y" {
    const map = @import("../map.zig");
    var n: usize = 0;
    for (trees()) |tr| n += tr.words.len;
    try std.testing.expect(map.at("MP_BW") + band_lists.n <= map.at("MP_HUFF"));
    try std.testing.expect(map.at("MP_HUFF") + n <= map.at("MP_YEND"));
}

