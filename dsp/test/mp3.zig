//! dsp/lib/mp3.sm against ref/mp3: each fixture frame armed on the stream, its header fields,
//! side information and main data bytes where the program keeps them.
const std = @import("std");
const ref = @import("ref");
const h = @import("../harness.zig");
const map = @import("../map.zig");
const tables = @import("../mp3/tables.zig");

const testing = std.testing;
const fixtures = [_][]const u8{
    @embedFile("clicks.vbr.mp3"),
    @embedFile("mono.cbr.mp3"),
    @embedFile("clicks.m2.mp3"),
    @embedFile("clicks.m25_8k.mp3"),
    @embedFile("heavy.cbr.mp3"),
};

fn y(st: *h.emu.State, addr: u32) u32 {
    return st.getY(addr) orelse 0xDEAD;
}

test "mp3_header and mp3_sideinfo read every fixture frame as ref/mp3 does" {
    const gpa = testing.allocator;
    const prog = try h.assemble(gpa,
        \\.include "lib/ybits.sm"
        \\.include "lib/stream.sm"
        \\.include "lib/mp3.sm"
        \\        stream_on()
        \\        ybits_init()
        \\        mp3_header()
        \\        mp3_sideinfo()
        \\        x17.halt
        \\
    );
    defer gpa.free(prog);
    var checked: usize = 0;
    for (fixtures) |file| {
        const fr = try tables.frames(gpa, file);
        defer gpa.free(fr);
        // one state across the file: the stream runs on from packet to packet
        var state = h.emu.State{};
        defer state.deinit(gpa);
        for (tables.flen, 0..) |v, i| try state.y_mem.put(gpa, map.at("MP_FLEN") + @as(u32, @intCast(i)), v);
        for (fr, 0..) |frame, n| {
            try h.stagePacket(gpa, &state, frame);
            state.halted = false;
            _ = try h.emu.runFrom(gpa, &state, prog, 0, 1 << 20);
            try testing.expect(state.halted);
            try testing.expect(!state.stream_starved);
            const hd = try ref.mp3.header.parse(frame);
            try testing.expectEqual(@as(u32, @intCast(frame.len)), y(&state, map.at("MH_FLEN")));
            try testing.expectEqual(@as(u32, hd.channels()), y(&state, map.at("MH_NCH")));
            try testing.expectEqual(@as(u32, @intCast(hd.mainDataOffset() - 4)), y(&state, map.at("MH_SIDE")));
            const main = frame[hd.mainDataOffset()..];
            for (main, 0..) |b, i| try testing.expectEqual(@as(u32, b), y(&state, map.at("MP_MAIN") + @as(u32, @intCast(i))));
            var r = ref.bits.BitReader.init(frame[4 + @as(usize, if (hd.crc) 2 else 0) .. hd.mainDataOffset()]);
            const si = try ref.mp3.sideinfo.read(&r, hd);
            try testing.expectEqual(@as(u32, si.main_data_begin), y(&state, map.at("MP_SI")));
            for (0..hd.channels()) |ch| try testing.expectEqual(@as(u32, si.scfsi[ch]), y(&state, map.at("MP_SI") + 1 + @as(u32, @intCast(ch))));
            for (0..hd.granules()) |gr| for (0..hd.channels()) |ch| {
                const g = si.gr[gr][ch];
                const at = map.at("MP_GR0") + @as(u32, @intCast((2 * gr + ch) * map.at("MP_GR")));
                const want = [_]u32{ g.part2_3_length, g.big_values, g.global_gain, g.scalefac_compress, @intFromBool(g.window_switching), g.block_type, @intFromBool(g.mixed), g.table_select[0], g.table_select[1], g.table_select[2], g.subblock_gain[0], g.subblock_gain[1], g.subblock_gain[2], g.region0_count, g.region1_count, @intFromBool(g.preflag), @intFromBool(g.scalefac_scale), @intFromBool(g.count1_table_b) };
                for (want, 0..) |wv, f| {
                    if (wv != y(&state, at + @as(u32, @intCast(f)))) std.debug.print("frame {d} gr {d} ch {d} field {d}\n", .{ n, gr, ch, f });
                    try testing.expectEqual(wv, y(&state, at + @as(u32, @intCast(f))));
                }
            };
            checked += 1;
        }
    }
    try testing.expect(checked > 500);
}

