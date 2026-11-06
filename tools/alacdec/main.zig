//! Decodes the ALAC track of an .m4a with the reference model to raw little-endian PCM at the
//! stream's depth (16 -> 2 bytes, 20/24 -> 3, 32 -> 4), for a byte-exact `cmp` against
//! afconvert's and ffmpeg's output.
//!
//!     alacdec in.m4a out.raw [--dsp] [--dump=pkts.bin]
//!
//! --dump writes the config, the first and the last packet and their PCM (little-endian u32
//! fields; see `Dump`) for x17's packet-level test of the sm1 decoder.
const std = @import("std");
const ref = @import("ref");

const Error = error{ NoAlacTrack, BadBox };

fn be32(b: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, b[at..][0..4], .big);
}

/// The payload of the first box named `name` among the boxes in `b`.
fn child(b: []const u8, name: []const u8) ?[]const u8 {
    var p: usize = 0;
    while (p + 8 <= b.len) {
        var size: usize = be32(b, p);
        var hdr: usize = 8;
        if (size == 1) {
            size = @intCast(std.mem.readInt(u64, b[p + 8 ..][0..8], .big));
            hdr = 16;
        } else if (size == 0) size = b.len - p;
        if (size < hdr or p + size > b.len) return null;
        if (std.mem.eql(u8, b[p + 4 .. p + 8], name)) return b[p + hdr .. p + size];
        p += size;
    }
    return null;
}

const Track = struct {
    cookie: []const u8,
    sizes: []const u8, // stsz entries
    uniform: u32,
    count: u32,
    stsc: []const u8,
    chunks: []const u8,
    co64: bool,
};

fn findTrack(file: []const u8) Error!Track {
    const moov = child(file, "moov") orelse return error.NoAlacTrack;
    var p: usize = 0;
    while (p + 8 <= moov.len) {
        const size = be32(moov, p);
        if (size < 8 or p + size > moov.len) return error.BadBox;
        defer p += size;
        if (!std.mem.eql(u8, moov[p + 4 .. p + 8], "trak")) continue;
        const trak = moov[p + 8 .. p + size];
        const mdia = child(trak, "mdia") orelse continue;
        const minf = child(mdia, "minf") orelse continue;
        const stbl = child(minf, "stbl") orelse continue;
        const stsd = child(stbl, "stsd") orelse continue;
        // version/flags, count, then the sample entry: size, 'alac', 28 bytes of audio fields,
        // then its 'alac' config box
        if (stsd.len < 44 or !std.mem.eql(u8, stsd[12..16], "alac")) continue;
        const stsz = child(stbl, "stsz") orelse return error.BadBox;
        const stsc = child(stbl, "stsc") orelse return error.BadBox;
        const co64 = child(stbl, "co64");
        const stco = co64 orelse child(stbl, "stco") orelse return error.BadBox;
        return .{
            .cookie = stsd[44..],
            .uniform = be32(stsz, 4),
            .count = be32(stsz, 8),
            .sizes = stsz[12..],
            .stsc = stsc[8 .. 8 + 12 * be32(stsc, 4)],
            .chunks = stco[8..],
            .co64 = co64 != null,
        };
    }
    return error.NoAlacTrack;
}

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
    const t = try findTrack(file);
    const cfg = try ref.alac.config.parse(t.cookie);
    var dec = try ref.alac.decoder.Decoder.init(gpa, cfg);
    defer dec.deinit();
    // --dsp: the whole decoder in measured sm1 operations (ref/dsp/alac)
    var use_dsp = false;
    var dump_path: ?[]const u8 = null;
    for (args[3..]) |a| {
        if (std.mem.eql(u8, a, "--dsp")) use_dsp = true;
        if (std.mem.startsWith(u8, a, "--dump=")) dump_path = a["--dump=".len..];
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

    // walk chunks: stsc runs give samples per chunk from first_chunk on
    var sample: u32 = 0;
    var failed: usize = 0;
    var frames: usize = 0;
    const n_chunks = if (t.co64) t.chunks.len / 8 else t.chunks.len / 4;
    var run: usize = 0;
    var cov: [5]usize = @splat(0);
    var max_order: u5 = 0;
    var elems: [8]usize = @splat(0);
    for (0..n_chunks) |c| {
        while (run + 1 < t.stsc.len / 12 and c + 1 >= be32(t.stsc, (run + 1) * 12)) run += 1;
        const per = be32(t.stsc, run * 12 + 4);
        var off: usize = if (t.co64) @intCast(std.mem.readInt(u64, t.chunks[c * 8 ..][0..8], .big)) else be32(t.chunks, c * 4);
        for (0..per) |_| {
            if (sample >= t.count) break;
            const len: usize = if (t.uniform != 0) t.uniform else be32(t.sizes, sample * 4);
            const pkt = file[off .. off + len];
            const res = if (use_dsp) ddec.decode(pkt, pcm) else dec.decode(pkt, pcm);
            const n = res catch |e| blk: {
                if (failed < 5) std.debug.print("packet {d}: {s}\n", .{ sample, @errorName(e) });
                failed += 1;
                break :blk 0;
            };
            if (dump_path != null and (sample == 0 or sample + 1 == t.count)) try dump.add(gpa, pkt, pcm[0 .. n * nch], n);
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
            off += len;
            sample += 1;
            frames += 1;
        }
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
