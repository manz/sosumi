//! ALAC packet decoder, following Apple's ALACDecoder::Decode (ALACDecoder.cpp, Apache 2.0):
//! elements (SCE, CPE, LFE, DSE, FIL) up to END or until every channel is filled. Output is
//! interleaved signed samples, right-aligned at the configured depth.
const std = @import("std");
const bits = @import("../bits.zig");
const config = @import("config.zig");
const rice = @import("rice.zig");
const predictor = @import("predictor.zig");
const dsp = @import("../dsp/alac.zig");

pub const Error = bits.Error || rice.Error || error{
    InvalidHeader,
    TooManySamples,
    UnsupportedElement,
    UnsupportedWidth,
    OutputTooSmall,
    /// `dsp_predictor` is set and the stream's widths are outside the DSP model.
    Unsupported,
};

const Tag = enum(u3) { sce = 0, cpe = 1, cce = 2, lfe = 3, dse = 4, pce = 5, fil = 6, end = 7 };

const Sub = struct {
    mode: u4,
    den_shift: u4,
    pb_factor: u3,
    coefs: [31]i16,
    order: u5,

    fn read(r: *bits.BitReader) Error!Sub {
        var s: Sub = undefined;
        s.mode = @intCast(try r.read(4));
        s.den_shift = @intCast(try r.read(4));
        s.pb_factor = @intCast(try r.read(3));
        s.order = @intCast(try r.read(5));
        for (s.coefs[0..s.order]) |*c| c.* = @bitCast(@as(u16, @intCast(try r.read(16))));
        return s;
    }
};

/// Which paths the last packet took. Diagnostics only.
pub const Stats = struct {
    verbatim: bool = false,
    shifted: bool = false,
    matrixed: bool = false,
    partial: bool = false,
    integrated: bool = false,
    max_order: u5 = 0,
    elements: [8]u8 = @splat(0),
};

