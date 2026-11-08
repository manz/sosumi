//! dsp/lib/alac.sm through x17's host model against its twin, ref/dsp/alac/decoder.zig: the
//! packets `alacdec --dsp --dump` wrote (testdata/alac), PCM bit for bit, one host state per
//! fixture as a track would run.
const std = @import("std");
const ref = @import("ref");
const player = @import("../player.zig");

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
