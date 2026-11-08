//! Decodes the ALAC track of an .m4a with the reference model to raw little-endian PCM at the
//! stream's depth (16 -> 2 bytes, 20/24 -> 3, 32 -> 4), for a byte-exact `cmp` against
//! afconvert's and ffmpeg's output.
//!
//!     alacdec in.m4a out.raw [--dsp] [--dump=pkts.bin]
//!
//! --dump writes the config, the first and the last packet and their PCM (little-endian u32
//! fields; see `Dump`) for x17's packet-level test of the sm1 decoder. --integrate rewrites
//! the first packet's sub-frame modes to 1 before decoding it, for a mode != 0 case no
//! encoder emits.
const std = @import("std");
const ref = @import("ref");

const mp4 = ref.alac.mp4;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 3) {
        std.debug.print("usage: alacdec in.m4a out.raw [--dsp] [--dump=pkts.bin]\n", .{});
        std.process.exit(2);
    }
    const cwd = std.Io.Dir.cwd();
    const file = try cwd.readFileAlloc(io, args[1], gpa, .limited(1 << 31));
    defer gpa.free(file);
    const cfg = try ref.alac.config.parse((try mp4.findTrack(file)).cookie);
    var dec = try ref.alac.decoder.Decoder.init(gpa, cfg);
    defer dec.deinit();
    // --dsp: the whole decoder in measured sm1 operations (ref/dsp/alac)
    var use_dsp = false;
    var integrate = false;
    var dump_path: ?[]const u8 = null;
    for (args[3..]) |a| {
        if (std.mem.eql(u8, a, "--dsp")) use_dsp = true;
        if (std.mem.startsWith(u8, a, "--dump=")) dump_path = a["--dump=".len..];
        if (std.mem.eql(u8, a, "--integrate")) integrate = true;
    }
    var dump: Dump = .{};
    defer dump.deinit(gpa);
    var ddec = try ref.dsp.alac.decoder.Decoder.init(gpa, cfg);
    defer ddec.deinit();
    const nch: usize = cfg.channels;
    const width: usize = (@as(usize, cfg.bit_depth) + 7) / 8;
    const pcm = try gpa.alloc(i32, @as(usize, cfg.frame_length) * nch);
    defer gpa.free(pcm);
    var raw: std.ArrayList(u8) = .empty;
    defer raw.deinit(gpa);

    var sample: u32 = 0;
    var failed: usize = 0;
    var frames: usize = 0;
    var cov: [5]usize = @splat(0);
    var max_order: u5 = 0;
    var elems: [8]usize = @splat(0);
    var packets = try mp4.Packets.init(file);
    const count = packets.t.count;
    while (try packets.next()) |pkt| {
        if (integrate and sample == 0) setModes(pkt);
        const res = if (use_dsp) ddec.decode(pkt, pcm) else dec.decode(pkt, pcm);
        const n = res catch |e| blk: {
            if (failed < 5) std.debug.print("packet {d}: {s}\n", .{ sample, @errorName(e) });
            failed += 1;
            break :blk 0;
        };
        if (dump_path != null and (sample == 0 or sample + 1 == count)) try dump.add(gpa, pkt, pcm[0 .. n * nch], n);
        const st = if (use_dsp) ddec.last else dec.last;
        inline for (.{ st.verbatim, st.shifted, st.matrixed, st.partial, st.integrated }, 0..) |b, k| cov[k] += @intFromBool(b);
        max_order = @max(max_order, st.max_order);
        for (st.elements, 0..) |e, k| elems[k] += e;
        // 20-bit samples sit left-justified in 3 bytes
        const lj: u5 = if (cfg.bit_depth == 20) 4 else 0;
        for (pcm[0 .. n * nch]) |s| {
            const v: u32 = @bitCast(s << lj);
            for (0..width) |k| try raw.append(gpa, @truncate(v >> @intCast(8 * k)));
        }
        sample += 1;
        frames += 1;
    }
    std.debug.print("  packets with: verbatim {d}, shifted {d}, matrixed {d}, partial {d}, integrated {d}; max order {d}; SCE {d} CPE {d} LFE {d} DSE {d} FIL {d}\n", .{ cov[0], cov[1], cov[2], cov[3], cov[4], max_order, elems[0], elems[1], elems[3], elems[4], elems[6] });
    try cwd.writeFile(io, .{ .sub_path = args[2], .data = raw.items });
    if (dump_path) |path| try cwd.writeFile(io, .{ .sub_path = path, .data = try dump.finish(gpa, cfg) });
    std.debug.print("{s}: {d} packets, {d} failed, {d} ch, {d} bit, {d} Hz, frame {d}, {d} samples\n", .{ args[1], frames, failed, nch, cfg.bit_depth, cfg.sample_rate, cfg.frame_length, raw.items.len / width / nch });
}

/// "ALPK", frame_length, bit_depth, pb, mb, kb, channels, packet count; then per packet:
/// length, bytes, samples per channel, samples * channels i32 PCM. All little-endian.
const Dump = struct {
    body: std.ArrayList(u8) = .empty,
    count: u32 = 0,
    out: std.ArrayList(u8) = .empty,

    fn put(list: *std.ArrayList(u8), gpa: std.mem.Allocator, v: u32) !void {
        var b: [4]u8 = undefined;
        std.mem.writeInt(u32, &b, v, .little);
        try list.appendSlice(gpa, &b);
    }

    fn add(self: *Dump, gpa: std.mem.Allocator, pkt: []const u8, pcm: []const i32, n: usize) !void {
        try put(&self.body, gpa, @intCast(pkt.len));
        try self.body.appendSlice(gpa, pkt);
        try put(&self.body, gpa, @intCast(n));
        for (pcm) |s| try put(&self.body, gpa, @bitCast(s));
        self.count += 1;
    }

    fn finish(self: *Dump, gpa: std.mem.Allocator, cfg: ref.alac.config.Config) ![]const u8 {
        try self.out.appendSlice(gpa, "ALPK");
        for ([_]u32{ cfg.frame_length, cfg.bit_depth, cfg.pb, cfg.mb, cfg.kb, cfg.channels, self.count }) |v| try put(&self.out, gpa, v);
        try self.out.appendSlice(gpa, self.body.items);
        return self.out.items;
    }

    fn deinit(self: *Dump, gpa: std.mem.Allocator) void {
        self.body.deinit(gpa);
        self.out.deinit(gpa);
    }
};

fn getBits(b: []const u8, at: usize, n: u5) u32 {
    var v: u32 = 0;
    for (0..n) |i| v = v << 1 | (b[(at + i) / 8] >> @intCast(7 - (at + i) % 8)) & 1;
    return v;
}

fn setBits(b: []u8, at: usize, n: u5, v: u32) void {
    for (0..n) |i| {
        const bit: u8 = @intCast(v >> @intCast(n - 1 - i) & 1);
        const sh: u3 = @intCast(7 - (at + i) % 8);
        b[(at + i) / 8] = b[(at + i) / 8] & ~(@as(u8, 1) << sh) | bit << sh;
    }
}

/// Mode 1 in the sub-frame headers of a leading SCE or CPE that is neither partial nor
/// escaped: the headers start at bit 39 (tag, instance, 12 bits, flags, mix fields).
fn setModes(pkt: []u8) void {
    const tag = getBits(pkt, 0, 3);
    if (tag > 1 or getBits(pkt, 19, 1) != 0 or getBits(pkt, 22, 1) != 0) return;
    setBits(pkt, 39, 4, 1);
    if (tag == 1) setBits(pkt, 39 + 16 + 16 * @as(usize, getBits(pkt, 50, 5)), 4, 1);
}
