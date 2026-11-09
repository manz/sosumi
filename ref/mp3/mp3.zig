//! MPEG-1, 2 and 2.5 Layer III (ISO/IEC 11172-3, 13818-3).
pub const header = @import("header.zig");
pub const sideinfo = @import("sideinfo.zig");
pub const bands = @import("bands.zig");
pub const scalefactors = @import("scalefactors.zig");
pub const spectrum = @import("spectrum.zig");
pub const requant = @import("requant.zig");
pub const stereo = @import("stereo.zig");
pub const hybrid = @import("hybrid.zig");
pub const synth = @import("synth.zig");
pub const decoder = @import("decoder.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
pub const tables = struct {
    pub const huffman = @import("tables/huffman.zig");
};
