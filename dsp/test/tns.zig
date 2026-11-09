//! dsp/lib/tns.sm against its twin, ref/dsp/aac/tns.zig `apply`, on random tns_data() over
//! random blocks with the real 44.1 kHz band offsets and TNS limits (ISO/IEC 14496-3 4.6.9).
const std = @import("std");
const ref = @import("ref");
const h = @import("../harness.zig");
const map = @import("../map.zig");

const T = ref.dsp.aac.tns;
const Block = ref.dsp.aac.dequant.Block;
const ics = ref.aac.ics;
const rtns = ref.aac.tns;
const Word = ref.dsp.ops.Word;
const testing = std.testing;

const fi = 4;
const Y = map.at("TN_Y");

/// tns_data() as the library's TN_REC wants it: per window n_filt, then if n_filt > 0
/// coef_res and per filter length, order, then if order > 0 direction and the order codes.
fn record(gpa: std.mem.Allocator, t: *const ics.Tns, nwin: usize, out: *std.ArrayList(i32)) !void {
    for (t.windows[0..nwin]) |w| {
        try out.append(gpa, w.n_filt);
        if (w.n_filt == 0) continue;
        try out.append(gpa, w.coef_res);
        for (w.filt[0..w.n_filt]) |f| {
            try out.append(gpa, f.length);
            try out.append(gpa, f.order);
            if (f.order == 0) continue;
            try out.append(gpa, @intFromBool(f.direction));
            for (f.coef[0..f.order]) |c| try out.append(gpa, c);
        }
    }
}

test "tns_channel filters every window as the twin's apply" {
    const gpa = testing.allocator;
    const prog = try h.assemble(gpa,
        \\.include "lib/bits.sm"
        \\.include "lib/mem.sm"
        \\.include "lib/tns.sm"
        \\        bits_init(0x4000)
        \\        tns_channel()
        \\        x17.halt
        \\
    );
    defer gpa.free(prog);
    var prng = std.Random.DefaultPrng.init(0x7E5C);
    const rnd = prng.random();
    var halvings: u32 = 0;
    var gave_up: u32 = 0;
    for (0..31) |trial| {
        const short = trial % 3 == 0 and trial != 30;
        const offsets: []const u16 = if (short) ref.aac.swb.short[fi] else ref.aac.swb.long[fi];
        const nswb: u6 = @intCast(offsets.len - 1);
        const nwin: usize = if (short) 8 else 1;
        var info: ics.IcsInfo = .{ .window_sequence = if (short) .eight_short else .only_long, .window_shape = 0, .max_sfb = rnd.intRangeAtMost(u6, 1, nswb), .num_window_groups = 1, .group_len = @splat(0) };
        info.group_len[0] = @intCast(nwin);
        var blk: Block = .{ .e = rnd.intRangeAtMost(Word, -30, 10) };
        const amp: Word = rnd.intRangeAtMost(Word, 1 << 10, 5600000);
        for (&blk.w) |*x| x.* = rnd.intRangeAtMost(Word, -amp, amp);
        var t: ics.Tns = .{};
        if (trial == 30) {
            // twelve stages at the largest code on a constant run: past max_halvings, the run zeroed
            info.max_sfb = nswb;
            blk.w = @splat(1 << 21);
            t.windows[0] = .{ .n_filt = 1, .coef_res = 1 };
            t.windows[0].filt[0] = .{ .length = nswb, .order = 12, .direction = false };
            @memset(t.windows[0].filt[0].coef[0..12], -8);
        } else for (t.windows[0..nwin]) |*w| {
            w.n_filt = rnd.intRangeAtMost(u2, 0, if (short) 1 else 3);
            if (w.n_filt == 0) continue;
            w.coef_res = rnd.int(u1);
            const lo: i4 = if (w.coef_res == 1) -8 else -4;
            const wide = trial % 5 == 4;
            for (w.filt[0..w.n_filt]) |*f| {
                f.length = rnd.intRangeAtMost(u6, 0, if (short) 15 else 63);
                f.order = rnd.intRangeAtMost(u5, 0, if (short) 7 else 31);
                f.direction = rnd.boolean();
                for (f.coef[0..f.order]) |*c| c.* = if (wide) rnd.intRangeAtMost(i4, lo, -1 - lo) else rnd.intRangeAtMost(i4, -2, 2);
            }
        }
        var rec: std.ArrayList(i32) = .empty;
        defer rec.deinit(gpa);
        try record(gpa, &t, nwin, &rec);

        var state = h.emu.State{};
        defer state.deinit(gpa);
        const top = @min(if (short) rtns.max_bands_short[fi] else rtns.max_bands_long[fi], info.max_sfb);
        try h.putY(&state, gpa, Y + 0, blk.e);
        try h.putY(&state, gpa, Y + 1, @intCast(nwin));
        try h.putY(&state, gpa, Y + 2, if (short) 128 else 1024);
        try h.putY(&state, gpa, Y + 3, nswb);
        try h.putY(&state, gpa, Y + 4, top);
        try h.putY(&state, gpa, Y + 5, if (short) rtns.max_order_short else rtns.max_order_long);
        for (offsets, 0..) |o, k| try h.putY(&state, gpa, Y + 0x20 + @as(u32, @intCast(k)), o);
        for (rec.items, 0..) |v, k| try h.putY(&state, gpa, Y + 0x60 + @as(u32, @intCast(k)), v);
        // coef_res 0 at TN_K + 4 + c, coef_res 1 at TN_K + 16 + c
        for (T.refl[0][0..8], 0..) |v, k| try h.putX(&state, gpa, map.at("TN_K") + @as(u32, @intCast(k)), v);
        for (T.refl[1], 0..) |v, k| try h.putX(&state, gpa, map.at("TN_K") + 8 + @as(u32, @intCast(k)), v);
        for (blk.w, 0..) |v, k| try h.putX(&state, gpa, 0x400 + @as(u32, @intCast(k)), v);

        const st = T.apply(&t, info, fi, &blk);
        halvings += st.halvings;
        gave_up += st.gave_up;
        _ = try h.emu.runFrom(gpa, &state, prog, 0, 1 << 28);
        try testing.expect(state.halted);

        try testing.expectEqual(@as(i32, blk.e), h.sx16(state.getY(Y + 0)));
        try testing.expectEqual(@as(i32, @intCast(st.halvings)), h.sx16(state.getY(Y + 6)));
        try testing.expectEqual(@as(i32, @intCast(st.gave_up)), h.sx16(state.getY(Y + 7)));
        for (blk.w, 0..) |w, k| {
            try testing.expectEqual(@as(u32, @as(u24, @bitCast(w))), state.readX(0x400 + @as(u32, @intCast(k))) orelse 0xDEAD);
        }
    }
    try testing.expect(halvings > 0);
    try testing.expectEqual(@as(u32, 1), gave_up);
}
