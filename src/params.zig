//! The compressor's public parameter types and limits, from the original's
//! zstd.h. Enums keep the original's values, so a parameter set converts to
//! and from the original's by value.

const std = @import("std");

pub const version_major = 1;
pub const version_minor = 5;
pub const version_release = 7;
/// The version of the original this port tracks, as `ZSTD_versionNumber` gives it.
pub const version_number = version_major * 100 * 100 + version_minor * 100 + version_release;
pub const version_string = "1.5.7";

/// The level a level of 0 selects.
pub const clevel_default = 3;

pub const magic_number: u32 = 0xFD2FB528;
pub const magic_dictionary: u32 = 0xEC30A437;
pub const magic_skippable_start: u32 = 0x184D2A50;
pub const magic_skippable_mask: u32 = 0xFFFFFFF0;

pub const block_size_log_max = 17;
pub const block_size_max = 1 << block_size_log_max;

pub const content_size_unknown: u64 = std.math.maxInt(u64);
pub const content_size_error: u64 = std.math.maxInt(u64) - 1;

pub const frame_header_size_max = 18;
pub const skippable_header_size = 8;

pub fn frameHeaderSizeMin(format: Format) usize {
    return if (format == .zstd1) 6 else 2;
}

pub const window_log_max_32 = 30;
pub const window_log_max_64 = 31;
pub const window_log_max: u32 = if (@sizeOf(usize) == 4) window_log_max_32 else window_log_max_64;
pub const window_log_min = 10;
pub const hash_log_max: u32 = if (window_log_max < 30) window_log_max else 30;
pub const hash_log_min = 6;
pub const chain_log_max_32 = 29;
pub const chain_log_max_64 = 30;
pub const chain_log_max: u32 = if (@sizeOf(usize) == 4) chain_log_max_32 else chain_log_max_64;
pub const chain_log_min = hash_log_min;
pub const search_log_max = window_log_max - 1;
pub const search_log_min = 1;
/// Only for `Strategy.fast`; other strategies are limited to 6.
pub const min_match_max = 7;
/// Only for `Strategy.btopt` and stronger; faster strategies are limited to 4.
pub const min_match_min = 3;
pub const target_length_max = block_size_max;
pub const target_length_min = 0;
pub const strategy_min = Strategy.fast;
pub const strategy_max = Strategy.btultra2;
/// The smallest maximum block size; below it, `compressBound` is not a bound.
pub const block_size_max_min = 1 << 10;

pub const overlap_log_min = 0;
pub const overlap_log_max = 9;
pub const window_log_limit_default = 27;

pub const ldm_hash_log_min = hash_log_min;
pub const ldm_hash_log_max = hash_log_max;
pub const ldm_min_match_min = 4;
pub const ldm_min_match_max = 4096;
pub const ldm_bucket_size_log_min = 1;
pub const ldm_bucket_size_log_max = 8;
pub const ldm_hash_rate_log_min = 0;
pub const ldm_hash_rate_log_max = window_log_max - hash_log_min;

pub const target_cblock_size_min = 1340;
pub const target_cblock_size_max = block_size_max;
pub const src_size_hint_min = 0;
pub const src_size_hint_max = std.math.maxInt(c_int);

pub const block_splitter_level_max = 6;

/// The match finders, from fastest to strongest. As in the original, other
/// values can be held: 0 in a parameter set leaves the strategy to the
/// level, and anything else outside 1 to 9 is refused where it is checked.
pub const Strategy = enum(u32) {
    fast = 1,
    dfast = 2,
    greedy = 3,
    lazy = 4,
    lazy2 = 5,
    btlazy2 = 6,
    btopt = 7,
    btultra = 8,
    btultra2 = 9,
    _,
};

/// The original's `ZSTD_compressionParameters`.
pub const CompressionParameters = struct {
    window_log: u32,
    chain_log: u32,
    hash_log: u32,
    search_log: u32,
    min_match: u32,
    target_length: u32,
    strategy: Strategy,
};

/// The original's `ZSTD_frameParameters`.
pub const FrameParameters = struct {
    /// Write the content size into the frame header when it is known.
    content_size_flag: bool = true,
    /// Write a 32-bit checksum of the content at the end of the frame.
    checksum_flag: bool = false,
    /// Leave the dictionary id out of the frame header.
    no_dict_id_flag: bool = false,
};

