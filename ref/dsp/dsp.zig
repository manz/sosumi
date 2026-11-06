//! The DSP-shaped layer (specs/dsp.md, Phase 1): the codecs again, in measured sm1 operations
//! only, checked bit for bit against the models in ref/.
pub const ops = @import("ops.zig");
pub const alac = @import("alac.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
