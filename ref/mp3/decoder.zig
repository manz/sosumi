//! Layer III decoder, as the device drives one: one whole frame per call, padding included
//! (specs/mp3.md). The decoder owns the bit reservoir.
const std = @import("std");
const bits = @import("../bits.zig");
const header = @import("header.zig");
const sideinfo = @import("sideinfo.zig");
const bands = @import("bands.zig");
const scalefactors = @import("scalefactors.zig");
const spectrum = @import("spectrum.zig");
const requant = @import("requant.zig");
const stereo = @import("stereo.zig");
const hybrid = @import("hybrid.zig");
const synth = @import("synth.zig");

pub const Error = header.Error || sideinfo.Error || spectrum.Error || error{OutputTooSmall};

/// Main data kept from earlier frames. main_data_begin reaches back at most 511 bytes.
const reservoir_cap = 512;
const max_frame = 2881; // MPEG-1 320 kbps at 32 kHz, padded

pub const Frame = struct {
    header: header.Header,
    /// False when main_data_begin reached past the reservoir (stream start, after a seek): the
    /// frame's PCM is silence and the filterbanks are untouched.
    decoded: bool,

    pub fn samples(f: Frame) usize {
        return @as(usize, f.header.samples()) * f.header.channels();
    }
};

/// Which tools the last frame used. Diagnostics only.
pub const ToolStats = struct {
    short: bool = false,
    mixed: bool = false,
    ms: bool = false,
    intensity: bool = false,
    scfsi: bool = false,
    preflag: bool = false,
    scalefac_scale: bool = false,
};

pub const Decoder = struct {
    last: ToolStats = .{},
    reservoir: [reservoir_cap]u8 = undefined,
    res_len: usize = 0,
    hybrid: [2]hybrid.State = .{ .{}, .{} },
    synth: [2]synth.State = .{ .{}, .{} },

    fn keep(self: *Decoder, main: []const u8) void {
        if (main.len >= reservoir_cap) {
            @memcpy(&self.reservoir, main[main.len - reservoir_cap ..]);
            self.res_len = reservoir_cap;
            return;
        }
        const total = self.res_len + main.len;
        if (total > reservoir_cap) {
            const drop = total - reservoir_cap;
            std.mem.copyForwards(u8, self.reservoir[0 .. self.res_len - drop], self.reservoir[drop..self.res_len]);
            self.res_len -= drop;
        }
        @memcpy(self.reservoir[self.res_len .. self.res_len + main.len], main);
        self.res_len += main.len;
    }

    /// Decodes one frame into interleaved PCM: samples() values.
    pub fn decode(self: *Decoder, frame: []const u8, out: []i16) Error!Frame {
        const h = try header.parse(frame);
        const nch = h.channels();
        const n = @as(usize, h.samples()) * nch;
        if (out.len < n) return error.OutputTooSmall;
        const off = h.mainDataOffset();
        if (frame.len < off) return error.Truncated;
        var r = bits.BitReader.init(frame[4 + @as(usize, if (h.crc) 2 else 0) .. off]);
        const si = try sideinfo.read(&r, h);
        const main = frame[off..@min(frame.len, max_frame)];
        const mdb: usize = si.main_data_begin;
        if (mdb > self.res_len) {
            self.keep(main);
            @memset(out[0..n], 0);
            return .{ .header = h, .decoded = false };
        }
        var buf: [reservoir_cap + max_frame]u8 = undefined;
        @memcpy(buf[0..mdb], self.reservoir[self.res_len - mdb .. self.res_len]);
        @memcpy(buf[mdb .. mdb + main.len], main);
        self.keep(main);

        self.last = .{ .ms = h.msStereo(), .intensity = h.intensityStereo() };
        for (0..h.granules()) |gr| for (0..nch) |ch| {
            const g = si.gr[gr][ch];
            self.last.short = self.last.short or g.isShort();
            self.last.mixed = self.last.mixed or (g.isShort() and g.mixed);
            self.last.preflag = self.last.preflag or g.preflag;
            self.last.scalefac_scale = self.last.scalefac_scale or g.scalefac_scale;
            self.last.scfsi = self.last.scfsi or (gr == 1 and si.scfsi[ch] != 0);
        };
        var md = bits.BitReader.init(buf[0 .. mdb + main.len]);
        var prev: [2][scalefactors.max_entries]u8 = @splat(@splat(0));
        for (0..h.granules()) |gr| {
            var coefs: [2]requant.Coefs = undefined;
            var sfs: [2]scalefactors.Scalefactors = undefined;
            for (0..nch) |ch| {
                const g = si.gr[gr][ch];
                const limit = md.pos + g.part2_3_length;
                const use_scfsi: u4 = if (gr == 1) si.scfsi[ch] else 0;
                sfs[ch] = try scalefactors.read(&md, h, g, ch, use_scfsi, &prev[ch]);
                const is = try spectrum.read(&md, g, bands.of(h, g), limit);
                coefs[ch] = requant.requantise(g, bands.of(h, g), &sfs[ch], &is);
            }
            if (nch == 2) stereo.process(h, si.gr[gr][0], si.gr[gr][1], &sfs[1], &coefs[0], &coefs[1]);
            for (0..nch) |ch| {
                const g = si.gr[gr][ch];
                hybrid.run(&self.hybrid[ch], g, bands.of(h, g), bands.mixedLongSubbands(h), &coefs[ch]);
                for (0..18) |t| {
                    var s: [32]@TypeOf(coefs[0][0]) = undefined;
                    for (0..32) |sb| s[sb] = coefs[ch][sb * 18 + t];
                    var pcm: [32]i16 = undefined;
                    synth.slot(&self.synth[ch], &s, &pcm);
                    for (pcm, 0..) |v, j| out[(gr * 576 + t * 32 + j) * nch + ch] = v;
                }
            }
        }
        return .{ .header = h, .decoded = true };
    }
};

const testing = std.testing;

test "a frame whose main data reaches into an empty reservoir decodes to silence" {
    var frame: [417]u8 = @splat(0);
    frame[0] = 0xFF;
    frame[1] = 0xFB;
    frame[2] = 0x90;
    frame[3] = 0x64;
    frame[4] = 0x80; // main_data_begin 256
    var d: Decoder = .{};
    var out: [2304]i16 = @splat(7);
    const f = try d.decode(&frame, &out);
    try testing.expect(!f.decoded);
    try testing.expectEqual(@as(i16, 0), out[1000]);
    try testing.expectEqual(@as(usize, 417 - 36), d.res_len);
}

test "an all-zero frame decodes to silence" {
    var frame: [417]u8 = @splat(0);
    frame[0] = 0xFF;
    frame[1] = 0xFB;
    frame[2] = 0x90;
    frame[3] = 0x64;
    var d: Decoder = .{};
    var out: [2304]i16 = @splat(7);
    const f = try d.decode(&frame, &out);
    try testing.expect(f.decoded);
    for (out) |v| try testing.expectEqual(@as(i16, 0), v);
}