test "mp3_granules decodes each granule to subband samples through the reservoir as ref/mp3's Parser does" {
    const gpa = testing.allocator;
    const prog = try h.assemble(gpa,
        \\.include "lib/ybits.sm"
        \\.include "lib/stream.sm"
        \\.include "lib/mem.sm"
        \\.include "lib/huffman.sm"
        \\.include "lib/sections.sm"
        \\.include "lib/dequant.sm"
        \\.include "lib/mp3.sm"
        \\        stream_on()
        \\        ybits_init()
        \\        mp3_header()
        \\        mp3_sideinfo()
        \\        mp3_main()
        \\        lde e7, #MP_OK
        \\        ldy s12, e7
        \\        ptst p3, s0, #EQ12, #PTST
        \\        jmp #3, #3, keep
        \\        nop()
        \\        nop()
        \\        mp3_granules()
        \\keep:   mp3_keep()
        \\        x17.halt
        \\
    );
    defer gpa.free(prog);
    var decoded: usize = 0;
    var skipped: usize = 0;
    var ill: usize = 0;
    var pre: usize = 0;
    var nz: usize = 0;
    var worst: usize = 0;
    var msf: usize = 0;
    var big: usize = 0;
    for (fixtures) |file| {
        const fr = try tables.frames(gpa, file);
        defer gpa.free(fr);
        var state = h.emu.State{};
        defer state.deinit(gpa);
        try tables.put(&state, gpa, map.at);
        try h.stageDequant(&state, gpa);
        try h.putY(&state, gpa, map.at("MP_OUT"), 0x80);
        var parser: ref.mp3.decoder.Parser = .{};
        var hyb: [2]ref.dsp.mp3.hybrid.State = .{ .{}, .{} };
        for (fr) |frame| {
            try h.stagePacket(gpa, &state, frame);
            state.halted = false;
            const nb = try h.emu.runFrom(gpa, &state, prog, 0, 1 << 22);
            worst = @max(worst, nb);
            try testing.expect(state.halted);
            try testing.expect(!state.stream_starved);
            const hd = try ref.mp3.header.parse(frame);
            const p = try parser.parse(frame, hd) orelse {
                try testing.expectEqual(@as(u32, 0), y(&state, map.at("MP_OK")));
                skipped += 1;
                continue;
            };
            try testing.expectEqual(@as(u32, 1), y(&state, map.at("MP_OK")));
            try testing.expectEqual(@as(u32, @intCast(parser.res_len)), y(&state, map.at("MP_RLEN")));
            for (0..hd.granules()) |gr| for (0..hd.channels()) |ch| {
                const k: u32 = @intCast(2 * gr + ch);
                const s = p.sf[gr][ch];
                for (0..40) |e| {
                    const want: u32 = @as(u32, s.sf[e]) + (if (s.illegal[e]) @as(u32, 0x100) else 0);
                    ill += @intFromBool(s.illegal[e]);
                    const got = y(&state, map.at("MP_SF") + 40 * k + @as(u32, @intCast(e)));
                    if (want != got) {
                        std.debug.print("frame {d} k {d} e {d}: want {d} got {d}; sfc {d} bt {d} mixed {d} ver {d}\n", .{ decoded + skipped, k, e, want, got, y(&state, map.at("MP_GR0") + 18 * k + 2), y(&state, map.at("MP_GR0") + 18 * k + 4), y(&state, map.at("MP_GR0") + 18 * k + 5), y(&state, map.at("MH_VER")) });
                        return error.TestExpectedEqual;
                    }
                }
                pre += @intFromBool(s.preflag);
                try testing.expectEqual(@as(u32, @intFromBool(s.preflag)), y(&state, map.at("MP_PRE") + k));
            };
            msf += @intFromBool(hd.msStereo());
            for (0..hd.granules()) |gr| {
                var want: [2]ref.dsp.mp3.requant.Coefs = undefined;
                for (0..hd.channels()) |ch| want[ch] = ref.dsp.mp3.requant.requantise(p.side.gr[gr][ch], p.bandsOf(gr, ch), &p.sf[gr][ch], &p.is[gr][ch]);
                if (hd.channels() == 2) ref.dsp.mp3.stereo.process(hd, p.side.gr[gr][0], p.side.gr[gr][1], &p.sf[gr][1], &want[0], &want[1]);
                for (0..hd.channels()) |ch| ref.dsp.mp3.hybrid.run(&hyb[ch], p.side.gr[gr][ch], p.bandsOf(gr, ch), ref.mp3.bands.mixedLongSubbands(hd), &want[ch]);
                // the slots keep the frame's last granule
                if (gr + 1 < hd.granules()) continue;
                for (0..hd.channels()) |ch| {
                    const k: u32 = @intCast(2 * gr + ch);
                    for (0..576) |c| {
                        const got: i32 = @as(i24, @bitCast(@as(u24, @truncate(state.getX(map.at("MP_XS") + 576 * @as(u32, @intCast(ch)) + @as(u32, @intCast(c))) orelse 0xDEAD))));
                        nz += @intFromBool(p.is[gr][ch][c] != 0);
                        big += @intFromBool(@abs(p.is[gr][ch][c]) > 15);
                        if (got != want[ch][c]) {
                            std.debug.print("frame {d} k {d} coef {d}: q {d} want {d} got {d} mode {d} ext {d}\n", .{ decoded + skipped, k, c, p.is[gr][ch][c], want[ch][c], got, @intFromEnum(hd.mode), hd.mode_ext });
                            return error.TestExpectedEqual;
                        }
                    }
                }
            }
            decoded += 1;
        }
    }
    std.debug.print("mp3 sf: {d} frames decoded, {d} skipped, {d} illegal, {d} preflag; {d} non-zero lines, {d} past 15; {d} syllables, worst frame {d} bundles; {d} M/S frames\n", .{ decoded, skipped, ill, pre, nz, big, prog.len, worst, msf });
    try testing.expect(decoded > 500);
}

