//! dsp/lib/pns.sm against its twin, ref/dsp/aac/pns.zig `channel` and `right`, on random
//! channels and pairs (ISO/IEC 14496-3 4.6.13). Band widths are random, 1 to 31, so band
//! lengths cross every shift step, and now and then one band covers the whole window.
const std = @import("std");
const ref = @import("ref");
const h = @import("../harness.zig");

const P = ref.dsp.aac.pns;
const Block = ref.dsp.aac.dequant.Block;
const ics = ref.aac.ics;
const Word = ref.dsp.ops.Word;
const testing = std.testing;

const Y = 0x2600;

fn emptyChannel(info: ics.IcsInfo) ics.Channel {
    return .{ .global_gain = 100, .info = info, .sections = .{}, .scalefactors = @splat(@splat(0)), .pulse = null, .tns = null, .spectrum = @splat(0) };
}

test "pns_channel fills noise bands as the twin does, both modes" {
    const gpa = testing.allocator;
    const prog = try h.assemble(gpa,
        \\.include "lib/bits.sm"
        \\.include "lib/mem.sm"
        \\.include "lib/pns.sm"
        \\        bits_init(0x4000)
        \\        pns_channel()
        \\        x17.halt
        \\
    );
    defer gpa.free(prog);
    var prng = std.Random.DefaultPrng.init(0x9E5C);
    const rnd = prng.random();
    var noisy: usize = 0;
    var corr: usize = 0;
    for (0..40) |trial| {
        const short = trial % 3 == 0;
        const mode: u1 = @intCast(trial % 2);
        const win: u16 = if (short) 128 else 1024;
        var info: ics.IcsInfo = .{ .window_sequence = if (short) .eight_short else .only_long, .window_shape = 0, .max_sfb = 0, .num_window_groups = 1, .group_len = @splat(0) };
        if (short) {
            var left: u4 = 8;
            info.num_window_groups = 0;
            while (left > 0) {
                const l = rnd.intRangeAtMost(u4, 1, left);
                info.group_len[info.num_window_groups] = l;
                info.num_window_groups += 1;
                left -= l;
            }
            info.max_sfb = rnd.intRangeAtMost(u6, 1, 14);
        } else {
            info.group_len[0] = 1;
            info.max_sfb = rnd.intRangeAtMost(u6, 1, 49);
        }
        var offs: [64]u16 = undefined;
        offs[0] = 0;
        for (1..64) |k| offs[k] = @min(offs[k - 1] + rnd.intRangeAtMost(u16, 1, if (short) 9 else 31), win);
        if (!short and trial % 7 == 2) {
            info.max_sfb = 1;
            offs[1] = 1024;
        }
        const offsets = offs[0 .. @as(usize, info.max_sfb) + 1];

        var pair: ics.ChannelPair = .{ .common_window = true, .ms = .{ .present = rnd.intRangeAtMost(u2, 0, 2) }, .left = emptyChannel(info), .right = emptyChannel(info) };
        const ch = if (mode == 0) &pair.left else &pair.right;
        const quiet = rnd.uintLessThan(u8, 5) == 0;
        for (0..info.num_window_groups) |g| for (0..info.max_sfb) |sfb| {
            const r = rnd.uintLessThan(u8, 3);
            ch.sections.sfb_cb[g][sfb] = if (r == 0) ics.noise_hcb else if (r == 1 or quiet) 0 else rnd.intRangeAtMost(u4, 1, 11);
            ch.scalefactors[g][sfb] = rnd.intRangeAtMost(i16, -60, 120);
            if (mode == 1) {
                pair.left.sections.sfb_cb[g][sfb] = if (rnd.boolean()) ics.noise_hcb else rnd.intRangeAtMost(u4, 0, 11);
                pair.left.scalefactors[g][sfb] = rnd.intRangeAtMost(i16, -60, 120);
            }
            pair.ms.?.used[g][sfb] = pair.ms.?.present == 2 or (pair.ms.?.present == 1 and rnd.boolean());
            if (ch.sections.sfb_cb[g][sfb] == ics.noise_hcb) {
                noisy += 1;
                if (mode == 1 and pair.ms.?.used[g][sfb] and pair.left.sections.sfb_cb[g][sfb] == ics.noise_hcb) corr += 1;
            }
        };
        var blk: Block = .{ .e = rnd.intRangeAtMost(Word, -40, 30) };
        var left: Block = .{ .e = rnd.intRangeAtMost(Word, -40, 30) };
        for (&left.w) |*x| x.* = rnd.intRangeAtMost(Word, -5600000, 5600000);
        var first: usize = 0;
        for (0..info.num_window_groups) |g| {
            for (0..info.max_sfb) |sfb| {
                const b = ch.sections.sfb_cb[g][sfb];
                if (b < 1 or b > 11) continue;
                for (first..first + info.group_len[g]) |w| for (offsets[sfb]..offsets[sfb + 1]) |k| {
                    blk.w[w * win + k] = rnd.intRangeAtMost(Word, -5600000, 5600000);
                };
            }
            first += info.group_len[g];
        }
        var rng: P.Rng = .{ .x = @bitCast(rnd.int(u24)) };

        var state = h.emu.State{};
        defer state.deinit(gpa);
        try h.putY(&state, gpa, Y + 0, @as(i32, info.num_window_groups) * info.max_sfb);
        try h.putY(&state, gpa, Y + 1, info.num_window_groups);
        try h.putY(&state, gpa, Y + 2, info.max_sfb);
        try h.putY(&state, gpa, Y + 3, win);
        try h.putY(&state, gpa, Y + 4, mode);
        try h.putY(&state, gpa, Y + 5, pair.ms.?.present);
        try h.putY(&state, gpa, Y + 6, blk.e);
        try h.putY(&state, gpa, Y + 7, left.e);
        for (info.group_len, 0..) |gl, g| try h.putY(&state, gpa, Y + 0x10 + @as(u32, @intCast(g)), gl);
        for (offsets, 0..) |o, k| try h.putY(&state, gpa, Y + 0x20 + @as(u32, @intCast(k)), o);
        for (0..info.num_window_groups) |g| for (0..info.max_sfb) |sfb| {
            const i: u32 = @intCast(g * info.max_sfb + sfb);
            try h.putY(&state, gpa, Y + 0x60 + i, ch.sections.sfb_cb[g][sfb]);
            try h.putY(&state, gpa, Y + 0xE0 + i, ch.scalefactors[g][sfb]);
            try h.putY(&state, gpa, Y + 0x160 + i, pair.left.sections.sfb_cb[g][sfb]);
            try h.putY(&state, gpa, Y + 0x1E0 + i, pair.left.scalefactors[g][sfb]);
            try h.putY(&state, gpa, Y + 0x260 + i, @intFromBool(pair.ms.?.used[g][sfb]));
        };
        for (P.quarter, 0..) |t, b| try h.putX(&state, gpa, 0x1F00 + @as(u32, @intCast(b)), t);
        for (P.seed, 0..) |s, i| try h.putX(&state, gpa, 0x1F04 + @as(u32, @intCast(i)), s);
        try h.putX(&state, gpa, 0x1F10, rng.x);
        for (blk.w, left.w, 0..) |a, b, k| {
            try h.putX(&state, gpa, 0x400 + @as(u32, @intCast(k)), a);
            try h.putX(&state, gpa, 0x800 + @as(u32, @intCast(k)), b);
        }
        if (mode == 0) P.channel(ch, offsets, &blk, &rng) else P.right(&pair, &left, offsets, &blk, &rng);
        _ = try h.emu.runFrom(gpa, &state, prog, 0, 1 << 28);
        try testing.expect(state.halted);

        try testing.expectEqual(@as(i32, blk.e), h.sx16(state.getY(Y + 6)));
        try testing.expectEqual(@as(u32, @as(u24, @bitCast(rng.x))), state.readX(0x1F10) orelse 0xDEAD);
        for (blk.w, 0..) |w, k| {
            try testing.expectEqual(@as(u32, @as(u24, @bitCast(w))), state.readX(0x400 + @as(u32, @intCast(k))) orelse 0xDEAD);
        }
    }
    try testing.expect(noisy > 200);
    try testing.expect(corr > 15);
}
