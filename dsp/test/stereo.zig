//! dsp/lib/stereo.sm against its twin, ref/dsp/aac/stereo.zig `applyPair`, on random
//! common-window pairs with the real 44.1 kHz band offsets (ISO/IEC 14496-3 4.6.8.1, 4.6.8.2).
const std = @import("std");
const ref = @import("ref");
const h = @import("../harness.zig");

const St = ref.dsp.aac.stereo;
const Block = ref.dsp.aac.dequant.Block;
const ics = ref.aac.ics;
const swb = ref.aac.swb;
const Word = ref.dsp.ops.Word;
const testing = std.testing;

const fi = 4;
const Y = 0x2600;

fn putX(st: *h.emu.State, gpa: std.mem.Allocator, addr: u32, v: Word) !void {
    try st.x_mem.put(gpa, addr, @as(u24, @bitCast(v)));
}

fn putY(st: *h.emu.State, gpa: std.mem.Allocator, addr: u32, v: i32) !void {
    try st.y_mem.put(gpa, addr, @as(u16, @truncate(@as(u32, @bitCast(v)))));
}

fn sx16(v: ?u32) i32 {
    return @as(i16, @bitCast(@as(u16, @truncate(v orelse 0xDEAD))));
}

fn emptyChannel(info: ics.IcsInfo) ics.Channel {
    return .{ .global_gain = 100, .info = info, .sections = .{}, .scalefactors = @splat(@splat(0)), .pulse = null, .tns = null, .spectrum = @splat(0) };
}

fn spectral(cb: u4) bool {
    return cb >= 1 and cb <= 11;
}

/// Random words in every spectral band of `ch`, zero elsewhere.
fn fill(rnd: std.Random, ch: *const ics.Channel, offsets: []const u16, b: *Block) void {
    b.w = @splat(0);
    const win: usize = if (ch.info.isShort()) 128 else 1024;
    var first: usize = 0;
    for (0..ch.info.num_window_groups) |g| {
        for (0..ch.info.max_sfb) |sfb| {
            if (!spectral(ch.sections.sfb_cb[g][sfb])) continue;
            for (first..first + ch.info.group_len[g]) |w| for (w * win + offsets[sfb]..w * win + offsets[sfb + 1]) |k| {
                b.w[k] = rnd.intRangeAtMost(Word, -5600000, 5600000);
            };
        }
        first += ch.info.group_len[g];
    }
}

