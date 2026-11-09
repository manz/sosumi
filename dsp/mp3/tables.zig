//! The MP3 program's data tables, from the reference model's rules.
const std = @import("std");
const ref = @import("ref");

const header = ref.mp3.header;

/// MP_FLEN: [MPEG-1, MPEG-2, MPEG-2.5][sr_index 0..2][bitrate_index 0..14] -> the frame's bytes
/// without padding (ref/mp3/header.zig frameLen, free format as 128 kbps).
pub const flen: [135]u16 = blk: {
    @setEvalBranchQuota(100000);
    var t: [135]u16 = undefined;
    for ([_]header.Version{ .mpeg1, .mpeg2, .mpeg25 }, 0..) |v, row| {
        for (0..3) |sr| for (0..15) |br| {
            const h: header.Header = .{ .version = v, .crc = false, .bitrate_index = br, .sr_index = sr, .padding = false, .mode = .stereo, .mode_ext = 0 };
            t[row * 45 + sr * 15 + br] = @intCast(h.frameLen());
        };
    }
    break :blk t;
};

/// The frames of an MP3 file: ID3v2 skipped, then header to header.
pub fn frames(gpa: std.mem.Allocator, file: []const u8) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(gpa);
    var pos: usize = 0;
    if (file.len > 10 and std.mem.eql(u8, file[0..3], "ID3")) {
        const size = (@as(usize, file[6]) << 21) | (@as(usize, file[7]) << 14) | (@as(usize, file[8]) << 7) | file[9];
        pos = 10 + size + @as(usize, if (file[5] & 0x10 != 0) 10 else 0);
    }
    while (pos + 4 <= file.len) {
        const h = header.parse(file[pos..]) catch {
            pos += 1;
            continue;
        };
        const len = h.frameLen();
        if (pos + len > file.len) break;
        try out.append(gpa, file[pos .. pos + len]);
        pos += len;
    }
    return out.toOwnedSlice(gpa);
}

const sfs = ref.mp3.scalefactors;

/// MP_SLEN: slen1[16] then slen2[16], by scalefac_compress.
pub const slen: [32]u16 = blk: {
    var t: [32]u16 = undefined;
    for (0..2) |r| for (0..16) |c| {
        t[r * 16 + c] = sfs.slen[r][c];
    };
    break :blk t;
};

/// MP_PART: entries per partition, [long, mixed, short][28].
pub const part: [84]u16 = blk: {
    var t: [84]u16 = undefined;
    for (0..3) |r| for (0..28) |c| {
        t[r * 28 + c] = sfs.partitions[r][c];
    };
    break :blk t;
};

/// MP_GMOD: the MPEG-2 partition radices.
pub const gmod: [24]u16 = blk: {
    var t: [24]u16 = undefined;
    for (&t, sfs.g_mod) |*d, v| d.* = v;
    break :blk t;
};

/// Every table at its Y address (`at` maps a .const name to its address).
pub fn put(st: anytype, gpa: std.mem.Allocator, comptime at: fn (comptime []const u8) u32) !void {
    for (flen, 0..) |v, i| try st.y_mem.put(gpa, at("MP_FLEN") + @as(u32, @intCast(i)), v);
    for (slen, 0..) |v, i| try st.y_mem.put(gpa, at("MP_SLEN") + @as(u32, @intCast(i)), v);
    for (part, 0..) |v, i| try st.y_mem.put(gpa, at("MP_PART") + @as(u32, @intCast(i)), v);
    for (gmod, 0..) |v, i| try st.y_mem.put(gpa, at("MP_GMOD") + @as(u32, @intCast(i)), v);
}
