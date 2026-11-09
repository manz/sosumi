//! Writes mp3_packet's x17 image source (dsp/mp3_player.zig `imageSource`) to stdout.
//!
//!     mp3image LIBDIR > mp3.sm
//!
//! LIBDIR is dsp/lib, for the decoder pass's .include lines. `zig build sm1` assembles the
//! result with `x17 image` into zig-out/sm1/mp3.x17i and its debug sidecar mp3.json.
const std = @import("std");
const dsp = @import("dsp");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 2) {
        std.debug.print("usage: mp3image LIBDIR\n", .{});
        std.process.exit(2);
    }
    // absolute, since x17 resolves .include against the including file
    const lib = try std.Io.Dir.cwd().realPathFileAlloc(io, args[1], init.arena.allocator());
    var obuf: [1 << 16]u8 = undefined;
    var ow = std.Io.File.stdout().writer(io, &obuf);
    try dsp.mp3.imageSource(init.gpa, &ow.interface, lib);
    try ow.interface.flush();
}
