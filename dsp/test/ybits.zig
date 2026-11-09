//! dsp/lib/ybits.sm against ref/dsp/bits.zig: the same reads over bytes held one per Y word.
const std = @import("std");
const ref = @import("ref");
const h = @import("../harness.zig");

const testing = std.testing;
const base: u32 = 0x1400;

test "ybits reads, seeks and reports its position as the Reader does" {
    const gpa = testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x7B17);
    const rnd = prng.random();
    for (0..200) |_| {
        var data: [64]u8 = undefined;
        rnd.bytes(&data);
        const start = rnd.intRangeAtMost(u32, 0, 8);
        const n = rnd.intRangeAtMost(usize, 1, 20);
        var widths: [20]u5 = undefined;
        for (widths[0..n]) |*w| w.* = rnd.intRangeAtMost(u5, 0, 15);

        var src: std.ArrayList(u8) = .empty;
        defer src.deinit(gpa);
        try src.print(gpa, ".include \"lib/ybits.sm\"\n        ybits_init()\n        ldi s1, #{d}\n        ybits_at(s1)\n", .{base + start});
        for (widths[0 .. n - 1]) |w| try src.print(gpa, "        getbits(s8, {d})\n", .{w});
        try src.print(gpa, "        getbits(s1, {d})\n        ybits_pos(s2)\n        x17.halt\n", .{widths[n - 1]});
        const prog = try h.assemble(gpa, src.items);
        defer gpa.free(prog);

        var state = h.emu.State{};
        defer state.deinit(gpa);
        for (data, 0..) |b, i| try state.y_mem.put(gpa, base + @as(u32, @intCast(i)), b);
        _ = try h.emu.runFrom(gpa, &state, prog, 0, 1 << 16);
        try testing.expect(state.halted);

        var r = ref.dsp.bits.Reader.init(data[start..]);
        for (widths[0 .. n - 1]) |w| _ = try r.read(w);
        try testing.expectEqual(@as(u32, @intCast(try r.read(widths[n - 1]))), state.s[1]);
        try testing.expectEqual(@as(u32, @intCast((base + start) * 8 + r.pos)), state.s[2]);
    }
}
