//! Apple Lossless, after Apple's reference decoder (github.com/macosforge/alac, Apache 2.0).
pub const config = @import("config.zig");
pub const rice = @import("rice.zig");
pub const predictor = @import("predictor.zig");
pub const decoder = @import("decoder.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