test "mp3_stereo's intensity matches ref/dsp/mp3/stereo.zig on random granules" {
    // no fixture carries intensity stereo (LAME writes none): random side information and lines,
    // below 2 in Q21 so M/S sums stay inside a word (past it the twin wraps, the taps do not)
    const gpa = testing.allocator;
    const prog = try h.assemble(gpa,
        \\.include "lib/ybits.sm"
        \\.include "lib/stream.sm"
        \\.include "lib/mem.sm"
        \\.include "lib/huffman.sm"
        \\.include "lib/sections.sm"
        \\.include "lib/dequant.sm"
        \\.include "lib/mp3.sm"
        \\        ldi s14, #1
        \\        ldi s15, #16
        \\        mp3_stereo()
        \\        x17.halt
        \\
    );
    defer gpa.free(prog);
    const S = ref.dsp.mp3.stereo;
    const Coefs = ref.dsp.mp3.requant.Coefs;
    var prng = std.Random.DefaultPrng.init(0x15);
    const rnd = prng.random();
    var cases: [6]usize = @splat(0); // mpeg1 long/short/mixed, mpeg2 long/short/mixed
    for (0..300) |n| {
        var state = h.emu.State{};
        defer state.deinit(gpa);
        try tables.put(&state, gpa, map.at);
        const vbs = [_]u2{ 3, 2, 0 };
        const vb = vbs[n % 3];
        const ver: ref.mp3.header.Version = switch (vb) {
            3 => .mpeg1,
            2 => .mpeg2,
            else => .mpeg25,
        };
        const hd: ref.mp3.header.Header = .{ .version = ver, .crc = false, .bitrate_index = 9, .sr_index = rnd.uintLessThan(u2, 3), .padding = false, .mode = .joint_stereo, .mode_ext = if (rnd.boolean()) 1 else 3 };
        const kind = rnd.uintLessThan(u32, 3);
        const g0: ref.mp3.sideinfo.Granule = .{ .window_switching = kind != 0, .block_type = if (kind != 0) 2 else 0, .mixed = kind == 2 };
        const g1: ref.mp3.sideinfo.Granule = .{ .scalefac_compress = rnd.int(u9) };
        var sf: ref.mp3.scalefactors.Scalefactors = .{};
        for (0..40) |e| {
            sf.sf[e] = if (vb == 3) rnd.uintLessThan(u8, 9) else rnd.uintLessThan(u8, 16);
            sf.illegal[e] = vb != 3 and rnd.uintLessThan(u8, 5) == 0;
        }
        var l: Coefs = undefined;
        var r: Coefs = undefined;
        const b = ref.mp3.bands.of(hd, g0);
        // right lines zero past a random entry per window
        var cut: [3]usize = undefined;
        for (&cut) |*c| c.* = rnd.uintLessThan(usize, b.len() + 1);
        var k: usize = 0;
        for (b.widths, 0..) |w, e| {
            for (k..k + w) |i| {
                l[i] = rnd.intRangeAtMost(i24, -(1 << 22) + 1, (1 << 22) - 1);
                r[i] = if (e < cut[e % 3] and rnd.uintLessThan(u8, 4) != 0) rnd.intRangeAtMost(i24, -(1 << 22) + 1, (1 << 22) - 1) else 0;
            }
            k += w;
        }
        try h.putY(&state, gpa, map.at("MH_VER"), vb);
        try h.putY(&state, gpa, map.at("MH_SR"), hd.sr_index);
        try h.putY(&state, gpa, map.at("MH_MODE"), 1);
        try h.putY(&state, gpa, map.at("MH_EXT"), hd.mode_ext);
        try h.putY(&state, gpa, map.at("MH_NCH"), 2);
        try h.putY(&state, gpa, map.at("MH_MP1"), @intFromBool(vb == 3));
        try h.putY(&state, gpa, map.at("MP_SGR"), 0);
        try h.putY(&state, gpa, map.at("MP_GR0") + 5, g0.block_type);
        try h.putY(&state, gpa, map.at("MP_GR0") + 6, @intFromBool(g0.mixed));
        try h.putY(&state, gpa, map.at("MP_GR0") + 18 + 3, g1.scalefac_compress);
        for (0..40) |e| try h.putY(&state, gpa, map.at("MP_SF") + 40 + @as(u32, @intCast(e)), @as(i32, sf.sf[e]) + (if (sf.illegal[e]) @as(i32, 0x100) else 0));
        try h.putAllX(&state, gpa, map.at("MP_XS"), &l);
        try h.putAllX(&state, gpa, map.at("MP_XS") + 576, &r);
        _ = try h.emu.runFrom(gpa, &state, prog, 0, 1 << 22);
        try testing.expect(state.halted);
        S.process(hd, g0, g1, &sf, &l, &r);
        for (0..1152) |i| {
            const want = if (i < 576) l[i] else r[i - 576];
            const got: i32 = @as(i24, @bitCast(@as(u24, @truncate(state.getX(map.at("MP_XS") + @as(u32, @intCast(i))) orelse 0xDEAD))));
            if (got != want) {
                std.debug.print("case {d} ver {d} kind {d} ext {d} line {d}: want {d} got {d}\n", .{ n, vb, kind, hd.mode_ext, i, want, got });
                return error.TestExpectedEqual;
            }
        }
        cases[(if (vb == 3) @as(usize, 0) else 3) + kind] += 1;
    }
    std.debug.print("mp3 intensity: {any} cases\n", .{cases});
}

