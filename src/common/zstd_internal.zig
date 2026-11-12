//! The format's constants and code tables, shared by the compressor's
//! parts, from the original's zstd_internal.h.

pub const opt_num = 1 << 12;
/// The number of repeat offsets.
pub const rep_num = 3;
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
