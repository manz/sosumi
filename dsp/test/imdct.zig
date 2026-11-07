//! dsp/lib/imdct.sm against its twin, ref/dsp/aac/imdct.zig `imdct`, long and short, with the
//! twin's own twiddle tables (ISO/IEC 14496-3 4.6.11.3.2).
const std = @import("std");
const ref = @import("ref");
const h = @import("../harness.zig");

const I = ref.dsp.aac.imdct;
const Word = ref.dsp.ops.Word;
const testing = std.testing;

fn putX(st: *h.emu.State, gpa: std.mem.Allocator, addr: u32, v: Word) !void {
    try st.x_mem.put(gpa, addr, @as(u24, @bitCast(v)));
}

fn putY(st: *h.emu.State, gpa: std.mem.Allocator, addr: u32, v: i32) !void {
    try st.y_mem.put(gpa, addr, @as(u16, @truncate(@as(u32, @bitCast(v)))));
}

fn putCx(st: *h.emu.State, gpa: std.mem.Allocator, base: u32, k: usize, c: I.Cx) !void {
    try putX(st, gpa, base + 2 * @as(u32, @intCast(k)), c.re);
    try putX(st, gpa, base + 2 * @as(u32, @intCast(k)) + 1, c.im);
}

fn runs(comptime n2: usize, call: []const u8, seed: u64) !void {
    const gpa = testing.allocator;
    const T = I.Tables(n2);
    const src = try std.fmt.allocPrint(gpa, ".include \"lib/bits.sm\"\n.include \"lib/mem.sm\"\n.include \"lib/imdct.sm\"\n        bits_init(0x4000)\n        {s}\n        x17.halt\n", .{call});
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
        for (w, 0..) |v, k| try putX(&state, gpa, 0x400 + @as(u32, @intCast(k)), v);
        for (T.pre, 0..) |c, k| try putCx(&state, gpa, 0x1000, k, c);
        for (T.post, 0..) |c, k| try putCx(&state, gpa, 0x1400, k, c);
        // TW: stage by stage, for size 2, 4, .. n4, the twin's fft[i * n4 / size], i < size / 2
        var at: usize = 0;
        var size: usize = 2;
        while (size <= T.n4) : (size *= 2) {
            for (0..size / 2) |i| {
                try putCx(&state, gpa, 0x1A00, at, T.fft[i * (T.n4 / size)]);
                at += 1;
            }
        }
        try testing.expectEqual(T.n4 - 1, at);
        for (T.rev, 0..) |r, n| try putY(&state, gpa, 0x2400 + @as(u32, @intCast(n)), 2 * @as(i32, r) - 2);
        try putY(&state, gpa, 0x2390, e);
        _ = try h.emu.runFrom(gpa, &state, prog, 0, 1 << 26);
        try testing.expect(state.halted);
        for (want, 0..) |v, k| {
            try testing.expectEqual(@as(u32, @as(u24, @bitCast(v))), state.readX(0x800 + @as(u32, @intCast(k))) orelse 0xDEAD);
        }
    }
}

test "imdct transforms a long block as the twin does" {
    try runs(1024, "imdct(1024, 512, 10, 9, 0x0400, 0x0000, 0x0800, 0x1000, 0x1400, 0x1A00, 0x2400, 0x2390)", 0x1DC7);
}

test "imdct transforms a short block as the twin does" {
    try runs(128, "imdct(128, 64, 7, 6, 0x0400, 0x0000, 0x0800, 0x1000, 0x1400, 0x1A00, 0x2400, 0x2390)", 0x5B7);
}
