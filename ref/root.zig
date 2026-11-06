//! sosumi reference model: AAC-LC in Zig at sm1's widths, the oracle the x17 assembly is
//! checked against stage by stage.
pub const bits = @import("bits.zig");
pub const fixed = @import("fixed.zig");
pub const asc = @import("asc.zig");
pub const raw = @import("raw.zig");
pub const ics = @import("ics.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
