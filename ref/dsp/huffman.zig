//! Huffman codes as trees of lookup tables of 16-bit words (Y memory's width), shared by the
//! AAC and MP3 twins. A step peeks w <= 8 bits and reads one entry at base + those bits; the
//! entry's low five bits say what it is:
//!
//!   - 1..8: a leaf, the codeword ends that many bits in; the rest is its value.
//!   - 16 + w', w' in 1..8: a pointer; consume w bits, the rest is the base of a w'-wide subtable.
//!   - 0: no codeword has this prefix.
const std = @import("std");
const Code = @import("../huffman.zig").Code;

pub const field_shift = 5;
pub const ptr_flag = 16;
pub const max_width = 8;

/// A codebook as lookup tables: the root at word 0, `root` bits wide.
pub const Table = struct { words: []const u16, root: u4 };

const Sym = struct { code: u32, len: u5, v: u16 };

fn Builder(comptime cap: usize) type {
    return struct {
        t: [cap]u16 = undefined,
        n: usize = 0,

        const Self = @This();

        /// Lays out one table of 2^width entries for `syms`, `depth` bits already consumed.
        /// Returns its base.
        fn build(self: *Self, syms: []const Sym, depth: u5, width: u4) usize {
            const base = self.n;
            const size = @as(usize, 1) << width;
            self.n += size;
            @memset(self.t[base..][0..size], 0);
            for (syms) |s| {
                const r = s.len - depth;
                if (r > width) continue;
                const rem = s.code & ((@as(u32, 1) << r) - 1);
                const start = @as(usize, rem) << @intCast(width - r);
                for (0..@as(usize, 1) << @intCast(width - r)) |j| {
                    self.t[base + start + j] = (s.v << field_shift) + r;
                }
            }
            for (0..size) |p| {
                var group: [289]Sym = undefined;
                var ng: usize = 0;
                var maxrem: u5 = 0;
                for (syms) |s| {
                    const r = s.len - depth;
                    if (r <= width) continue;
                    const rem = s.code & ((@as(u32, 1) << r) - 1);
                    if (rem >> @intCast(r - width) != p) continue;
                    group[ng] = s;
                    ng += 1;
                    maxrem = @max(maxrem, r - width);
                }
                if (ng == 0) continue;
                const w2: u4 = @intCast(@min(max_width, maxrem));
                const sub = self.build(group[0..ng], depth + width, w2);
                std.debug.assert(sub < 1 << (16 - field_shift));
                self.t[base + p] = @intCast((sub << field_shift) + ptr_flag + w2);
            }
            return base;
        }
    };
}

pub fn makeTable(comptime codes: []const Code, comptime root: u4, comptime value: fn (usize) u16) Table {
    return comptime blk: {
        @setEvalBranchQuota(10_000_000);
        var syms: [codes.len]Sym = undefined;
        for (codes, 0..) |c, i| syms[i] = .{ .code = c.code, .len = c.len, .v = value(i) };
        var b: Builder(8192) = .{};
        _ = b.build(&syms, 0, root);
        const n = b.n;
        const words: [n]u16 = b.t[0..n].*;
        break :blk .{ .words = &words, .root = root };
    };
}

