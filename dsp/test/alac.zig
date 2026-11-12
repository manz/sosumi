//! dsp/lib/alac.sm through x17's host model against its twin, ref/dsp/alac/decoder.zig: the
//! packets `alacdec --dsp --dump` wrote (testdata/alac), PCM bit for bit, one host state per
//! fixture as a track would run.
const std = @import("std");
const ref = @import("ref");
const player = @import("../player.zig");
const h = @import("../harness.zig");
const image = @import("image");

const testing = std.testing;

fn le32(b: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, b[at..][0..4], .little);
}

/// Format: tools/alacdec/main.zig `Dump`.
fn check(gpa: std.mem.Allocator, prog: []const u32, dump: []const u8) !void {
    try testing.expectEqualSlices(u8, "ALPK", dump[0..4]);
    const cfg: ref.alac.config.Config = .{
        .frame_length = le32(dump, 4),
        .compatible_version = 0,
        .bit_depth = @intCast(le32(dump, 8)),
        .pb = @intCast(le32(dump, 12)),
        .mb = @intCast(le32(dump, 16)),
        .kb = @intCast(le32(dump, 20)),
        .channels = @intCast(le32(dump, 24)),
        .max_run = 255,
        .max_frame_bytes = 0,
        .avg_bit_rate = 0,
        .sample_rate = 44100,
    };
    if (!player.supported(cfg)) {
        try testing.expectError(error.Unsupported, player.Player.init(gpa, prog, cfg));
        return;
    }
    var p = try player.Player.init(gpa, prog, cfg);
    defer p.deinit();
    var at: usize = 32;
    for (0..le32(dump, 28)) |_| {
        const len = le32(dump, at);
        const pkt = dump[at + 4 .. at + 4 + len];
        at += 4 + len;
        const n = le32(dump, at);
        at += 4;
        const want = dump[at .. at + 4 * n * cfg.channels];
        at += want.len;
        const got = try p.feed(pkt);
        try testing.expectEqual(@as(usize, n), p.frames());
        try testing.expectEqual(n * cfg.channels, got.len);
        for (got, 0..) |s, i| try testing.expectEqual(@as(i16, @truncate(@as(i32, @bitCast(le32(want, 4 * i))))), s);
    }
    try testing.expectEqual(dump.len, at);
}

test "alac_packet through the host decodes the dumped packets as the twin's Decoder" {
    const gpa = testing.allocator;
    const prog = try player.program(gpa);
    defer gpa.free(prog);
    inline for (.{ "mono.at", "tone.at", "white24.at", "clicks.c0.ff", "clicks.o30.ff", "mono.at.int", "tone.at.int" }) |name| {
        try check(gpa, prog, @embedFile(name ++ ".pkts"));
    }
}

test "the ALAC x17 image's init pass, then its decoder at q256, decode as the twin" {
    const gpa = testing.allocator;
    var src: std.Io.Writer.Allocating = .init(gpa);
    defer src.deinit();
    try player.imageSource(gpa, &src.writer, "lib");
    var prog = try h.assembleImage(gpa, src.written());
    defer prog.deinit();
    const bytes = try image.write(gpa, &prog);
    defer gpa.free(bytes);
    var img = try image.parse(gpa, bytes);
    defer img.deinit(gpa);
    try testing.expectEqual(@as(?u8, 3), img.mode());
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
            .mode => {}, // the configure mode (fact 960), no words
        };
        if (pass == 0) {
            _ = try h.emu.runFrom(gpa, &state, p, 0, 1 << 10);
            try testing.expect(state.halted);
        }
    }
    const dump = @embedFile("clicks.o30.ff.pkts");
    const nch = le32(dump, 24);
    // the per-track configure words the host writes (specs/alac.md)
    for ([_][2]u32{ .{ 0xFD80, 0x1F }, .{ 0xFD82, le32(dump, 8) }, .{ 0xFD83, le32(dump, 12) }, .{ 0xFD84, le32(dump, 20) }, .{ 0xFD85, le32(dump, 16) } }) |q|
        try state.y_mem.put(gpa, q[0], q[1]);
    var at: usize = 32;
    for (0..le32(dump, 28)) |_| {
        const len = le32(dump, at);
        const pkt = dump[at + 4 .. at + 4 + len];
        at += 4 + len;
        const n = le32(dump, at);
        at += 4;
        const want = dump[at .. at + 4 * n * nch];
        at += want.len;
        try h.stagePacket(gpa, &state, pkt);
        state.halted = false;
        state.cur_lane = 0;
        _ = try h.emu.runFrom(gpa, &state, p, 256, 1 << 26);
        try testing.expect(state.halted and !state.stream_starved);
        try testing.expectEqual(@as(u32, 2 * n), state.getY(6).?);
        for (0..n * nch) |i| {
            const off: u32 = @intCast(if (nch == 1) 2 * i else i);
            try testing.expectEqual(@as(i16, @truncate(@as(i32, @bitCast(le32(want, 4 * i))))), h.sx16(state.getY(0x80 + off)));
        }
    }
    try testing.expectEqual(dump.len, at);
    // mode 3's maps (specs/alac.md, fact 960): Y stores outside 0..0x227F, the window
    // 0x2400..0x267F and the host's FD80..FDFF are dropped on silicon; X kept below 0x2000
    var ys = state.y_mem.keyIterator();
    while (ys.next()) |a| {
        const ok = a.* < 0x2280 or (a.* >= 0x2400 and a.* < 0x2680) or (a.* >= 0xFD80 and a.* < 0xFE00);
        if (!ok) std.debug.print("Y:0x{X} outside mode 3's map\n", .{a.*});
        try testing.expect(ok);
    }
    var xs = state.x_mem.keyIterator();
    while (xs.next()) |a| try testing.expect(a.* < 0x2000);
}
