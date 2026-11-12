//! Bit streams, from the original's bitstream.h. The entropy coders write a
//! stream forward with `CStream`, and a decoder reads it backward with
//! `DStream`, so the first bits written are the last read. The reader is
//! here for the decoder of compressed Huffman weights in entropy_common.zig.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const assert = std.debug.assert;
const Error = @import("../error.zig").Error;

/// `BitContainerType`: the register bits gather in before a flush.
pub const Container = usize;
const container_bits = @bitSizeOf(Container);
const container_bytes = @sizeOf(Container);
const ShiftInt = std.math.Log2Int(Container);
const register_mask: u32 = container_bits - 1;

/// The fewest bits a full reload leaves in the register.
pub const accumulator_min: u32 = if (container_bits == 32) 25 else 57;

/// `BIT_mask`: the low `n` bits set, for `n` up to 31.
pub const mask = blk: {
    var table: [32]u32 = undefined;
    for (&table, 0..) |*entry, n| entry.* = (@as(u32, 1) << n) - 1;
    break :blk table;
};

/// Whether `getLowerBits` masks with BMI2's `bzhi`, as the original does
/// when it is built for a BMI2 target with its intrinsics.
const lower_bits_bzhi = build_options.intrinsics and builtin.cpu.arch == .x86_64 and
    std.Target.x86.featureSetHas(builtin.cpu.features, .bmi2);

/// `BIT_getLowerBits`: the low `nb_bits` bits of `value`, for `nb_bits`
/// up to 31.
inline fn getLowerBits(value: Container, nb_bits: u32) Container {
    assert(nb_bits < mask.len);
    // The compiler turns this into `bzhi`, which needs no table load.
    if (lower_bits_bzhi) return value & ((@as(Container, 1) << @intCast(nb_bits)) - 1);
    return value & mask[nb_bits];
}

/// `ZSTD_highbit32`: the position of the highest set bit of `value`.
pub fn highbit32(value: u32) u32 {
    assert(value != 0);
    return 31 - @as(u32, @clz(value));
}

/// `BIT_CStream_t`: a stream written forward into a caller's buffer, which
/// it never writes past. Its pointers are valid while that buffer is.
pub const CStream = struct {
    bit_container: Container,
    bit_pos: u32,
    start_ptr: [*]u8,
    ptr: [*]u8,
    /// The last position a whole container can be written at.
    end_ptr: [*]u8,

    /// `BIT_initCStream`: `dst` must be longer than a container.
    pub fn init(dst: []u8) Error!CStream {
        if (dst.len <= container_bytes) return error.DstSizeTooSmall;
        return .{
            .bit_container = 0,
            .bit_pos = 0,
            .start_ptr = dst.ptr,
            .ptr = dst.ptr,
            .end_ptr = dst.ptr + dst.len - container_bytes,
        };
    }

    /// `BIT_addBits`: adds the low `nb_bits` bits of `value`, up to 31. The
    /// caller flushes before the register overflows.
    pub inline fn addBits(bit_c: *CStream, value: Container, nb_bits: u32) void {
        assert(nb_bits + bit_c.bit_pos < container_bits);
        bit_c.bit_container |= getLowerBits(value, nb_bits) << @intCast(bit_c.bit_pos);
        bit_c.bit_pos += nb_bits;
    }

    /// `BIT_addBitsFast`: `value` must have no bits set above `nb_bits`.
    pub inline fn addBitsFast(bit_c: *CStream, value: Container, nb_bits: u32) void {
        assert(value >> @intCast(nb_bits) == 0);
        assert(nb_bits + bit_c.bit_pos < container_bits);
        bit_c.bit_container |= value << @intCast(bit_c.bit_pos);
        bit_c.bit_pos += nb_bits;
    }

    /// `BIT_flushBitsFast`: the caller makes sure the buffer has room.
    pub inline fn flushBitsFast(bit_c: *CStream) void {
        const nb_bytes = bit_c.bit_pos >> 3;
        assert(@intFromPtr(bit_c.ptr) <= @intFromPtr(bit_c.end_ptr));
        std.mem.writeInt(Container, bit_c.ptr[0..container_bytes], bit_c.bit_container, .little);
        bit_c.ptr += nb_bytes;
        bit_c.bit_pos &= 7;
        bit_c.bit_container >>= @intCast(nb_bytes * 8);
    }

    /// `BIT_flushBits`: stops at the end of the buffer; `close` reports an
    /// overflow.
    pub inline fn flushBits(bit_c: *CStream) void {
        const nb_bytes = bit_c.bit_pos >> 3;
        assert(@intFromPtr(bit_c.ptr) <= @intFromPtr(bit_c.end_ptr));
        std.mem.writeInt(Container, bit_c.ptr[0..container_bytes], bit_c.bit_container, .little);
        bit_c.ptr += nb_bytes;
        if (@intFromPtr(bit_c.ptr) > @intFromPtr(bit_c.end_ptr)) bit_c.ptr = bit_c.end_ptr;
        bit_c.bit_pos &= 7;
        bit_c.bit_container >>= @intCast(nb_bytes * 8);
    }

    /// `BIT_closeCStream`: adds the end mark and returns the stream's size,
    /// or 0 if it did not fit.
    pub fn close(bit_c: *CStream) usize {
        bit_c.addBitsFast(1, 1);
        bit_c.flushBits();
        if (@intFromPtr(bit_c.ptr) >= @intFromPtr(bit_c.end_ptr)) return 0;
        const size = @intFromPtr(bit_c.ptr) - @intFromPtr(bit_c.start_ptr);
        return size + @intFromBool(bit_c.bit_pos > 0);
    }
};

