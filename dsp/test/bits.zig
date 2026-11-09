//! dsp/lib/bits.sm against its twin, ref/dsp/bits.zig.
const std = @import("std");
const ref = @import("ref");
const h = @import("../harness.zig");

const testing = std.testing;
const dsts = [_]u4{ 1, 2, 3, 4, 5, 7 };

test "getbits reads what ref/dsp's Reader reads, across refills" {
    const gpa = testing.allocator;
    var prng = std.Random.DefaultPrng.init(0xB175);
    const rnd = prng.random();
    for (0..300) |_| {
        var data: [64]u8 = undefined;
        rnd.bytes(&data);
        const skip = rnd.intRangeAtMost(usize, 0, 20);
        var widths: [26]u5 = undefined;
        for (widths[0 .. skip + dsts.len]) |*w| w.* = rnd.intRangeAtMost(u5, 1, 8);

        var src: std.ArrayList(u8) = .empty;
        defer src.deinit(gpa);
        try src.appendSlice(gpa, ".include \"lib/bits.sm\"\n        bits_init()\n");
        for (widths[0..skip]) |w| try src.print(gpa, "        getbits(s8, {d})\n", .{w});
        for (dsts, widths[skip .. skip + dsts.len]) |d, w| try src.print(gpa, "        getbits(s{d}, {d})\n", .{ d, w });
        try src.appendSlice(gpa, "        x17.halt\n");
        const prog = try h.assemble(gpa, src.items);
        defer gpa.free(prog);

        var state = h.emu.State{};
        defer state.deinit(gpa);
        try h.stagePacket(gpa, &state, &data);
        _ = try h.emu.runFrom(gpa, &state, prog, 0, 1 << 16);
        try testing.expect(state.halted);

        var r = ref.dsp.bits.Reader.init(&data);
        for (widths[0..skip]) |w| _ = try r.read(w);
        for (dsts, widths[skip .. skip + dsts.len]) |d, w| {
            const want: u32 = @intCast(try r.read(w));
            try testing.expectEqual(want, state.s[d]);
        }
    }
}

test "readn reads up to 24 bits as the Reader does" {
    const gpa = testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x24B1);
    const rnd = prng.random();
    for (0..200) |_| {
        var data: [64]u8 = undefined;
        rnd.bytes(&data);
        const lead = rnd.intRangeAtMost(u5, 0, 8);
        const n = rnd.intRangeAtMost(u5, 0, 23);
        var src: std.ArrayList(u8) = .empty;
        defer src.deinit(gpa);
        try src.print(gpa, ".include \"lib/bits.sm\"\n        bits_init()\n        getbits(s8, {d})\n        ldi s7, #{d}\n        readn(s1)\n        x17.halt\n", .{ lead, n });
        const prog = try h.assemble(gpa, src.items);
        defer gpa.free(prog);

        var state = h.emu.State{};
        defer state.deinit(gpa);
        try h.stagePacket(gpa, &state, &data);
        _ = try h.emu.runFrom(gpa, &state, prog, 0, 1 << 16);
        try testing.expect(state.halted);

        var r = ref.dsp.bits.Reader.init(&data);
        _ = try r.read(lead);
        const want: u32 = @intCast(try r.read(n));
        try testing.expectEqual(want, state.s[1]);
    }
}
