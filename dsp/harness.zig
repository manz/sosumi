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
    .{ .path = "lib/stereo.sm", .text = @embedFile("lib/stereo.sm") },
    .{ .path = "lib/pns.sm", .text = @embedFile("lib/pns.sm") },
    .{ .path = "lib/tns.sm", .text = @embedFile("lib/tns.sm") },
    .{ .path = "lib/imdct.sm", .text = @embedFile("lib/imdct.sm") },
    .{ .path = "lib/window.sm", .text = @embedFile("lib/window.sm") },
    .{ .path = "lib/aac.sm", .text = @embedFile("lib/aac.sm") },
    .{ .path = "lib/rice.sm", .text = @embedFile("lib/rice.sm") },
    .{ .path = "lib/predictor.sm", .text = @embedFile("lib/predictor.sm") },
    .{ .path = "lib/unmix.sm", .text = @embedFile("lib/unmix.sm") },
    .{ .path = "lib/alac.sm", .text = @embedFile("lib/alac.sm") },
};

fn load(ctx: ?*anyopaque, gpa: std.mem.Allocator, path: []const u8) anyerror!?[]u8 {
    _ = ctx;
    for (libs) |l| if (std.mem.eql(u8, l.path, path)) return try gpa.dupe(u8, l.text);
    return null;
}

/// The syllables of `src`, which may `.include` any lib above (caller frees).
pub fn assemble(gpa: std.mem.Allocator, src: []const u8) ![]u32 {
    return assembleSites(gpa, src, null);
}

pub const Site = asm_mod.Site;

/// `assemble`, also listing where each bundle came from when `sites` is set.
pub fn assembleSites(gpa: std.mem.Allocator, src: []const u8, sites: ?*std.ArrayList(Site)) ![]u32 {
    return switch (try asm_mod.assembleFileWith(gpa, src, .{ .path = "t.sm", .loader = .{ .load = load }, .sites = sites })) {
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

const Word = @import("ref").dsp.ops.Word;
const imdct = @import("ref").dsp.aac.imdct;

/// X:[addr] = v, its 24 bits.
pub fn putX(st: *emu.State, gpa: std.mem.Allocator, addr: u32, v: Word) !void {
    try st.x_mem.put(gpa, addr, @as(u24, @bitCast(v)));
}

/// X[base ..] = ws.
pub fn putAllX(st: *emu.State, gpa: std.mem.Allocator, base: u32, ws: []const Word) !void {
    for (ws, 0..) |v, k| try putX(st, gpa, base + @as(u32, @intCast(k)), v);
}

/// Y:[addr] = v, its low 16 bits.
pub fn putY(st: *emu.State, gpa: std.mem.Allocator, addr: u32, v: i32) !void {
    try st.y_mem.put(gpa, addr, @as(u16, @truncate(@as(u32, @bitCast(v)))));
}

/// A Y word read back as signed 16 bits; a missing word reads as 0xDEAD.
pub fn sx16(v: ?u32) i32 {
    return @as(i16, @bitCast(@as(u16, @truncate(v orelse 0xDEAD))));
}

pub fn putCx(st: *emu.State, gpa: std.mem.Allocator, base: u32, k: usize, c: imdct.Cx) !void {
    try putX(st, gpa, base + 2 * @as(u32, @intCast(k)), c.re);
    try putX(st, gpa, base + 2 * @as(u32, @intCast(k)) + 1, c.im);
}

/// One IMDCT size's tables: PRE, POST, TW stage by stage from the twin's fft, Y REV.
pub fn stageImdct(st: *emu.State, gpa: std.mem.Allocator, comptime n2: usize, pre: u32, post: u32, tw: u32, rev: u32) !void {
    const T = imdct.Tables(n2);
    for (T.pre, T.post, 0..) |a, c, k| {
        try putCx(st, gpa, pre, k, a);
        try putCx(st, gpa, post, k, c);
    }
    var at: usize = 0;
    var size: usize = 2;
    while (size <= T.n4) : (size *= 2) for (0..size / 2) |i| {
        try putCx(st, gpa, tw, at, T.fft[i * (T.n4 / size)]);
        at += 1;
    };
    for (T.rev, 0..) |r, n| try putY(st, gpa, rev + @as(u32, @intCast(n)), 2 * @as(i32, r) - 2);
}