inline fn readContainer(ptr: [*]const u8) Container {
    return std.mem.readInt(Container, ptr[0..container_bytes], .little);
}

/// `BIT_DStream_status`.
pub const DStreamStatus = enum(u32) {
    /// The register is refilled.
    unfinished = 0,
    /// The buffer is read; bits remain in the register.
    end_of_buffer = 1,
    /// Every bit is read, exactly.
    completed = 2,
    /// More bits were read than the stream holds.
    overflow = 3,
};

/// `BIT_DStream_t`: a stream read backward from a caller's buffer. Its
/// pointers are valid while that buffer is.
pub const DStream = struct {
    bit_container: Container,
    bits_consumed: u32,
    ptr: [*]const u8,
    start: [*]const u8,
    limit_ptr: [*]const u8,

    /// `BIT_initDStream`: `src` is the whole stream, ending in its end mark.
    pub fn init(src: []const u8) Error!DStream {
        if (src.len < 1) return error.SrcSizeWrong;
        var bit_d: DStream = .{
            .bit_container = 0,
            .bits_consumed = 0,
            .ptr = src.ptr,
            .start = src.ptr,
            .limit_ptr = src.ptr + container_bytes,
        };
        const last_byte = src[src.len - 1];
        bit_d.bits_consumed = if (last_byte != 0) 8 - highbit32(last_byte) else 0;
        if (src.len >= container_bytes) {
            bit_d.ptr = src.ptr + src.len - container_bytes;
            bit_d.bit_container = readContainer(bit_d.ptr);
            if (last_byte == 0) return error.Generic;
        } else {
            for (src, 0..) |byte, n| bit_d.bit_container += @as(Container, byte) << @intCast(n * 8);
            if (last_byte == 0) return error.CorruptionDetected;
            bit_d.bits_consumed += @intCast((container_bytes - src.len) * 8);
        }
        return bit_d;
    }

    /// `BIT_lookBits`: the next `nb_bits` bits, up to 31, without consuming
    /// them. Past the stream's start the result is garbage, but the
    /// original's garbage: the shift wraps as its x86-64 code does.
    pub inline fn lookBits(bit_d: *const DStream, nb_bits: u32) Container {
        const start = (container_bits -% bit_d.bits_consumed -% nb_bits) & register_mask;
        const shifted = bit_d.bit_container >> @as(ShiftInt, @intCast(start));
        return shifted & ((@as(Container, 1) << @intCast(nb_bits)) - 1);
    }

    /// `BIT_lookBitsFast`: `nb_bits` must be at least 1.
    pub inline fn lookBitsFast(bit_d: *const DStream, nb_bits: u32) Container {
        assert(nb_bits >= 1);
        const consumed: ShiftInt = @intCast(bit_d.bits_consumed & register_mask);
        const right: ShiftInt = @intCast((container_bits - nb_bits) & register_mask);
        return (bit_d.bit_container << consumed) >> right;
    }

    /// `BIT_readBits`.
    pub inline fn readBits(bit_d: *DStream, nb_bits: u32) Container {
        const value = bit_d.lookBits(nb_bits);
        bit_d.bits_consumed += nb_bits;
        return value;
    }

    /// `BIT_readBitsFast`: `nb_bits` must be at least 1.
    pub inline fn readBitsFast(bit_d: *DStream, nb_bits: u32) Container {
        const value = bit_d.lookBitsFast(nb_bits);
        bit_d.bits_consumed += nb_bits;
        return value;
    }

    /// `BIT_reloadDStream`: refills the register from the buffer, never
    /// reading before its start. Once in overflow a stream stays there,
    /// since `bits_consumed` only grows; the original also points `ptr` at
    /// a zero word then, which nothing reads.
    pub inline fn reload(bit_d: *DStream) DStreamStatus {
        if (bit_d.bits_consumed > container_bits) return .overflow;
        assert(@intFromPtr(bit_d.ptr) >= @intFromPtr(bit_d.start));
        if (@intFromPtr(bit_d.ptr) >= @intFromPtr(bit_d.limit_ptr)) {
            bit_d.ptr -= bit_d.bits_consumed >> 3;
            bit_d.bits_consumed &= 7;
            bit_d.bit_container = readContainer(bit_d.ptr);
            return .unfinished;
        }
        if (bit_d.ptr == bit_d.start) {
            if (bit_d.bits_consumed < container_bits) return .end_of_buffer;
            return .completed;
        }
        var nb_bytes = bit_d.bits_consumed >> 3;
        var result: DStreamStatus = .unfinished;
        const available = @intFromPtr(bit_d.ptr) - @intFromPtr(bit_d.start);
        if (available < nb_bytes) {
            nb_bytes = @intCast(available);
            result = .end_of_buffer;
        }
        bit_d.ptr -= nb_bytes;
        bit_d.bits_consumed -= nb_bytes * 8;
        bit_d.bit_container = readContainer(bit_d.ptr);
        return result;
    }

    /// `BIT_endOfDStream`: whether every bit was read, exactly.
    pub fn endOfStream(bit_d: *const DStream) bool {
        return bit_d.ptr == bit_d.start and bit_d.bits_consumed == container_bits;
    }
};