pub const Decoder = struct {
    last: Stats = .{},
    /// Run the predictor in measured sm1 operations (ref/dsp/alac.zig) instead of i32.
    dsp_predictor: bool = false,
    cfg: config.Config,
    gpa: std.mem.Allocator,
    pred: []i32,
    mix: [2][]i32,
    shift: []u16,

    pub fn init(gpa: std.mem.Allocator, cfg: config.Config) !Decoder {
        const n = cfg.frame_length;
        const pred = try gpa.alloc(i32, n);
        errdefer gpa.free(pred);
        const u = try gpa.alloc(i32, n);
        errdefer gpa.free(u);
        const v = try gpa.alloc(i32, n);
        errdefer gpa.free(v);
        const shift = try gpa.alloc(u16, 2 * n);
        return .{ .cfg = cfg, .gpa = gpa, .pred = pred, .mix = .{ u, v }, .shift = shift };
    }

    pub fn deinit(self: *Decoder) void {
        self.gpa.free(self.pred);
        self.gpa.free(self.mix[0]);
        self.gpa.free(self.mix[1]);
        self.gpa.free(self.shift);
    }

    /// Residuals through the predictor into `dst`. Mode non-zero integrates first.
    fn channel(self: *Decoder, r: *bits.BitReader, s: Sub, n: usize, chan_bits: u6, dst: []i32) Error!void {
        const p: rice.Params = .{
            .mb = self.cfg.mb,
            .pb = (@as(u32, self.cfg.pb) * s.pb_factor) / 4,
            .kb = self.cfg.kb,
        };
        try rice.decompress(r, self.pred[0..n], p, chan_bits);
        self.last.max_order = @max(self.last.max_order, s.order);
        self.last.integrated = self.last.integrated or s.mode != 0;
        var coefs = s.coefs;
        if (self.dsp_predictor) {
            if (s.mode != 0) try dsp.integrate(self.pred[0..n], chan_bits);
            try dsp.unpredict(self.pred[0..n], dst[0..n], coefs[0..s.order], chan_bits, s.den_shift);
            return;
        }
        if (s.mode != 0) predictor.integrate(self.pred[0..n], chan_bits);
        predictor.unpredict(self.pred[0..n], dst[0..n], coefs[0..s.order], chan_bits, s.den_shift);
    }

    /// Uncompressed samples: `width` bits each, the high 16 first above 16.
    fn verbatim(r: *bits.BitReader, width: u6) Error!i32 {
        if (width <= 16) {
            const s: u5 = @intCast(32 - @as(u32, width));
            const v: u32 = try r.read(width);
            return @as(i32, @bitCast(v << s)) >> s;
        }
        const s: u5 = @intCast(32 - @as(u32, width));
        const hi: u32 = try r.read(16);
        const lo = try r.read(width - 16);
        return (@as(i32, @bitCast(hi << 16)) >> s) | @as(i32, @bitCast(lo));
    }

    /// One SCE/LFE (pair = false) or CPE. Writes channels `ch`, `ch + 1` of `out`.
    fn element(self: *Decoder, r: *bits.BitReader, pair: bool, num_samples: *usize, ch: usize, out: []i32) Error!void {
        const nch: usize = self.cfg.channels;
        const depth: u32 = self.cfg.bit_depth;
        _ = try r.read(4); // element instance tag
        if (try r.read(12) != 0) return error.InvalidHeader;
        const partial = try r.readFlag();
        const bytes_shifted: u32 = try r.read(2);
        if (bytes_shifted == 3) return error.InvalidHeader;
        const escape = try r.readFlag();
        if (partial) {
            const n = try r.read(32);
            if (n > self.cfg.frame_length) return error.TooManySamples;
            num_samples.* = n;
        }
        const n = num_samples.*;
        self.last.partial = self.last.partial or partial;
        self.last.verbatim = self.last.verbatim or escape;
        self.last.shifted = self.last.shifted or (bytes_shifted != 0 and !escape);
        const lanes: usize = if (pair) 2 else 1;
        var mix_bits: u8 = 0;
        var mix_res: i8 = 0;
        var shifted: u32 = 0;
        if (!escape) {
            const cb = depth - bytes_shifted * 8 + @intFromBool(pair);
            if (cb > 32) return error.UnsupportedWidth;
            const chan_bits: u6 = @intCast(cb);
            if (pair) {
                mix_bits = @intCast(try r.read(8));
                mix_res = @bitCast(@as(u8, @intCast(try r.read(8))));
            } else {
                _ = try r.read(16); // mixBits, mixRes: unused in a single channel
            }
            var subs: [2]Sub = undefined;
            for (0..lanes) |l| subs[l] = try Sub.read(r);
            var shift_reader = r.*;
            if (bytes_shifted != 0) try r.skip(bytes_shifted * 8 * lanes * n);
            for (0..lanes) |l| try self.channel(r, subs[l], n, chan_bits, self.mix[l]);
            if (bytes_shifted != 0) {
                shifted = bytes_shifted * 8;
                for (0..n * lanes) |i| self.shift[i] = @intCast(try shift_reader.read(@intCast(shifted)));
            }
        } else {
            const width: u6 = @intCast(depth);
            for (0..n) |i| for (0..lanes) |l| {
                self.mix[l][i] = try verbatim(r, width);
            };
        }
        // stereo unmixing, low bytes back on, then the depth's wrap (the reference's casts)
        const out_shift: u5 = @intCast(32 - depth);
        for (0..n) |i| {
            var s: [2]i32 = undefined;
            if (pair and mix_res != 0) {
                self.last.matrixed = true;
                const u = self.mix[0][i];
                const v = self.mix[1][i];
                const mb: u5 = @intCast(@min(mix_bits, 31));
                s[0] = u +% v -% ((@as(i32, mix_res) *% v) >> mb);
                s[1] = s[0] -% v;
            } else {
                for (0..lanes) |l| s[l] = self.mix[l][i];
            }
            for (0..lanes) |l| {
                var x = s[l];
                if (shifted != 0) {
                    const ux: u32 = @bitCast(x);
                    x = @bitCast((ux << @intCast(shifted)) | self.shift[i * lanes + l]);
                }
                const ux: u32 = @bitCast(x);
                out[i * nch + ch + l] = @as(i32, @bitCast(ux << out_shift)) >> out_shift;
            }
        }
    }

    /// Decodes one packet into `out` (frame_length * channels). Returns samples per channel.
    pub fn decode(self: *Decoder, packet: []const u8, out: []i32) Error!usize {
        const nch: usize = self.cfg.channels;
        if (out.len < @as(usize, self.cfg.frame_length) * nch) return error.OutputTooSmall;
        var r = bits.BitReader.init(packet);
        var num_samples: usize = self.cfg.frame_length;
        var ch: usize = 0;
        self.last = .{};
        while (ch < nch) {
            if (r.bitsLeft() < 3) return error.EndOfStream;
            const tag: Tag = @fromBackingInt(@intCast(try r.read(3)));
            self.last.elements[@backingInt(tag)] +|= 1;
            switch (tag) {
                .sce, .lfe => {
                    try self.element(&r, false, &num_samples, ch, out);
                    ch += 1;
                },
                .cpe => {
                    if (ch + 2 > nch) break;
                    try self.element(&r, true, &num_samples, ch, out);
                    ch += 2;
                },
                .cce, .pce => return error.UnsupportedElement,
                .dse => {
                    _ = try r.read(4);
                    const aligned = try r.readFlag();
                    var count: usize = try r.read(8);
                    if (count == 255) count += try r.read(8);
                    if (aligned) r.byteAlign();
                    try r.skip(count * 8);
                },
                .fil => {
                    var count: usize = try r.read(4);
                    if (count == 15) count += @as(usize, try r.read(8)) - 1;
                    try r.skip(count * 8);
                },
                .end => break,
            }
        }
        // channels no element filled are silent
        while (ch < nch) : (ch += 1) {
            for (0..num_samples) |i| out[i * nch + ch] = 0;
        }
        return num_samples;
    }
};

const testing = std.testing;

test "an escaped (uncompressed) mono 16-bit packet returns its samples" {
    const cfg: config.Config = .{ .frame_length = 2, .compatible_version = 0, .bit_depth = 16, .pb = 40, .mb = 10, .kb = 14, .channels = 1, .max_run = 255, .max_frame_bytes = 0, .avg_bit_rate = 0, .sample_rate = 44100 };
    var d = try Decoder.init(testing.allocator, cfg);
    defer d.deinit();
    // SCE 000, tag 0000, 12 zero bits, partial 0, shift 00, escape 1; samples 0x1234, 0xFFFE; END 111
    var w: u64 = 0;
    var nbits: u6 = 0;
    const fields = [_][2]u32{ .{ 3, 0 }, .{ 4, 0 }, .{ 12, 0 }, .{ 1, 0 }, .{ 2, 0 }, .{ 1, 1 }, .{ 16, 0x1234 }, .{ 16, 0xFFFE }, .{ 3, 7 } };
    for (fields) |f| {
        w = (w << @intCast(f[0])) | f[1];
        nbits += @intCast(f[0]);
    }
    w <<= @intCast(64 - @as(u32, nbits));
    var pkt: [8]u8 = undefined;
    std.mem.writeInt(u64, &pkt, w, .big);
    var out: [2]i32 = undefined;
    try testing.expectEqual(@as(usize, 2), try d.decode(&pkt, &out));
    try testing.expectEqualSlices(i32, &.{ 0x1234, -2 }, &out);
}