test "stereo_pair applies M/S and intensity as the twin's applyPair" {
    const gpa = testing.allocator;
    const prog = try h.assemble(gpa,
        \\.include "lib/bits.sm"
        \\.include "lib/mem.sm"
        \\.include "lib/stereo.sm"
        \\        bits_init(0x4000)
        \\        stereo_pair()
        \\        x17.halt
        \\
    );
    defer gpa.free(prog);
    var prng = std.Random.DefaultPrng.init(0x57E2);
    const rnd = prng.random();
    var seen_ms: usize = 0;
    var seen_is: usize = 0;
    var seen_is_neg: usize = 0;
    for (0..40) |_| {
        const short = rnd.boolean();
        const offsets: []const u16 = if (short) swb.short[fi] else swb.long[fi];
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
        } else info.group_len[0] = 1;
        info.max_sfb = rnd.intRangeAtMost(u6, 1, @intCast(offsets.len - 1));

        var pair: ics.ChannelPair = .{ .common_window = true, .ms = .{ .present = rnd.intRangeAtMost(u2, 0, 2) }, .left = emptyChannel(info), .right = emptyChannel(info) };
        // books: mostly spectral, some zero, intensity on the right; sometimes a silent side
        const quiet_l = rnd.uintLessThan(u8, 8) == 0;
        const quiet_r = rnd.uintLessThan(u8, 6) == 0;
        for (0..info.num_window_groups) |g| for (0..info.max_sfb) |sfb| {
            pair.left.sections.sfb_cb[g][sfb] = if (quiet_l) 0 else rnd.intRangeAtMost(u4, 0, 11);
            const c = rnd.uintLessThan(u8, 10);
            pair.right.sections.sfb_cb[g][sfb] = if (c < 2) ics.intensity_hcb2 + rnd.intRangeAtMost(u4, 0, 1) else if (quiet_r) 0 else rnd.intRangeAtMost(u4, 0, 11);
            pair.right.scalefactors[g][sfb] = rnd.intRangeAtMost(i16, -24, 60);
            pair.ms.?.used[g][sfb] = pair.ms.?.present == 2 or (pair.ms.?.present == 1 and rnd.boolean());
        };
        var l: Block = .{ .e = rnd.intRangeAtMost(Word, -20, 20) };
        var r: Block = .{ .e = l.e + rnd.intRangeAtMost(Word, -30, 30) };
        fill(rnd, &pair.left, offsets, &l);
        fill(rnd, &pair.right, offsets, &r);

        var state = h.emu.State{};
        defer state.deinit(gpa);
        const nb = @as(usize, info.num_window_groups) * info.max_sfb;
        try putY(&state, gpa, Y + 0, @intCast(nb));
        try putY(&state, gpa, Y + 1, info.num_window_groups);
        try putY(&state, gpa, Y + 2, info.max_sfb);
        try putY(&state, gpa, Y + 3, if (short) 128 else 1024);
        try putY(&state, gpa, Y + 4, pair.ms.?.present);
        try putY(&state, gpa, Y + 5, l.e);
        try putY(&state, gpa, Y + 6, r.e);
        for (info.group_len, 0..) |gl, g| try putY(&state, gpa, Y + 0x10 + @as(u32, @intCast(g)), gl);
        for (offsets, 0..) |o, k| try putY(&state, gpa, Y + 0x20 + @as(u32, @intCast(k)), o);
        for (0..info.num_window_groups) |g| for (0..info.max_sfb) |sfb| {
            const i: u32 = @intCast(g * info.max_sfb + sfb);
            const rb = pair.right.sections.sfb_cb[g][sfb];
            try putY(&state, gpa, Y + 0x60 + i, pair.left.sections.sfb_cb[g][sfb]);
            try putY(&state, gpa, Y + 0xE0 + i, rb);
            try putY(&state, gpa, Y + 0x160 + i, pair.right.scalefactors[g][sfb]);
            try putY(&state, gpa, Y + 0x1E0 + i, @intFromBool(pair.ms.?.used[g][sfb]));
            if (rb >= ics.intensity_hcb2) {
                seen_is += 1;
                if (rb == ics.intensity_hcb2 and pair.ms.?.present == 1) seen_is_neg += 1;
            } else if (pair.ms.?.used[g][sfb] and pair.left.sections.sfb_cb[g][sfb] < ics.noise_hcb) seen_ms += 1;
        };
        for (St.quarter, 0..) |t, b| try putX(&state, gpa, 0x1F00 + @as(u32, @intCast(b)), t);
        for (l.w, r.w, 0..) |a, b, k| {
            try putX(&state, gpa, 0x400 + @as(u32, @intCast(k)), a);
            try putX(&state, gpa, 0x800 + @as(u32, @intCast(k)), b);
        }
        St.applyPair(&pair, &l, &r, offsets, offsets);
        _ = try h.emu.runFrom(gpa, &state, prog, 0, 1 << 24);
        try testing.expect(state.halted);

        try testing.expectEqual(@as(i32, l.e), sx16(state.getY(Y + 5)));
        try testing.expectEqual(@as(i32, r.e), sx16(state.getY(Y + 6)));
        for (l.w, r.w, 0..) |a, b, k| {
            try testing.expectEqual(@as(u32, @as(u24, @bitCast(a))), state.readX(0x400 + @as(u32, @intCast(k))) orelse 0xDEAD);
            try testing.expectEqual(@as(u32, @as(u24, @bitCast(b))), state.readX(0x800 + @as(u32, @intCast(k))) orelse 0xDEAD);
        }
    }
    try testing.expect(seen_ms > 100);
    try testing.expect(seen_is > 50);
    try testing.expect(seen_is_neg > 5);
}
