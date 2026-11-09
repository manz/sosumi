//! AAC Huffman decoding in measured sm1 operations: the twin of `ref/aac/huffman.zig`.
//!
//! Each codebook becomes a tree of lookup tables of 16-bit words (Y memory's width). A step
//! peeks w <= 8 bits (the reader's piece) and reads one entry at base + those bits. The entry's
//! low five bits say what it is:
//!
//!   - 1..8: a leaf. The codeword ends that many bits in; the rest of the entry is the decoded
//!     value, already unpacked (below), so decoding needs no divide.
//!   - 16 + w', w' in 1..8: a pointer. Consume w bits; the rest is the base of a subtable of
//!     width w'.
//!   - 0: no codeword has this prefix.
//!
//! Field extraction is a floor shift and a subtraction (no AND is measured); the tests on the
//! field are sign tests of f - 16 and of f. Table indices are address arithmetic, the AGU's.
//!
//! Spectral values arrive packed in the leaf: a 4-tuple as four 2-bit fields (value + offset,
//! 0..2), a pair as two 5-bit fields (0..16), the last value lowest. Unpacking is shifts and subtractions, then the
//! sign bits and escapes as in the reference.
const std = @import("std");
const ops = @import("../ops.zig");
const bits = @import("../bits.zig");
const ref = @import("../../aac/huffman.zig");
const ref_tables = @import("../../aac/tables/huffman.zig");

const Word = ops.Word;

pub const Error = bits.Error || error{ InvalidCodeword, EscapeTooLong };

const tree = @import("../huffman.zig");
const field_shift = tree.field_shift;
const ptr_flag = tree.ptr_flag;
pub const max_width = tree.max_width;
pub const Table = tree.Table;
const makeTable = tree.makeTable;

fn identity(i: usize) u16 {
    return @intCast(i);
}

/// The packed form of spectral index i of `book` (1..11): its values plus offset, MSB first.
fn packedValue(comptime book: u4) fn (usize) u16 {
    return struct {
        fn f(i: usize) u16 {
            const p = ref.books[book - 1];
            const fbits: u4 = if (p.dim == 4) 2 else 5;
            var idx = i;
            var v: u16 = 0;
            var k: u4 = 0;
            while (k < p.dim) : (k += 1) {
                const a: u16 = @intCast(idx % p.mod);
                idx /= p.mod;
                v += a << @intCast(fbits * k);
            }
            return v;
        }
    }.f;
}

pub const root_width = 6;

pub const scalefactor = makeTable(&ref_tables.scalefactor, root_width, identity);

pub const spectral: [11]Table = blk: {
    var t: [11]Table = undefined;
    for (0..11) |b| t[b] = makeTable(ref_tables.spectral[b], root_width, packedValue(b + 1));
    break :blk t;
};

/// The value of the next codeword of `table`.
pub fn decode(r: *bits.Reader, table: Table) Error!Word {
    var base: usize = 0;
    var w: u4 = table.root;
    while (true) {
        const e: Word = table.words[base + @as(usize, @intCast(r.peek(w)))];
        const hi = ops.floorShr(e, field_shift);
        const f = ops.sub(e, ops.shl(hi, field_shift));
        if (ops.isZero(f)) return error.InvalidCodeword;
        const g = ops.sub(f, ptr_flag);
        if (ops.isNeg(g)) {
            try r.skip(@intCast(f));
            return hi;
        }
        try r.skip(w);
        base = @intCast(hi);
        w = @intCast(g);
    }
}

/// Scale factor codeword, as the signed difference (index - 60).
pub fn decodeScalefactorDelta(r: *bits.Reader) Error!Word {
    return ops.sub(try decode(r, scalefactor), 60);
}

