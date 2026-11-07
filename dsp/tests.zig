//! The sm1 stage libraries in dsp/lib, each tested in x17's emulator against its ref/dsp twin.
test {
    _ = @import("test/bits.zig");
    _ = @import("test/pcm.zig");
    _ = @import("test/huffman.zig");
    _ = @import("test/sections.zig");
    _ = @import("test/dequant.zig");
    _ = @import("test/stereo.zig");
    _ = @import("test/pns.zig");
    _ = @import("test/tns.zig");
    _ = @import("test/imdct.zig");
}
