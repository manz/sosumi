//! dsp/lib/sections.sm against its twin, ref/dsp/aac/sections.zig, on generated
//! section_data() and scale_factor_data() streams (ISO/IEC 14496-3 4.6.2.3), with the twin's
//! scale factor book.
const std = @import("std");
const ref = @import("ref");
const h = @import("../harness.zig");

const S = ref.dsp.aac.sections;
const H = ref.dsp.aac.huffman;
const codes = ref.aac.huffman_tables;
const Word = ref.dsp.ops.Word;
const testing = std.testing;

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

/// A plausible stream: sections, then scale factor codewords, now and then a reserved book, an
/// overrun or a scale factor outside 0..255; random bytes after.
fn write(w: *Writer, rnd: std.Random, s: Shape) void {
    const sb: u5 = if (s.short) 3 else 5;
    const esc: u32 = if (s.short) 7 else 31;
    var books: [121]u4 = undefined;
    var n: usize = 0;
    for (0..s.groups) |_| {
        var left: u32 = s.max_sfb;
        while (left > 0) {
            var cb = rnd.intRangeAtMost(u4, 0, 15);
            if (cb == 12 and rnd.uintLessThan(u8, 8) != 0) cb = 1;
            var len = rnd.intRangeAtMost(u32, 0, left);
            if (rnd.uintLessThan(u8, 60) == 0) len = left + 1 + rnd.uintLessThan(u32, 40);
            w.put(cb, 4);
            var l = len;
            while (l >= esc) : (l -= esc) w.put(esc, sb);
            w.put(l, sb);
            for (0..@min(len, left)) |_| {
                books[n] = cb;
                n += 1;
            }
            left -|= len;
        }
    }
    var fac: i32 = s.gain;
    var pcm = true;
    for (books[0..n]) |cb| switch (cb) {
        0 => {},
        13 => if (pcm) {
            pcm = false;
            w.put(rnd.int(u9), 9);
        } else w.delta(rnd.intRangeAtMost(i32, -60, 60)),
        14, 15 => w.delta(rnd.intRangeAtMost(i32, -60, 60)),
        else => {
            var d = rnd.intRangeAtMost(i32, -10, 10);
            if (rnd.uintLessThan(u8, 100) == 0) d = if (fac > 127) 60 else -60;
            if ((fac + d < 0 or fac + d > 255) and rnd.boolean()) d = -d;
            fac += d;
            w.delta(d);
        },
    };
    for (0..32) |_| w.put(rnd.int(u8), 8);
}

fn y16(w: Word) u32 {
    return @as(u16, @truncate(@as(u24, @bitCast(w))));
}

test "aac_sections and aac_scalefactors decode as the twin does" {
    const gpa = testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x5EC5);
    const rnd = prng.random();
    var ok: usize = 0;
    var sec_fails: usize = 0;
    var sf_fails: usize = 0;
    var grouped: usize = 0;
    for (0..150) |_| {
        const short = rnd.boolean();
        const s: Shape = .{
            .short = short,
            .groups = if (short) rnd.intRangeAtMost(u4, 1, 8) else 1,
            .max_sfb = if (short) rnd.intRangeAtMost(u6, 0, 15) else rnd.intRangeAtMost(u6, 0, 51),
            .gain = rnd.int(u8),
        };
        var w: Writer = .{};
        write(&w, rnd, s);

        var src: std.ArrayList(u8) = .empty;
        defer src.deinit(gpa);
        // two bundles after x17.halt still run, so each fail marker sits past them
        try src.print(gpa,
            \\.include "lib/bits.sm"
            \\.include "lib/huffman.sm"
            \\.include "lib/sections.sm"
            \\        bits_init(0x4000)
            \\        ldi s1, #{d}
            \\        ldi s2, #{d}
            \\        aac_sections({d}, {d}, fail1)
            \\        ldi s1, #{d}
            \\        aac_scalefactors(0x1000, fail)
            \\        getbits(s8, 8)
            \\        x17.halt
            \\        nop()
            \\        nop()
            \\fail1:  ldi s8, #0x777
            \\        x17.halt
            \\        nop()
            \\        nop()
            \\fail:   ldi s8, #0x778
            \\        x17.halt
            \\
        , .{ s.groups, s.max_sfb, @as(u32, if (short) 3 else 5), @as(u32, if (short) 7 else 31), s.gain });
        const prog = try h.assemble(gpa, src.items);
        defer gpa.free(prog);

        var state = h.emu.State{};
        defer state.deinit(gpa);
        try h.stagePacket(gpa, &state, 0x4000, &w.buf);
        for (H.scalefactor.words, 0..) |x, i| try state.y_mem.put(gpa, 0x1000 + @as(u32, @intCast(i)), x);
        _ = try h.emu.runFrom(gpa, &state, prog, 0, 1 << 22);
        try testing.expect(state.halted);

        var r = ref.dsp.bits.Reader.init(&w.buf);
        var b: S.Bands = .{};
        S.readSections(&r, short, s.groups, s.max_sfb, &b) catch |e| {
            try testing.expect(e == error.ReservedCodebook or e == error.SectionOverrun);
            try testing.expectEqual(@as(u32, 0x777), state.s[8]);
            sec_fails += 1;
            continue;
        };
        S.readScalefactors(&r, s.gain, &b) catch |e| {
            try testing.expectEqual(error.ScalefactorOutOfRange, e);
            try testing.expectEqual(@as(u32, 0x778), state.s[8]);
            sf_fails += 1;
            continue;
        };
        ok += 1;
        if (short and s.groups > 1) grouped += 1;
        for (b.book[0..b.n], b.sf[0..b.n], 0..) |cb, sf, i| {
            const at: u32 = @intCast(i);
            try testing.expectEqual(y16(cb), state.getY(0x2000 + at) orelse 0xDEAD);
            try testing.expectEqual(y16(sf), state.getY(0x2080 + at) orelse 0xDEAD);
        }
        try testing.expectEqual(@as(u32, 0xFFFF), state.getY(0x2000 + @as(u32, @intCast(b.n))) orelse 0xDEAD);
        try testing.expectEqual(@as(u32, @intCast(try r.read(8))), state.s[8]);
    }
    try testing.expect(ok > 90);
    try testing.expect(sec_fails > 5);
    try testing.expect(sf_fails > 3);
    try testing.expect(grouped > 20);
}
