//! AAC access units through dsp/lib/aac.sm in x17's emulator. The program still runs on the
//! imported layout (docs/aac-mode0.md), so the tables are staged
//! straight into the emulator's memory, not through the host model: the raw_data_block at
//! Y:AU, AK_NCH and AK_ST, the interleaved PCM at Y:OUTY (addresses from dsp/map.zig).
const std = @import("std");
const ref = @import("ref");
const h = @import("harness.zig");
const map = @import("map.zig");

const A = ref.dsp.aac;

pub const Error = error{ Unsupported, Status, NotHalted } || h.emu.RunError || std.mem.Allocator.Error;

const au_base = map.at("AU");
const ak_nch = map.at("AK_NCH");
const ak_st = map.at("AK_ST");
const pcm_base = map.at("OUTY");
pub const frame_len = 1024;

/// aac_packet, assembled from the audited libs (caller frees).
pub fn program(gpa: std.mem.Allocator) ![]u32 {
    return programSites(gpa, null);
}

/// `program`, also listing each bundle's source line when `sites` is set.
pub fn programSites(gpa: std.mem.Allocator, sites: ?*std.ArrayList(h.Site)) ![]u32 {
    return h.assembleSites(gpa,
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
        \\.include "lib/aac.sm"
        \\        bits_init(AU)
        \\        aac_packet()
        \\        x17.halt
        \\
    , sites);
}

/// What aac.sm decodes: AAC-LC the device accepts, one or two channels, 1024-sample frames.
pub fn supported(asc: ref.aac.asc.Asc) bool {
    return ref.aac.asc.deviceAccepts(asc) and asc.channel_config <= 2 and asc.frame_length == frame_len;
}

/// Every table aac.sm reads, filled once by the host, for sampling frequency index `fi`.
pub fn stageTables(st: *h.emu.State, gpa: std.mem.Allocator, fi: u4) !void {
    // Huffman codes in Y from HUFF0, the scale factor code first; AK_BOOKS + b points at book b
    var addr: u32 = map.at("HUFF0");
    for (0..12) |b| {
        const t = if (b == 0) A.huffman.scalefactor else A.huffman.spectral[b - 1];
        for (t.words, 0..) |w, i| try st.y_mem.put(gpa, addr + @as(u32, @intCast(i)), w);
        if (b > 0) try h.putY(st, gpa, map.at("AK_BOOKS") + @as(u32, @intCast(b)), @intCast(addr));
        addr += @intCast(t.words.len);
    }
    std.debug.assert(addr <= map.at("HUFF_END"));
    // dequantiser
    for (A.dequant.direct_m, A.dequant.direct_e, 0..) |m, e, k| {
        try h.putX(st, gpa, map.at("DQ_D") + 2 * @as(u32, @intCast(k)), m);
        try h.putX(st, gpa, map.at("DQ_D") + 1 + 2 * @as(u32, @intCast(k)), e);
    }
    try h.putAllX(st, gpa, map.at("DQ_IT"), &A.dequant.interp);
    try h.putAllX(st, gpa, map.at("DQ_G"), &A.dequant.gain);
    for (A.dequant.interp_e, A.dequant.interp_rem, 0..) |e, r, j| {
        try h.putY(st, gpa, map.at("DQ_IE") + @as(u32, @intCast(j)), e);
        try h.putY(st, gpa, map.at("DQ_IR") + @as(u32, @intCast(j)), 4 * r);
    }
    try h.stageImdct(st, gpa, 1024, map.at("REVL"));
    try h.stageImdct(st, gpa, 128, map.at("REVS"));
    try stageWindows(st, gpa);
    try h.putAllX(st, gpa, map.at("XSTT"), &A.stereo.quarter);
    try h.putAllX(st, gpa, map.at("XPNT"), &A.pns.quarter);
    try h.putAllX(st, gpa, map.at("XSEED"), &A.pns.seed);
    try h.putAllX(st, gpa, map.at("XTNK"), A.tns.refl[0][0..8]);
    try h.putAllX(st, gpa, map.at("XTNK") + 8, &A.tns.refl[1]);
    // swb_offset (64 words each, the last value repeated), band counts, TNS_MAX_BANDS
    const long = ref.aac.swb.long[fi];
    const short = ref.aac.swb.short[fi];
    for (0..64) |k| {
        try h.putY(st, gpa, map.at("SWB_L") + @as(u32, @intCast(k)), long[@min(k, long.len - 1)]);
        try h.putY(st, gpa, map.at("SWB_S") + @as(u32, @intCast(k)), short[@min(k, short.len - 1)]);
    }
    try h.putY(st, gpa, map.at("AK_NSWBL"), @intCast(long.len - 1));
    try h.putY(st, gpa, map.at("AK_NSWBS"), @intCast(short.len - 1));
    try h.putY(st, gpa, map.at("AK_TOPL"), ref.aac.tns.max_bands_long[fi]);
    try h.putY(st, gpa, map.at("AK_TOPS"), ref.aac.tns.max_bands_short[fi]);
}

