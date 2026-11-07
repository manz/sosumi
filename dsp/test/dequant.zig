//! dsp/lib/dequant.sm against its twin, ref/dsp/aac/dequant.zig `dequantChannel`, with the
//! twin's own tables staged where the library reads them (ISO/IEC 14496-3 4.6.1.3).
const std = @import("std");
const ref = @import("ref");
const h = @import("../harness.zig");

const D = ref.dsp.aac.dequant;
const S = ref.dsp.aac.sections;
const Word = ref.dsp.ops.Word;
const swb = ref.aac.swb;
const testing = std.testing;

const fi = 4; // 44.1 kHz

fn putX(st: *h.emu.State, gpa: std.mem.Allocator, addr: u32, v: Word) !void {
    try st.x_mem.put(gpa, addr, @as(u24, @bitCast(v)));
}

fn putY(st: *h.emu.State, gpa: std.mem.Allocator, addr: u32, v: Word) !void {
    try st.y_mem.put(gpa, addr, @as(u16, @truncate(@as(u24, @bitCast(v)))));
}

/// The twin's tables at the library's addresses: X DQ_D pairs (m, em), DQ_IT, DQ_G; Y DQ_IE,
/// DQ_IR (4 rem), DQ_OFF.
fn stageTables(st: *h.emu.State, gpa: std.mem.Allocator, offsets: []const u16) !void {
    for (D.direct_m, D.direct_e, 0..) |m, e, k| {
        try putX(st, gpa, 0x1800 + 2 * @as(u32, @intCast(k)), m);
        try putX(st, gpa, 0x1801 + 2 * @as(u32, @intCast(k)), e);
    }
    for (D.interp, 0..) |v, j| try putX(st, gpa, 0x1910 + @as(u32, @intCast(j)), v);
    for (D.gain, 0..) |v, j| try putX(st, gpa, 0x1960 + @as(u32, @intCast(j)), v);
    for (D.interp_e, D.interp_rem, 0..) |e, r, j| {
        try putY(st, gpa, 0x2140 + @as(u32, @intCast(j)), e);
        try putY(st, gpa, 0x2148 + @as(u32, @intCast(j)), 4 * r);
    }
    for (offsets, 0..) |o, j| try putY(st, gpa, 0x2180 + @as(u32, @intCast(j)), @intCast(o));
}

test "dq_channel dequantises as the twin does: words and exponent" {
    const gpa = testing.allocator;
    var prng = std.Random.DefaultPrng.init(0xD0A);
    const rnd = prng.random();
    const prog = try h.assemble(gpa,
        \\.include "lib/bits.sm"
        \\.include "lib/mem.sm"
        \\.include "lib/huffman.sm"
        \\.include "lib/sections.sm"
        \\.include "lib/dequant.sm"
        \\        bits_init(0x4000)
        \\        dq_channel()
        \\        x17.halt
        \\
    );
    defer gpa.free(prog);
    var nonzero: usize = 0;
    var interp: usize = 0;
    var shorts: usize = 0;
    for (0..60) |run| {
        const short = rnd.boolean();
        var s: D.Shape = .{ .short = short, .groups = 1, .group_len = @splat(0), .max_sfb = 0 };
        const offsets: []const u16 = if (short) swb.short[fi] else swb.long[fi];
        const bands = offsets.len - 1;
        if (short) {
            var left: u4 = 8;
            s.groups = 0;
            while (left > 0) {
                const l = rnd.intRangeAtMost(u4, 1, left);
                s.group_len[s.groups] = l;
                s.groups += 1;
                left -= l;
            }
            shorts += 1;
        } else s.group_len[0] = 1;
        s.max_sfb = rnd.intRangeAtMost(u6, 0, @intCast(bands));
        var b: S.Bands = .{ .n = @as(usize, s.groups) * s.max_sfb };
        const base_sf = rnd.intRangeAtMost(i32, 60, 200);
        for (0..b.n) |i| {
            const cb = rnd.intRangeAtMost(Word, 0, 15);
            b.book[i] = if (cb == 12) 0 else cb;
            b.sf[i] = @intCast(std.math.clamp(base_sf + rnd.intRangeAtMost(i32, -30, 30), 0, 255));
        }
        var spec: [1024]Word = undefined;
        for (&spec) |*q| {
            const r = rnd.uintLessThan(u8, 100);
            const mag: Word = if (r < 40) 0 else if (r < 90) rnd.intRangeAtMost(Word, 1, 16) else if (r < 98) rnd.intRangeAtMost(Word, 17, 1000) else rnd.intRangeAtMost(Word, 1001, 8191);
            q.* = if (rnd.boolean()) -mag else mag;
            if (mag > 128) interp += 1;
        }
        // one run with nothing to dequantise
        if (run == 0) @memset(&spec, 0);
        const want = D.dequantChannel(&spec, s, &b, offsets);

        var state = h.emu.State{};
        defer state.deinit(gpa);
        for (spec, 0..) |q, k| try putX(&state, gpa, @intCast(k), q);
        try stageTables(&state, gpa, offsets);
        try putY(&state, gpa, 0x2150, s.groups);
        try putY(&state, gpa, 0x2151, s.max_sfb);
        try putY(&state, gpa, 0x2152, if (short) 128 else 1024);
        for (s.group_len, 0..) |l, j| try putY(&state, gpa, 0x2153 + @as(u32, @intCast(j)), l);
        for (0..b.n) |i| {
            try putY(&state, gpa, 0x2000 + @as(u32, @intCast(i)), b.book[i]);
            try putY(&state, gpa, 0x2080 + @as(u32, @intCast(i)), b.sf[i]);
        }
        _ = try h.emu.runFrom(gpa, &state, prog, 0, 1 << 24);
        try testing.expect(state.halted);

        // the twin reports e = 0 for an all-zero channel, as dq_channel does
        try testing.expectEqual(@as(u32, @as(u16, @truncate(@as(u24, @bitCast(want.e))))), state.getY(0x215B) orelse 0xDEAD);
        for (want.w, 0..) |w, k| {
            if (w != 0) nonzero += 1;
            try testing.expectEqual(@as(u32, @as(u24, @bitCast(w))), state.readX(0x400 + @as(u32, @intCast(k))) orelse 0xDEAD);
        }
    }
    try testing.expect(nonzero > 5000);
    try testing.expect(interp > 1000);
    try testing.expect(shorts > 10);
}
