//! dsp/lib/imdct.sm against its twin, ref/dsp/aac/imdct.zig `imdct`, long and short, with the
//! shared sine table (ISO/IEC 14496-3 4.6.11.3.2).
const std = @import("std");
const ref = @import("ref");
const h = @import("../harness.zig");
const map = @import("../map.zig");
const rev_eslot = std.fmt.comptimePrint("{d}, {d})", .{ map.at("REVL"), map.at("ESLOT") });

const I = ref.dsp.aac.imdct;
const Word = ref.dsp.ops.Word;
const testing = std.testing;

fn runs(comptime n2: usize, call: []const u8, seed: u64) !void {
    const gpa = testing.allocator;
    const src = try std.fmt.allocPrint(gpa, ".include \"lib/bits.sm\"\n.include \"lib/mem.sm\"\n.include \"lib/imdct.sm\"\n        bits_init()\n        {s}\n        x17.halt\n", .{call});
    defer gpa.free(src);
    const prog = try h.assemble(gpa, src);
    defer gpa.free(prog);
    var prng = std.Random.DefaultPrng.init(seed);
    const rnd = prng.random();
    for (0..6) |run| {
        var w: [n2]Word = undefined;
        // a falling spectrum; runs 0 and 3 near 2^22.3 (the halving), run 1 small
        // (doublings), run 2 silence, run 4 one positive peak, run 5 a large last coefficient
        const top: f64 = if (run == 1) 9 else 22.3;
        for (&w, 0..) |*v, k| {
            const amp = std.math.pow(f64, 2, top) / (1.0 + @as(f64, @floatFromInt(k)) / 8.0);
            v.* = @intFromFloat(@round((rnd.float(f64) * 2 - 1) * amp));
        }
        if (run == 2) @memset(&w, 0);
        if (run == 4) {
            for (&w) |*v| v.* = @divTrunc(v.*, 64);
            w[3] = (1 << 22) + 12345;
        }
        if (run == 5) {
            for (&w) |*v| v.* = @divTrunc(v.*, 64);
            w[n2 - 1] = (1 << 22) - 3;
        }
        const e: i32 = -20 + @as(i32, @intCast(run)) * 3;
        var want: [2 * n2]Word = undefined;
        I.imdct(n2, &w, e, &want);

        var state = h.emu.State{};
        defer state.deinit(gpa);
        for (w, 0..) |v, k| try h.putX(&state, gpa, 0x400 + @as(u32, @intCast(k)), v);
        try h.stageImdct(&state, gpa, n2, map.at("REVL"));
        try h.stageSine(&state, gpa, 0x1000, 0x1400);
        try h.putY(&state, gpa, map.at("ESLOT"), e);
        _ = try h.emu.runFrom(gpa, &state, prog, 0, 1 << 26);
        try testing.expect(state.halted);
        for (want, 0..) |v, k| {
            try testing.expectEqual(@as(u32, @as(u24, @bitCast(v))), state.readX(0x800 + @as(u32, @intCast(k))) orelse 0xDEAD);
        }
    }
}

test "imdct transforms a long block as the twin does" {
    try runs(1024, "imdct(1024, 512, 10, 9, 0x0400, 0x0000, 0x0800, 0x1000 + 1023, 0x1000, 2, 0x1400, " ++ rev_eslot, 0x1DC7);
}

test "imdct transforms a short block as the twin does" {
    try runs(128, "imdct_even(128, 64, 7, 6, 0x0400, 0x0000, 0x0800, 0x1400 + 510, 0x1400 + 2, 8, 0x1400, " ++ rev_eslot, 0x5B7);
}

fn twgen(comptime n2: usize) !void {
    const gpa = testing.allocator;
    const T = I.Tables(n2);
    const l = T.n4 / 4;
    const src = try std.fmt.allocPrint(gpa, ".include \"lib/bits.sm\"\n.include \"lib/mem.sm\"\n.include \"lib/imdct.sm\"\n        bits_init()\n        im_twgen(0x0400, 0x1400, {d})\n        x17.halt\n", .{l});
    defer gpa.free(src);
    const prog = try h.assemble(gpa, src);
    defer gpa.free(prog);
    var state = h.emu.State{};
    defer state.deinit(gpa);
    try h.stageSine(&state, gpa, 0x1000, 0x1400);
    _ = try h.emu.runFrom(gpa, &state, prog, 0, 1 << 22);
    try testing.expect(state.halted);
    for (T.tw4[T.tw4_len - l ..], 0..) |w, j| for (w, 0..) |c, m| {
        const at: u32 = 0x400 + @as(u32, @intCast(6 * j + 2 * m));
        try testing.expectEqual(@as(u32, @as(u24, @bitCast(c.re))), state.readX(at) orelse 0xDEAD);
        try testing.expectEqual(@as(u32, @as(u24, @bitCast(c.im))), state.readX(at + 1) orelse 0xDEAD);
    };
}

test "im_twgen writes the last radix-4 stage's twiddles from the sine table" {
    try twgen(128);
    try twgen(1024);
}
