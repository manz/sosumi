//! The ALAC or AAC track of an MP4 (ISO/IEC 14496-12 boxes): its configuration and its packets,
//! in order, from stsz, stsc and stco or co64. For AAC the configuration is the
//! AudioSpecificConfig from the esds box's DecoderSpecificInfo (ISO/IEC 14496-1 7.2.6, 14496-14).
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

pub const Codec = enum { alac, aac };

pub const Track = struct {
    codec: Codec = .alac,
    /// ALAC's magic cookie, or AAC's AudioSpecificConfig.
    cookie: []const u8,
    sizes: []const u8, // stsz entries
    uniform: u32,
    count: u32,
    stsc: []const u8,
    chunks: []const u8,
    co64: bool,
};

/// An expandable descriptor's tag and payload at `b[p..]` (ISO/IEC 14496-1 8.3.3).
fn descriptor(b: []const u8, p: usize) ?struct { tag: u8, body: []const u8, end: usize } {
    if (p >= b.len) return null;
    var q = p + 1;
    var len: usize = 0;
    for (0..4) |_| {
        if (q >= b.len) return null;
        len = len << 7 | (b[q] & 0x7F);
        q += 1;
        if (b[q - 1] & 0x80 == 0) break;
    }
    if (q + len > b.len) return null;
    return .{ .tag = b[p], .body = b[q .. q + len], .end = q + len };
}

/// The DecoderSpecificInfo inside an esds payload: ES_Descriptor (3), DecoderConfigDescriptor
/// (4, 13 fixed bytes), DecoderSpecificInfo (5) (ISO/IEC 14496-1 7.2.6.5, 7.2.6.6).
fn esdsConfig(esds: []const u8) ?[]const u8 {
    if (esds.len < 4) return null;
    const es = descriptor(esds, 4) orelse return null;
    if (es.tag != 3 or es.body.len < 3) return null;
    const flags = es.body[2];
    var p: usize = 3;
    if (flags & 0x80 != 0) p += 2; // dependsOn_ES_ID
    if (flags & 0x40 != 0) {
        if (p >= es.body.len) return null;
        p += 1 + es.body[p]; // URL
    }
    if (flags & 0x20 != 0) p += 2; // OCR_ES_Id
    while (descriptor(es.body, p)) |d| : (p = d.end) {
        if (d.tag != 4 or d.body.len < 13) continue;
        var q: usize = 13;
        while (descriptor(d.body, q)) |e| : (q = e.end) if (e.tag == 5) return e.body;
    }
    return null;
}

/// The mp4a sample entry's esds config: the entry's 8-byte header, 8 bytes of SampleEntry, the
/// audio fields (20 bytes; QuickTime sound versions 1 and 2 add 16 and 36), then its boxes.
fn mp4aConfig(entry: []const u8) ?[]const u8 {
    if (entry.len < 36) return null;
    const version = std.mem.readInt(u16, entry[16..18], .big);
    const at: usize = switch (version) {
        0 => 36,
        1 => 52,
        2 => 72,
        else => return null,
    };
    if (entry.len < at) return null;
    return esdsConfig(child(entry[at..], "esds") orelse return null);
}

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
        if (stsd.len < 44) continue;
        const entry = stsd[8..@min(stsd.len, 8 + be32(stsd, 8))];
        const codec: Codec = if (std.mem.eql(u8, stsd[12..16], "alac")) .alac else if (std.mem.eql(u8, stsd[12..16], "mp4a")) .aac else continue;
        const cookie = if (codec == .alac) stsd[44..] else mp4aConfig(entry) orelse continue;
        const stsz = child(stbl, "stsz") orelse return error.BadBox;
        const stsc = child(stbl, "stsc") orelse return error.BadBox;
        const co64 = child(stbl, "co64");
        const stco = co64 orelse child(stbl, "stco") orelse return error.BadBox;
        return .{
            .codec = codec,
            .cookie = cookie,
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
