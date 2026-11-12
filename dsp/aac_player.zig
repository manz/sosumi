//! AAC access units through dsp/lib/aac.sm in x17's emulator. The tables are staged straight
//! into the emulator's memory, not through the host model: the raw_data_block armed on the
//! input stream, AK_NCH and AK_ST, the interleaved PCM at Y:OUTY (addresses from dsp/map.zig).
const std = @import("std");
const ref = @import("ref");
const h = @import("harness.zig");
const map = @import("map.zig");

/// aac.sm's constants (the libraries' `.const` values).
pub const at = map.at;

const A = ref.dsp.aac;

pub const Error = error{ Unsupported, Status, NotHalted, Starved, MonoCopy } || h.emu.RunError || std.mem.Allocator.Error;

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
        \\.include "lib/ring.sm"
        \\.include "lib/aac.sm"
        \\dsp_entry:
        \\        bits_init()
        \\        aac_packet()
        \\        x17.halt
        \\.include "lib/winsubs.sm"
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
    try h.stageDequant(st, gpa);
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
        try st.queueStream(self.gpa, au);
        st.cur_lane = 0;
        const k = st.getY(map.at("AK_OSL")) orelse 0;
        self.bundles = try h.emu.runFrom(self.gpa, st, self.prog, 0, 1 << 30);
        if (st.stream_starved) return error.Starved; // it read past its access unit
        if (!st.halted) return error.NotHalted;
        self.status = st.getY(ak_st) orelse 0;
        if (self.status != 0) return error.Status;
        const slot = pcm_base + map.at("RING_SLOT") * k;
        // the slot is always stereo; a mono channel sits on both sides
        for (self.pcm, 0..) |*s, i| {
            const off: u32 = @intCast(if (self.nch == 1) 2 * i else i);
            s.* = @bitCast(@as(u16, @truncate(st.getY(slot + off) orelse 0)));
            if (self.nch == 1 and st.getY(slot + off + 1) != st.getY(slot + off)) return error.MonoCopy;
        }
        try st.y_mem.put(self.gpa, map.at("RING_E") + 2 * k, 0); // the host releases the slot
        return self.pcm;
    }
};

/// One space's words as image directives (x17 ASSEMBLY.md "Placement and layout"), up to 16 a
/// line, a line per run of consecutive addresses.
pub fn emitData(w: *std.Io.Writer, gpa: std.mem.Allocator, dir: []const u8, mem: *const std.AutoHashMapUnmanaged(u32, u32), mask: u32) !void {
    var keys: std.ArrayList(u32) = .empty;
    defer keys.deinit(gpa);
    var it = mem.keyIterator();
    while (it.next()) |k| try keys.append(gpa, k.*);
    std.mem.sort(u32, keys.items, {}, std.sort.asc(u32));
    var i: usize = 0;
    while (i < keys.items.len) {
        var j = i;
        while (j + 1 < keys.items.len and keys.items[j + 1] == keys.items[j] + 1 and j + 1 - i < 16) j += 1;
        try w.print("{s} 0x{X:0>4}", .{ dir, keys.items[i] });
        for (keys.items[i .. j + 1]) |k| try w.print(", 0x{X}", .{mem.get(k).? & mask});
        try w.writeAll("\n");
        i = j + 1;
    }
}

/// An image's init pass (x17 ASSEMBLY.md "Placement and layout"): `st`'s words as .xdata and
/// .ydata, with the ring's `slots` entries cleared (owned 0, length 0), then code that clears
/// the stream enable's flag at Y:`on` (lib/stream.sm: BITS_ON, or the image's own), which no
/// .ydata reaches: the first packet after the load enables the stream. Then the decoder
/// pass's header.
pub fn initPass(gpa: std.mem.Allocator, w: *std.Io.Writer, st: *h.emu.State, slots: u32, on: u32) !void {
    for (0..2 * slots) |k| try st.y_mem.put(gpa, map.at("RING_E") + @as(u32, @intCast(k)), 0);
    try w.writeAll(".pass init\n");
    try emitData(w, gpa, ".xdata", &st.x_mem, 0xFFFFFF);
    try emitData(w, gpa, ".ydata", &st.y_mem, 0xFFFF);
    try w.print(
        \\        ldi s3, #0
        \\        lde e6, #0x{X}
        \\        x17.sty e6, #3, #0      ; the stream enable's flag = 0
        \\        x17.halt
        \\
        \\.pass decoder
        \\
    , .{on});
}

/// aac_packet's x17 image source: one init pass carrying, as .xdata and .ydata, every word the
/// host sets before the first access unit (`Player.init`: the tables for `fi`, AK_NCH) and the
/// stream state the emulator reads as zero (the overlaps, the PNS generator, prev_shape), then
/// a halt; then the decoder pass, its libraries included from `lib` (dsp/lib).
pub fn imageSource(gpa: std.mem.Allocator, w: *std.Io.Writer, lib: []const u8, fi: u4, nch: u32) !void {
    var st: h.emu.State = .{};
    defer st.deinit(gpa);
    try stageTables(&st, gpa, fi);
    try st.y_mem.put(gpa, ak_nch, nch);
    try h.stageRing(&st, gpa, 2, map.at("RING_SLOT"));
    for (0..2048) |k| try st.x_mem.put(gpa, map.at("OVL0") + @as(u32, @intCast(k)), 0);
    try st.x_mem.put(gpa, map.at("XRNG"), 0);
    for (0..2) |c| try st.y_mem.put(gpa, map.at("AK_SHP") + @as(u32, @intCast(c)), 0);
    try st.y_mem.put(gpa, map.at("AK_OSL"), 0);
    try w.print("; aac_packet's image (dsp/aac_player.zig imageSource: freq_index {d}, {d} channels)\n", .{ fi, nch });
    try initPass(gpa, w, &st, 2, map.at("BITS_ON"));
    for ([_][]const u8{ "bits", "mem", "huffman", "sections", "dequant", "stereo", "pns", "tns", "imdct", "window", "ring", "aac" }) |f|
        try w.print(".include \"{s}/{s}.sm\"\n", .{ lib, f });
    try w.writeAll(
        \\dsp_entry:
        \\        bits_init()
        \\        aac_packet()
        \\        x17.halt
        \\
    );
    try w.print(".include \"{s}/winsubs.sm\"\n", .{lib});
}