/// The window tables window.sm reads: the shared sine table in X, the KBD rises in Y.
pub fn stageWindows(st: *h.emu.State, gpa: std.mem.Allocator) !void {
    try h.stageSine(st, gpa, map.at("SINE"), map.at("SINE4"));
    for (A.window.kbd_long_y, 0..) |v, i| try h.putY(st, gpa, map.at("KBD_L") + @as(u32, @intCast(i)), v);
    for (A.window.kbd_short_y, 0..) |v, i| try h.putY(st, gpa, map.at("KBD_S") + @as(u32, @intCast(i)), v);
}

pub const Player = struct {
    gpa: std.mem.Allocator,
    state: h.emu.State = .{},
    prog: []const u32,
    nch: usize,
    pcm: []i16,
    /// AK_ST after the last access unit (aac.sm header).
    status: u32 = 0,
    bundles: usize = 0,

    /// A fresh stream: zero overlaps, prev_shape 0 and the PNS generator at 0, as the twin's
    /// Decoder.init leaves them.
    pub fn init(gpa: std.mem.Allocator, prog: []const u32, asc: ref.aac.asc.Asc) Error!Player {
        if (!supported(asc)) return error.Unsupported;
        const nch: usize = asc.channel_config;
        var p: Player = .{ .gpa = gpa, .prog = prog, .nch = nch, .pcm = try gpa.alloc(i16, frame_len * nch) };
        errdefer p.deinit();
        try stageTables(&p.state, gpa, asc.freq_index);
        try h.putY(&p.state, gpa, ak_nch, @intCast(nch));
        return p;
    }

    /// Counts, from now on, the bundles run at each syllable (x17 emulator `State.profile`).
    pub fn profile(self: *Player, counts: []u64) void {
        self.state.profile = counts;
    }

    pub fn deinit(self: *Player) void {
        self.state.deinit(self.gpa);
        self.gpa.free(self.pcm);
    }

    /// One access unit: its PCM, interleaved 16-bit, valid until the next call.
    pub fn feed(self: *Player, au: []const u8) Error![]const i16 {
        const st = &self.state;
        // 16-bit words, the first byte high; an odd last byte gets a zero low half
        for (0..(au.len + 1) / 2) |i| {
            const hi: u32 = au[2 * i];
            const lo: u32 = if (2 * i + 1 < au.len) au[2 * i + 1] else 0;
            try st.y_mem.put(self.gpa, au_base + @as(u32, @intCast(i)), hi << 8 | lo);
        }
        st.cur_lane = 0;
        self.bundles = try h.emu.runFrom(self.gpa, st, self.prog, 0, 1 << 30);
        if (!st.halted) return error.NotHalted;
        self.status = st.getY(ak_st) orelse 0;
        if (self.status != 0) return error.Status;
        for (self.pcm, 0..) |*s, i| s.* = @bitCast(@as(u16, @truncate(st.getY(pcm_base + @as(u32, @intCast(i))) orelse 0)));
        return self.pcm;
    }
};
