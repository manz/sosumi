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
