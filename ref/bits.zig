//! MSB-first bit reader over an access unit, as ISO/IEC 14496-3 reads its bitstream syntax.
const std = @import("std");

pub const Error = error{EndOfStream};

pub const BitReader = struct {
    data: []const u8,
    pos: usize = 0,

    pub fn init(data: []const u8) BitReader {
        return .{ .data = data };
    }

    pub fn bitsLeft(self: *const BitReader) usize {
        return self.data.len * 8 - self.pos;
    }

    /// Reads `n` bits (0..32), most significant first.
    pub fn read(self: *BitReader, n: u6) Error!u32 {
        std.debug.assert(n <= 32);
        if (n > self.bitsLeft()) return error.EndOfStream;
        var v: u32 = 0;
        for (0..n) |_| {
            const byte = self.data[self.pos >> 3];
            const shift: u3 = @intCast(7 - (self.pos & 7));
            v = (v << 1) | ((byte >> shift) & 1);
            self.pos += 1;
        }
        return v;
    }

    pub fn readFlag(self: *BitReader) Error!bool {
        return try self.read(1) == 1;
    }

    pub fn skip(self: *BitReader, nbits: usize) Error!void {
        if (nbits > self.bitsLeft()) return error.EndOfStream;
        self.pos += nbits;
    }

    /// byte_alignment(): advance to the next byte boundary.
    pub fn byteAlign(self: *BitReader) void {
        self.pos = @min((self.pos + 7) & ~@as(usize, 7), self.data.len * 8);
    }
};

const testing = std.testing;

test "reads fields across byte boundaries" {
    var r = BitReader.init(&.{ 0b1010_1100, 0b0101_0011 });
    try testing.expectEqual(@as(u32, 0b101), try r.read(3));
    try testing.expectEqual(@as(u32, 0b01100_010), try r.read(8));
    try testing.expectEqual(@as(usize, 5), r.bitsLeft());
}

test "reads a full 32-bit word" {
    var r = BitReader.init(&.{ 0xDE, 0xAD, 0xBE, 0xEF });
    try testing.expectEqual(@as(u32, 0xDEADBEEF), try r.read(32));
}

test "refuses to read past the end" {
    var r = BitReader.init(&.{0xFF});
    try testing.expectError(error.EndOfStream, r.read(9));
}

test "byteAlign moves to the next boundary and stays put on one" {
    var r = BitReader.init(&.{ 0xFF, 0x00 });
    _ = try r.read(3);
    r.byteAlign();
    try testing.expectEqual(@as(usize, 8), r.pos);
    r.byteAlign();
    try testing.expectEqual(@as(usize, 8), r.pos);
}
