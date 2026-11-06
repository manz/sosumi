//! ALAC packet decoder in measured sm1 operations: ref/alac/decoder.zig's structure, with the
//! bit reader, Rice decoder, predictor, stereo unmix and low-byte merge on 24-bit words.
//!
//! Every output sample is wrapped to the stream's depth at the end, so arithmetic modulo 2^24
//! is enough everywhere before it (depth <= 24). The unmix product is exact (`ops.mulWide`)
//! and its shift is taken from the two halves. Supported: depth <= 24 and the widths
//! `predictor.supported` and `rice.supported` accept; the rest returns `error.Unsupported`.
const std = @import("std");
const ops = @import("../ops.zig");
const bits = @import("../bits.zig");
const rice = @import("rice.zig");
const predictor = @import("predictor.zig");
const config = @import("../../alac/config.zig");
const ref = @import("../../alac/decoder.zig");

const Word = ops.Word;

pub const Error = ref.Error || rice.Error || predictor.Error;
pub const Stats = ref.Stats;

const Sub = struct {
    mode: u4,
    den_shift: u4,
    pb_factor: u3,
    coefs: [31]i16,
    order: u5,

    fn read(r: *bits.Reader) Error!Sub {
        var s: Sub = undefined;
        s.mode = @intCast(try r.read(4));
        s.den_shift = @intCast(try r.read(4));
        s.pb_factor = @intCast(try r.read(3));
        s.order = @intCast(try r.read(5));
        for (s.coefs[0..s.order]) |*c| c.* = @intCast(ops.signExtend(try r.read(16), 16));
        return s;
    }
};

