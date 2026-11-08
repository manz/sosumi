//! The ALAC track of an MP4 (ISO/IEC 14496-12 boxes): its magic cookie and its packets, in
//! order, from stsz, stsc and stco or co64.
const std = @import("std");

pub const Error = error{ NoAlacTrack, BadBox };

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

pub const Track = struct {
    cookie: []const u8,
    sizes: []const u8, // stsz entries
    uniform: u32,
    count: u32,
    stsc: []const u8,
    chunks: []const u8,
    co64: bool,
};

pub fn findTrack(file: []const u8) Error!Track {
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

/// The track's packets in order: stsc runs give the samples per chunk from first_chunk on.
pub const Packets = struct {
    file: []u8,
    t: Track,
    chunk: usize = 0,
    in_chunk: u32 = 0,
    run: usize = 0,
    off: usize = 0,
    sample: u32 = 0,

    pub fn init(file: []u8) Error!Packets {
        return .{ .file = file, .t = try findTrack(file) };
    }

    fn chunkCount(self: *const Packets) usize {
        return if (self.t.co64) self.t.chunks.len / 8 else self.t.chunks.len / 4;
    }

    fn chunkOffset(self: *const Packets, c: usize) usize {
        if (self.t.co64) return @intCast(std.mem.readInt(u64, self.t.chunks[c * 8 ..][0..8], .big));
        return be32(self.t.chunks, c * 4);
    }

    /// The next packet, or null after the last. Its bytes are the file's, writable.
    pub fn next(self: *Packets) Error!?[]u8 {
        const t = &self.t;
        while (true) {
            if (self.sample >= t.count or self.chunk >= self.chunkCount()) return null;
            while (self.run + 1 < t.stsc.len / 12 and self.chunk + 1 >= be32(t.stsc, (self.run + 1) * 12)) self.run += 1;
            const per = be32(t.stsc, self.run * 12 + 4);
            if (self.in_chunk == 0) self.off = self.chunkOffset(self.chunk);
            if (self.in_chunk >= per) {
                self.chunk += 1;
                self.in_chunk = 0;
                continue;
            }
            const len: usize = if (t.uniform != 0) t.uniform else be32(t.sizes, self.sample * 4);
            if (self.off + len > self.file.len) return error.BadBox;
            const pkt = self.file[self.off .. self.off + len];
            self.off += len;
            self.in_chunk += 1;
            self.sample += 1;
            return pkt;
        }
    }
};
