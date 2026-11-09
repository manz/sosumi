//! Writes aac_packet's x17 image source (dsp/aac_player.zig `imageSource`) to stdout.
//!
//!     aacimage LIBDIR [freq_index] [channels] > aac.sm
//!
//! LIBDIR is dsp/lib, for the decoder pass's .include lines. `zig build sm1` assembles the
//! result with `x17 image` into zig-out/sm1/aac.x17i and its debug sidecar aac.json.
const std = @import("std");
const dsp = @import("dsp");

const A = dsp.aac;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 2) {
        std.debug.print("usage: aacimage LIBDIR [freq_index] [channels]\n", .{});
        std.process.exit(2);
    }
    // absolute, since x17 resolves .include against the including file
    const lib = try std.Io.Dir.cwd().realPathFileAlloc(io, args[1], init.arena.allocator());
    const fi: u4 = if (args.len > 2) try std.fmt.parseInt(u4, args[2], 10) else 4;
    const nch: u32 = if (args.len > 3) try std.fmt.parseInt(u32, args[3], 10) else 2;

    var obuf: [1 << 16]u8 = undefined;
    var ow = std.Io.File.stdout().writer(io, &obuf);
    const w = &ow.interface;
    try A.imageSource(gpa, w, lib, fi, nch);
    try w.flush();
}
