//! MPEG Layer III's numeric half in measured sm1 operations; the parse is `ref/mp3`'s.
pub const requant = @import("requant.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
