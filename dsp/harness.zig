//! Assembles the stage libraries in dsp/lib with x17's assembler and runs them in its emulator,
//! for tests against the ref/dsp twins.
const std = @import("std");
const asm_mod = @import("asm");
pub const emu = @import("emu");

pub const libs = [_]struct { path: []const u8, text: []const u8 }{
    .{ .path = "lib/bitcore.sm", .text = @embedFile("lib/bitcore.sm") },
    .{ .path = "lib/stream.sm", .text = @embedFile("lib/stream.sm") },
    .{ .path = "lib/bits.sm", .text = @embedFile("lib/bits.sm") },
    .{ .path = "lib/ybits.sm", .text = @embedFile("lib/ybits.sm") },
    .{ .path = "lib/mem.sm", .text = @embedFile("lib/mem.sm") },
    .{ .path = "lib/ring.sm", .text = @embedFile("lib/ring.sm") },
    .{ .path = "lib/pcm.sm", .text = @embedFile("lib/pcm.sm") },
    .{ .path = "lib/huffman.sm", .text = @embedFile("lib/huffman.sm") },
    .{ .path = "lib/sections.sm", .text = @embedFile("lib/sections.sm") },
    .{ .path = "lib/dequant.sm", .text = @embedFile("lib/dequant.sm") },
    .{ .path = "lib/stereo.sm", .text = @embedFile("lib/stereo.sm") },
    .{ .path = "lib/pns.sm", .text = @embedFile("lib/pns.sm") },
    .{ .path = "lib/tns.sm", .text = @embedFile("lib/tns.sm") },
    .{ .path = "lib/imdct.sm", .text = @embedFile("lib/imdct.sm") },
    .{ .path = "lib/window.sm", .text = @embedFile("lib/window.sm") },
    .{ .path = "lib/winsubs.sm", .text = @embedFile("lib/winsubs.sm") },
    .{ .path = "lib/aac.sm", .text = @embedFile("lib/aac.sm") },
    .{ .path = "lib/rice.sm", .text = @embedFile("lib/rice.sm") },
    .{ .path = "lib/predictor.sm", .text = @embedFile("lib/predictor.sm") },
    .{ .path = "lib/unmix.sm", .text = @embedFile("lib/unmix.sm") },
    .{ .path = "lib/alac.sm", .text = @embedFile("lib/alac.sm") },
    .{ .path = "lib/mp3.sm", .text = @embedFile("lib/mp3.sm") },
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

/// An image source (`.pass` blocks and their data, x17 ASSEMBLY.md), its includes from the libs
/// above (caller deinits).
pub fn assembleImage(gpa: std.mem.Allocator, src: []const u8) !asm_mod.Program {
    return switch (try asm_mod.assembleProgram(gpa, src, .{ .path = "t.sm", .loader = .{ .load = load } })) {
        .ok => |p| p,
        .err => |fe| {
            std.debug.print("line {d}: {s}\n", .{ fe.line, fe.lineText() });
            return error.Assemble;
        },
    };
}

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

/// A packet armed on the input stream (fact 783), after any bytes still unread.
pub fn stagePacket(gpa: std.mem.Allocator, state: *emu.State, data: []const u8) !void {
    try state.queueStream(gpa, data);
}

const Word = @import("ref").dsp.ops.Word;
const imdct = @import("ref").dsp.aac.imdct;
const sine = @import("ref").dsp.aac.sine;

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
/// The output ring's header as the init pass leaves it (lib/ring.sm): Y:0..4 = 0, `slots`,
/// `words` per slot, 0, 0x10. AAC and PCM 2 x RING_SLOT (specs/aac.md), ALAC 1 x 0x2000
/// (specs/alac.md).
pub fn stageRing(st: *emu.State, gpa: std.mem.Allocator, slots: u32, words: u32) !void {
    for ([_]u32{ 0, slots, words, 0, 0x10 }, 0..) |v, i| try st.y_mem.put(gpa, @intCast(i), v);
}

pub fn sx16(v: ?u32) i32 {
    return @as(i16, @bitCast(@as(u16, @truncate(v orelse 0xDEAD))));
}

pub fn putCx(st: *emu.State, gpa: std.mem.Allocator, base: u32, k: usize, c: imdct.Cx) !void {
    try putX(st, gpa, base + 2 * @as(u32, @intCast(k)), c.re);
    try putX(st, gpa, base + 2 * @as(u32, @intCast(k)) + 1, c.im);
}

/// One IMDCT size's bit reversal, Y REV (its twiddles come from the sine table, `stageSine`).
pub fn stageImdct(st: *emu.State, gpa: std.mem.Allocator, comptime n2: usize, rev: u32) !void {
    const T = imdct.Tables(n2);
    for (T.rev, 0..) |r, n| try putY(st, gpa, rev + @as(u32, @intCast(n)), 2 * @as(i32, r));
}

/// The shared sine table (ref/dsp/aac/sine.zig): the odd entries at `odd`, the multiples of 4
/// at `four`.
pub fn stageSine(st: *emu.State, gpa: std.mem.Allocator, odd: u32, four: u32) !void {
    try putAllX(st, gpa, odd, &sine.odd);
    try putAllX(st, gpa, four, &sine.four);
}

/// lib/dequant.sm's |q|^(4/3) tables (ref/dsp/aac/dequant.zig) at their addresses: X DQ_D pairs
/// (m, em), DQ_IT, DQ_G; Y DQ_IE, DQ_IR (4 rem).
pub fn stageDequant(st: *emu.State, gpa: std.mem.Allocator) !void {
    const map = @import("map.zig");
    try stageDequantAt(st, gpa, .{ .d = map.at("DQ_D"), .it = map.at("DQ_IT"), .g = map.at("DQ_G"), .ie = map.at("DQ_IE"), .ir = map.at("DQ_IR") });
}

/// lib/dequant.sm's tables where a program keeps them (X d, it, g; Y ie, ir).
pub const DequantAt = struct { d: u32, it: u32, g: u32, ie: u32, ir: u32 };

/// MP3's (lib/mp3.sm MP_XDQ, MP_XIT, MP_XG, MP_IE, MP_IR).
pub fn mp3Dequant() DequantAt {
    const map = @import("map.zig");
    return .{ .d = map.at("MP_XDQ"), .it = map.at("MP_XIT"), .g = map.at("MP_XG"), .ie = map.at("MP_IE"), .ir = map.at("MP_IR") };
}

pub fn stageDequantAt(st: *emu.State, gpa: std.mem.Allocator, at: DequantAt) !void {
    const D = @import("ref").dsp.aac.dequant;
    for (D.direct_m, D.direct_e, 0..) |m, e, k| {
        try putX(st, gpa, at.d + 2 * @as(u32, @intCast(k)), m);
        try putX(st, gpa, at.d + 1 + 2 * @as(u32, @intCast(k)), e);
    }
    try putAllX(st, gpa, at.it, &D.interp);
    try putAllX(st, gpa, at.g, &D.gain);
    for (D.interp_e, D.interp_rem, 0..) |e, r, j| {
        try putY(st, gpa, at.ie + @as(u32, @intCast(j)), e);
        try putY(st, gpa, at.ir + @as(u32, @intCast(j)), 4 * r);
    }
}
