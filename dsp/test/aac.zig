//! dsp/lib/aac.sm against its twin, ref/dsp/aac/decoder.zig `Decoder.decode`: the access units
//! `aacdec --dump` wrote (testdata/aac), each fixture from its saved decoder state on, PCM bit
//! for bit. Every table is the twin's own, at aac.sm's addresses (44.1 kHz).
const std = @import("std");
const ref = @import("ref");
const h = @import("../harness.zig");
const map = @import("../map.zig");
const aac = @import("../aac_player.zig");
const image = @import("image");

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
    var state = h.emu.State{};
    defer state.deinit(gpa);
    try aac.stageTables(&state, gpa, fi);
    try checkFrom(gpa, &state, prog, 0, dump);
}

/// `check` on a state whose tables are in place, the program entered at syllable `start`.
fn checkFrom(gpa: std.mem.Allocator, state: *h.emu.State, prog: []const u32, start: usize, dump: []const u8) !void {
    try testing.expectEqualSlices(u8, "AAPK", dump[0..4]);
    try testing.expectEqual(@as(u32, fi), le32(dump, 4));
    const nch = le32(dump, 8);
    const count = le32(dump, 16);
    try h.putY(state, gpa, map.at("AK_NCH"), @intCast(nch));
    var p: usize = 20;
    for (0..nch) |c| {
        try h.putY(state, gpa, map.at("AK_SHP") + @as(u32, @intCast(c)), @intCast(le32(dump, p)));
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
        try state.queueStream(gpa, au); // the host arms the access unit (fact 783)
        state.cur_lane = 0;
        const k = state.getY(map.at("AK_OSL")) orelse 0;
        try state.y_mem.put(gpa, map.at("HOST_ST"), 0x8000);
        _ = try h.emu.runFrom(gpa, state, prog, start, 1 << 30);
        try testing.expect(!state.stream_starved); // never past its own access unit (784)
        try testing.expect(state.halted);
        try testing.expectEqual(@as(?u32, 0), state.getY(map.at("AK_ST")));
        for (0..1024 * nch) |i| {
            try testing.expectEqual(le32(pcm, 4 * i) & 0xFFFF, state.getY(map.at("OUTY") + 0x800 * k + @as(u32, @intCast(i))) orelse 0xDEAD0000);
        }
        // the output contract: slot k owned with its length, output ready, the other slot next
        try testing.expectEqual(@as(?u32, 1), state.getY(map.at("RING_E") + 2 * k));
        try testing.expectEqual(@as(?u32, 0x800), state.getY(map.at("RING_E") + 2 * k + 1));
        try testing.expectEqual(@as(?u32, 0x8001), state.getY(map.at("HOST_ST")));
        try testing.expectEqual(@as(?u32, 0), state.getY(map.at("HOST_P0")));
        try testing.expectEqual(@as(?u32, 1 - k), state.getY(map.at("AK_OSL")));
        try state.y_mem.put(gpa, map.at("RING_E") + 2 * k, 0);
    }
    try testing.expectEqual(dump.len, p);
    // mode 0 (docs/aac-mode0.md): X below 0x1C00, Y below 0x2F00, the host's below 0x2E80
    var xi = state.x_mem.keyIterator();
    while (xi.next()) |k| try testing.expect(k.* < 0x1C00);
    var yi = state.y_mem.keyIterator();
    while (yi.next()) |k| {
        if (k.* >= map.at("HOST_P0") and k.* <= map.at("HOST_ST") + 1) continue; // the host's block
        try testing.expect(k.* < 0x2F00);
    }
}

test "aac_packet decodes the dumped access units as the twin's Decoder" {
    const gpa = testing.allocator;
    const prog = try aac.program(gpa);
    defer gpa.free(prog);
    inline for (.{ "tone.aac_at", "sweep.ff_tns", "pink.ff_pns", "pink.ff_is", "clicks.aac_at" }) |name| {
        try check(gpa, prog, @embedFile(name ++ ".pkts"));
    }
}

test "the stages read the records' fields in place" {
    try testing.expectEqual(map.at("STL") + map.at("R_BOOK"), map.at("PN_LBOOK"));
    try testing.expectEqual(map.at("STL") + map.at("R_SF"), map.at("PN_LSF"));
    try testing.expectEqual(map.at("STL") + map.at("R_BOOK"), map.at("ST_LB"));
    try testing.expectEqual(map.at("STR") + map.at("R_BOOK"), map.at("ST_RB"));
    try testing.expectEqual(map.at("STR") + map.at("R_SF"), map.at("ST_RS"));
    try testing.expectEqual(map.at("PAIR_MSU"), map.at("PN_MSU"));
    try testing.expectEqual(map.at("PAIR_MSU"), map.at("ST_MSU"));
    // the stage blocks end below the KBD tables
    try testing.expect(map.at("PN_RUNS") + 384 <= map.at("KBD_L"));
    try testing.expect(map.at("ST_RUNS") + 384 <= map.at("KBD_L"));
    try testing.expect(map.at("PN_PE") + 128 <= map.at("KBD_L"));
    try testing.expect(map.at("PN_RUNS") + 384 <= map.at("PN_PE"));
}

test "the x17 image's init pass, then its decoder at q256, decode as the twin" {
    const gpa = testing.allocator;
    var src: std.Io.Writer.Allocating = .init(gpa);
    defer src.deinit();
    try aac.imageSource(gpa, &src.writer, "lib", fi, 2);
    var prog = try h.assembleImage(gpa, src.written());
    defer prog.deinit();
    const bytes = try image.write(gpa, &prog);
    defer gpa.free(bytes);
    var img = try image.parse(gpa, bytes);
    defer img.deinit(gpa);
    // init pass: its P and data, run from q0 to its halt; then the decoder's P over it
    const p = try gpa.alloc(u32, 0x4000);
    defer gpa.free(p);
    var state = h.emu.State{};
    defer state.deinit(gpa);
    for ([_]u8{ 0, image.decoder_pass }) |pass| {
        @memset(p, 0);
        for (img.sections) |sec| if (sec.pass == pass) switch (sec.kind) {
            .p => image.placeRows(p, sec),
            .x => for (sec.words, 0..) |w, k| try state.x_mem.put(gpa, sec.addr + @as(u32, @intCast(k)), w),
            .y, .param => for (sec.words, 0..) |w, k| try state.y_mem.put(gpa, sec.addr + @as(u32, @intCast(k)), w),
        };
        if (pass == 0) {
            _ = try h.emu.runFrom(gpa, &state, p, 0, 1 << 10);
            try testing.expect(state.halted);
        }
    }
    try testing.expectEqual(@as(?u32, 2), state.getY(map.at("AK_NCH")));
    try checkFrom(gpa, &state, p, 256, @embedFile("pink.ff_pns.pkts"));
}
