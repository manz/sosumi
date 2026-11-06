//! Huffman decoding for scale factors and spectral codebooks (ISO/IEC 14496-3).
//!
//! The reference model decodes by matching the codeword one bit at a time against the table.
//! Slow, and obviously right; the fast lookup belongs to the sm1 port.
const std = @import("std");
const bits = @import("../bits.zig");
const tables = @import("tables/huffman.zig");

pub const Error = bits.Error || error{ InvalidCodeword, EscapeTooLong };

/// Codebook parameters from OpenCORE's `hcbbook_binary` (Apache 2.0): values per codeword,
/// the radix they are packed in, the offset subtracted from each, and whether the values are
/// signed (no separate sign bits).
pub const Book = struct { dim: u3, mod: u5, off: u3, signed: bool };

pub const books = [11]Book{
    .{ .dim = 4, .mod = 3, .off = 1, .signed = true },
    .{ .dim = 4, .mod = 3, .off = 1, .signed = true },
    .{ .dim = 4, .mod = 3, .off = 0, .signed = false },
    .{ .dim = 4, .mod = 3, .off = 0, .signed = false },
    .{ .dim = 2, .mod = 9, .off = 4, .signed = true },
    .{ .dim = 2, .mod = 9, .off = 4, .signed = true },
    .{ .dim = 2, .mod = 8, .off = 0, .signed = false },
    .{ .dim = 2, .mod = 8, .off = 0, .signed = false },
    .{ .dim = 2, .mod = 13, .off = 0, .signed = false },
    .{ .dim = 2, .mod = 13, .off = 0, .signed = false },
    .{ .dim = 2, .mod = 17, .off = 0, .signed = false },
};

pub const esc_book = 11;
pub const esc_flag = 16;

/// Index of the next codeword in `table`.
pub fn decodeIndex(r: *bits.BitReader, table: []const tables.Code) Error!u16 {
    var code: u32 = 0;
    var len: u5 = 0;
    while (len < 19) {
        code = (code << 1) | try r.read(1);
        len += 1;
        for (table, 0..) |e, i| {
            if (e.len == len and e.code == code) return @intCast(i);
        }
    }
    return error.InvalidCodeword;
}

/// Scale factor codeword, as the signed difference (index - 60).
pub fn decodeScalefactorDelta(r: *bits.BitReader) Error!i16 {
    return @as(i16, @intCast(try decodeIndex(r, &tables.scalefactor))) - 60;
}

/// One spectral codeword of `book` (1..11): its `dim` values, signs and escapes applied.
pub fn decodeSpectral(r: *bits.BitReader, book: u4, out: []i16) Error!void {
    const p = books[book - 1];
    std.debug.assert(out.len == p.dim);
    var idx = try decodeIndex(r, tables.spectral[book - 1]);
    var i: usize = p.dim;
    while (i > 0) {
        i -= 1;
        out[i] = @as(i16, @intCast(idx % p.mod)) - p.off;
        idx /= p.mod;
    }
    if (!p.signed) {
        for (out) |*v| {
            if (v.* != 0 and try r.readFlag()) v.* = -v.*;
        }
    }
    if (book == esc_book) {
        for (out) |*v| {
            if (@abs(v.*) == esc_flag) {
                const mag = try readEscape(r);
                v.* = if (v.* < 0) -mag else mag;
            }
        }
    }
}

/// escape_prefix (N ones, then a zero) and an (N + 4)-bit escape_word: 2^(N+4) + word.
/// N is at most 8, which caps magnitudes at 8191.
fn readEscape(r: *bits.BitReader) Error!i16 {
    var n: u6 = 0;
    while (try r.readFlag()) {
        n += 1;
        if (n > 8) return error.EscapeTooLong;
    }
    const word = try r.read(n + 4);
    return @intCast((@as(u32, 1) << @intCast(n + 4)) + word);
}

const testing = std.testing;

/// Writes codewords MSB first into `buf`; returns the used slice.
fn emit(buf: []u8, codes: []const tables.Code) []const u8 {
    @memset(buf, 0);
    var n: usize = 0;
    for (codes) |c| {
        var k: u5 = c.len;
        while (k > 0) {
            k -= 1;
            if ((c.code >> k) & 1 == 1) buf[n >> 3] |= @as(u8, 0x80) >> @intCast(n & 7);
            n += 1;
        }
    }
    return buf[0 .. (n + 7) / 8];
}

test "every codeword of every book decodes to its own index" {
    var buf: [4]u8 = undefined;
    for ([_][]const tables.Code{&tables.scalefactor} ++ tables.spectral) |table| {
        for (table, 0..) |c, i| {
            var r = bits.BitReader.init(emit(&buf, &.{c}));
            try testing.expectEqual(@as(u16, @intCast(i)), try decodeIndex(&r, table));
            try testing.expectEqual(@as(usize, c.len), r.pos);
        }
    }
}

test "scale factor index 60 is a zero delta" {
    var buf: [4]u8 = undefined;
    var r = bits.BitReader.init(emit(&buf, &.{tables.scalefactor[60]}));
    try testing.expectEqual(@as(i16, 0), try decodeScalefactorDelta(&r));
}

test "signed 4-tuple book unpacks base 3 with offset 1" {
    var buf: [4]u8 = undefined;
    // index 0 of book 1 is (-1, -1, -1, -1); index 80 is (1, 1, 1, 1)
    var out: [4]i16 = undefined;
    var r = bits.BitReader.init(emit(&buf, &.{tables.book1[0]}));
    try decodeSpectral(&r, 1, &out);
    try testing.expectEqualSlices(i16, &.{ -1, -1, -1, -1 }, &out);
    r = bits.BitReader.init(emit(&buf, &.{tables.book1[80]}));
    try decodeSpectral(&r, 1, &out);
    try testing.expectEqualSlices(i16, &.{ 1, 1, 1, 1 }, &out);
}

test "unsigned book reads one sign bit per non-zero value" {
    var buf: [4]u8 = undefined;
    // book 7 index 8*3 + 0 = (3, 0): one sign bit, set
    var out: [2]i16 = undefined;
    var r = bits.BitReader.init(emit(&buf, &.{ tables.book7[24], .{ .code = 1, .len = 1 } }));
    try decodeSpectral(&r, 7, &out);
    try testing.expectEqualSlices(i16, &.{ -3, 0 }, &out);
}

test "escape book expands 16 into 2^(N+4) + word" {
    var buf: [8]u8 = undefined;
    // book 11 index 16*17 + 1 = (16, 1); sign bits 0, 1; escape N = 1: "10" then 5 bits 00011
    var out: [2]i16 = undefined;
    var r = bits.BitReader.init(emit(&buf, &.{
        tables.book11[16 * 17 + 1],
        .{ .code = 0b01, .len = 2 },
        .{ .code = 0b10, .len = 2 },
        .{ .code = 0b00011, .len = 5 },
    }));
    try decodeSpectral(&r, 11, &out);
    try testing.expectEqualSlices(i16, &.{ 35, -1 }, &out);
}

test "an escape prefix longer than 8 is refused" {
    var buf: [8]u8 = undefined;
    var out: [2]i16 = undefined;
    var r = bits.BitReader.init(emit(&buf, &.{
        tables.book11[16 * 17],
        .{ .code = 0, .len = 1 },
        .{ .code = 0x1ff, .len = 9 },
    }));
    try testing.expectError(error.EscapeTooLong, decodeSpectral(&r, 11, &out));
}
