//! Canonical Huffman decoding, shared by every codec: a table maps a symbol index to its
//! codeword, and the decoder matches the input one bit at a time against it. Slow and obviously
//! right; fast lookups belong to the sm1 ports. Entries with len 0 are symbols the table does
//! not code.
const std = @import("std");
const bits = @import("bits.zig");

pub const Code = struct { code: u32, len: u5 };

pub const Error = bits.Error || error{InvalidCodeword};

pub const max_len = 19;

/// Symbol index of the next codeword in `table`.
pub fn decode(r: *bits.BitReader, table: []const Code) Error!u16 {
    var code: u32 = 0;
    var len: u5 = 0;
    while (len < max_len) {
        code = (code << 1) | try r.read(1);
        len += 1;
        for (table, 0..) |e, i| {
            if (e.len == len and e.code == code) return @intCast(i);
        }
    }
    return error.InvalidCodeword;
}

/// Kraft sum of a table, as a fraction of 2^max_len: a complete prefix code sums to exactly 1.
pub fn kraft(table: []const Code) u64 {
    var sum: u64 = 0;
    for (table) |e| {
        if (e.len != 0) sum += @as(u64, 1) << @intCast(max_len - @as(u6, e.len));
    }
    return sum;
}

const testing = std.testing;

test "decode matches a three-symbol code and skips uncoded entries" {
    const t = [_]Code{ .{ .code = 0b0, .len = 1 }, .{ .code = 0, .len = 0 }, .{ .code = 0b10, .len = 2 }, .{ .code = 0b11, .len = 2 } };
    var r = bits.BitReader.init(&.{0b0_10_11_000});
    try testing.expectEqual(@as(u16, 0), try decode(&r, &t));
    try testing.expectEqual(@as(u16, 2), try decode(&r, &t));
    try testing.expectEqual(@as(u16, 3), try decode(&r, &t));
    try testing.expectEqual(@as(u64, 1) << max_len, kraft(&t));
}
