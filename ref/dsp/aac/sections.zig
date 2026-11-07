//! section_data() and scale_factor_data() in measured sm1 operations: the twin of
//! `ref/aac/ics.zig` `readSectionData` and `readScalefactors`.
//!
//! Bands are flat, group by group, the order both the scale factor pass and the spectral pass
//! walk them: band i = g * max_sfb + sfb, one book word and one scale factor word each. Short
//! windows reach 8 groups of 15 bands, long ones 63 (the field; a rate allows at most 51), so
//! 120 words of each. The codebook tests are sign tests of cb - 12 and cb - 13; the range check
//! is two sign tests; section lengths count down, so the overrun is a sign test too.
const std = @import("std");
const ops = @import("../ops.zig");
const bits = @import("../bits.zig");
const huffman = @import("huffman.zig");
const ref = @import("../../aac/ics.zig");

const Word = ops.Word;

pub const Error = huffman.Error || error{ ReservedCodebook, SectionOverrun, ScalefactorOutOfRange };

pub const max_bands = 120;

pub const Bands = struct {
    n: usize = 0,
    book: [max_bands]Word = undefined,
    sf: [max_bands]Word = undefined,
};

/// section_data(): the book of every band in `groups` groups of `max_sfb` bands.
pub fn readSections(r: *bits.Reader, short: bool, groups: u4, max_sfb: u6, out: *Bands) Error!void {
    const sect_bits: u5 = if (short) 3 else 5;
    const esc: Word = if (short) 7 else 31;
    var i: usize = 0;
    for (0..groups) |_| {
        var left: Word = max_sfb;
        while (!ops.isZero(left)) {
            const cb = try r.read(4);
            if (ops.isZero(ops.sub(cb, ref.reserved_hcb))) return error.ReservedCodebook;
            var len: Word = 0;
            while (true) {
                const incr = try r.read(sect_bits);
                len = ops.add(len, incr);
                if (!ops.isZero(ops.sub(incr, esc))) break;
            }
            left = ops.sub(left, len);
            if (ops.isNeg(left)) return error.SectionOverrun;
            while (!ops.isZero(len)) : (len = ops.sub(len, 1)) {
                out.book[i] = cb;
                i += 1;
            }
        }
    }
    out.n = i;
}

/// scale_factor_data(): scale factors from global_gain, noise energy from global_gain - 90
/// (its first value a 9-bit PCM word offset by 256), intensity positions from 0.
pub fn readScalefactors(r: *bits.Reader, global_gain: Word, b: *Bands) Error!void {
    var fac = global_gain;
    var is_pos: Word = 0;
    var noise = ops.sub(global_gain, 90);
    var noise_pcm = true;
    for (b.book[0..b.n], b.sf[0..b.n]) |cb, *sf| {
        if (ops.isZero(cb)) {
            sf.* = 0;
            continue;
        }
        const c = ops.sub(cb, ref.noise_hcb);
        if (ops.isNeg(c)) {
            fac = ops.add(fac, try huffman.decodeScalefactorDelta(r));
            if (ops.isNeg(fac) or ops.isNeg(ops.sub(255, fac))) return error.ScalefactorOutOfRange;
            sf.* = fac;
        } else if (ops.isZero(c)) {
            if (noise_pcm) {
                noise_pcm = false;
                noise = ops.add(noise, ops.sub(try r.read(9), 256));
            } else {
                noise = ops.add(noise, try huffman.decodeScalefactorDelta(r));
            }
            sf.* = noise;
        } else {
            is_pos = ops.add(is_pos, try huffman.decodeScalefactorDelta(r));
            sf.* = is_pos;
        }
    }
}

const testing = std.testing;
const ref_bits = @import("../../bits.zig");
const codes = @import("../../aac/tables/huffman.zig");

const Writer = struct {
    buf: [512]u8 = @splat(0),
    n: usize = 0,

    fn put(self: *Writer, value: u32, len: u5) void {
        var k = len;
        while (k > 0) {
            k -= 1;
            if ((value >> k) & 1 == 1) self.buf[self.n >> 3] |= @as(u8, 0x80) >> @intCast(self.n & 7);
            self.n += 1;
        }
    }

    fn delta(self: *Writer, d: i32) void {
        const c = codes.scalefactor[@intCast(d + 60)];
        self.put(c.code, c.len);
    }
};

const Shape = struct { short: bool, groups: u4, max_sfb: u6, gain: u8 };

fn info(s: Shape) ref.IcsInfo {
    return .{
        .window_sequence = if (s.short) .eight_short else .only_long,
        .window_shape = 0,
        .max_sfb = s.max_sfb,
        .num_window_groups = s.groups,
        .group_len = @splat(1),
    };
}

