//! The AAC-LC decoder again, every stage after the bitstream in measured sm1 operations:
//! dequantisation, PNS, M/S and intensity, TNS, IMDCT, window and overlap. The parse is
//! `ref/aac`'s (its x17 twins are `sections.sm` and `huffman.sm`); what it hands on is integers.
const std = @import("std");
const ops = @import("../ops.zig");
const bits = @import("../../bits.zig");
const asc_mod = @import("../../aac/asc.zig");
const raw = @import("../../aac/raw.zig");
const ics = @import("../../aac/ics.zig");
const ref_dec = @import("../../aac/decoder.zig");
const sections = @import("sections.zig");
const dequant = @import("dequant.zig");
const pns = @import("pns.zig");
const stereo = @import("stereo.zig");
const tns = @import("tns.zig");
const imdct = @import("imdct.zig");
const window = @import("window.zig");

const Word = ops.Word;
const Block = dequant.Block;

pub const Error = ref_dec.Error;
pub const frame_len = ref_dec.frame_len;
pub const max_channels = ref_dec.max_channels;
pub const ToolStats = ref_dec.ToolStats;

/// The dequantised block of one channel: its pulses added, its spectral bands as words.
pub fn dequantise(ch: *const ics.Channel, offsets: []const u16) Block {
    var b: sections.Bands = .{};
    const s: dequant.Shape = .{ .short = ch.info.isShort(), .groups = ch.info.num_window_groups, .group_len = ch.info.group_len, .max_sfb = ch.info.max_sfb };
    b.n = @as(usize, s.groups) * s.max_sfb;
    for (0..s.groups) |g| for (0..s.max_sfb) |sfb| {
        b.book[g * s.max_sfb + sfb] = ch.sections.sfb_cb[g][sfb];
        b.sf[g * s.max_sfb + sfb] = ch.scalefactors[g][sfb];
    };
    var spec: [1024]Word = undefined;
    for (&spec, ch.spectrum) |*w, q| w.* = q;
    if (ch.pulse) |p| dequant.applyPulse(&spec, p, offsets);
    return dequant.dequantChannel(&spec, s, &b, offsets);
}

pub const Decoder = struct {
    config: asc_mod.Asc,
    channels: u2,
    banks: [max_channels]window.State = .{ .{}, .{} },
    rng: pns.Rng = .{},
    last: ToolStats = .{},
    tns_stats: tns.Stats = .{},

    pub fn init(config: []const u8) Error!Decoder {
        var r = bits.BitReader.init(config);
        const a = try asc_mod.parse(&r);
        if (a.channel_config > 2) return error.UnsupportedChannelConfig;
        return .{ .config = a, .channels = @intCast(a.channel_config) };
    }

    /// Decodes one access unit into interleaved 16-bit PCM: frame_len * channels samples.
    pub fn decode(self: *Decoder, au: []const u8, out: []i16) Error!void {
        std.debug.assert(out.len >= frame_len * @as(usize, self.channels));
        const fi = self.config.freq_index;
        var r = bits.BitReader.init(au);
        var slot: usize = 0;
        self.last = .{};
        while (true) {
            if (r.bitsLeft() < 3) return error.MissingEnd;
            const h = try raw.readHeader(&r);
            switch (h.id) {
                .end => return,
                .dse => try raw.skipDse(&r),
                .fil => try raw.skipFil(&r),
                .sce, .lfe => {
                    if (slot + 1 > self.channels) return error.TooManyChannels;
                    const ch = try ics.readChannel(&r, null, fi);
                    self.note(&ch, slot);
                    const offsets = ch.info.bandOffsets(fi);
                    var c = dequantise(&ch, offsets);
                    pns.channel(&ch, offsets, &c, &self.rng);
                    self.finish(&ch, &c, slot, out);
                    slot += 1;
                },
                .cpe => {
                    if (slot + 2 > self.channels) return error.TooManyChannels;
                    const pair = try ics.readChannelPair(&r, fi);
                    self.note(&pair.left, slot);
                    self.note(&pair.right, slot + 1);
                    self.last.common_window = pair.common_window;
                    if (pair.ms) |m| self.last.ms = m.present;
                    const lo = pair.left.info.bandOffsets(fi);
                    const ro = pair.right.info.bandOffsets(fi);
                    var l = dequantise(&pair.left, lo);
                    var rr = dequantise(&pair.right, ro);
                    pns.channel(&pair.left, lo, &l, &self.rng);
                    stereo.applyPair(&pair, &l, &rr, lo, ro);
                    pns.right(&pair, &l, ro, &rr, &self.rng);
                    self.finish(&pair.left, &l, slot, out);
                    self.finish(&pair.right, &rr, slot + 1, out);
                    slot += 2;
                },
                .cce, .pce => return error.ElementNotImplemented,
            }
        }
    }

    fn note(self: *Decoder, ch: *const ics.Channel, slot: usize) void {
        self.last.window[slot] = ch.info.window_sequence;
        self.last.tns[slot] = ch.tns != null;
        self.last.pulse[slot] = ch.pulse != null;
        for (0..ch.info.num_window_groups) |g| for (0..ch.info.max_sfb) |sfb| {
            const cb = ch.sections.sfb_cb[g][sfb];
            self.last.pns = self.last.pns or cb == ics.noise_hcb;
            self.last.intensity = self.last.intensity or cb == ics.intensity_hcb or cb == ics.intensity_hcb2;
        };
    }

    fn finish(self: *Decoder, ch: *const ics.Channel, c: *Block, slot: usize, out: []i16) void {
        if (ch.tns) |*t| {
            const st = tns.apply(t, ch.info, self.config.freq_index, c);
            self.tns_stats.halvings += st.halvings;
            self.tns_stats.gave_up += st.gave_up;
        }
        const bank = &self.banks[slot];
        const cur = ch.info.window_shape;
        var buf: [2048]Word = undefined;
        if (ch.info.isShort()) {
            var t: [8][256]Word = undefined;
            for (&t, 0..) |*o, w| imdct.imdct(128, c.w[w * 128 ..][0..128], c.e, o);
            window.block(bank.prev_shape, cur, ch.info.window_sequence, .{ .short = &t }, &buf);
        } else {
            var t: [2048]Word = undefined;
            imdct.imdct(1024, &c.w, c.e, &t);
            window.block(bank.prev_shape, cur, ch.info.window_sequence, .{ .long = &t }, &buf);
        }
        var pcm: [frame_len]i16 = undefined;
        window.synth(bank, cur, &buf, &pcm);
        const n: usize = self.channels;
        for (pcm, 0..) |s, i| out[i * n + slot] = s;
    }
};

const testing = std.testing;

test "the device's priming access unit decodes to stereo silence" {
    var d = try Decoder.init(&.{ 0x12, 0x10 });
    var out: [2048]i16 = @splat(1);
    try d.decode(&.{ 0x21, 0x00, 0x03, 0x40, 0x68, 0x1c }, &out);
    for (out) |s| try testing.expectEqual(@as(i16, 0), s);
}
