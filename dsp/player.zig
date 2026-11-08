//! ALAC packets through x17's host model and dsp/lib/alac.sm: the host stages each packet at
//! Y:0x80, runs alac_packet to its stop and drains the output ring (specs/aac.md output
//! contract; alac.sm's header for its slots).
const std = @import("std");
const ref = @import("ref");
const host = @import("host");
const h = @import("harness.zig");

pub const emu = h.emu;

const packet_base = 0x80;
const pk = 0x2E00;
const pk_n = pk + 6;
const pk_status = pk + 7;

pub const Error = error{ Unsupported, Status } || host.Error || std.mem.Allocator.Error;

/// alac_packet, assembled from the audited libs (caller frees).
pub fn program(gpa: std.mem.Allocator) ![]u32 {
    return h.assemble(gpa,
        \\.include "lib/bits.sm"
        \\.include "lib/rice.sm"
        \\.include "lib/predictor.sm"
        \\.include "lib/unmix.sm"
        \\.include "lib/mem.sm"
        \\.include "lib/alac.sm"
        \\        bits_init(0x80)
        \\        alac_packet()
        \\        x17.halt
        \\
    );
}

/// What alac.sm decodes: 16-bit output, at most two channels, frames up to 4096.
pub fn supported(cfg: ref.alac.config.Config) bool {
    return cfg.bit_depth <= 16 and cfg.channels <= 2 and cfg.frame_length <= 4096;
}

pub const Player = struct {
    host: host.Host,
    prog: []const u32,
    params: []host.Param,
    /// alac_packet's status for the last packet (alac.sm header).
    status: u32 = 0,
    bundles: usize = 0,

    pub fn init(gpa: std.mem.Allocator, prog: []const u32, cfg: ref.alac.config.Config) Error!Player {
        if (!supported(cfg)) return error.Unsupported;
        // The track's config into alac.sm's slots, written by the host before every packet
        // (x17 host model `Config.params`, a stub until the device's path is measured).
        const values = [_]u32{ cfg.frame_length, cfg.bit_depth, cfg.pb, cfg.mb, cfg.kb, cfg.channels };
        const params = try gpa.alloc(host.Param, values.len);
        errdefer gpa.free(params);
        for (params, values, 0..) |*q, v, i| q.* = .{ .addr = pk + @as(u32, @intCast(i)), .value = v };
        return .{
            .host = try host.Host.init(gpa, .{
                .rate_hz = cfg.sample_rate,
                .packet = .{ .base = packet_base, .len_at = packet_base - 1 },
                .params = params,
                .max_bundles = 1 << 30,
            }),
            .prog = prog,
            .params = params,
        };
    }

    pub fn deinit(self: *Player) void {
        self.host.deinit();
        self.host.gpa.free(self.params);
    }

    /// One packet: its PCM, interleaved 16-bit, valid until the next call.
    pub fn feed(self: *Player, packet: []const u8) Error![]const i16 {
        self.host.pcm.clearRetainingCapacity();
        const r = try self.host.feed(self.prog, packet);
        self.bundles = r.bundles;
        self.status = self.host.state.y_mem.get(pk_status) orelse 0;
        if (self.status != 0) return error.Status;
        return self.host.pcm.items;
    }

    /// Samples per channel of the last packet.
    pub fn frames(self: *const Player) usize {
        return self.host.state.y_mem.get(pk_n) orelse 0;
    }
};
