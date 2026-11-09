//! dsp/lib/pcm.sm through x17's host model: packets in, the output ring read back.
const std = @import("std");
const host = @import("host");
const h = @import("../harness.zig");

const testing = std.testing;

test "pcm_packet copies WAV and AIFF samples into the host ring, packet after packet" {
    const gpa = testing.allocator;
    const prog = try h.assemble(gpa,
        \\.include "lib/bits.sm"
        \\.include "lib/mem.sm"
        \\.include "lib/ring.sm"
        \\.include "lib/pcm.sm"
        \\        bits_init(0x4000)
        \\        pcm_packet()
        \\        x17.halt
        \\
    );
    defer gpa.free(prog);
    var prng = std.Random.DefaultPrng.init(0x9C3);
    const rnd = prng.random();
    for ([_]u32{ 1, 0 }) |little| {
        var hst = try host.Host.init(gpa, .{ .max_bundles = 1 << 24 });
        defer hst.deinit();
        try h.stageRing(&hst.state, gpa, 2, 0x800);
        try hst.state.y_mem.put(gpa, 0xFD81, little);
        var want: std.ArrayList(i16) = .empty;
        defer want.deinit(gpa);
        // three packets: the ring flips 0, 1, 0; one is empty
        for ([_]usize{ 300, 0, 2048 }) |n| {
            const bytes = try gpa.alloc(u8, 2 * n);
            defer gpa.free(bytes);
            for (0..n) |k| {
                const v: i16 = if (k == 0) -32768 else if (k == 1) 32767 else rnd.int(i16);
                try want.append(gpa, v);
                const u: u16 = @bitCast(v);
                const order: std.builtin.Endian = if (little == 1) .little else .big;
                std.mem.writeInt(u16, bytes[2 * k ..][0..2], u, order);
            }
            const r = try hst.feed(prog, bytes);
            try testing.expectEqual(n, r.units);
            try testing.expectEqual(@as(?u32, 1), hst.state.getY(0xFD94));
        }
        try testing.expectEqualSlices(i16, want.items, hst.pcm.items);
    }
}