/// Decodes `buf` with both and compares books, scale factors, errors and reader position.
fn expectSame(buf: []const u8, s: Shape) !enum { ok, failed } {
    var a = ref_bits.BitReader.init(buf);
    var b = bits.Reader.init(buf);
    var bands: Bands = .{};
    const ri = info(s);
    const want_s = ref.readSectionData(&a, ri);
    const got_s = readSections(&b, s.short, s.groups, s.max_sfb, &bands);
    const sections = want_s catch {
        try testing.expect(std.meta.isError(got_s));
        return .failed;
    };
    try got_s;
    try testing.expectEqual(@as(usize, s.groups) * s.max_sfb, bands.n);
    for (0..s.groups) |g| for (0..s.max_sfb) |k| {
        try testing.expectEqual(@as(Word, sections.sfb_cb[g][k]), bands.book[g * s.max_sfb + k]);
    };
    try testing.expectEqual(a.pos, b.pos);
    const want_f = ref.readScalefactors(&a, ri, &sections, s.gain);
    const got_f = readScalefactors(&b, s.gain, &bands);
    const sf = want_f catch {
        try testing.expect(std.meta.isError(got_f));
        return .failed;
    };
    try got_f;
    for (0..s.groups) |g| for (0..s.max_sfb) |k| {
        try testing.expectEqual(@as(Word, sf[g][k]), bands.sf[g * s.max_sfb + k]);
    };
    try testing.expectEqual(a.pos, b.pos);
    return .ok;
}

fn randomShape(rnd: std.Random) Shape {
    const short = rnd.boolean();
    return .{
        .short = short,
        .groups = if (short) rnd.intRangeAtMost(u4, 1, 8) else 1,
        .max_sfb = if (short) rnd.intRangeAtMost(u6, 0, 15) else rnd.intRangeAtMost(u6, 0, 51),
        .gain = rnd.int(u8),
    };
}

/// A plausible stream for `s`: sections, then scale factors, with an occasional reserved book,
/// overrun or out-of-range scale factor. Random bytes follow.
fn writeStream(w: *Writer, rnd: std.Random, s: Shape) void {
    const sect_bits: u5 = if (s.short) 3 else 5;
    const esc: u32 = if (s.short) 7 else 31;
    var books: [max_bands]u4 = undefined;
    var n: usize = 0;
    for (0..s.groups) |_| {
        var left: u32 = s.max_sfb;
        while (left > 0) {
            var cb = rnd.intRangeAtMost(u4, 0, 15);
            if (cb == ref.reserved_hcb and rnd.uintLessThan(u8, 8) != 0) cb = 1;
            var len = rnd.intRangeAtMost(u32, 0, left);
            if (rnd.uintLessThan(u8, 60) == 0) len = left + 1 + rnd.uintLessThan(u32, 40);
            w.put(cb, 4);
            var l = len;
            while (l >= esc) : (l -= esc) w.put(esc, sect_bits);
            w.put(l, sect_bits);
            for (0..@min(len, left)) |_| {
                books[n] = cb;
                n += 1;
            }
            left -|= len;
        }
    }
    var fac: i32 = s.gain;
    var noise_pcm = true;
    for (books[0..n]) |cb| {
        switch (cb) {
            0 => {},
            13 => if (noise_pcm) {
                noise_pcm = false;
                w.put(rnd.int(u9), 9);
            } else w.delta(rnd.intRangeAtMost(i32, -60, 60)),
            14, 15 => w.delta(rnd.intRangeAtMost(i32, -60, 60)),
            else => {
                // mostly in range; now and then step outside 0..255
                var d = rnd.intRangeAtMost(i32, -10, 10);
                if (rnd.uintLessThan(u8, 100) == 0) d = if (fac > 127) 60 else -60;
                if (fac + d < 0 or fac + d > 255) {
                    if (rnd.uintLessThan(u8, 2) == 0) d = -d;
                }
                d = std.math.clamp(d, -60, 60);
                fac += d;
                w.delta(d);
            },
        }
    }
    var junk: [16]u8 = undefined;
    rnd.bytes(&junk);
    for (junk) |x| w.put(x, 8);
}

test "valid streams decode as the reference does, errors included" {
    var prng = std.Random.DefaultPrng.init(0xAAC5);
    const rnd = prng.random();
    var ok: usize = 0;
    var failed: usize = 0;
    var short: usize = 0;
    for (0..3000) |_| {
        const s = randomShape(rnd);
        var w: Writer = .{};
        writeStream(&w, rnd, s);
        switch (try expectSame(w.buf[0 .. (w.n + 7) / 8], s)) {
            .ok => {
                ok += 1;
                if (s.short and s.groups > 1) short += 1;
            },
            .failed => failed += 1,
        }
    }
    try testing.expect(ok > 2000);
    try testing.expect(failed > 100);
    try testing.expect(short > 500);
}

test "random bitstreams decode as the reference does" {
    var prng = std.Random.DefaultPrng.init(0x5EC7);
    const rnd = prng.random();
    var buf: [128]u8 = undefined;
    for (0..2000) |_| {
        rnd.bytes(&buf);
        for (&buf) |*x| x.* &= rnd.int(u8);
        _ = try expectSame(&buf, randomShape(rnd));
    }
}
