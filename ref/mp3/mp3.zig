//! MPEG-1, 2 and 2.5 Layer III (ISO/IEC 11172-3, 13818-3).
pub const header = @import("header.zig");
pub const sideinfo = @import("sideinfo.zig");
pub const bands = @import("bands.zig");
pub const scalefactors = @import("scalefactors.zig");
pub const spectrum = @import("spectrum.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
