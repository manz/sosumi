//! Layer III again, the numeric half in measured sm1 operations: requantisation, stereo, the
//! hybrid filterbank and synthesis. The parse (header, side information, reservoir, scale
//! factors, spectrum) is `ref/mp3`'s; what it hands on is integers.
const std = @import("std");
const ref_dec = @import("../../mp3/decoder.zig");
const header = @import("../../mp3/header.zig");
const bands = @import("../../mp3/bands.zig");
const requant = @import("requant.zig");
const stereo = @import("stereo.zig");
const hybrid = @import("hybrid.zig");
const synth = @import("synth.zig");

pub const Error = ref_dec.Error;
pub const Frame = ref_dec.Frame;

pub const Decoder = struct {
    last: ref_dec.ToolStats = .{},
    parser: ref_dec.Parser = .{},
    hybrid: [2]hybrid.State = .{ .{}, .{} },
    synth: [2]synth.State = .{ .{}, .{} },

    /// One frame into interleaved PCM: samples() values.
    pub fn decode(self: *Decoder, frame: []const u8, out: []i16) Error!Frame {
        const h = try header.parse(frame);
        const nch = h.channels();
        const n = @as(usize, h.samples()) * nch;
        if (out.len < n) return error.OutputTooSmall;
        const p = (try self.parser.parse(frame, h)) orelse {
            @memset(out[0..n], 0);
            return .{ .header = h, .decoded = false };
        };
        self.last = p.tools();
        for (0..h.granules()) |gr| {
            var coefs: [2]requant.Coefs = undefined;
            for (0..nch) |ch| coefs[ch] = requant.requantise(p.side.gr[gr][ch], p.bandsOf(gr, ch), &p.sf[gr][ch], &p.is[gr][ch]);
            if (nch == 2) stereo.process(h, p.side.gr[gr][0], p.side.gr[gr][1], &p.sf[gr][1], &coefs[0], &coefs[1]);
            for (0..nch) |ch| {
                hybrid.run(&self.hybrid[ch], p.side.gr[gr][ch], p.bandsOf(gr, ch), bands.mixedLongSubbands(h), &coefs[ch]);
                for (0..18) |t| {
                    var sub: [32]@TypeOf(coefs[0][0]) = undefined;
                    for (0..32) |sb| sub[sb] = coefs[ch][sb * 18 + t];
                    var pcm: [32]i16 = undefined;
                    synth.slot(&self.synth[ch], &sub, &pcm);
                    for (pcm, 0..) |v, j| out[(gr * 576 + t * 32 + j) * nch + ch] = v;
                }
            }
        }
        return .{ .header = h, .decoded = true };
    }
};
