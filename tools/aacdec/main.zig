//! Decodes an ADTS AAC-LC file with ref/dsp/aac and lists each access unit's tools; --dump writes
//! a run of access units with the decoder state before them, for x17's packet-level test of the
//! sm1 decoder (the AAC twin of `alacdec --dump`).
//!
//!     aacdec in.aac [--dump=out.pkts] [--from=S] [--count=N]
//!
//! Every line of stdout is one access unit: its index, window sequence per channel, then the
//! tools it uses (tns per channel, ms, is, pns, pulse per channel).
const std = @import("std");
const ref = @import("ref");

const Dsp = ref.dsp.aac.decoder;
const Word = ref.dsp.ops.Word;

/// "AAPK", freq_index, channel_config, from, count; then per channel: prev_shape and the 1024
/// overlap words; then the PNS rng word; then per access unit: its length, its raw_data_block
/// bytes (ADTS header stripped, not padded) and 1024 * channels interleaved PCM samples.
/// Every field is a little-endian u32. Words are their 24 bits two's complement, upper byte 0;
/// PCM samples are sign-extended.
const Dump = struct {
    out: std.ArrayList(u8) = .empty,

    fn put(self: *Dump, gpa: std.mem.Allocator, v: u32) !void {
        var b: [4]u8 = undefined;
        std.mem.writeInt(u32, &b, v, .little);
        try self.out.appendSlice(gpa, &b);
    }

    fn word(self: *Dump, gpa: std.mem.Allocator, w: Word) !void {
        try self.put(gpa, @as(u24, @bitCast(w)));
    }

    fn header(self: *Dump, gpa: std.mem.Allocator, h: ref.aac.adts.Header, from: u32, count: u32) !void {
        try self.out.appendSlice(gpa, "AAPK");
        for ([_]u32{ h.freqIndex(), h.channelConfig(), from, count }) |v| try self.put(gpa, v);
    }

    fn state(self: *Dump, gpa: std.mem.Allocator, d: *const Dsp.Decoder) !void {
        for (d.banks[0..d.channels]) |*b| {
            try self.put(gpa, b.prev_shape);
            for (b.overlap) |w| try self.word(gpa, w);
        }
        try self.word(gpa, d.rng.x);
    }

    fn unit(self: *Dump, gpa: std.mem.Allocator, au: []const u8, pcm: []const i16) !void {
        try self.put(gpa, @intCast(au.len));
        try self.out.appendSlice(gpa, au);
        for (pcm) |s| try self.put(gpa, @bitCast(@as(i32, s)));
    }
};

const Args = struct {
    in: []const u8,
    dump: ?[]const u8 = null,
    from: u32 = 0,
    count: u32 = 4,

    fn parse(all: []const [:0]const u8) !Args {
        if (all.len < 2) return error.Usage;
        var a: Args = .{ .in = all[1] };
        for (all[2..]) |s| {
            if (std.mem.startsWith(u8, s, "--dump=")) a.dump = s["--dump=".len..] else if (std.mem.startsWith(u8, s, "--from=")) {
                a.from = try std.fmt.parseInt(u32, s["--from=".len..], 10);
            } else if (std.mem.startsWith(u8, s, "--count=")) {
                a.count = try std.fmt.parseInt(u32, s["--count=".len..], 10);
            } else return error.Usage;
        }
        return a;
    }
};

fn list(w: *std.Io.Writer, i: usize, t: ref.aac.decoder.ToolStats, nch: usize) !void {
    try w.print("{d}", .{i});
    for (t.window[0..nch]) |ws| try w.print(" {s}", .{@tagName(ws)});
    try w.writeAll(" tns");
    for (t.tns[0..nch]) |b| try w.print(" {d}", .{@intFromBool(b)});
    try w.print(" ms {d} is {d} pns {d} pulse", .{ t.ms, @intFromBool(t.intensity), @intFromBool(t.pns) });
    for (t.pulse[0..nch]) |b| try w.print(" {d}", .{@intFromBool(b)});
    try w.writeAll("\n");
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const args = Args.parse(try init.minimal.args.toSlice(init.arena.allocator())) catch {
        std.debug.print("usage: aacdec in.aac [--dump=out.pkts] [--from=S] [--count=N]\n", .{});
        std.process.exit(2);
    };
    const cwd = std.Io.Dir.cwd();
    const file = try cwd.readFileAlloc(io, args.in, gpa, .limited(1 << 30));
    defer gpa.free(file);

    var obuf: [4096]u8 = undefined;
    var ow = std.Io.File.stdout().writer(io, &obuf);
    const w = &ow.interface;

    var dump: Dump = .{};
    defer dump.out.deinit(gpa);
    var dec: ?Dsp.Decoder = null;
    var pcm: [2 * Dsp.frame_len]i16 = undefined;
    var pos: usize = 0;
    var i: u32 = 0;
    var dumped: u32 = 0;
    while (pos + 7 <= file.len) : (i += 1) {
        const h = try ref.aac.adts.parse(file[pos..]);
        if (dec == null) {
            dec = try Dsp.Decoder.init(&h.config);
            if (args.dump != null) try dump.header(gpa, h, args.from, args.count);
        }
        const d = &dec.?;
        const au = file[pos + h.header_len .. pos + h.frame_len];
        const n = Dsp.frame_len * @as(usize, d.channels);
        const in_run = args.dump != null and i >= args.from and dumped < args.count;
        if (in_run and i == args.from) try dump.state(gpa, d);
        try d.decode(au, pcm[0..n]);
        try list(w, i, d.last, d.channels);
        if (in_run) {
            try dump.unit(gpa, au, pcm[0..n]);
            dumped += 1;
        }
        pos += h.frame_len;
    }
    try w.flush();
    if (args.dump) |path| {
        if (dumped != args.count) {
            std.debug.print("{s}: only {d} of {d} access units from {d}\n", .{ args.in, dumped, args.count, args.from });
            std.process.exit(1);
        }
        try cwd.writeFile(io, .{ .sub_path = path, .data = dump.out.items });
    }
}
