//! sosumi reference model: the codecs in Zig at sm1's widths, the oracle the x17 assembly is
//! checked against stage by stage.
pub const bits = @import("bits.zig");
pub const fixed = @import("fixed.zig");
pub const aac = @import("aac/aac.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
