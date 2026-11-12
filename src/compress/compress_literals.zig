//! The literals section of a compressed block, from the original's
//! zstd_compress_literals.c: raw, one byte repeated, or Huffman-coded with a
//! new table or the previous block's.

const std = @import("std");
const assert = std.debug.assert;

const params = @import("../params.zig");
const Error = @import("../error.zig").Error;
const zstd_internal = @import("../common/zstd_internal.zig");
const huf = @import("../common/huf.zig");
const huf_compress = @import("huf_compress.zig");
const compress_internal = @import("compress_internal.zig");

const SymbolEncodingType = zstd_internal.SymbolEncodingType;
const HufCTables = compress_internal.HufCTables;

/// The original's `HUF_OPTIMAL_DEPTH_THRESHOLD`: from this strategy on, the
/// Huffman encoder searches for the table depth that compresses best.
const optimal_depth_threshold: params.Strategy = .btultra;

/// `ZSTD_noCompressLiterals`: writes `src` as raw literals, after a header
/// of 1 to 3 bytes. Returns the size written.
pub fn noCompressLiterals(dst: []u8, src: []const u8) Error!usize {
    const fl_size = literalsHeaderSize(src.len);
    if (src.len + fl_size > dst.len) return error.DstSizeTooSmall;
    writeSimpleHeader(dst, .basic, src.len, fl_size);
    @memcpy(dst[fl_size..][0..src.len], src);
    return src.len + fl_size;
}

fn allBytesIdentical(src: []const u8) bool {
    assert(src.len >= 1);
    const b = src[0];
    for (src[1..]) |byte| {
        if (byte != b) return false;
    }
    return true;
}

/// `ZSTD_compressRleLiteralsBlock`: writes `src`, one byte repeated, as an
/// RLE literals section. `dst` holds at least 4 bytes.
pub fn compressRleLiteralsBlock(dst: []u8, src: []const u8) usize {
    const fl_size = literalsHeaderSize(src.len);
    assert(dst.len >= 4);
    assert(allBytesIdentical(src));
    writeSimpleHeader(dst, .rle, src.len, fl_size);
    dst[fl_size] = src[0];
    return fl_size + 1;
}

/// The header size of a raw or RLE literals section.
fn literalsHeaderSize(src_size: usize) u32 {
    return 1 + @as(u32, @intFromBool(src_size > 31)) + @intFromBool(src_size > 4095);
}

fn writeSimpleHeader(dst: []u8, h_type: SymbolEncodingType, src_size: usize, fl_size: u32) void {
    const t: u32 = @backingInt(h_type);
    switch (fl_size) {
        // 2 - 1 - 5
        1 => dst[0] = @truncate(t + (src_size << 3)),
        // 2 - 2 - 12
        2 => std.mem.writeInt(u16, dst[0..2], @truncate(t + (1 << 2) + (src_size << 4)), .little),
        // 2 - 2 - 20
        3 => std.mem.writeInt(u32, dst[0..4], @truncate(t + (3 << 2) + (src_size << 4)), .little),
        else => unreachable,
    }
}

/// `ZSTD_minLiteralsToCompress`: below this size, literals are not worth a
/// Huffman attempt. 8 bytes at btultra2, twice as many for each faster
/// strategy, up to 64; 6 when the previous table is valid.
fn minLiteralsToCompress(strategy: params.Strategy, huf_repeat: huf.Repeat) usize {
    const strat: u32 = @backingInt(strategy);
    assert(strat <= 9);
    const shift: u6 = @intCast(@min(9 - strat, 3));
    return if (huf_repeat == .valid) 6 else @as(usize, 8) << shift;
}

