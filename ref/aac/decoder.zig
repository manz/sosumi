//! AAC-LC decoder, as the device drives one: an AudioSpecificConfig at configure time, then one
//! raw access unit per call (specs/aac.md). Mono and stereo (channel_configuration 1 and 2).
//!
//! Per channel, in ISO/IEC 14496-3 order: dequantisation, PNS / M/S / intensity, TNS, filterbank.
const std = @import("std");
const bits = @import("../bits.zig");
const asc_mod = @import("asc.zig");
const raw = @import("raw.zig");
const ics = @import("ics.zig");
const iquant = @import("iquant.zig");
const stereo = @import("stereo.zig");
const tns = @import("tns.zig");
const filterbank = @import("filterbank.zig");

pub const Error = raw.Error || asc_mod.Error || error{ UnsupportedChannelConfig, TooManyChannels, MissingEnd };

pub const frame_len = 1024;
pub const max_channels = 2;

/// Which tools the last access unit used, per channel slot. Diagnostics only.
pub const ToolStats = struct {
    window: [max_channels]ics.WindowSequence = @splat(.only_long),
    common_window: bool = false,
    ms: u2 = 0,
    pns: bool = false,
    intensity: bool = false,
    tns: [max_channels]bool = @splat(false),
    pulse: [max_channels]bool = @splat(false),
};

fn usesBook(ch: *const ics.Channel, pred: fn (u4) bool) bool {
    for (0..ch.info.num_window_groups) |g| for (0..ch.info.max_sfb) |sfb| {
        if (pred(ch.sections.sfb_cb[g][sfb])) return true;
    };
    return false;
}

fn isNoise(cb: u4) bool {
    return cb == ics.noise_hcb;
}

fn isIntensity(cb: u4) bool {
    return cb == ics.intensity_hcb or cb == ics.intensity_hcb2;
}

pub const Decoder = struct {
    config: asc_mod.Asc,
    channels: u2,
    banks: [max_channels]filterbank.State = .{ .{}, .{} },
    rng: stereo.Rng = .{},
    last: ToolStats = .{},

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
                    var c = iquant.dequantChannel(&ch, fi);
                    stereo.pns(&ch, &c, ch.info.bandOffsets(fi), &self.rng);
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
                    var l = iquant.dequantChannel(&pair.left, fi);
                    var rr = iquant.dequantChannel(&pair.right, fi);
                    stereo.applyPair(&pair, &l, &rr, pair.left.info.bandOffsets(fi), pair.right.info.bandOffsets(fi), &self.rng);
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
        self.last.pns = self.last.pns or usesBook(ch, isNoise);
        self.last.intensity = self.last.intensity or usesBook(ch, isIntensity);
    }

    fn finish(self: *Decoder, ch: *const ics.Channel, c: *iquant.Coefs, slot: usize, out: []i16) void {
        tns.apply(ch, c, self.config.freq_index);
        var pcm: [frame_len]i16 = undefined;
        filterbank.synth(&self.banks[slot], ch.info, c, &pcm);
        const n: usize = self.channels;
        for (pcm, 0..) |s, i| out[i * n + slot] = s;
    }
};

const testing = std.testing;

test "the device's priming access unit decodes to stereo silence" {
    // ASC: AAC-LC, 44.1 kHz, stereo
    var d = try Decoder.init(&.{ 0x12, 0x10 });
    var out: [2048]i16 = @splat(1);
    try d.decode(&.{ 0x21, 0x00, 0x03, 0x40, 0x68, 0x1c }, &out);
    for (out) |s| try testing.expectEqual(@as(i16, 0), s);
}
