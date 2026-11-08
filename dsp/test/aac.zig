//! dsp/lib/aac.sm against its twin, ref/dsp/aac/decoder.zig `Decoder.decode`: the access units
//! `aacdec --dump` wrote (testdata/aac), each fixture from its saved decoder state on, PCM bit
//! for bit. Every table is the twin's own, at aac.sm's addresses (44.1 kHz).
const std = @import("std");
const ref = @import("ref");
const h = @import("../harness.zig");

const A = ref.dsp.aac;
const Word = ref.dsp.ops.Word;
const testing = std.testing;

const fi = 4;

/// Every table aac.sm reads, filled once by the host.
fn stageTables(st: *h.emu.State, gpa: std.mem.Allocator) !void {
    // Huffman codes in Y from HUFF0, the scale factor code first; AK_BOOKS + b points at book b
    var addr: u32 = 0x4800;
    for (0..12) |b| {
        const t = if (b == 0) A.huffman.scalefactor else A.huffman.spectral[b - 1];
        for (t.words, 0..) |w, i| try st.y_mem.put(gpa, addr + @as(u32, @intCast(i)), w);
        if (b > 0) try h.putY(st, gpa, 0x3C40 + @as(u32, @intCast(b)), @intCast(addr));
        addr += @intCast(t.words.len);
    }
    try testing.expect(addr <= 0x5C00); // CUR
    // dequantiser
    for (A.dequant.direct_m, A.dequant.direct_e, 0..) |m, e, k| {
        try h.putX(st, gpa, 0x1800 + 2 * @as(u32, @intCast(k)), m);
        try h.putX(st, gpa, 0x1801 + 2 * @as(u32, @intCast(k)), e);
    }
    try h.putAllX(st, gpa, 0x1910, &A.dequant.interp);
    try h.putAllX(st, gpa, 0x1960, &A.dequant.gain);
    for (A.dequant.interp_e, A.dequant.interp_rem, 0..) |e, r, j| {
        try h.putY(st, gpa, 0x2140 + @as(u32, @intCast(j)), e);
        try h.putY(st, gpa, 0x2148 + @as(u32, @intCast(j)), 4 * r);
    }
    try h.stageImdct(st, gpa, 1024, 0x1000, 0x1400, 0x3000, 0x2400);
    try h.stageImdct(st, gpa, 128, 0x1A00, 0x1A80, 0x1B00, 0x2D00);
    for (0..2) |s| {
        try h.putAllX(st, gpa, 0x4800 + 0x400 * @as(u32, @intCast(s)), &A.window.long[s]);
        try h.putAllX(st, gpa, 0x5000 + 0x80 * @as(u32, @intCast(s)), &A.window.short[s]);
    }
    try h.putAllX(st, gpa, 0x5100, &A.stereo.quarter);
    try h.putAllX(st, gpa, 0x5104, &A.pns.quarter);
    try h.putAllX(st, gpa, 0x5108, &A.pns.seed);
    try h.putAllX(st, gpa, 0x5110, A.tns.refl[0][0..8]);
    try h.putAllX(st, gpa, 0x5118, &A.tns.refl[1]);
    // swb_offset (64 words each, the last value repeated), band counts, TNS_MAX_BANDS
    const long = ref.aac.swb.long[fi];
    const short = ref.aac.swb.short[fi];
    for (0..64) |k| {
        try h.putY(st, gpa, 0x3D00 + @as(u32, @intCast(k)), long[@min(k, long.len - 1)]);
        try h.putY(st, gpa, 0x3D40 + @as(u32, @intCast(k)), short[@min(k, short.len - 1)]);
    }
    try h.putY(st, gpa, 0x3C0A, @intCast(long.len - 1));
    try h.putY(st, gpa, 0x3C0B, @intCast(short.len - 1));
    try h.putY(st, gpa, 0x3C0C, ref.aac.tns.max_bands_long[fi]);
    try h.putY(st, gpa, 0x3C0D, ref.aac.tns.max_bands_short[fi]);
}

fn le32(b: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, b[at..][0..4], .little);
}

/// The dump's state into aac.sm's slots, then each access unit in one emulator state, its PCM
/// against the twin's. Format: tools/aacdec/main.zig `Dump`.
fn check(gpa: std.mem.Allocator, prog: []const u32, dump: []const u8) !void {
    try testing.expectEqualSlices(u8, "AAPK", dump[0..4]);
    try testing.expectEqual(@as(u32, fi), le32(dump, 4));
    const nch = le32(dump, 8);
    const count = le32(dump, 16);
    var state = h.emu.State{};
    defer state.deinit(gpa);
    try stageTables(&state, gpa);
    try h.putY(&state, gpa, 0x3C00, @intCast(nch));
    var p: usize = 20;
    for (0..nch) |c| {
        try h.putY(&state, gpa, 0x3C0E + @as(u32, @intCast(c)), @intCast(le32(dump, p)));
        p += 4;
        for (0..1024) |k| try state.x_mem.put(gpa, @intCast(0x3C00 + 0x400 * c + k), le32(dump, p + 4 * k));
        p += 4096;
    }
    try state.x_mem.put(gpa, 0x5130, le32(dump, p));
    p += 4;
    for (0..count) |_| {
        const len = le32(dump, p);
        const au = dump[p + 4 .. p + 4 + len];
        p += 4 + len;
        const pcm = dump[p .. p + 4 * 1024 * nch];
        p += 4 * 1024 * nch;
        // 16-bit words, the first byte high; an odd last byte gets a zero low half
        for (0..(len + 1) / 2) |i| {
            const hi: u32 = au[2 * i];
            const lo: u32 = if (2 * i + 1 < len) au[2 * i + 1] else 0;
            try state.y_mem.put(gpa, 0x4000 + @as(u32, @intCast(i)), hi << 8 | lo);
        }
        state.cur_lane = 0;
        _ = try h.emu.runFrom(gpa, &state, prog, 0, 1 << 30);
        try testing.expect(state.halted);
        try testing.expectEqual(@as(?u32, 0), state.getY(0x3C01));
        for (0..1024 * nch) |i| {
            try testing.expectEqual(le32(pcm, 4 * i) & 0xFFFF, state.getY(0x3400 + @as(u32, @intCast(i))) orelse 0xDEAD0000);
        }
    }
    try testing.expectEqual(dump.len, p);
}

test "aac_packet decodes the dumped access units as the twin's Decoder" {
    const gpa = testing.allocator;
    const prog = try h.assemble(gpa,
        \\.include "lib/bits.sm"
        \\.include "lib/mem.sm"
        \\.include "lib/huffman.sm"
        \\.include "lib/sections.sm"
        \\.include "lib/dequant.sm"
        \\.include "lib/stereo.sm"
        \\.include "lib/pns.sm"
        \\.include "lib/tns.sm"
        \\.include "lib/imdct.sm"
        \\.include "lib/window.sm"
        \\.include "lib/aac.sm"
        \\        bits_init(0x4000)
        \\        aac_packet()
        \\        x17.halt
        \\
    );
    defer gpa.free(prog);
    inline for (.{ "tone.aac_at", "sweep.ff_tns", "pink.ff_pns", "pink.ff_is", "clicks.aac_at" }) |name| {
        try check(gpa, prog, @embedFile(name ++ ".pkts"));
    }
}