// --------------------------------------------------------
// Tests
// --------------------------------------------------------

const testing = std.testing;

test "a written stream reads back in reverse" {
    var buffer: [64]u8 = undefined;
    var bit_c = try CStream.init(&buffer);
    const values = [_]u32{ 5, 0, 1023, 77, 1, 0x1FFFF };
    const widths = [_]u32{ 3, 1, 10, 7, 1, 17 };
    for (values, widths) |value, width| {
        bit_c.addBits(value, width);
        bit_c.flushBits();
    }
    const size = bit_c.close();
    try testing.expect(size > 0);

    var bit_d = try DStream.init(buffer[0..size]);
    var n: usize = values.len;
    while (n > 0) {
        n -= 1;
        try testing.expectEqual(@as(Container, values[n]), bit_d.readBits(widths[n]));
        _ = bit_d.reload();
    }
    try testing.expect(bit_d.endOfStream());
}

test "a stream too large for its buffer closes to 0" {
    var buffer: [container_bytes + 1]u8 = undefined;
    var bit_c = try CStream.init(&buffer);
    for (0..container_bytes) |_| {
        bit_c.addBits(0xFF, 8);
        bit_c.flushBits();
    }
    try testing.expectEqual(@as(usize, 0), bit_c.close());
    try testing.expectError(error.DstSizeTooSmall, CStream.init(buffer[0..container_bytes]));
}
