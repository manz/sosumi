//! dsp/lib/window.sm against its twin, ref/dsp/aac/window.zig `block` and `synth`: every window
//! sequence, every pair of shapes, with the twin's own sine and KBD halves (ISO/IEC 14496-3
//! 4.6.11.3.3, windowing and block switching).
const std = @import("std");
const ref = @import("ref");
const h = @import("../harness.zig");

const W = ref.dsp.aac.window;
const Word = ref.dsp.ops.Word;
const testing = std.testing;

const t_at = 0x0000;
const lp_at = 0x0800; // previous shape's long rising half
const lc_at = 0x0C00; // current shape's
const sp_at = 0x1000; // previous shape's short rising half
const sc_at = 0x1080; // current shape's
const b_at = 0x1100;
const ovl_at = 0x1900;
const pcm_at = 0x2000;

fn putX(st: *h.emu.State, gpa: std.mem.Allocator, addr: u32, v: Word) !void {
    try st.x_mem.put(gpa, addr, @as(u24, @bitCast(v)));
}

fn putAll(st: *h.emu.State, gpa: std.mem.Allocator, base: u32, ws: []const Word) !void {
    for (ws, 0..) |v, k| try putX(st, gpa, base + @as(u32, @intCast(k)), v);
}

fn call(seq: ref.aac.ics.WindowSequence) []const u8 {
    return switch (seq) {
        .only_long => std.fmt.comptimePrint("win_long({d}, {d}, {d}, {d}, {d})", .{ t_at, lp_at, lc_at, ovl_at, pcm_at }),
        .long_start => std.fmt.comptimePrint("win_start({d}, {d}, {d}, {d}, {d}, {d})", .{ t_at, lp_at, sc_at, b_at, ovl_at, pcm_at }),
        .long_stop => std.fmt.comptimePrint("win_stop({d}, {d}, {d}, {d}, {d}, {d})", .{ t_at, sp_at, lc_at, b_at, ovl_at, pcm_at }),
        .eight_short => std.fmt.comptimePrint("win_short({d}, {d}, {d}, {d}, {d}, {d})", .{ t_at, sp_at, sc_at, b_at, ovl_at, pcm_at }),
    };
}

test "the window macros window, overlap and clamp as the twin's block and synth" {
    const gpa = testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x3D2);
    const rnd = prng.random();
    const seqs = [_]ref.aac.ics.WindowSequence{ .only_long, .long_start, .long_stop, .eight_short };
    var clipped: usize = 0;
    for (seqs) |seq| {
        const src = try std.fmt.allocPrint(gpa, ".include \"lib/bits.sm\"\n.include \"lib/mem.sm\"\n.include \"lib/window.sm\"\n        bits_init(0x4000)\n        {s}\n        x17.halt\n", .{call(seq)});
        defer gpa.free(src);
        const prog = try h.assemble(gpa, src);
        defer gpa.free(prog);
        for (0..2) |prev| for (0..2) |cur| for (0..3) |run| {
            // run 0 quiet, 1 loud enough to clip both ways, 2 silence over an overlap at the
            // clamp's rounding edges
            const amp: Word = if (run == 0) 1 << 20 else (1 << 23) - 1;
            var t: [2048]Word = undefined;
            for (&t) |*v| v.* = if (run == 2) 0 else rnd.intRangeAtMost(Word, -amp, amp);
            var st: W.State = .{ .prev_shape = @intCast(prev) };
            for (&st.overlap, 0..) |*v, n| v.* = if (run == 2)
                (if (n % 2 == 0) (32767 << 5) + 15 + @as(Word, @intCast(n % 4)) else -(32768 << 5) - 16 - @as(Word, @intCast(n % 4)))
            else
                rnd.intRangeAtMost(Word, -(1 << 21), 1 << 21);

            var state = h.emu.State{};
            defer state.deinit(gpa);
            try putAll(&state, gpa, t_at, &t);
            try putAll(&state, gpa, lp_at, &W.long[prev]);
            try putAll(&state, gpa, lc_at, &W.long[cur]);
            try putAll(&state, gpa, sp_at, &W.short[prev]);
            try putAll(&state, gpa, sc_at, &W.short[cur]);
            try putAll(&state, gpa, ovl_at, &st.overlap);
            // B starts as garbage: every word must be written
            for (0..2048) |k| try putX(&state, gpa, b_at + @as(u32, @intCast(k)), 0x5A5A5A);

            var buf: [2048]Word = undefined;
            const in: W.Imdct = if (seq == .eight_short) .{ .short = @ptrCast(&t) } else .{ .long = &t };
            W.block(@intCast(prev), @intCast(cur), seq, in, &buf);
            var pcm: [1024]i16 = undefined;
            W.synth(&st, @intCast(cur), &buf, &pcm);
            _ = try h.emu.runFrom(gpa, &state, prog, 0, 1 << 23);
            try testing.expect(state.halted);

            for (pcm, st.overlap, 0..) |p, o, n| {
                if (p == 32767 or p == -32768) clipped += 1;
                try testing.expectEqual(@as(u32, @as(u16, @bitCast(p))), (state.getY(pcm_at + @as(u32, @intCast(n))) orelse 0xDEAD) & 0xFFFF);
                try testing.expectEqual(@as(u32, @as(u24, @bitCast(o))), state.readX(ovl_at + @as(u32, @intCast(n))) orelse 0xDEAD);
            }
        };
    }
    try testing.expect(clipped > 1000);
}