pub const Decoder = struct {
    last: Stats = .{},
    cfg: config.Config,
    gpa: std.mem.Allocator,
    pred: []i32,
    mix: [2][]i32,
    shift: []Word,

    pub fn init(gpa: std.mem.Allocator, cfg: config.Config) !Decoder {
        const n = cfg.frame_length;
        const pred = try gpa.alloc(i32, n);
        errdefer gpa.free(pred);
        const u = try gpa.alloc(i32, n);
        errdefer gpa.free(u);
        const v = try gpa.alloc(i32, n);
        errdefer gpa.free(v);
        const shift = try gpa.alloc(Word, 2 * n);
        return .{ .cfg = cfg, .gpa = gpa, .pred = pred, .mix = .{ u, v }, .shift = shift };
    }

    pub fn deinit(self: *Decoder) void {
        self.gpa.free(self.pred);
        self.gpa.free(self.mix[0]);
        self.gpa.free(self.mix[1]);
        self.gpa.free(self.shift);
    }

    fn channel(self: *Decoder, r: *bits.Reader, s: Sub, n: usize, chan_bits: u6, dst: []i32) Error!void {
        // pb * pb_factor / 4
        const pb = ops.floorShr(ops.wideValue(ops.mulWide(self.cfg.pb, s.pb_factor)), 2);
        const p: rice.Params = .{ .mb = self.cfg.mb, .pb = @intCast(pb), .kb = self.cfg.kb };
        try rice.decompress(r, self.pred[0..n], p, chan_bits);
        self.last.max_order = @max(self.last.max_order, s.order);
        self.last.integrated = self.last.integrated or s.mode != 0;
        if (s.mode != 0) try predictor.integrate(self.pred[0..n], chan_bits);
        var coefs = s.coefs;
        try predictor.unpredict(self.pred[0..n], dst[0..n], coefs[0..s.order], chan_bits, s.den_shift);
    }

    /// Uncompressed samples: `width` (<= 24) bits each, the high 16 first above 16.
    fn verbatim(r: *bits.Reader, width: u5) Error!Word {
        if (width <= 16) return ops.signExtend(try r.read(width), width);
        const hi = try r.read(16);
        const lo = try r.read(width - 16);
        const up = ops.shl(hi, @intCast(width - 16));
        return ops.signExtend(ops.add(up, lo), width);
    }

    /// floor(a * v / 2^s) modulo 2^24, a 8-bit, s in 0..31.
    fn mulShr(a: i16, v: Word, s: u5) Word {
        const p = ops.mulWide(a, v);
        if (s <= 15) return ops.add(ops.shl(p.hi, @intCast(15 - @as(u5, s))), ops.floorShr(p.lo, s));
        return ops.floorShr(p.hi, s - 15); // |a * v| < 2^30: hi did not wrap
    }

    fn element(self: *Decoder, r: *bits.Reader, pair: bool, num_samples: *usize, ch: usize, out: []i32) Error!void {
        const nch: usize = self.cfg.channels;
        const depth: u32 = self.cfg.bit_depth;
        if (depth > 24) return error.Unsupported;
        _ = try r.read(4); // element instance tag
        if (!ops.isZero(try r.read(12))) return error.InvalidHeader;
        const partial = try r.readFlag();
        const bytes_shifted: u32 = @intCast(try r.read(2));
        if (bytes_shifted == 3) return error.InvalidHeader;
        const escape = try r.readFlag();
        if (partial) {
            const hi = try r.read(16);
            const lo = try r.read(16);
            if (!ops.isZero(hi) or @as(u32, @intCast(lo)) > self.cfg.frame_length) return error.TooManySamples;
            num_samples.* = @intCast(lo);
        }
        const n = num_samples.*;
        self.last.partial = self.last.partial or partial;
        self.last.verbatim = self.last.verbatim or escape;
        self.last.shifted = self.last.shifted or (bytes_shifted != 0 and !escape);
        const lanes: usize = if (pair) 2 else 1;
        var mix_bits: u5 = 0;
        var mix_res: i16 = 0;
        var shifted: u5 = 0;
        if (!escape) {
            const cb = depth - bytes_shifted * 8 + @intFromBool(pair);
            const chan_bits: u6 = @intCast(cb);
            if (pair) {
                mix_bits = @intCast(@min(try r.read(8), 31));
                mix_res = @intCast(ops.signExtend(try r.read(8), 8));
            } else {
                _ = try r.read(16); // mixBits, mixRes: unused in a single channel
            }
            var subs: [2]Sub = undefined;
            for (0..lanes) |l| subs[l] = try Sub.read(r);
            var shift_reader = r.*;
            if (bytes_shifted != 0) try r.skip(bytes_shifted * 8 * lanes * n);
            for (0..lanes) |l| try self.channel(r, subs[l], n, chan_bits, self.mix[l]);
            if (bytes_shifted != 0) {
                shifted = @intCast(bytes_shifted * 8);
                for (0..n * lanes) |i| self.shift[i] = try shift_reader.read(shifted);
            }
        } else {
            for (0..n) |i| for (0..lanes) |l| {
                self.mix[l][i] = try verbatim(r, @intCast(depth));
            };
        }
        // stereo unmixing, low bytes back on, then the depth's wrap
        for (0..n) |i| {
            var s: [2]Word = undefined;
            if (pair and mix_res != 0) {
                self.last.matrixed = true;
                const u: Word = @intCast(self.mix[0][i]);
                const v: Word = @intCast(self.mix[1][i]);
                s[0] = ops.sub(ops.add(u, v), mulShr(mix_res, v, mix_bits));
                s[1] = ops.sub(s[0], v);
            } else {
                for (0..lanes) |l| s[l] = @intCast(self.mix[l][i]);
            }
            for (0..lanes) |l| {
                var x = s[l];
                if (shifted != 0) {
                    const up = if (shifted > 15) ops.shl(ops.shl(x, 8), @intCast(shifted - 8)) else ops.shl(x, @intCast(shifted));
                    x = ops.add(up, self.shift[i * lanes + l]);
                }
                out[i * nch + ch + l] = ops.signExtend(x, @intCast(depth));
            }
        }
    }

    /// Decodes one packet into `out` (frame_length * channels). Returns samples per channel.
    pub fn decode(self: *Decoder, packet: []const u8, out: []i32) Error!usize {
        const nch: usize = self.cfg.channels;
        if (out.len < @as(usize, self.cfg.frame_length) * nch) return error.OutputTooSmall;
        var r = bits.Reader.init(packet);
        var num_samples: usize = self.cfg.frame_length;
        var ch: usize = 0;
        self.last = .{};
        while (ch < nch) {
            if (r.bitsLeft() < 3) return error.EndOfStream;
            const tag: u3 = @intCast(try r.read(3));
            self.last.elements[tag] +|= 1;
            switch (tag) {
                0, 3 => { // SCE, LFE
                    try self.element(&r, false, &num_samples, ch, out);
                    ch += 1;
                },
                1 => { // CPE
                    if (ch + 2 > nch) break;
                    try self.element(&r, true, &num_samples, ch, out);
                    ch += 2;
                },
                2, 5 => return error.UnsupportedElement, // CCE, PCE
                4 => { // DSE
                    _ = try r.read(4);
                    const aligned = try r.readFlag();
                    var count: usize = @intCast(try r.read(8));
                    if (count == 255) count += @intCast(try r.read(8));
                    if (aligned) r.byteAlign();
                    try r.skip(count * 8);
                },
                6 => { // FIL
                    var count: usize = @intCast(try r.read(4));
                    if (count == 15) count += @as(usize, @intCast(try r.read(8))) - 1;
                    try r.skip(count * 8);
                },
                7 => break, // END
            }
        }
        while (ch < nch) : (ch += 1) {
            for (0..num_samples) |i| out[i * nch + ch] = 0;
        }
        return num_samples;
    }
};

const testing = std.testing;

test "an escaped mono 16-bit packet returns its samples" {
    const cfg: config.Config = .{ .frame_length = 2, .compatible_version = 0, .bit_depth = 16, .pb = 40, .mb = 10, .kb = 14, .channels = 1, .max_run = 255, .max_frame_bytes = 0, .avg_bit_rate = 0, .sample_rate = 44100 };
    var d = try Decoder.init(testing.allocator, cfg);
    defer d.deinit();
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

test "the unmix shift matches 32-bit arithmetic modulo 2^24" {
    var prng = std.Random.DefaultPrng.init(3);
    const rnd = prng.random();
    for (0..100_000) |_| {
        const a = rnd.int(i8);
        const v = rnd.intRangeAtMost(Word, -(1 << 22), (1 << 22) - 1);
        const s = rnd.int(u5);
        const want: i32 = (@as(i32, a) *% v) >> s;
        try testing.expectEqual(@as(Word, @truncate(want)), Decoder.mulShr(a, v, s));
    }
}
