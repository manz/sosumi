//! dsp/lib/huffman.sm against its twin, ref/dsp/aac/huffman.zig: the twin's own tables for the
//! scale factor book and the eleven spectral books, decoded from random bits.
const std = @import("std");
const ref = @import("ref");
const h = @import("../harness.zig");

const H = ref.dsp.aac.huffman;
const Word = ref.dsp.ops.Word;
const testing = std.testing;

const table_base = 0x1000;
const out_base = 0x100;
const count = 8;

/// The macro that decodes one codeword of `book` (ISO/IEC 14496-3 4.6.3.1, table 4.152).
fn macro(book: u4) []const u8 {
    return switch (book) {
        1, 2 => "spec_quad_s()",
        3, 4 => "spec_quad_u()",
        5, 6 => "spec_pair_s()",
        7, 8, 9, 10 => "spec_pair_u()",
        11 => "spec_pair_esc(fail)",
        else => unreachable,
    };
}

fn x24(w: Word) u32 {
    return @as(u24, @bitCast(w));
}

/// Runs `body` count times over `data` with `table` staged in Y; the program halts after
/// reading 8 more bits into s8, or stores 0x777 and halts at `fail`.
fn run(gpa: std.mem.Allocator, state: *h.emu.State, table: H.Table, data: []const u8, body: []const u8) !void {
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(gpa);
    try src.appendSlice(gpa, ".include \"lib/bits.sm\"\n.include \"lib/huffman.sm\"\n        bits_init()\n");
    for (0..count) |_| try src.print(gpa, "        ldi s1, #{d}\n        ldi s11, #{d}\n{s}\n", .{ table_base, table.root, body });
    // two bundles after x17.halt still run, so the fail marker sits past them
    try src.appendSlice(gpa,
        \\        getbits(s8, 8)
        \\        x17.halt
        \\        nop()
        \\        nop()
        \\fail:   ldi s1, #0x777
        \\        stx A6, s1
        \\        x17.halt
        \\
    );
    const prog = try h.assemble(gpa, src.items);
    defer gpa.free(prog);
    try h.stagePacket(gpa, state, data);
    for (table.words, 0..) |w, i| try state.y_mem.put(gpa, table_base + @as(u32, @intCast(i)), w);
    state.a[6] = out_base;
    _ = try h.emu.runFrom(gpa, state, prog, 0, 1 << 20);
    try testing.expect(state.halted);
}

test "huff_decode decodes the scale factor book as the twin does" {
    const gpa = testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x4AFF);
    const rnd = prng.random();
    var deep: usize = 0;
    for (0..60) |trial| {
        var data: [256]u8 = undefined;
        rnd.bytes(&data);
        // the long scale factor codewords are runs of ones: dense bits on every other trial
        if (trial % 2 == 1) for (&data) |*x| {
            x.* |= rnd.int(u8);
        };
        var state = h.emu.State{};
        defer state.deinit(gpa);
        try run(gpa, &state, H.scalefactor, &data, "        huff_decode(s1)\n        stx A6, s1\n        x02.ainc #6, #6");

        var r = ref.dsp.bits.Reader.init(&data);
        for (0..count) |i| {
            const before = r.pos;
            const want = try H.decode(&r, H.scalefactor);
            if (r.pos - before > H.scalefactor.root) deep += 1;
            try testing.expectEqual(x24(want), state.readX(out_base + @as(u32, @intCast(i))) orelse 0xDEAD);
        }
        try testing.expectEqual(x24(try r.read(8)), state.s[8]);
    }
    try testing.expect(deep > 20);
}

test "the spectral macros decode every spectral book as the twin's decodeSpectral" {
    const gpa = testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x5BEC);
    const rnd = prng.random();
    var escapes: usize = 0;
    var fails: usize = 0;
    for (1..12) |b| {
        const book: u4 = @intCast(b);
        const dim = ref.aac.huffman.books[book - 1].dim;
        for (0..@as(usize, if (book == 11) 300 else 40)) |trial| {
            var data: [256]u8 = undefined;
            rnd.bytes(&data);
            // sparse bits favour short codewords and escape prefixes; dense ones reach N > 8
            if (book == 11) for (&data) |*x| {
                x.* = if (trial % 2 == 1) x.* | rnd.int(u8) else x.* & (rnd.int(u8) | rnd.int(u8));
            };
            var state = h.emu.State{};
            defer state.deinit(gpa);
            try run(gpa, &state, H.spectral[book - 1], &data, macro(book));

            var r = ref.dsp.bits.Reader.init(&data);
            var at: u32 = out_base;
            const failed = for (0..count) |_| {
                var out: [4]Word = undefined;
                H.decodeSpectral(&r, book, out[0..dim]) catch |e| {
                    try testing.expectEqual(error.EscapeTooLong, e);
                    break true;
                };
                for (out[0..dim]) |x| {
                    if (@abs(@as(i32, x)) > 16) escapes += 1;
                    try testing.expectEqual(x24(x), state.readX(at) orelse 0xDEAD);
                    at += 1;
                }
            } else false;
            if (failed) {
                fails += 1;
                try testing.expectEqual(@as(u32, 0x777), state.readX(at) orelse 0xDEAD);
            } else try testing.expectEqual(x24(try r.read(8)), state.s[8]);
        }
    }
    try testing.expect(escapes > 10);
    try testing.expect(fails > 2);
}
