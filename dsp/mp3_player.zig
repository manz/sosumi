//! MP3 frames through x17's host model and dsp/lib/mp3.sm: the host arms each frame on the
//! input stream, runs mp3_packet to its stop and drains the ring's two slots (specs/mp3.md "The
//! sm1 side"). The tables and the zeroed stream state are the init pass's (`imageSource`).
const std = @import("std");
const ref = @import("ref");
const host = @import("host");
const h = @import("harness.zig");
const map = @import("map.zig");
const tables = @import("mp3/tables.zig");

pub const Error = error{ Starved, RingFull } || host.Error || std.mem.Allocator.Error;

/// The libraries mp3_packet needs, in include order.
const libs = [_][]const u8{ "ybits", "stream", "mem", "ring", "huffman", "sections", "dequant", "mp3" };

/// mp3_packet, assembled from the libs (caller frees).
pub fn program(gpa: std.mem.Allocator) ![]u32 {
    return programSites(gpa, null);
}

/// `program`, also listing each bundle's source line when `sites` is set.
pub fn programSites(gpa: std.mem.Allocator, sites: ?*std.ArrayList(h.Site)) ![]u32 {
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(gpa);
    for (libs) |f| try src.print(gpa, ".include \"lib/{s}.sm\"\n", .{f});
    try src.appendSlice(gpa, "        mp3_packet()\n        x17.halt\n");
    return h.assembleSites(gpa, src.items, sites);
}

/// Every word the init pass leaves: the tables, the ring's header (two slots of MP_RSL words),
/// and the stream state at zero (synthesis history, overlap, each channel's newest V block,
/// the slot word, the reservoir's length).
pub fn stageInit(st: *h.emu.State, gpa: std.mem.Allocator) !void {
    try tables.put(st, gpa, map.at);
    try h.stageDequant(st, gpa);
    try h.stageRing(st, gpa, 2, map.at("MP_RSL"));
    for (0..2 * map.at("MP_VC")) |k| try st.x_mem.put(gpa, map.at("MP_XV") + @as(u32, @intCast(k)), 0);
    for (0..1152) |k| try st.x_mem.put(gpa, map.at("MP_XOV") + @as(u32, @intCast(k)), 0);
    inline for (.{ "MP_YP", "MP_OSL", "MP_RLEN" }) |name| try st.y_mem.put(gpa, map.at(name), 0);
    try st.y_mem.put(gpa, map.at("MP_YP") + 1, 0);
}

pub const Player = struct {
    host: host.Host,
    prog: []const u32,
    bundles: usize = 0,

    pub fn init(gpa: std.mem.Allocator, prog: []const u32, rate_hz: u32) Error!Player {
        var p: Player = .{
            .host = try host.Host.init(gpa, .{ .rate_hz = rate_hz, .max_bundles = 1 << 30 }),
            .prog = prog,
        };
        errdefer p.host.deinit();
        try stageInit(&p.host.state, gpa);
        return p;
    }

    pub fn deinit(self: *Player) void {
        self.host.deinit();
    }

    /// One frame: the PCM the host took, interleaved 16-bit in the stream's own channel count,
    /// valid until the next call. RingFull: both slots were owned, the frame stays queued.
    pub fn feed(self: *Player, frame: []const u8) Error![]const i16 {
        self.host.pcm.clearRetainingCapacity();
        const r = try self.host.feed(self.prog, frame);
        self.bundles = r.bundles;
        if (r.waiting) return error.Starved; // it read past its frame (784)
        if ((self.host.state.getY(map.at("HOST_ST") + 1) orelse 0) == 0x21) return error.RingFull;
        return self.host.pcm.items;
    }

    /// Counts, from now on, the bundles run at each syllable (x17 emulator `State.profile`).
    pub fn profile(self: *Player, counts: []u64) void {
        self.host.state.profile = counts;
    }
};

/// mp3_packet's x17 image source: one init pass carrying, as .xdata and .ydata, every word
/// `stageInit` sets, then a halt; then the decoder pass, its libraries included from `lib`.
pub fn imageSource(gpa: std.mem.Allocator, w: *std.Io.Writer, lib: []const u8) !void {
    var st: h.emu.State = .{};
    defer st.deinit(gpa);
    try stageInit(&st, gpa);
    try w.writeAll("; mp3_packet's image (dsp/mp3_player.zig imageSource)\n");
    try @import("aac_player.zig").initPass(gpa, w, &st, 2, map.at("BITS_ON"), null); // mode 1's map does not hold it yet (specs/questions.md Q32)
    for (libs) |f| try w.print(".include \"{s}/{s}.sm\"\n", .{ lib, f });
    try w.writeAll("        mp3_packet()\n        x17.halt\n");
}

/// The frames of an MP3 file: ID3v2 skipped, then header to header (caller frees the list).
pub const frames = tables.frames;
