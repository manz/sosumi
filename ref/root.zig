//! sosumi reference model: AAC-LC in Zig at sm1's widths, the oracle the x17 assembly is
//! checked against stage by stage.
pub const bits = @import("bits.zig");
pub const fixed = @import("fixed.zig");
pub const asc = @import("asc.zig");
pub const raw = @import("raw.zig");
pub const ics = @import("ics.zig");
pub const huffman = @import("huffman.zig");
pub const swb = @import("tables/swb.zig");
pub const iquant = @import("iquant.zig");
pub const stereo = @import("stereo.zig");
pub const tns = @import("tns.zig");
pub const window = @import("window.zig");
pub const imdct = @import("imdct.zig");
pub const filterbank = @import("filterbank.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
