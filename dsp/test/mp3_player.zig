//! dsp/mp3_player.zig: mp3_packet under x17's host model (the ring drained by the host, its
//! owned slots guarded), the ring-full stop, and the x17 image's two passes, each against the
//! twin's Decoder (ref/dsp/mp3/decoder.zig).
const std = @import("std");
const ref = @import("ref");
const h = @import("../harness.zig");
const map = @import("../map.zig");
const mp3 = @import("../mp3_player.zig");
const image = @import("image");

const testing = std.testing;

/// The twin's PCM for every frame of `file`, concatenated, interleaved in the stream's channels.
fn twinPcm(gpa: std.mem.Allocator, fr: []const []const u8) ![]i16 {
    var dec: ref.dsp.mp3.decoder.Decoder = .{};
    var all: std.ArrayList(i16) = .empty;
    errdefer all.deinit(gpa);
    var buf: [2304]i16 = undefined;
    for (fr) |frame| {
        const f = try dec.decode(frame, &buf);
        try all.appendSlice(gpa, buf[0 .. @as(usize, f.header.samples()) * f.header.channels()]);
    }
    return all.toOwnedSlice(gpa);
}

test "the MP3 player's frames come out of the host's ring as the twin decodes them" {
    const gpa = testing.allocator;
    const prog = try mp3.program(gpa);
    defer gpa.free(prog);
    for ([_][]const u8{ @embedFile("mono.cbr.mp3"), @embedFile("clicks.m2.mp3") }) |file| {
        const fr = try mp3.frames(gpa, file);
        defer gpa.free(fr);
        const want = try twinPcm(gpa, fr);
        defer gpa.free(want);
        var p = try mp3.Player.init(gpa, prog, 44100);
        defer p.deinit();
        var at: usize = 0;
        for (fr) |frame| {
            const got = try p.feed(frame);
            try testing.expectEqualSlices(i16, want[at..][0..got.len], got);
            at += got.len;
        }
        try testing.expectEqual(want.len, at);
    }
}

test "with both slots owned the player stops, FD95 = 0x21, and decodes the frame once released" {
    const gpa = testing.allocator;
    const prog = try mp3.program(gpa);
    defer gpa.free(prog);
    const fr = try mp3.frames(gpa, @embedFile("clicks.m2.mp3"));
    defer gpa.free(fr);
    const want = try twinPcm(gpa, fr[0..4]);
    defer gpa.free(want);
    var p = try mp3.Player.init(gpa, prog, 24000);
    defer p.deinit();
    p.host.cfg.drain_limit = 0; // a host that lags: nothing taken
    for (fr[0..2]) |frame| try testing.expectEqual(@as(usize, 0), (try p.feed(frame)).len);
    try testing.expectError(error.RingFull, p.feed(fr[2]));
    // the host takes both slots, as its drain would, then arms the next frame: the program
    // reads on from the frame it left
    const n = 0x480; // an MPEG-2 stereo frame's words (specs/mp3.md)
    const st = &p.host.state;
    for (0..2) |k| {
        const base = map.at("OUTY") + map.at("MP_RSL") * @as(u32, @intCast(k));
        for (0..n) |i| try testing.expectEqual(want[k * n + i], h.sx16(st.getY(base + @as(u32, @intCast(i)))));
        try st.y_mem.put(gpa, map.at("RING_E") + 2 * @as(u32, @intCast(k)), 0);
    }
    p.host.idx = 0;
    p.host.cfg.drain_limit = null;
    try testing.expectEqualSlices(i16, want[2 * n ..][0..n], try p.feed(fr[3]));
}

test "the MP3 x17 image's init pass, then its decoder at q256, decode as the twin" {
    const gpa = testing.allocator;
    var src: std.Io.Writer.Allocating = .init(gpa);
    defer src.deinit();
    try mp3.imageSource(gpa, &src.writer, "lib");
    var prog = try h.assembleImage(gpa, src.written());
    defer prog.deinit();
    const bytes = try image.write(gpa, &prog);
    defer gpa.free(bytes);
    var img = try image.parse(gpa, bytes);
    defer img.deinit(gpa);
    const p = try gpa.alloc(u32, 0x4000);
    defer gpa.free(p);
    var state = h.emu.State{};
    defer state.deinit(gpa);
    for ([_]u8{ 0, image.decoder_pass }) |pass| {
        @memset(p, 0);
        for (img.sections) |sec| if (sec.pass == pass) switch (sec.kind) {
            .p => image.placeRows(p, sec),
            .x => for (sec.words, 0..) |w, k| try state.x_mem.put(gpa, sec.addr + @as(u32, @intCast(k)), w),
            .y, .param => for (sec.words, 0..) |w, k| try state.y_mem.put(gpa, sec.addr + @as(u32, @intCast(k)), w),
        };
        if (pass == 0) {
            _ = try h.emu.runFrom(gpa, &state, p, 0, 1 << 10);
            try testing.expect(state.halted);
        }
    }
    const fr = try mp3.frames(gpa, @embedFile("heavy.cbr.mp3"));
    defer gpa.free(fr);
    const want = try twinPcm(gpa, fr[0..24]);
    defer gpa.free(want);
    var at: usize = 0;
    for (fr[0..24]) |frame| {
        const k = state.getY(map.at("MP_OSL")).?;
        try h.stagePacket(gpa, &state, frame);
        state.halted = false;
        state.cur_lane = 0;
        _ = try h.emu.runFrom(gpa, &state, p, 256, 1 << 23);
        try testing.expect(state.halted and !state.stream_starved);
        const len = state.getY(map.at("RING_E") + 2 * k + 1).?;
        const base = map.at("OUTY") + map.at("MP_RSL") * k;
        for (0..len) |i| try testing.expectEqual(want[at + i], h.sx16(state.getY(base + @as(u32, @intCast(i)))));
        at += len;
        try state.y_mem.put(gpa, map.at("RING_E") + 2 * k, 0);
    }
    try testing.expectEqual(want.len, at);
}
