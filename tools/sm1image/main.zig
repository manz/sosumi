//! Writes a decoder's x17 image source to stdout: aac_packet (dsp/aac_player.zig), mp3_packet
//! (dsp/mp3_player.zig) or alac_packet (dsp/player.zig), each `imageSource`.
//!
//!     sm1image aac LIBDIR [freq_index] [channels] > aac.sm
//!     sm1image mp3 LIBDIR > mp3.sm
//!     sm1image alac LIBDIR > alac.sm
//!
//! LIBDIR is dsp/lib, for the decoder pass's .include lines. `zig build sm1` assembles each with
//! `x17 image` into zig-out/sm1/<codec>.x17i and its debug sidecar <codec>.json.
const std = @import("std");
const dsp = @import("dsp");

fn usage() noreturn {
    std.debug.print("usage: sm1image aac|mp3|alac LIBDIR [freq_index channels]\n", .{});
    std.process.exit(2);
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 3) usage();
    // absolute, since x17 resolves .include against the including file
    const lib = try std.Io.Dir.cwd().realPathFileAlloc(io, args[2], init.arena.allocator());
    var obuf: [1 << 16]u8 = undefined;
    var ow = std.Io.File.stdout().writer(io, &obuf);
    const w = &ow.interface;
    if (std.mem.eql(u8, args[1], "aac")) {
        const fi: u4 = if (args.len > 3) try std.fmt.parseInt(u4, args[3], 10) else 4;
        const nch: u32 = if (args.len > 4) try std.fmt.parseInt(u32, args[4], 10) else 2;
        try dsp.aac.imageSource(gpa, w, lib, fi, nch);
    } else if (std.mem.eql(u8, args[1], "mp3")) {
        try dsp.mp3.imageSource(gpa, w, lib);
    } else if (std.mem.eql(u8, args[1], "alac")) {
        try dsp.imageSource(gpa, w, lib);
    } else usage();
    try w.flush();
}
