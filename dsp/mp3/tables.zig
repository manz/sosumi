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