/// `ZSTD_compressLiterals`: writes the literals section for `src` and fills
/// `next_huf` with the table the next block may reuse. Huffman failures fall
/// back to raw literals; only a `dst` too small for those is an error.
/// `entropy_workspace` holds `huf.workspace_size` bytes.
pub fn compressLiterals(
    dst: []u8,
    src: []const u8,
    entropy_workspace: []u8,
    prev_huf: *const HufCTables,
    next_huf: *HufCTables,
    strategy: params.Strategy,
    disable_literal_compression: bool,
    suspect_uncompressible: bool,
    bmi2: bool,
) Error!usize {
    const lh_size: usize = 3 + @as(usize, @intFromBool(src.len >= 1 << 10)) +
        @intFromBool(src.len >= 16 << 10);
    var single_stream = src.len < 256;
    var h_type: SymbolEncodingType = .compressed;

    // Assume the existing table is reused.
    next_huf.* = prev_huf.*;

    if (disable_literal_compression) return noCompressLiterals(dst, src);

    // Too small to be worth an attempt.
    if (src.len < minLiteralsToCompress(strategy, prev_huf.repeat_mode)) {
        return noCompressLiterals(dst, src);
    }

    if (dst.len < lh_size + 1) return error.DstSizeTooSmall;
    const c_lit_size: usize = c_lit_size: {
        var repeat = prev_huf.repeat_mode;
        const strat: u32 = @backingInt(strategy);
        const flags: huf.Flags = .{
            .bmi2 = bmi2,
            .prefer_repeat = strat < @backingInt(params.Strategy.lazy) and src.len <= 1024,
            .optimal_depth = strat >= @backingInt(optimal_depth_threshold),
            .suspect_uncompressible = suspect_uncompressible,
        };
        if (repeat == .valid and lh_size == 3) single_stream = true;
        const hufCompress: *const @TypeOf(huf_compress.compress1XRepeat) = if (single_stream)
            &huf_compress.compress1XRepeat
        else
            &huf_compress.compress4XRepeat;
        const result = hufCompress(
            dst[lh_size..],
            src,
            huf.symbol_value_max,
            zstd_internal.lit_huf_log,
            entropy_workspace,
            &next_huf.ctable,
            &repeat,
            flags,
        );
        // The existing table was reused.
        if (repeat != .none) h_type = .repeat;
        break :c_lit_size result catch {
            next_huf.* = prev_huf.*;
            return noCompressLiterals(dst, src);
        };
    };

    const min_gain = compress_internal.minGain(src.len, strategy);
    if (c_lit_size == 0 or c_lit_size >= src.len - min_gain) {
        next_huf.* = prev_huf.*;
        return noCompressLiterals(dst, src);
    }
    if (c_lit_size == 1) {
        // 1 means the alphabet is a single symbol. It can also be a real
        // one-byte size, but only below 8 bytes, so those are checked.
        if (src.len >= 8 or allBytesIdentical(src)) {
            next_huf.* = prev_huf.*;
            return compressRleLiteralsBlock(dst, src);
        }
    }

    // A newly built table.
    if (h_type == .compressed) next_huf.repeat_mode = .check;

    const t: u32 = @backingInt(h_type);
    const src_size: u32 = @intCast(src.len);
    const c_size: u32 = @intCast(c_lit_size);
    switch (lh_size) {
        // 2 - 2 - 10 - 10
        3 => {
            if (!single_stream) assert(src.len >= zstd_internal.min_literals_for_4_streams);
            const lhc = t + (@as(u32, @intFromBool(!single_stream)) << 2) + (src_size << 4) +
                (c_size << 14);
            std.mem.writeInt(u24, dst[0..3], @truncate(lhc), .little);
        },
        // 2 - 2 - 14 - 14
        4 => {
            assert(src.len >= zstd_internal.min_literals_for_4_streams);
            const lhc = t + (2 << 2) + (src_size << 4) + (c_size << 18);
            std.mem.writeInt(u32, dst[0..4], lhc, .little);
        },
        // 2 - 2 - 18 - 18
        5 => {
            assert(src.len >= zstd_internal.min_literals_for_4_streams);
            const lhc = t + (3 << 2) + (src_size << 4) + (c_size << 22);
            std.mem.writeInt(u32, dst[0..4], lhc, .little);
            dst[4] = @truncate(c_size >> 10);
        },
        else => unreachable,
    }
    return lh_size + c_lit_size;
}
