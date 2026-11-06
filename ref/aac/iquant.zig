//! Inverse quantisation (ISO/IEC 14496-3): x = sign(q) * |q|^(4/3) * 2^((sf - 100) / 4), after
//! the pulse data is added to the quantised values.
//!
//! The power and gain come from the shared dequantiser (ref/pow43.zig).
const std = @import("std");
const fixed = @import("../fixed.zig");
const ics = @import("ics.zig");
const pow43 = @import("../pow43.zig");

const F24 = fixed.F24;

pub const sf_offset = 100;

/// One dequantised coefficient.
pub fn dequant(q: i16, sf: i16) F24 {
    return pow43.scaled(q, @as(i32, sf) - sf_offset);
}

/// pulse_data: offsets accumulate from the start of pulse_start_sfb; a positive value grows,
/// anything else (zero included) goes more negative.
pub fn applyPulse(spec: *ics.Spectrum, p: ics.Pulse, long_offsets: []const u16) void {
    var k: usize = long_offsets[p.start_sfb];
    for (0..p.count) |i| {
        k += p.offset[i];
        if (spec[k] > 0) spec[k] += p.amp[i] else spec[k] -= p.amp[i];
    }
}

pub const Coefs = [1024]F24;

/// Dequantises every band coded with a spectral book. Noise and intensity bands stay zero;
/// the stereo and noise tools fill them.
pub fn dequantChannel(ch: *const ics.Channel, freq_index: u4) Coefs {
    var spec = ch.spectrum;
    const offsets = ch.info.bandOffsets(freq_index);
    if (ch.pulse) |p| applyPulse(&spec, p, offsets);
    var out: Coefs = @splat(F24.zero);
    const win_len: usize = if (ch.info.isShort()) 128 else 1024;
    var first_win: usize = 0;
    for (0..ch.info.num_window_groups) |g| {
        for (0..ch.info.max_sfb) |sfb| {
            const cb = ch.sections.sfb_cb[g][sfb];
            if (cb == ics.zero_hcb or cb > 11) continue;
            const sf = ch.scalefactors[g][sfb];
            for (first_win..first_win + ch.info.group_len[g]) |w| {
                for (w * win_len + offsets[sfb]..w * win_len + offsets[sfb + 1]) |k| {
                    out[k] = dequant(spec[k], sf);
                }
            }
        }
        first_win += ch.info.group_len[g];
    }
    return out;
}

const testing = std.testing;

test "pulses accumulate offsets and push zero negative" {
    var spec: ics.Spectrum = @splat(0);
    spec[5] = 2;
    const offsets = [_]u16{ 0, 4, 8, 12 };
    const p: ics.Pulse = .{ .count = 2, .start_sfb = 1, .offset = .{ 1, 2, 0, 0 }, .amp = .{ 3, 4, 0, 0 } };
    applyPulse(&spec, p, &offsets);
    try testing.expectEqual(@as(i16, 5), spec[5]); // 4 + 1
    try testing.expectEqual(@as(i16, -4), spec[7]); // 5 + 2, was zero
}