/// One spectral codeword of `book` (1..11): its `dim` values, signs and escapes applied.
pub fn decodeSpectral(r: *bits.Reader, book: u4, out: []Word) Error!void {
    const p = ref.books[book - 1];
    std.debug.assert(out.len == p.dim);
    var v = try decode(r, spectral[book - 1]);
    const fbits: u4 = if (p.dim == 4) 2 else 5;
    for (0..p.dim) |k| {
        const rest = ops.floorShr(v, fbits);
        out[p.dim - 1 - k] = ops.sub(ops.sub(v, ops.shl(rest, fbits)), p.off);
        v = rest;
    }
    if (!p.signed) {
        for (out) |*x| {
            if (!ops.isZero(x.*) and try r.readFlag()) x.* = ops.sub(0, x.*);
        }
    }
    if (book == ref.esc_book) {
        for (out) |*x| {
            if (ops.isZero(ops.sub(absWord(x.*), ref.esc_flag))) {
                const mag = try readEscape(r);
                x.* = if (ops.isNeg(x.*)) ops.sub(0, mag) else mag;
            }
        }
    }
}

/// |x| for book 11's values, which are 0..16 before the sign bit.
fn absWord(x: Word) Word {
    return if (ops.isNeg(x)) ops.sub(0, x) else x;
}

/// escape_prefix (N ones, then a zero) and an (N + 4)-bit escape_word: 2^(N+4) + word.
fn readEscape(r: *bits.Reader) Error!Word {
    var n: u4 = 0;
    while (try r.readFlag()) {
        n += 1;
        if (n > 8) return error.EscapeTooLong;
    }
    const word = try r.read(n + 4);
    return ops.add(ops.shl(1, n + 4), word);
}

const testing = std.testing;
const ref_bits = @import("../../bits.zig");

fn expectSameStream(buf: []const u8, book: u4, count: usize) !void {
    var a = ref_bits.BitReader.init(buf);
    var b = bits.Reader.init(buf);
    for (0..count) |_| {
        if (book == 0) {
            const want = ref.decodeScalefactorDelta(&a);
            const got = decodeScalefactorDelta(&b);
            if (want) |w| try testing.expectEqual(@as(Word, w), try got) else |_| {
                try testing.expect(std.meta.isError(got));
                return;
            }
        } else {
            const dim = ref.books[book - 1].dim;
            var wo: [4]i16 = undefined;
            var go: [4]Word = undefined;
            const want = ref.decodeSpectral(&a, book, wo[0..dim]);
            const got = decodeSpectral(&b, book, go[0..dim]);
            if (want) |_| {
                try got;
                for (0..dim) |i| try testing.expectEqual(@as(Word, wo[i]), go[i]);
            } else |_| {
                try testing.expect(std.meta.isError(got));
                return;
            }
        }
        try testing.expectEqual(a.pos, b.pos);
    }
}

test "random bitstreams decode as the reference does, in every book" {
    var prng = std.Random.DefaultPrng.init(0xAAC);
    const rnd = prng.random();
    var buf: [256]u8 = undefined;
    for (0..12) |book| {
        for (0..40) |_| {
            rnd.bytes(&buf);
            // bias towards short codewords, as real spectra are
            for (&buf) |*x| x.* &= rnd.int(u8);
            try expectSameStream(&buf, @intCast(book), 120);
        }
    }
}

test "every codeword of every book" {
    var buf: [8]u8 = undefined;
    for (0..12) |book| {
        const codes: []const ref_tables.Code = if (book == 0) &ref_tables.scalefactor else ref_tables.spectral[book - 1];
        for (codes) |c| {
            @memset(&buf, 0);
            const shift: u6 = @intCast(64 - @as(u7, c.len));
            std.mem.writeInt(u64, &buf, @as(u64, c.code) << shift, .big);
            try expectSameStream(&buf, @intCast(book), 1);
        }
    }
}

test "every entry stays below 0x8000, since ldy sign-extends" {
    // x17 docs/sm1/reference.md, `ldy` (silicon probe own-ldysx): a Y word of 0x8000 or more
    // loads as negative.
    for (scalefactor.words) |w| try testing.expect(w < 0x8000);
    for (spectral) |t| for (t.words) |w| try testing.expect(w < 0x8000);
}

test "all twelve tables fit in Y with room for buffers" {
    // Y:0..0x2E7F is the safe 16-bit region (specs/questions.md 6): 11904 words.
    var total: usize = scalefactor.words.len;
    for (spectral) |t| total += t.words.len;
    try testing.expectEqual(@as(usize, 2910), total); // root 6; root 8 took 4544
}
