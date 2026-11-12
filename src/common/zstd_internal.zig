//! The format's constants and code tables, shared by the compressor's
//! parts, from the original's zstd_internal.h.

const std = @import("std");

pub const opt_num = 1 << 12;
/// The number of repeat offsets.
pub const rep_num = 3;

/// The alignment of the functions that run the compressor's inner loops (the
/// block compressors, the match searches, the histogram and the entropy
/// coders): a 4 KiB page. A loop that straddles a page boundary misses in the
/// instruction cache on every pass on some CPUs (Zen 5 here, from the cache
/// counters), so where the linker happened to place a function moved its
/// speed by up to 4%. Page-aligned, a function under 4 KiB never crosses a
/// page, and a larger one keeps the same layout within its pages wherever it
/// lands. The cost is padding in the binary, never fetched.
pub const hot_code_align = 4096;
pub const rep_start_value = [rep_num]u32{ 1, 4, 8 };

pub const window_log_absolute_min = 10;
pub const fcs_field_size = [4]usize{ 0, 2, 4, 8 };
pub const did_field_size = [4]usize{ 0, 1, 2, 4 };
/// The size of the magic number.
pub const frame_id_size = 4;
pub const block_header_size = 3;
pub const frame_checksum_size = 4;

pub const BlockType = enum(u2) { raw, rle, compressed, reserved };

pub const min_sequences_size = 1;
/// The smallest compressed block: one byte of literals header, one of sequences.
pub const min_cblock_size = 1 + 1;
pub const min_literals_for_4_streams = 6;

pub const SymbolEncodingType = enum(u2) { basic, rle, compressed, repeat };

pub const long_nb_seq = 0x7F00;
pub const min_match = 3;
pub const lit_bits = 8;
pub const lit_huf_log = 11;
pub const max_lit = (1 << lit_bits) - 1;
pub const max_ml = 52;
pub const max_ll = 35;
pub const default_max_off = 28;
pub const max_off = 31;
pub const max_seq = @max(max_ll, max_ml);
pub const ml_fse_log = 9;
pub const ll_fse_log = 9;
pub const off_fse_log = 8;
pub const max_fse_log = @max(@max(ml_fse_log, ll_fse_log), off_fse_log);
pub const max_ml_bits = 16;
pub const max_ll_bits = 16;
pub const max_huf_header_size = 128;
pub const max_fse_headers_size =
    ((max_ml + 1) * ml_fse_log + (max_ll + 1) * ll_fse_log + (max_off + 1) * off_fse_log + 7) / 8;

pub const ll_bits = [max_ll + 1]u8{
    0,  0,  0,  0,  0, 0,  0,  0,
    0,  0,  0,  0,  0, 0,  0,  0,
    1,  1,  1,  1,  2, 2,  3,  3,
    4,  6,  7,  8,  9, 10, 11, 12,
    13, 14, 15, 16,
};

pub const ll_default_norm = [max_ll + 1]i16{
    4,  3,  2,  2,  2, 2, 2, 2,
    2,  2,  2,  2,  2, 1, 1, 1,
    2,  2,  2,  2,  2, 2, 2, 2,
    2,  3,  2,  1,  1, 1, 1, 1,
    -1, -1, -1, -1,
};
pub const ll_default_norm_log = 6;

pub const ml_bits = [max_ml + 1]u8{
    0,  0,  0,  0,  0,  0, 0,  0,
    0,  0,  0,  0,  0,  0, 0,  0,
    0,  0,  0,  0,  0,  0, 0,  0,
    0,  0,  0,  0,  0,  0, 0,  0,
    1,  1,  1,  1,  2,  2, 3,  3,
    4,  4,  5,  7,  8,  9, 10, 11,
    12, 13, 14, 15, 16,
};

pub const ml_default_norm = [max_ml + 1]i16{
    1,  4,  3,  2,  2,  2, 2,  2,
    2,  1,  1,  1,  1,  1, 1,  1,
    1,  1,  1,  1,  1,  1, 1,  1,
    1,  1,  1,  1,  1,  1, 1,  1,
    1,  1,  1,  1,  1,  1, 1,  1,
    1,  1,  1,  1,  1,  1, -1, -1,
    -1, -1, -1, -1, -1,
};
pub const ml_default_norm_log = 6;

pub const of_default_norm = [default_max_off + 1]i16{
    1,  1,  1,  1,  1,  1, 2, 2,
    2,  1,  1,  1,  1,  1, 1, 1,
    1,  1,  1,  1,  1,  1, 1, 1,
    -1, -1, -1, -1, -1,
};
pub const of_default_norm_log = 5;

pub const wildcopy_overlength = 32;
pub const wildcopy_veclen = 16;

pub const workspace_too_large_factor = 3;
/// The number of calls with an oversized workspace after which it shrinks.
pub const workspace_too_large_max_duration = 128;

pub const BufferMode = enum(u1) {
    /// Input and output are buffered inside the context.
    buffered = 0,
    /// The caller keeps input and output stable between calls.
    stable = 1,
};

/// Copies 16 bytes; the two ranges may overlap.
pub inline fn copy16(dst: [*]u8, src: [*]const u8) void {
    const bytes: [16]u8 = src[0..16].*;
    dst[0..16].* = bytes;
}

/// The original's `ZSTD_overlap_e`.
pub const Overlap = enum {
    /// Source and destination are at least `wildcopy_veclen` bytes apart.
    no_overlap,
    /// The source is before the destination, at least 8 bytes apart.
    src_before_dst,
};

/// `ZSTD_wildcopy`: copies `length` bytes in 16-byte steps (8-byte steps for
/// close overlapping ranges), so it may read and write up to
/// `wildcopy_overlength` bytes past the end of both ranges.
pub inline fn wildcopy(dst: [*]u8, src: [*]const u8, length: isize, comptime overlap: Overlap) void {
    const diff = @as(isize, @bitCast(@intFromPtr(dst))) -% @as(isize, @bitCast(@intFromPtr(src)));
    var ip = src;
    var op = dst;
    const oend = @intFromPtr(op) +% @as(usize, @bitCast(length));
    if (overlap == .src_before_dst and diff < wildcopy_veclen) {
        while (true) {
            const bytes: [8]u8 = ip[0..8].*;
            op[0..8].* = bytes;
            op += 8;
            ip += 8;
            if (@intFromPtr(op) >= oend) break;
        }
    } else {
        std.debug.assert(diff >= wildcopy_veclen or diff <= -wildcopy_veclen);
        // The first copy is on its own: the length is almost always short.
        copy16(op, ip);
        if (16 >= length) return;
        op += 16;
        ip += 16;
        while (true) {
            copy16(op, ip);
            op += 16;
            ip += 16;
            copy16(op, ip);
            op += 16;
            ip += 16;
            if (@intFromPtr(op) >= oend) break;
        }
    }
}