/// The original's `ZSTD_parameters`.
pub const Parameters = struct {
    cparams: CompressionParameters,
    fparams: FrameParameters,
};

/// The original's `ZSTD_cParameter`, with its values.
pub const CParameter = enum(u32) {
    compression_level = 100,
    window_log = 101,
    hash_log = 102,
    chain_log = 103,
    search_log = 104,
    min_match = 105,
    target_length = 106,
    strategy = 107,
    target_cblock_size = 130,
    enable_long_distance_matching = 160,
    ldm_hash_log = 161,
    ldm_min_match = 162,
    ldm_bucket_size_log = 163,
    ldm_hash_rate_log = 164,
    content_size_flag = 200,
    checksum_flag = 201,
    dict_id_flag = 202,
    nb_workers = 400,
    job_size = 401,
    overlap_log = 402,
    rsyncable = 500,
    format = 10,
    force_max_window = 1000,
    force_attach_dict = 1001,
    literal_compression_mode = 1002,
    src_size_hint = 1004,
    enable_dedicated_dict_search = 1005,
    stable_in_buffer = 1006,
    stable_out_buffer = 1007,
    block_delimiters = 1008,
    validate_sequences = 1009,
    split_after_sequences = 1010,
    use_row_match_finder = 1011,
    deterministic_ref_prefix = 1012,
    prefetch_cdict_tables = 1013,
    enable_seq_producer_fallback = 1014,
    max_block_size = 1015,
    repcode_resolution = 1016,
    block_splitter_level = 1017,
};

/// The original's `ZSTD_bounds`, without its error field: a parameter with
/// no bounds is an error.
pub const Bounds = struct {
    lower: i32,
    upper: i32,
};

pub const ResetDirective = enum(u32) {
    session_only = 1,
    parameters = 2,
    session_and_parameters = 3,
};

pub const EndDirective = enum(u32) {
    /// Collect more data; the encoder decides when to output.
    @"continue" = 0,
    /// Flush every block so far; the frame stays open.
    flush = 1,
    /// Flush everything and close the frame.
    end = 2,
};

/// The input of a streaming call: the call reads `src[pos..]` and moves `pos`.
pub const InBuffer = struct {
    src: []const u8,
    pos: usize = 0,
};

/// The output of a streaming call: the call writes from `dst[pos..]` and moves `pos`.
pub const OutBuffer = struct {
    dst: []u8,
    pos: usize = 0,
};

pub const Format = enum(u32) {
    /// The frame format with its magic number.
    zstd1 = 0,
    /// The frame format without its 4-byte magic number.
    zstd1_magicless = 1,
};

pub const DictLoadMethod = enum(u32) {
    /// The dictionary is copied: the caller may free it after the call.
    by_copy = 0,
    /// The dictionary is referenced: it must outlive every use of the result.
    by_ref = 1,
};

pub const DictContentType = enum(u32) {
    /// A dictionary with the dictionary magic number is a full dictionary;
    /// anything else is raw content.
    auto = 0,
    raw_content = 1,
    /// Refuse anything that is not a full dictionary.
    full_dict = 2,
};

pub const DictAttachPref = enum(u32) {
    default = 0,
    force_attach = 1,
    force_copy = 2,
    force_load = 3,
};

/// The original's `ZSTD_ParamSwitch_e`.
pub const ParamSwitch = enum(u32) {
    auto = 0,
    enable = 1,
    disable = 2,
};

/// The original's `ZSTD_frameProgression`.
pub const FrameProgression = struct {
    ingested: u64 = 0,
    consumed: u64 = 0,
    produced: u64 = 0,
    flushed: u64 = 0,
    current_job_id: u32 = 0,
    nb_active_workers: u32 = 0,
};

/// One sequence, as the sequence API takes and gives them: `lit_length`
/// literals, then a match of `match_length` bytes at `offset` back. A
/// sequence with `offset` and `match_length` 0 is a block delimiter.
pub const Sequence = extern struct {
    offset: u32,
    lit_length: u32,
    match_length: u32,
    /// The repeat offset the match used, 1 to 3, or 0 for a new offset.
    rep: u32,
};

pub const SequenceFormat = enum(u32) {
    no_block_delimiters = 0,
    explicit_block_delimiters = 1,
};
