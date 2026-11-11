//! aac_packet's size against program memory: P is 4 lanes x 0x1000 rows, and pass 2 loads at row
//! 0x40 (x17 handbook §11), so 16128 syllables (docs/aac-mode0.md).
const std = @import("std");
const h = @import("../harness.zig");

const budget = 0x4000 - 4 * 0x40;

test "aac_packet fits program memory" {
    const gpa = std.testing.allocator;
    const prog = try h.assemble(gpa,
        \\.include "lib/bits.sm"
        \\.include "lib/mem.sm"
        \\.include "lib/huffman.sm"
        \\.include "lib/sections.sm"
        \\.include "lib/dequant.sm"
        \\.include "lib/stereo.sm"
        \\.include "lib/pns.sm"
        \\.include "lib/tns.sm"
        \\.include "lib/imdct.sm"
        \\.include "lib/window.sm"
        \\.include "lib/ring.sm"
        \\.include "lib/aac.sm"
        \\dsp_entry:
        \\        bits_init()
        \\        aac_packet()
        \\        x17.halt
        \\.include "lib/winsubs.sm"
        \\
    );
    defer gpa.free(prog);
    std.testing.expect(prog.len <= budget) catch |e| {
        std.log.err("aac_packet: {d} syllables", .{prog.len});
        return e;
    };
}
