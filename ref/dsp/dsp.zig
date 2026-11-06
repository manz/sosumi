//! The DSP-shaped layer (specs/dsp.md, Phase 1): the codecs again, in measured sm1 operations
//! only, checked bit for bit against the models in ref/.
pub const ops = @import("ops.zig");
pub const bits = @import("bits.zig");
pub const alac = @import("alac/alac.zig");
pub const aac = @import("aac/aac.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
