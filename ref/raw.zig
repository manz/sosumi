//! raw_data_block element loop (ISO/IEC 14496-3): element headers, and the elements an
//! AAC-LC decoder only has to parse past (data_stream_element, fill_element).
const std = @import("std");
const bits = @import("bits.zig");

pub const Error = bits.Error || error{ElementNotImplemented};

/// id_syn_ele values.
pub const ElementId = enum(u3) { sce, cpe, cce, lfe, dse, pce, fil, end };

pub const Header = struct {
    id: ElementId,
    /// element_instance_tag; fill_element and END carry none.
    tag: u4,
};

pub fn readHeader(r: *bits.BitReader) bits.Error!Header {
    const id: ElementId = @enumFromInt(try r.read(3));
    const tag: u4 = switch (id) {
        .fil, .end => 0,
        else => @intCast(try r.read(4)),
    };
    return .{ .id = id, .tag = tag };
}

/// data_stream_element() body, after its tag.
pub fn skipDse(r: *bits.BitReader) bits.Error!void {
    const byte_align = try r.readFlag();
    var count = try r.read(8);
    if (count == 255) count += try r.read(8);
    if (byte_align) r.byteAlign();
    try r.skip(count * 8);
}

/// fill_element() body. The extension payloads it may carry are skipped whole.
pub fn skipFil(r: *bits.BitReader) bits.Error!void {
    var count = try r.read(4);
    if (count == 15) count += try r.read(8) - 1;
    try r.skip(count * 8);
}

pub const Summary = struct { dse: u32 = 0, fil: u32 = 0 };

/// Walks one raw_data_block to its END element. Channel elements are not decoded yet.
pub fn walk(r: *bits.BitReader) Error!Summary {
    var s: Summary = .{};
    while (true) {
        const h = try readHeader(r);
        switch (h.id) {
            .dse => {
                try skipDse(r);
                s.dse += 1;
            },
            .fil => {
                try skipFil(r);
                s.fil += 1;
            },
            .end => {
                r.byteAlign();
                return s;
            },
            .sce, .cpe, .cce, .lfe, .pce => return error.ElementNotImplemented,
        }
    }
}

const testing = std.testing;

test "the device's priming access unit opens with a CPE, tag 0, common_window set" {
    // The first packet the host sends on an AAC track (specs/aac.md).
    var r = bits.BitReader.init(&.{ 0x21, 0x00, 0x03, 0x40, 0x68, 0x1c });
    const h = try readHeader(&r);
    try testing.expectEqual(ElementId.cpe, h.id);
    try testing.expectEqual(@as(u4, 0), h.tag);
    try testing.expect(try r.readFlag());
}

test "walk skips a DSE and a FIL and stops at END" {
    // DSE tag 0, no align, 2 bytes AB CD; FIL with 1 byte; END.
    var r = bits.BitReader.init(&.{ 0x80, 0x02, 0xAB, 0xCD, 0xC2, 0x01, 0xC0 });
    const s = try walk(&r);
    try testing.expectEqual(@as(u32, 1), s.dse);
    try testing.expectEqual(@as(u32, 1), s.fil);
    try testing.expectEqual(@as(usize, 0), r.bitsLeft());
}

test "walk reports a channel element as not implemented" {
    var r = bits.BitReader.init(&.{ 0x21, 0x00, 0x03, 0x40, 0x68, 0x1c });
    try testing.expectError(error.ElementNotImplemented, walk(&r));
}

test "a truncated DSE is an end-of-stream error" {
    var r = bits.BitReader.init(&.{ 0x80, 0x05, 0xAB });
    try testing.expectError(error.EndOfStream, walk(&r));
}
