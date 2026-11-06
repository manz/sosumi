//! sosumi reference model: the codecs in Zig at sm1's widths, the oracle the x17 assembly is
//! checked against stage by stage.
pub const bits = @import("bits.zig");
pub const fixed = @import("fixed.zig");
pub const huffman = @import("huffman.zig");
pub const pow43 = @import("pow43.zig");
pub const aac = @import("aac/aac.zig");
pub const mp3 = @import("mp3/mp3.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
