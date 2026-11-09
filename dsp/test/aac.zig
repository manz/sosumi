//! dsp/lib/aac.sm against its twin, ref/dsp/aac/decoder.zig `Decoder.decode`: the access units
//! `aacdec --dump` wrote (testdata/aac), each fixture from its saved decoder state on, PCM bit
//! for bit. Every table is the twin's own, at aac.sm's addresses (44.1 kHz).
const std = @import("std");
const ref = @import("ref");
const h = @import("../harness.zig");
const map = @import("../map.zig");
const aac = @import("../aac_player.zig");

const A = ref.dsp.aac;
const Word = ref.dsp.ops.Word;
const testing = std.testing;

const fi = 4;

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
    try aac.stageTables(&state, gpa, fi);
    try h.putY(&state, gpa, map.at("AK_NCH"), @intCast(nch));
    var p: usize = 20;
    for (0..nch) |c| {
        try h.putY(&state, gpa, map.at("AK_SHP") + @as(u32, @intCast(c)), @intCast(le32(dump, p)));
        p += 4;
        for (0..1024) |k| try state.x_mem.put(gpa, @intCast(map.at("OVL0") + 0x400 * c + k), le32(dump, p + 4 * k));
        p += 4096;
    }
    try state.x_mem.put(gpa, map.at("XRNG"), le32(dump, p));
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
            try state.y_mem.put(gpa, map.at("AU") + @as(u32, @intCast(i)), hi << 8 | lo);
        }
        state.cur_lane = 0;
        _ = try h.emu.runFrom(gpa, &state, prog, 0, 1 << 30);
        try testing.expect(state.halted);
        try testing.expectEqual(@as(?u32, 0), state.getY(map.at("AK_ST")));
        for (0..1024 * nch) |i| {
            try testing.expectEqual(le32(pcm, 4 * i) & 0xFFFF, state.getY(map.at("OUTY") + @as(u32, @intCast(i))) orelse 0xDEAD0000);
        }
    }
    try testing.expectEqual(dump.len, p);
}

test "aac_packet decodes the dumped access units as the twin's Decoder" {
    const gpa = testing.allocator;
    const prog = try aac.program(gpa);
    defer gpa.free(prog);
    inline for (.{ "tone.aac_at", "sweep.ff_tns", "pink.ff_pns", "pink.ff_is", "clicks.aac_at" }) |name| {
        try check(gpa, prog, @embedFile(name ++ ".pkts"));
    }
}