test "mp3_hybrid matches ref/dsp/mp3/hybrid.zig over random granules" {
    const gpa = testing.allocator;
    const prog = try h.assemble(gpa,
        \\.include "lib/ybits.sm"
        \\.include "lib/stream.sm"
        \\.include "lib/mem.sm"
        \\.include "lib/huffman.sm"
        \\.include "lib/sections.sm"
        \\.include "lib/dequant.sm"
        \\.include "lib/mp3.sm"
        \\        ldi s14, #1
        \\        ldi s15, #16
        \\        mp3_hybrid()
        \\        x17.halt
        \\
    );
    defer gpa.free(prog);
    const H = ref.dsp.mp3.hybrid;
    var prng = std.Random.DefaultPrng.init(0x4b);
    const rnd = prng.random();
    var cases: [4]usize = @splat(0);
    var worst: usize = 0;
    for (0..3) |vi| {
        const vbs = [_]u2{ 3, 2, 0 };
        const vb = vbs[vi];
        const ver: ref.mp3.header.Version = switch (vb) {
            3 => .mpeg1,
            2 => .mpeg2,
            else => .mpeg25,
        };
        const hd: ref.mp3.header.Header = .{ .version = ver, .crc = false, .bitrate_index = 9, .sr_index = rnd.uintLessThan(u2, 3), .padding = false, .mode = .single_channel, .mode_ext = 0 };
        var state = h.emu.State{};
        defer state.deinit(gpa);
        try tables.put(&state, gpa, map.at);
        var twin: H.State = .{};
        try h.putY(&state, gpa, map.at("MH_VER"), vb);
        try h.putY(&state, gpa, map.at("MH_SR"), hd.sr_index);
        try h.putY(&state, gpa, map.at("MH_MP1"), @intFromBool(vb == 3));
        try h.putY(&state, gpa, map.at("MP_SGR"), 0);
        try h.putY(&state, gpa, map.at("MP_HCH"), 0);
        for (0..12) |n| {
            // block types in a legal-ish order: normal, start, short, stop, and mixed
            const bts = [_]u2{ 0, 1, 2, 3, 0, 1, 2, 2, 3, 1, 2, 3 };
            const bt = bts[n];
            const mixed = bt == 2 and n == 7;
            const g: ref.mp3.sideinfo.Granule = .{ .window_switching = bt != 0, .block_type = bt, .mixed = mixed };
            var c: H.Coefs = undefined;
            for (&c) |*x| x.* = rnd.intRangeAtMost(i24, -(1 << 21), 1 << 21);
            try h.putY(&state, gpa, map.at("MP_GR0") + 5, bt);
            try h.putY(&state, gpa, map.at("MP_GR0") + 6, @intFromBool(mixed));
            try h.putAllX(&state, gpa, map.at("MP_XS"), &c);
            state.halted = false;
            const nb = try h.emu.runFrom(gpa, &state, prog, 0, 1 << 22);
            worst = @max(worst, nb);
            try testing.expect(state.halted);
            H.run(&twin, g, ref.mp3.bands.of(hd, g), ref.mp3.bands.mixedLongSubbands(hd), &c);
            for (0..576) |i| {
                const got: i32 = @as(i24, @bitCast(@as(u24, @truncate(state.getX(map.at("MP_XS") + @as(u32, @intCast(i))) orelse 0xDEAD))));
                if (got != c[i]) {
                    std.debug.print("ver {d} granule {d} bt {d} mixed {any} line {d}: want {d} got {d}\n", .{ vb, n, bt, mixed, i, c[i], got });
                    return error.TestExpectedEqual;
                }
            }
            cases[if (mixed) 3 else if (bt == 2) 2 else if (bt == 0) 0 else 1] += 1;
        }
    }
    std.debug.print("mp3 hybrid: {any} granules (long, start/stop, short, mixed), worst {d} bundles\n", .{ cases, worst });
}


