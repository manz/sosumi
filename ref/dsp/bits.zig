//! MSB-first bit reader in measured sm1 operations.
//!
//! The packet sits in memory as 16-bit words, big-endian byte pairs, the way x17's host model
//! stages it (the engine-side packet path is still OPEN, specs/questions.md 2). A read takes at
//! most 8 bits at a time from a 23-bit window: word i shifted up 7, plus the top 7 bits of word
//! i + 1. No AND exists, so a field is t - (t >> k) << k. The bit position is address
//! arithmetic (the AGU's job), so it stays an integer.
const std = @import("std");
const ops = @import("ops.zig");

const Word = ops.Word;

pub const Error = error{EndOfStream};

pub const Reader = struct {
    data: []const u8,
    pos: usize = 0,

    pub fn init(data: []const u8) Reader {
        return .{ .data = data };
    }

    pub fn bitsLeft(self: *const Reader) usize {
        return self.data.len * 8 - self.pos;
    }

    /// Memory word i: bytes 2i and 2i + 1, zero past the end.
    fn word(self: *const Reader, i: usize) Word {
        const hi: Word = if (2 * i < self.data.len) self.data[2 * i] else 0;
        const lo: Word = if (2 * i + 1 < self.data.len) self.data[2 * i + 1] else 0;
        return ops.addShl(hi, 0, 8) +% lo;
    }

    /// k (1..8) bits at the current position.
    fn piece(self: *Reader, k: u4) Word {
        const i = self.pos >> 4;
        const off: u5 = @intCast(self.pos & 15);
        const window = ops.add(ops.shl(self.word(i), 7), ops.floorShr(self.word(i + 1), 9));
        const t = ops.floorShr(window, @intCast(23 - @as(u32, off) - k));
        self.pos += k;
        return ops.sub(t, ops.shl(ops.floorShr(t, k), k));
    }

    /// n (0..24) bits, most significant first. A 24-bit read fills the word, sign bit included.
    pub fn read(self: *Reader, n: u5) Error!Word {
        std.debug.assert(n <= 24);
        if (n > self.bitsLeft()) return error.EndOfStream;
        var v: Word = 0;
        var left = n;
        while (left > 0) {
            const k: u4 = @intCast(@min(left, 8));
            v = ops.add(ops.shl(v, k), self.piece(k));
            left -= k;
        }
        return v;
    }

    /// k (1..8) bits at the current position, without consuming them. Bits past the end read
    /// as zero; the `skip` that consumes them checks the length.
    pub fn peek(self: *Reader, k: u4) Word {
        const p = self.pos;
        defer self.pos = p;
        return self.piece(k);
    }

    pub fn readFlag(self: *Reader) Error!bool {
        return !ops.isZero(try self.read(1));
    }

    pub fn skip(self: *Reader, nbits: usize) Error!void {
        if (nbits > self.bitsLeft()) return error.EndOfStream;
        self.pos += nbits;
    }

    pub fn byteAlign(self: *Reader) void {
        self.pos = @min((self.pos + 7) & ~@as(usize, 7), self.data.len * 8);
    }
};

const testing = std.testing;
const ref = @import("../bits.zig");

test "every read width at every offset matches the reference reader" {
    var prng = std.Random.DefaultPrng.init(0xB175);
    const rnd = prng.random();
    var buf: [64]u8 = undefined;
    rnd.bytes(&buf);
    for (0..64) |start| {
        for (0..24) |n0| {
            const n: u5 = @intCast(n0 + 1);
            var a = ref.BitReader.init(&buf);
            var b = Reader.init(&buf);
            a.pos = start;
            b.pos = start;
            const want: u32 = try a.read(n);
            const got: u24 = @bitCast(try b.read(n));
            try testing.expectEqual(want, got);
            try testing.expectEqual(a.pos, b.pos);
        }
    }
}

test "reads to the last bit of an odd-length packet, then refuses" {
    var r = Reader.init(&.{ 0xAB, 0xCD, 0xEF });
    try testing.expectEqual(@as(Word, 0xABCDEF - 0x1000000), try r.read(24));
    try testing.expectError(error.EndOfStream, r.read(1));
}
