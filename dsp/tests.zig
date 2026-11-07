//! The sm1 stage libraries in dsp/lib, each tested in x17's emulator against its ref/dsp twin.
test {
    _ = @import("test/bits.zig");
    _ = @import("test/pcm.zig");
}