test "mp3_synth matches ref/dsp/mp3/synth.zig over random granules" {
    const gpa = testing.allocator;
    const prog = try h.assemble(gpa,
        \\.include "lib/ybits.sm"
        \\.include "lib/stream.sm"
        \\.include "lib/mem.sm"
        \\.include "lib/huffman.sm"
        \\.include "lib/sections.sm"
        \\.include "lib/dequant.sm"
        \\.include "lib/mp3.sm"
        \\        ldi s14, #1
        \\        ldi s15, #16
        \\        mp3_synth()
        \\        x17.halt
        \\
    );
    defer gpa.free(prog);
    const S = ref.dsp.mp3.synth;
    var prng = std.Random.DefaultPrng.init(0x5f);
    const rnd = prng.random();
    var state = h.emu.State{};
    defer state.deinit(gpa);
    try tables.put(&state, gpa, map.at);
    const zeros: [2048]i24 = @splat(0);
    try h.putAllX(&state, gpa, map.at("MP_XV"), &zeros);
    try h.putY(&state, gpa, map.at("MP_YP"), 0);
    try h.putY(&state, gpa, map.at("MP_YP") + 1, 0);
    try h.putY(&state, gpa, map.at("MH_NCH"), 2);
    const out = 0x80;
    try h.putY(&state, gpa, map.at("MP_OUT"), out);
    var twin: [2]S.State = .{ .{}, .{} };
    var worst: usize = 0;
    var clipped: usize = 0;
    for (0..8) |n| {
        const gr: u32 = @intCast(n % 2);
        for (0..2) |ch| {
            var c: [576]i24 = undefined;
            const big: i24 = if (n == 5) 1 << 22 else 1 << 19;
            for (&c) |*x| x.* = rnd.intRangeAtMost(i24, -big, big);
            try h.putAllX(&state, gpa, map.at("MP_XS") + 576 * @as(u32, @intCast(ch)), &c);
            try h.putY(&state, gpa, map.at("MP_SGR"), @intCast(gr));
            try h.putY(&state, gpa, map.at("MP_HCH"), @intCast(ch));
            state.halted = false;
            const nb = try h.emu.runFrom(gpa, &state, prog, 0, 1 << 22);
            worst = @max(worst, nb);
            try testing.expect(state.halted);
            for (0..18) |t| {
                var s: [32]i24 = undefined;
                for (0..32) |k| s[k] = c[k * 18 + t];
                var pcm: [32]i16 = undefined;
                S.slot(&twin[ch], &s, &pcm);
                for (pcm, 0..) |v, j| {
                    clipped += @intFromBool(v == 32767 or v == -32768);
                    const at: u32 = out + @as(u32, @intCast((gr * 576 + t * 32 + j) * 2 + ch));
                    const got: i16 = @bitCast(@as(u16, @truncate(y(&state, at))));
                    if (got != v) {
                        std.debug.print("granule {d} ch {d} t {d} j {d}: want {d} got {d}\n", .{ n, ch, t, j, v, got });
                        // the twin's V after the whole granule against the ring
                        for (t + 1..18) |t2| {
                            for (0..32) |k| s[k] = c[k * 18 + t2];
                            S.slot(&twin[ch], &s, &pcm);
                        }
                        const p = y(&state, map.at("MP_YP") + @as(u32, @intCast(ch)));
                        var bad: usize = 0;
                        for (0..1024) |i| {
                            const a = i / 64;
                            const m = i % 64;
                            const b = (p + a) % 16;
                            const xa = map.at("MP_XV") + 1024 * @as(u32, @intCast(ch)) + 512 * @as(u32, @intFromBool(m >= 32)) + 32 * @as(u32, @intCast(b)) + @as(u32, @intCast(m % 32));
                            const gv: i32 = @as(i24, @bitCast(@as(u24, @truncate(state.getX(xa) orelse 0xDEAD))));
                            if (gv != twin[ch].v[i] and bad < 12) {
                                std.debug.print("  V age {d} m {d}: want {d} got {d}\n", .{ a, m, twin[ch].v[i], gv });
                                bad += 1;
                            }
                        }
                        return error.TestExpectedEqual;
                    }
                }
            }
        }
    }
    std.debug.print("mp3 synth: {d} clipped samples, worst {d} bundles per granule-channel\n", .{ clipped, worst });
    try testing.expect(clipped > 0);
}

