//! Assembles the stage libraries in dsp/lib with x17's assembler and runs them in its emulator,
//! for tests against the ref/dsp twins.
const std = @import("std");
const asm_mod = @import("asm");
pub const emu = @import("emu");

const libs = [_]struct { path: []const u8, text: []const u8 }{
    .{ .path = "lib/bits.sm", .text = @embedFile("lib/bits.sm") },
    .{ .path = "lib/mem.sm", .text = @embedFile("lib/mem.sm") },
    .{ .path = "lib/pcm.sm", .text = @embedFile("lib/pcm.sm") },
    .{ .path = "lib/huffman.sm", .text = @embedFile("lib/huffman.sm") },
    .{ .path = "lib/sections.sm", .text = @embedFile("lib/sections.sm") },
    .{ .path = "lib/dequant.sm", .text = @embedFile("lib/dequant.sm") },
};

fn load(ctx: ?*anyopaque, gpa: std.mem.Allocator, path: []const u8) anyerror!?[]u8 {
    _ = ctx;
    for (libs) |l| if (std.mem.eql(u8, l.path, path)) return try gpa.dupe(u8, l.text);
    return null;
}

/// The syllables of `src`, which may `.include` any lib above (caller frees).
pub fn assemble(gpa: std.mem.Allocator, src: []const u8) ![]u32 {
    return switch (try asm_mod.assembleFileWith(gpa, src, .{ .path = "t.sm", .loader = .{ .load = load } })) {
        .ok => |p| p,
        .err => |fe| {
            std.debug.print("line {d}: {s}\n", .{ fe.line, fe.lineText() });
            return error.Assemble;
        },
    };
}

/// A packet staged in Y from `base` as 16-bit big-endian byte pairs (x17's host model).
pub fn stagePacket(gpa: std.mem.Allocator, state: *emu.State, base: u32, data: []const u8) !void {
    for (0..data.len / 2) |i| try state.y_mem.put(gpa, base + @as(u32, @intCast(i)), @as(u32, data[2 * i]) << 8 | data[2 * i + 1]);
}
