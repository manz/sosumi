//! ALAC packets through x17's host model and dsp/lib/alac.sm: the host arms each packet on the
//! input stream, writes the configure words, runs alac_packet to its stop and drains the
//! ring's one stereo slot (specs/alac.md).
const std = @import("std");
const ref = @import("ref");
const host = @import("host");
const h = @import("harness.zig");

pub const emu = h.emu;
pub const aac = @import("aac_player.zig");
pub const mp3 = @import("mp3_player.zig");

const pk = 0x2E00;
const pk_n = pk + 6;
const pk_status = pk + 7;

pub const Error = error{ Unsupported, Status, Starved, MonoCopy } || host.Error || std.mem.Allocator.Error;

pub const Site = h.Site;

/// alac_packet, assembled from the audited libs (caller frees).
pub fn program(gpa: std.mem.Allocator) ![]u32 {
    return programSites(gpa, null);
}

/// `program`, also listing each bundle's source line when `sites` is set.
pub fn programSites(gpa: std.mem.Allocator, sites: ?*std.ArrayList(Site)) ![]u32 {
    return h.assembleSites(gpa,
        \\.include "lib/bits.sm"
        \\.include "lib/rice.sm"
        \\.include "lib/predictor.sm"
        \\.include "lib/unmix.sm"
        \\.include "lib/mem.sm"
        \\.include "lib/ring.sm"
        \\.include "lib/alac.sm"
        \\        bits_init()
        \\        alac_packet()
        \\        x17.halt
        \\
    , sites);
}

/// What alac.sm decodes: 16-bit output, at most two channels, 4096-sample frames (the length
/// the ring's slot fixes; the host does not pass the cookie's).
pub fn supported(cfg: ref.alac.config.Config) bool {
    return cfg.bit_depth <= 16 and cfg.channels <= 2 and cfg.frame_length == 4096;
}

pub const Player = struct {
    host: host.Host,
    prog: []const u32,
    params: []host.Param,
    nch: usize,
    /// The last packet's PCM, `nch` interleaved.
    pcm: std.ArrayList(i16) = .empty,
    /// alac_packet's status for the last packet (alac.sm header).
    status: u32 = 0,
    bundles: usize = 0,

    pub fn init(gpa: std.mem.Allocator, prog: []const u32, cfg: ref.alac.config.Config) Error!Player {
        if (!supported(cfg)) return error.Unsupported;
        // The cookie's fields as the host's configure leaves them (specs/alac.md): FD80 bits
        // 0-4, then depth, pb, kb, mb at FD82..FD85.
        const values = [_]host.Param{
            .{ .addr = 0xFD80, .value = 0x1F },
            .{ .addr = 0xFD82, .value = cfg.bit_depth },
            .{ .addr = 0xFD83, .value = cfg.pb },
            .{ .addr = 0xFD84, .value = cfg.kb },
            .{ .addr = 0xFD85, .value = cfg.mb },
        };
        const params = try gpa.dupe(host.Param, &values);
        errdefer gpa.free(params);
        var p: Player = .{
            .host = try host.Host.init(gpa, .{
                .rate_hz = cfg.sample_rate,
                .params = params,
                .max_bundles = 1 << 30,
            }),
            .prog = prog,
            .params = params,
            .nch = cfg.channels,
        };
        errdefer p.host.deinit();
        // the init pass's ring header: one slot of 0x2000 words
        try h.stageRing(&p.host.state, gpa, 1, 0x2000);
        return p;
    }

    pub fn deinit(self: *Player) void {
        self.pcm.deinit(self.host.gpa);
        self.host.deinit();
        self.host.gpa.free(self.params);
    }

    /// One packet: its PCM, interleaved 16-bit, valid until the next call.
    pub fn feed(self: *Player, packet: []const u8) Error![]const i16 {
        self.host.pcm.clearRetainingCapacity();
        const r = try self.host.feed(self.prog, packet);
        self.bundles = r.bundles;
        if (r.waiting) return error.Starved; // it read past its packet (784)
        self.status = self.host.state.y_mem.get(pk_status) orelse 0;
        if (self.status != 0) return error.Status;
        if (self.nch == 2) return self.host.pcm.items;
        // the slot is always stereo: a mono channel sits on both sides
        const st = self.host.pcm.items;
        self.pcm.clearRetainingCapacity();
        for (0..st.len / 2) |i| {
            if (st[2 * i + 1] != st[2 * i]) return error.MonoCopy;
            try self.pcm.append(self.host.gpa, st[2 * i]);
        }
        return self.pcm.items;
    }

    /// Counts, from now on, the bundles run at each syllable (x17 emulator `State.profile`).
    pub fn profile(self: *Player, counts: []u64) void {
        self.host.state.profile = counts;
    }

    /// Samples per channel of the last packet.
    pub fn frames(self: *const Player) usize {
        return self.host.state.y_mem.get(pk_n) orelse 0;
    }
};