test "mp3_packet decodes every fixture frame into the ring as ref/dsp/mp3's Decoder does" {
    const gpa = testing.allocator;
    const prog = try h.assemble(gpa,
        \\.include "lib/ybits.sm"
        \\.include "lib/stream.sm"
        \\.include "lib/mem.sm"
        \\.include "lib/ring.sm"
        \\.include "lib/huffman.sm"
        \\.include "lib/sections.sm"
        \\.include "lib/dequant.sm"
        \\.include "lib/mp3.sm"
        \\        mp3_packet()
        \\        x17.halt
        \\
    );
    defer gpa.free(prog);
    var frames: usize = 0;
    var worst: usize = 0;
    var total: usize = 0;
    for (fixtures) |file| {
        const fr = try tables.frames(gpa, file);
        defer gpa.free(fr);
        var state = h.emu.State{};
        defer state.deinit(gpa);
        try tables.put(&state, gpa, map.at);
        try h.stageDequant(&state, gpa);
        try h.stageRing(&state, gpa, 2, map.at("MP_RSL"));
        const zeros: [2048]i24 = @splat(0);
        try h.putAllX(&state, gpa, map.at("MP_XV"), &zeros);
        try h.putAllX(&state, gpa, map.at("MP_XOV"), zeros[0..1152]);
        inline for (.{ "MP_YP", "MP_OSL", "MP_RLEN" }) |name| try h.putY(&state, gpa, map.at(name), 0);
        try h.putY(&state, gpa, map.at("MP_YP") + 1, 0);
        var dec: ref.dsp.mp3.decoder.Decoder = .{};
        var want: [2304]i16 = undefined;
        for (fr, 0..) |frame, n| {
            const slot = y(&state, map.at("MP_OSL"));
            try h.stagePacket(gpa, &state, frame);
            state.halted = false;
            const nb = try h.emu.runFrom(gpa, &state, prog, 0, 1 << 23);
            worst = @max(worst, nb);
            total += nb;
            try testing.expect(state.halted);
            try testing.expect(!state.stream_starved);
            const f = try dec.decode(frame, &want);
            const len: u32 = @as(u32, f.header.samples()) * f.header.channels();
            try testing.expectEqual(@as(u32, 1), y(&state, map.at("RING_E") + 2 * slot));
            try testing.expectEqual(len, y(&state, map.at("RING_E") + 2 * slot + 1));
            try testing.expectEqual(1 - slot, y(&state, map.at("MP_OSL")));
            const base = map.at("OUTY") + map.at("MP_RSL") * slot;
            for (want[0..len], 0..) |v, i| {
                const got = h.sx16(state.getY(base + @as(u32, @intCast(i))));
                if (got != v) {
                    std.debug.print("frame {d} sample {d}: want {d} got {d}\n", .{ n, i, v, got });
                    return error.TestExpectedEqual;
                }
            }
            try h.putY(&state, gpa, map.at("RING_E") + 2 * slot, 0); // the host releases it
            frames += 1;
        }
    }
    std.debug.print("mp3 packet: {d} frames bit-exact, {d} syllables, worst frame {d} bundles, mean {d}\n", .{ frames, prog.len, worst, total / frames });
}
