//! The compressor's shared types and helpers, from the original's
//! zstd_compress_internal.h: the contexts, the sequence store, the match
//! state and its window, the hashes, the match length counters and the
//! repeat-offset bookkeeping that every match finder uses.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");

const params = @import("../params.zig");
const Error = @import("../error.zig").Error;
const zstd_internal = @import("../common/zstd_internal.zig");
const fse = @import("../common/fse.zig");
const huf = @import("../common/huf.zig");
const Cwksp = @import("cwksp.zig").Cwksp;

const assert = std.debug.assert;
const native_endian = builtin.cpu.arch.endian();
const rep_num = zstd_internal.rep_num;
const min_match = zstd_internal.min_match;

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

pub const search_strength = 8;
pub const hash_read_size = 8;
/// For btlazy2, index 1 marks an unsorted candidate. A real successor at
/// index 1 could be taken for it; the candidate is then only sorted again.
/// The mark cannot be misread after a table is reused by another strategy.
pub const dubt_unsorted_mark = 1;

/// The pre-splitter's workspace size, from zstd_preSplit.h.
pub const slipblock_workspace_size = 8208;

pub const compress_sequences_workspace_size = @sizeOf(u32) * (zstd_internal.max_seq + 2);
pub const entropy_workspace_size = huf.workspace_size + compress_sequences_workspace_size;
pub const tmp_workspace_size = @max(entropy_workspace_size, slipblock_workspace_size);

/// Indexes start above 1 so that the first position is valid and above
/// `dubt_unsorted_mark`.
pub const window_start_index = 2;
/// The row-based match finder's cache of hashes.
pub const row_hash_cache_size = 8;
pub const ldm_batch_size = 64;
pub const opt_size = zstd_internal.opt_num + 3;
pub const max_nb_block_splits = 196;
pub const roll_hash_char_offset = 10;

/// The largest current index allowed. In 32-bit mode it stays below 2 GB, away
/// from signed overflow; in 64-bit mode, adding the largest job size (512 MB)
/// still fits in a u32 index.
pub const current_max: u32 = if (@sizeOf(usize) == 8) 3500 << 20 else 2000 << 20;
/// The largest chunk before overflow correction must run again.
pub const chunk_size_max: u32 = std.math.maxInt(u32) - current_max;

/// Runs the overflow correction far more often than needed, for tests.
pub const window_overflow_correct_frequently = build_options.overflow_correct_frequently;

pub const short_cache_tag_bits = 8;
pub const short_cache_tag_mask: u32 = (1 << short_cache_tag_bits) - 1;

// ---------------------------------------------------------------------------
// Placeholders for types defined in files not yet ported
// ---------------------------------------------------------------------------

/// The original's `ZSTD_CDict_s`, defined in zstd_compress.c.
pub const CDict = opaque {};
/// The original's `ZSTD_threadPool` (POOL_ctx), from pool.c.
pub const ThreadPool = @import("../common/pool.zig").ThreadPool;
/// The original's `ZSTDMT_CCtx`, from zstdmt_compress.c.
pub const ZstdmtCCtx = opaque {};

/// The original's `ZSTD_sequenceProducer_F`: an external match finder that
/// writes up to `out_seqs_capacity` sequences for `src` and returns their
/// number, or a value above `sequence_producer_error`.
pub const SequenceProducer = *const fn (
    state: ?*anyopaque,
    out_seqs: [*]params.Sequence,
    out_seqs_capacity: usize,
    src: [*]const u8,
    src_size: usize,
    dict: ?[*]const u8,
    dict_size: usize,
    compression_level: i32,
    window_size: usize,
) callconv(.c) usize;

// ---------------------------------------------------------------------------
// Context memory management
// ---------------------------------------------------------------------------

pub const CompressionStage = enum(u32) { created = 0, init, ongoing, ending };
pub const CStreamStage = enum(u32) { init = 0, load, flush };

/// A dictionary for one frame only (`refPrefix`). `dict` is the caller's
/// buffer, valid until the next call that resets the context.
pub const PrefixDict = struct {
    dict: ?[*]const u8 = null,
    dict_size: usize = 0,
    dict_content_type: params.DictContentType = .auto,
};

pub const LocalDict = struct {
    /// The context's own copy of the dictionary, when loaded by copy.
    dict_buffer: ?[*]u8 = null,
    /// The dictionary: `dict_buffer`, or the caller's buffer when loaded by
    /// reference, valid until the dictionary is replaced or the context reset.
    dict: ?[*]const u8 = null,
    dict_size: usize = 0,
    dict_content_type: params.DictContentType = .auto,
    cdict: ?*CDict = null,
};

pub const HufCTables = struct {
    ctable: [huf.ctableSizeSt(255)]huf.CElt,
    repeat_mode: huf.Repeat,
};

pub const FseCTables = struct {
    offcode_ctable: [fse.ctableSizeU32(zstd_internal.off_fse_log, zstd_internal.max_off)]fse.CTable,
    matchlength_ctable: [fse.ctableSizeU32(zstd_internal.ml_fse_log, zstd_internal.max_ml)]fse.CTable,
    litlength_ctable: [fse.ctableSizeU32(zstd_internal.ll_fse_log, zstd_internal.max_ll)]fse.CTable,
    offcode_repeat_mode: fse.Repeat,
    matchlength_repeat_mode: fse.Repeat,
    litlength_repeat_mode: fse.Repeat,
};

pub const EntropyCTables = struct {
    huf: HufCTables,
    fse: FseCTables,
};

// ---------------------------------------------------------------------------
// Sequences
// ---------------------------------------------------------------------------

pub const SeqDef = extern struct {
    /// The offset plus `rep_num`, or a repeat code 1 to 3.
    off_base: u32,
    lit_length: u16,
    /// The match length minus `min_match`.
    ml_base: u16,
};

/// Which length of one sequence, if any, is larger than a u16 holds.
pub const LongLengthType = enum(u32) {
    none = 0,
    literal_length = 1,
    match_length = 2,
};

/// The sequences and literals of one block, in buffers the workspace holds.
/// Every pointer is into the context's workspace and valid until the next
/// workspace reset.
pub const SeqStore = struct {
    sequences_start: [*]SeqDef = undefined,
    /// One past the last sequence.
    sequences: [*]SeqDef = undefined,
    lit_start: [*]u8 = undefined,
    /// One past the last literal.
    lit: [*]u8 = undefined,
    ll_code: [*]u8 = undefined,
    ml_code: [*]u8 = undefined,
    of_code: [*]u8 = undefined,
    max_nb_seq: usize = 0,
    max_nb_lit: usize = 0,

    /// One sequence may have a literal or match length above 0xFFFF; its
    /// stored length then lacks the 0x10000 these two fields add back.
    long_length_type: LongLengthType = .none,
    /// The index of the sequence with the long length.
    long_length_pos: u32 = 0,
};

/// `ZSTD_resetSeqStore`: empties the store.
pub fn resetSeqStore(seq_store: *SeqStore) void {
    seq_store.lit = seq_store.lit_start;
    seq_store.sequences = seq_store.sequences_start;
    seq_store.long_length_type = .none;
}

pub const SequenceLength = struct {
    lit_length: u32,
    match_length: u32,
};

/// `ZSTD_getSequenceLength`: the lengths of `seq`, with the long length and
/// `min_match` added back.
pub fn getSequenceLength(seq_store: *const SeqStore, seq: *const SeqDef) SequenceLength {
    var seq_len: SequenceLength = .{
        .lit_length = seq.lit_length,
        .match_length = @as(u32, seq.ml_base) + min_match,
    };
    const index = (@intFromPtr(seq) - @intFromPtr(seq_store.sequences_start)) / @sizeOf(SeqDef);
    if (seq_store.long_length_pos == index) {
        if (seq_store.long_length_type == .literal_length) seq_len.lit_length += 0x10000;
        if (seq_store.long_length_type == .match_length) seq_len.match_length += 0x10000;
    }
    return seq_len;
}

// ---------------------------------------------------------------------------
// Entropy statistics
// ---------------------------------------------------------------------------

/// The literals block type and Huffman tree description of a super-block.
pub const HufCTablesMetadata = struct {
    h_type: zstd_internal.SymbolEncodingType,
    huf_des_buffer: [zstd_internal.max_huf_header_size]u8,
    huf_des_size: usize,
};

/// The sequence encoding types and FSE tables of a super-block.
pub const FseCTablesMetadata = struct {
    ll_type: zstd_internal.SymbolEncodingType,
    of_type: zstd_internal.SymbolEncodingType,
    ml_type: zstd_internal.SymbolEncodingType,
    fse_tables_buffer: [zstd_internal.max_fse_headers_size]u8,
    fse_tables_size: usize,
    /// The size of the last table header, for the 1.3.4 decoder's limit
    /// (see `entropyCompressSeqStoreInternal`).
    last_count_size: usize,
};

pub const EntropyCTablesMetadata = struct {
    huf_metadata: HufCTablesMetadata,
    fse_metadata: FseCTablesMetadata,
};

// ---------------------------------------------------------------------------
// Compression internals
// ---------------------------------------------------------------------------

pub const Match = struct {
    /// The offset in `storeSeq`'s off_base form.
    off: u32,
    len: u32,
};

/// `rawSeq`.
pub const RawSeq = struct {
    offset: u32,
    lit_length: u32,
    match_length: u32,
};

/// `RawSeqStore_t`: sequences found ahead of the block compressor (long
/// distance matching, external sequences). `seq` is a buffer the context
/// holds, or the caller's for referenced external sequences, valid until the
/// next reset.
pub const RawSeqStore = struct {
    seq: ?[*]RawSeq = null,
    /// The index in `seq` where reading stopped; at most `size`.
    pos: usize = 0,
    /// Where reading stopped inside `seq[pos]`, at most its literal plus
    /// match length.
    pos_in_sequence: usize = 0,
    size: usize = 0,
    capacity: usize = 0,
};

/// `kNullRawSeqStore`.
pub const null_raw_seq_store: RawSeqStore = .{};

/// `ZSTD_optimal_t`.
pub const Optimal = struct {
    /// The price from the start of the segment to this position.
    price: i32,
    /// The offset of the previous match.
    off: u32,
    /// The length of the previous match.
    mlen: u32,
    /// The literals since the previous match.
    litlen: u32,
    /// The repeat offsets after the previous match.
    rep: [rep_num]u32,
};

/// `ZSTD_OptPrice_e`.
pub const OptPrice = enum(u32) { dynamic = 0, predef };

/// `optState_t`: the optimal parser's statistics. Its tables are in the
/// context's workspace, valid until the next workspace reset.
pub const OptState = struct {
    /// 256 literal counts.
    lit_freq: [*]u32 = undefined,
    /// `max_ll + 1` literal length code counts.
    lit_length_freq: [*]u32 = undefined,
    /// `max_ml + 1` match length code counts.
    match_length_freq: [*]u32 = undefined,
    /// `max_off + 1` offset code counts.
    off_code_freq: [*]u32 = undefined,
    /// `opt_size` matches found.
    match_table: [*]Match = undefined,
    /// `opt_size` positions the parser tracks.
    price_table: [*]Optimal = undefined,

    lit_sum: u32 = 0,
    lit_length_sum: u32 = 0,
    match_length_sum: u32 = 0,
    off_code_sum: u32 = 0,
    lit_sum_base_price: u32 = 0,
    lit_length_sum_base_price: u32 = 0,
    match_length_sum_base_price: u32 = 0,
    off_code_sum_base_price: u32 = 0,
    price_type: OptPrice = .dynamic,
    /// Statistics from a dictionary, the previous block's entropy tables.
    symbol_costs: ?*const EntropyCTables = null,
    literal_compression_mode: params.ParamSwitch = .auto,
};

/// `ZSTD_compressedBlockState_t`.
pub const CompressedBlockState = struct {
    entropy: EntropyCTables,
    rep: [rep_num]u32,
};

/// `ZSTD_window_t`: the input seen so far, as indexes from `base`.
///
/// Indexes from `dict_limit` up are in the current prefix, at `base + index`;
/// from `low_limit` to `dict_limit` they are in the external dictionary, at
/// `dict_base + index`. `base` and `dict_base` point before their buffers and
/// are only offset by indexes at or above the limits. Both, and `next_src`,
/// point into the caller's input (or a buffer of the context), valid until the
/// next call that resets the context.
pub const Window = struct {
    /// The end of the last block: a block starting here continues the prefix.
    next_src: [*]const u8,
    base: [*]const u8,
    dict_base: [*]const u8,
    /// Below this index, data is in the external dictionary.
    dict_limit: u32,
    /// Below this index, there is no valid data.
    low_limit: u32,
    /// The number of overflow corrections since `init`.
    nb_overflow_corrections: u32,

    /// The address `init` points `base` at: indexes then start at
    /// `window_start_index`, as after any later reset.
    const empty: *const [1:0]u8 = " ";

    /// `ZSTD_window_init`.
    pub fn init(window: *Window) void {
        window.* = .{
            .base = empty,
            .dict_base = empty,
            .dict_limit = window_start_index,
            .low_limit = window_start_index,
            .next_src = @as([*]const u8, empty) + window_start_index,
            .nb_overflow_corrections = 0,
        };
    }

    /// `ZSTD_window_clear`: forgets the history, keeping the indexes.
    pub fn clear(window: *Window) void {
        const end: u32 = @intCast(@intFromPtr(window.next_src) - @intFromPtr(window.base));
        window.low_limit = end;
        window.dict_limit = end;
    }

    /// `ZSTD_window_isEmpty`.
    pub fn isEmpty(window: Window) bool {
        return window.dict_limit == window_start_index and
            window.low_limit == window_start_index and
            @intFromPtr(window.next_src) -% @intFromPtr(window.base) == window_start_index;
    }

    /// `ZSTD_window_hasExtDict`: whether the external dictionary is not empty.
    pub fn hasExtDict(window: Window) bool {
        return window.low_limit < window.dict_limit;
    }

    /// `ZSTD_window_canOverflowCorrect`: whether the indexes are large enough
    /// for an overflow correction that costs no compression ratio.
    pub fn canOverflowCorrect(
        window: Window,
        cycle_log: u32,
        max_dist: u32,
        loaded_dict_end: u32,
        src: [*]const u8,
    ) bool {
        const cycle_size = @as(u32, 1) << @intCast(cycle_log);
        const curr: u32 = @truncate(@intFromPtr(src) -% @intFromPtr(window.base));
        const min_index_to_overflow_correct = cycle_size + @max(max_dist, cycle_size) +
            window_start_index;
        // Back off with each correction, so they do not cost too much time.
        // An overflow here does not matter: the index stays at least the minimum.
        const adjustment = window.nb_overflow_corrections +% 1;
        const adjusted_index = @max(
            min_index_to_overflow_correct *% adjustment,
            min_index_to_overflow_correct,
        );
        const index_large_enough = curr > adjusted_index;
        // Correct early only once the dictionary is out of reach anyway.
        const dictionary_invalidated = curr > max_dist +% loaded_dict_end;
        return index_large_enough and dictionary_invalidated;
    }

    /// `ZSTD_window_needOverflowCorrection`: whether the indexes are getting
    /// too large.
    pub fn needOverflowCorrection(
        window: Window,
        cycle_log: u32,
        max_dist: u32,
        loaded_dict_end: u32,
        src: [*]const u8,
        src_end: [*]const u8,
    ) bool {
        const curr: u32 = @truncate(@intFromPtr(src_end) -% @intFromPtr(window.base));
        if (window_overflow_correct_frequently) {
            if (window.canOverflowCorrect(cycle_log, max_dist, loaded_dict_end, src)) return true;
        }
        return curr > current_max;
    }

    /// `ZSTD_window_correctOverflow`: lowers the indexes and returns the
    /// correction, which the caller subtracts from every stored index.
    ///
    /// The low `cycle_log` bits of every index stay the same, and every index
    /// up to `max_dist` back stays valid.
    pub fn correctOverflow(window: *Window, cycle_log: u32, max_dist: u32, src: [*]const u8) u32 {
        // The correction is large enough (about 1 << 29), and afterwards the
        // current index is below (1 << chain_log) + (1 << window_log), so
        // neither `ip + chunk_size_max - base` nor `low_limit + window size`
        // overflows.
        const cycle_size = @as(u32, 1) << @intCast(cycle_log);
        const cycle_mask = cycle_size - 1;
        const curr: u32 = @truncate(@intFromPtr(src) -% @intFromPtr(window.base));
        const current_cycle = curr & cycle_mask;
        // Keeps new_current - max_dist >= window_start_index.
        const current_cycle_correction: u32 = if (current_cycle < window_start_index)
            @max(cycle_size, window_start_index)
        else
            0;
        const new_current = current_cycle + current_cycle_correction + @max(max_dist, cycle_size);
        const correction = curr - new_current;
        // max_dist must be a power of two so that the chains and trees keep
        // their low bits.
        assert(max_dist & (max_dist -% 1) == 0);
        assert(curr & cycle_mask == new_current & cycle_mask);
        if (!window_overflow_correct_frequently) assert(correction > 1 << 28);

        window.base = @ptrFromInt(@intFromPtr(window.base) +% correction);
        window.dict_base = @ptrFromInt(@intFromPtr(window.dict_base) +% correction);
        if (window.low_limit < correction + window_start_index) {
            window.low_limit = window_start_index;
        } else {
            window.low_limit -= correction;
        }
        if (window.dict_limit < correction + window_start_index) {
            window.dict_limit = window_start_index;
        } else {
            window.dict_limit -= correction;
        }

        // The whole window stays reachable, and the limits did not underflow.
        assert(new_current >= max_dist);
        assert(new_current - max_dist >= window_start_index);
        assert(window.low_limit <= new_current);
        assert(window.dict_limit <= new_current);

        window.nb_overflow_corrections += 1;
        return correction;
    }

    /// `ZSTD_window_enforceMaxDist`: raises `low_limit` so that
    /// `(block_end - base) - low_limit == max_dist + loaded_dict_end`, so an
    /// index is valid exactly when it is at or above `low_limit`. Runs before
    /// each block.
    ///
    /// `loaded_dict_end` is null when no dictionary is in use. A dictionary may
    /// be referenced whole as long as its last byte is in the window; once the
    /// input moves past that, it is invalidated: `loaded_dict_end` and
    /// `dict_match_state` are cleared. In plain dictionary mode the dictionary
    /// is between `low_limit` and `dict_limit`; with a dict match state the
    /// limits are equal and the dictionary is below them, so `forceWindow` and
    /// a dict match state do not go together.
    pub fn enforceMaxDist(
        window: *Window,
        block_end: [*]const u8,
        max_dist: u32,
        loaded_dict_end: ?*u32,
        dict_match_state: ?*?*const MatchState,
    ) void {
        const block_end_idx: u32 = @truncate(@intFromPtr(block_end) -% @intFromPtr(window.base));
        const loaded_end: u32 = if (loaded_dict_end) |end| end.* else 0;
        // Without a dictionary, loaded_end is 0 and the test only keeps the
        // subtraction from underflowing. A copied dictionary's indexes start
        // at 0, so loaded_end is its size; an attached one's are in this
        // window's referential. Either way they compare with block_end_idx.
        if (block_end_idx > max_dist + loaded_end) {
            const new_low_limit = block_end_idx - max_dist;
            if (window.low_limit < new_low_limit) window.low_limit = new_low_limit;
            if (window.dict_limit < window.low_limit) window.dict_limit = window.low_limit;
            if (loaded_dict_end) |end| end.* = 0;
            if (dict_match_state) |dms| dms.* = null;
        }
    }

    /// `ZSTD_checkDictValidity`: like `enforceMaxDist`, but only invalidates the
    /// dictionary, once the input moves past the window size (`max_dist`).
    /// `loaded_dict_end` is in the referential of `base`.
    pub fn checkDictValidity(
        window: *const Window,
        block_end: [*]const u8,
        max_dist: u32,
        loaded_dict_end: *u32,
        dict_match_state: *?*const MatchState,
    ) void {
        const block_end_idx: u32 = @truncate(@intFromPtr(block_end) -% @intFromPtr(window.base));
        const loaded_end = loaded_dict_end.*;
        assert(block_end_idx >= loaded_end);
        // The dictionary goes for the whole block if the window ends anywhere
        // in it, or when `update` found the segments not contiguous
        // (loaded_end != dict_limit). loaded_end may be 0 with forceWindow,
        // which never uses a dict match state.
        if (block_end_idx > loaded_end + max_dist or loaded_end != window.dict_limit) {
            loaded_dict_end.* = 0;
            dict_match_state.* = null;
        }
    }

    /// `ZSTD_window_update`: appends `src` to the window. If it does not follow
    /// the previous input, the prefix becomes the external dictionary and the
    /// old one is forgotten; where the input overlaps the external dictionary,
    /// the dictionary shrinks. Returns whether `src` was contiguous.
    /// `src` must stay valid as `window` describes it.
    pub fn update(window: *Window, src: []const u8, force_non_contiguous: bool) bool {
        const ip = src.ptr;
        var contiguous = true;
        if (src.len == 0) return contiguous;
        if (ip != window.next_src or force_non_contiguous) {
            const distance_from_base = @intFromPtr(window.next_src) -% @intFromPtr(window.base);
            window.low_limit = window.dict_limit;
            window.dict_limit = @intCast(distance_from_base);
            window.dict_base = window.base;
            window.base = @ptrFromInt(@intFromPtr(ip) -% distance_from_base);
            // Too small an external dictionary is not worth keeping.
            if (window.dict_limit - window.low_limit < hash_read_size) {
                window.low_limit = window.dict_limit;
            }
            contiguous = false;
        }
        window.next_src = ip + src.len;
        // The input overlaps the dictionary: the caller has overwritten it.
        const ip_end = @intFromPtr(ip) + src.len;
        const dict_low = @intFromPtr(window.dict_base) +% window.low_limit;
        const dict_high = @intFromPtr(window.dict_base) +% window.dict_limit;
        if (ip_end > dict_low and @intFromPtr(ip) < dict_high) {
            const high_input_idx = ip_end -% @intFromPtr(window.dict_base);
            const low_limit_max: u32 = if (high_input_idx > window.dict_limit)
                window.dict_limit
            else
                @intCast(high_input_idx);
            window.low_limit = low_limit_max;
        }
        return contiguous;
    }
};

/// The row-based match finder's tags, the hash tables and the optimal
/// parser's state for one context or dictionary. Its tables are in the
/// workspace of the context or dictionary that owns it, valid until that
/// workspace is reset; `dict_match_state` is another dictionary's, valid
/// while that dictionary is attached.
pub const MatchState = struct {
    window: Window = undefined,
    /// The index of the end of the dictionary, in this window's referential;
    /// not 0 while a dictionary is in use and valid. `Window.enforceMaxDist`
    /// and `Window.checkDictValidity` clear it when the dictionary goes out of
    /// reach. A copied (not attached) dictionary's indexes start at 0, so this
    /// is then its size.
    loaded_dict_end: u32 = 0,
    /// The index from which table updates continue.
    next_to_update: u32 = 0,
    /// The log of the table of 3-byte matches; larger is faster, and takes
    /// more memory.
    hash_log3: u32 = 0,

    /// Row-based match finder: the hash log from the number of rows.
    row_hash_log: u32 = 0,
    /// Row-based match finder: the rows of tags and their head indexes.
    tag_table: [*]u8 = undefined,
    /// Row-based match finder: a cache of hashes ahead of the position.
    hash_cache: [row_hash_cache_size]u32 = @splat(0),
    /// Row-based match finder: salts the hashes so the tag table can be
    /// reused without clearing.
    hash_salt: u64 = 0,
    /// Row-based match finder: entropy collected for the next salt.
    hash_salt_entropy: u32 = 0,

    hash_table: [*]u32 = undefined,
    hash_table3: [*]u32 = undefined,
    chain_table: [*]u32 = undefined,

    /// Makes the next window update start a new segment.
    force_non_contiguous: bool = false,

    /// Whether this match state uses the dedicated dictionary search tables.
    dedicated_dict_search: bool = false,
    opt: OptState = .{},
    dict_match_state: ?*const MatchState = null,
    cparams: params.CompressionParameters = undefined,
    ldm_seq_store: ?*const RawSeqStore = null,

    /// Prefetches the dictionary's tables in some dict match state finders.
    /// Set from the context's match state; it has no effect in a dictionary's.
    prefetch_cdict_tables: bool = false,

    /// When false, the lazy match finders insert every position; when true,
    /// only the positions they search, which skips faster over incompressible
    /// data at a small cost in ratio.
    lazy_skipping: bool = false,
};

/// `ZSTD_blockState_t`. The block states are in the context's workspace,
/// valid until the next workspace reset; the two swap after each block.
pub const BlockState = struct {
    prev_cblock: *CompressedBlockState = undefined,
    next_cblock: *CompressedBlockState = undefined,
    match_state: MatchState = .{},
};

/// `ldmEntry_t`.
pub const LdmEntry = struct {
    offset: u32,
    checksum: u32,
};

/// `ldmMatchCandidate_t`. `split` points into the input being compressed and
/// `bucket` into the long distance matcher's hash table, valid for one batch.
pub const LdmMatchCandidate = struct {
    split: [*]const u8,
    hash: u32,
    checksum: u32,
    bucket: [*]LdmEntry,
};

/// `ldmState_t`. Its tables are in the context's workspace, valid until the
/// next workspace reset.
pub const LdmState = struct {
    window: Window = undefined,
    hash_table: [*]LdmEntry = undefined,
    loaded_dict_end: u32 = 0,
    /// The next position to insert at in each bucket.
    bucket_offsets: [*]u8 = undefined,
    split_indices: [ldm_batch_size]usize = undefined,
    match_candidates: [ldm_batch_size]LdmMatchCandidate = undefined,
};

/// `ldmParams_t`.
pub const LdmParams = struct {
    /// `.enable` turns long distance matching on; `.auto` by default.
    enable_ldm: params.ParamSwitch = .auto,
    /// The log of the hash table size.
    hash_log: u32 = 0,
    /// The log of the bucket size, at most 8.
    bucket_size_log: u32 = 0,
    min_match_length: u32 = 0,
    /// The log of the number of positions between entries.
    hash_rate_log: u32 = 0,
    window_log: u32 = 0,
};

/// Collects the sequences of each block for `generateSequences`. `seq_start`
/// is the caller's buffer, valid for that one call.
pub const SeqCollector = struct {
    collect_sequences: bool = false,
    seq_start: [*]params.Sequence = undefined,
    seq_index: usize = 0,
    max_sequences: usize = 0,
};

/// `ZSTD_CCtx_params_s`.
pub const CCtxParams = struct {
    format: params.Format = .zstd1,
    cparams: params.CompressionParameters = undefined,
    fparams: params.FrameParameters = .{},

    compression_level: i32 = 0,
    /// Back-references respect `1 << window_log`, even into a dictionary.
    force_window: bool = false,
    /// The compressed block size to aim for; 0 for none. Not a guarantee.
    target_cblock_size: usize = 0,
    /// The caller's guess of the source size; 0 for none.
    src_size_hint: i32 = 0,

    attach_dict_pref: params.DictAttachPref = .default,
    literal_compression_mode: params.ParamSwitch = .auto,

    // Multithreading, passed on to the multithreaded context.
    nb_workers: i32 = 0,
    job_size: usize = 0,
    overlap_log: i32 = 0,
    rsyncable: bool = false,

    ldm_params: LdmParams = .{},

    enable_dedicated_dict_search: bool = false,

    in_buffer_mode: zstd_internal.BufferMode = .buffered,
    out_buffer_mode: zstd_internal.BufferMode = .buffered,

    // The sequence compression API.
    block_delimiters: params.SequenceFormat = .no_block_delimiters,
    validate_sequences: bool = false,

    /// Splits a block after its sequences are found: more accurate, and
    /// slower than the pre-splitter.
    post_block_splitter: params.ParamSwitch = .auto,
    /// Splits before the sequences are known: 0 is automatic, 1 is off, and
    /// 2 (fastest) to 6 (slowest) spend more time. The highest level works
    /// well with the post-splitter.
    pre_block_splitter_level: i32 = 0,

    max_block_size: usize = 0,

    use_row_match_finder: params.ParamSwitch = .auto,

    /// Loads a dictionary as an external dictionary, never as a prefix.
    deterministic_ref_prefix: bool = false,

    /// The allocator `createCCtxParams` used, for `freeCCtxParams`.
    custom_mem: ?std.mem.Allocator = null,

    prefetch_cdict_tables: params.ParamSwitch = .auto,

    /// Fall back to the internal match finder when the external sequence
    /// producer fails.
    enable_match_finder_fallback: bool = false,

    /// The external sequence producer, set by `registerSequenceProducer`.
    ext_seq_prod_state: ?*anyopaque = null,
    ext_seq_prod_func: ?SequenceProducer = null,

    /// The repeat-code search for external sequences.
    search_for_external_repcodes: params.ParamSwitch = .auto,
};

/// Whether compression goes straight from the caller's input to the
/// caller's output, or through the context's buffers.
pub const BufferedPolicy = enum(u32) { not_buffered, buffered };

/// The block splitter's state, in the workspace.
pub const BlockSplitCtx = struct {
    full_seq_store_chunk: SeqStore,
    first_half_seq_store: SeqStore,
    second_half_seq_store: SeqStore,
    curr_seq_store: SeqStore,
    next_seq_store: SeqStore,

    partitions: [max_nb_block_splits]u32,
    entropy_metadata: EntropyCTablesMetadata,
};

/// `ZSTD_CCtx_s`: a compression context.
pub const CCtx = struct {
    stage: CompressionStage = .created,
    /// The compression parameters (but the window log) or the level changed
    /// in `requested_params`; they go to the multithreaded context, then this
    /// is cleared.
    cparams_changed: bool = false,
    /// Kept for the entropy coders' flags; the port's output does not depend
    /// on BMI2, so it stays false.
    bmi2: bool = false,
    requested_params: CCtxParams = .{},
    applied_params: CCtxParams = .{},
    /// The simple API's parameters, used only inside its top-level calls.
    simple_api_params: CCtxParams = .{},
    dict_id: u32 = 0,
    dict_content_size: usize = 0,

    workspace: Cwksp = .{},
    block_size_max: usize = 0,
    /// The pledged source size plus one, so that 0 means unknown.
    pledged_src_size_plus_one: u64 = 0,
    consumed_src_size: u64 = 0,
    produced_csize: u64 = 0,
    xxh_state: std.hash.XxHash64 = .init(0),
    /// The context's allocator; null for a static context.
    custom_mem: ?std.mem.Allocator = null,
    /// A thread pool the caller owns, valid until it is unset.
    pool: ?*ThreadPool = null,
    /// The size of the caller's buffer for a static context, else 0.
    static_size: usize = 0,
    seq_collector: SeqCollector = .{},
    is_first_block: bool = false,
    initialized: bool = false,

    seq_store: SeqStore = .{},
    ldm_state: LdmState = .{},
    /// The long distance matcher's sequences, in the workspace.
    ldm_sequences: [*]RawSeq = undefined,
    max_nb_ldm_sequences: usize = 0,
    /// External sequences, referenced by `referenceExternalSequences`.
    extern_seq_store: RawSeqStore = .{},
    block_state: BlockState = .{},
    /// Scratch space in place of the stack, aligned for i64; in the workspace.
    tmp_workspace: [*]align(8) u8 = undefined,
    tmp_wksp_size: usize = 0,

    buffered_policy: BufferedPolicy = .not_buffered,

    // Streaming: the buffers are in the workspace.
    in_buff: [*]u8 = undefined,
    in_buff_size: usize = 0,
    in_to_compress: usize = 0,
    in_buff_pos: usize = 0,
    in_buff_target: usize = 0,
    out_buff: [*]u8 = undefined,
    out_buff_size: usize = 0,
    out_buff_content_size: usize = 0,
    out_buff_flushed_size: usize = 0,
    stream_stage: CStreamStage = .init,
    frame_ended: bool = false,

    /// The stable input buffer the next call must pass; its slice is the
    /// caller's buffer, only compared, never read after the call.
    expected_in_buffer: params.InBuffer = .{ .src = &.{} },
    /// Bytes of a stable input buffer reported consumed but not yet compressed.
    stable_in_not_consumed: usize = 0,
    expected_out_buffer_size: usize = 0,

    local_dict: LocalDict = .{},
    /// A dictionary the caller owns, valid until it is unset or the context reset.
    cdict: ?*const CDict = null,
    /// A dictionary for one frame only.
    prefix_dict: PrefixDict = .{},

    mtctx: (if (build_options.multithread) ?*ZstdmtCCtx else void) =
        if (build_options.multithread) null else {},

    block_split_ctx: BlockSplitCtx = undefined,

    /// The external sequence producer's output buffer.
    ext_seq_buf: ?[*]params.Sequence = null,
    ext_seq_buf_capacity: usize = 0,
};

/// `ZSTD_dictTableLoadMethod_e`.
pub const DictTableLoadMethod = enum(u32) { fast, full };

/// `ZSTD_tableFillPurpose_e`.
pub const TableFillPurpose = enum(u32) { for_cctx, for_cdict };

/// `ZSTD_BuildSeqStore_e`.
pub const BuildSeqStore = enum(u32) { compress, no_compress };

/// `ZSTD_dictMode_e`.
pub const DictMode = enum(u32) {
    no_dict = 0,
    ext_dict = 1,
    dict_match_state = 2,
    dedicated_dict_search = 3,
};

/// `ZSTD_CParamMode_e`: what the parameters are chosen and adjusted for.
pub const CParamMode = enum(u32) {
    /// Compression without a dictionary or with an external one: source and
    /// dictionary sizes both count.
    no_attach_dict = 0,
    /// Compression with an attached dictionary: only the source size counts.
    attach_dict = 1,
    /// Making a dictionary: source and dictionary sizes both count.
    create_cdict = 2,
    /// `getCParams`, `getParams`, `adjustParams`: the purpose is unknown, so
    /// both sizes count, as they always did.
    unknown = 3,
};

/// `ZSTD_BlockCompressor_f`: finds the sequences of one block of `src`,
/// stores them in `seq_store`, updates `rep`, and returns the size of the
/// literals after the last sequence.
pub const BlockCompressor = *const fn (
    ms: *MatchState,
    seq_store: *SeqStore,
    rep: *[rep_num]u32,
    src: []const u8,
) usize;

// ---------------------------------------------------------------------------
// Bit counts (the original's bits.h)
// ---------------------------------------------------------------------------

/// `ZSTD_highbit32`: the index of the highest set bit.
pub inline fn highbit32(val: u32) u32 {
    assert(val != 0);
    return 31 - @as(u32, @clz(val));
}

/// `ZSTD_NbCommonBytes`: the number of equal leading bytes in memory order,
/// from the xor of two words read in native order.
pub inline fn nbCommonBytes(val: usize) u32 {
    return switch (native_endian) {
        .little => @as(u32, @ctz(val)) >> 3,
        .big => @as(u32, @clz(val)) >> 3,
    };
}

// ---------------------------------------------------------------------------
// Codes, blocks and literals
// ---------------------------------------------------------------------------

const ll_code_table = [64]u8{
    0,  1,  2,  3,  4,  5,  6,  7,
    8,  9,  10, 11, 12, 13, 14, 15,
    16, 16, 17, 17, 18, 18, 19, 19,
    20, 20, 20, 20, 21, 21, 21, 21,
    22, 22, 22, 22, 22, 22, 22, 22,
    23, 23, 23, 23, 23, 23, 23, 23,
    24, 24, 24, 24, 24, 24, 24, 24,
    24, 24, 24, 24, 24, 24, 24, 24,
};

/// `ZSTD_LLcode`: the literal length code of `lit_length`.
pub inline fn llCode(lit_length: u32) u32 {
    const ll_delta_code = 19;
    return if (lit_length > 63) highbit32(lit_length) + ll_delta_code else ll_code_table[lit_length];
}

const ml_code_table = [128]u8{
    0,  1,  2,  3,  4,  5,  6,  7,  8,  9,  10, 11, 12, 13, 14, 15,
    16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31,
    32, 32, 33, 33, 34, 34, 35, 35, 36, 36, 36, 36, 37, 37, 37, 37,
    38, 38, 38, 38, 38, 38, 38, 38, 39, 39, 39, 39, 39, 39, 39, 39,
    40, 40, 40, 40, 40, 40, 40, 40, 40, 40, 40, 40, 40, 40, 40, 40,
    41, 41, 41, 41, 41, 41, 41, 41, 41, 41, 41, 41, 41, 41, 41, 41,
    42, 42, 42, 42, 42, 42, 42, 42, 42, 42, 42, 42, 42, 42, 42, 42,
    42, 42, 42, 42, 42, 42, 42, 42, 42, 42, 42, 42, 42, 42, 42, 42,
};

/// `ZSTD_MLcode`: the match length code of `ml_base`, the match length
/// minus `min_match`, as the sequence store keeps it.
pub inline fn mlCode(ml_base: u32) u32 {
    const ml_delta_code = 36;
    return if (ml_base > 127) highbit32(ml_base) + ml_delta_code else ml_code_table[ml_base];
}

/// `ZSTD_selectAddr`: `candidate` when `index >= low_limit`, else `backup`.
pub inline fn selectAddr(
    index: u32,
    low_limit: u32,
    candidate: [*]const u8,
    backup: [*]const u8,
) [*]const u8 {
    return if (index >= low_limit) candidate else backup;
}

/// `ZSTD_noCompressBlock`: writes `src` as a raw block and returns its size.
pub fn noCompressBlock(dst: []u8, src: []const u8, last_block: u32) Error!usize {
    const block_type: u32 = @backingInt(zstd_internal.BlockType.raw);
    const cblock_header24 = last_block + (block_type << 1) + @as(u32, @truncate(src.len << 3));
    if (src.len + zstd_internal.block_header_size > dst.len) return error.DstSizeTooSmall;
    std.mem.writeInt(u24, dst[0..3], @truncate(cblock_header24), .little);
    @memcpy(dst[zstd_internal.block_header_size..][0..src.len], src);
    return zstd_internal.block_header_size + src.len;
}

/// `ZSTD_rleCompressBlock`: writes `src_size` copies of `src` as an RLE
/// block and returns its size.
pub fn rleCompressBlock(dst: []u8, src: u8, src_size: usize, last_block: u32) Error!usize {
    const block_type: u32 = @backingInt(zstd_internal.BlockType.rle);
    const cblock_header = last_block + (block_type << 1) + @as(u32, @truncate(src_size << 3));
    if (dst.len < 4) return error.DstSizeTooSmall;
    std.mem.writeInt(u24, dst[0..3], @truncate(cblock_header), .little);
    dst[3] = src;
    return 4;
}

/// `ZSTD_minGain`: the smallest saving for a compressed block or literals
/// section; the same rule serves both.
pub fn minGain(src_size: usize, strategy: params.Strategy) usize {
    const strat: u32 = @backingInt(strategy);
    comptime assert(@backingInt(params.Strategy.btultra) == 8);
    const minlog: u6 = if (strat >= @backingInt(params.Strategy.btultra)) @intCast(strat - 1) else 6;
    return (src_size >> minlog) + 2;
}

/// `ZSTD_literalsCompressionIsDisabled`.
pub fn literalsCompressionIsDisabled(cctx_params: *const CCtxParams) bool {
    return switch (cctx_params.literal_compression_mode) {
        .enable => false,
        .disable => true,
        .auto => cctx_params.cparams.strategy == .fast and cctx_params.cparams.target_length > 0,
    };
}

/// `ZSTD_safecopyLiterals`: copies `[ip, iend)` to `op`, reading no further
/// than `wildcopy_overlength` bytes past `ilimit_w`. Only called when the
/// literals end past `ilimit_w`, so it is tuned for single long copies.
pub fn safecopyLiterals(
    op_start: [*]u8,
    ip_start: [*]const u8,
    iend: [*]const u8,
    ilimit_w: usize,
) void {
    assert(@intFromPtr(iend) > ilimit_w);
    var op = op_start;
    var ip = ip_start;
    if (@intFromPtr(ip) <= ilimit_w) {
        const length = ilimit_w - @intFromPtr(ip);
        zstd_internal.wildcopy(op, ip, @intCast(length), .no_overlap);
        op += length;
        ip += length;
    }
    while (@intFromPtr(ip) < @intFromPtr(iend)) {
        op[0] = ip[0];
        op += 1;
        ip += 1;
    }
}

// ---------------------------------------------------------------------------
// Offsets and repeat codes
// ---------------------------------------------------------------------------

/// `REPCODE_TO_OFFBASE`: repeat code 1 to 3 as an off_base.
pub inline fn repcodeToOffbase(r: u32) u32 {
    assert(r >= 1 and r <= rep_num);
    return r;
}

pub const repcode1_to_offbase = 1;
pub const repcode2_to_offbase = 2;
pub const repcode3_to_offbase = 3;

/// `OFFSET_TO_OFFBASE`.
pub inline fn offsetToOffbase(o: u32) u32 {
    assert(o > 0);
    return o + rep_num;
}

/// `OFFBASE_IS_OFFSET`.
pub inline fn offbaseIsOffset(o: u32) bool {
    return o > rep_num;
}

/// `OFFBASE_IS_REPCODE`.
pub inline fn offbaseIsRepcode(o: u32) bool {
    return 1 <= o and o <= rep_num;
}

/// `OFFBASE_TO_OFFSET`.
pub inline fn offbaseToOffset(o: u32) u32 {
    assert(offbaseIsOffset(o));
    return o - rep_num;
}

/// `OFFBASE_TO_REPCODE`: the repeat code 1 to 3.
pub inline fn offbaseToRepcode(o: u32) u32 {
    assert(offbaseIsRepcode(o));
    return o;
}

/// `ZSTD_storeSeqOnly`: stores a sequence without copying its literals.
/// `off_base` comes from `repcodeToOffbase` or `offsetToOffbase`;
/// `match_length` is at least `min_match`.
pub inline fn storeSeqOnly(
    seq_store: *SeqStore,
    lit_length: usize,
    off_base: u32,
    match_length: usize,
) void {
    const seq_index = (@intFromPtr(seq_store.sequences) -
        @intFromPtr(seq_store.sequences_start)) / @sizeOf(SeqDef);
    assert(seq_index < seq_store.max_nb_seq);

    assert(lit_length <= params.block_size_max);
    if (lit_length > 0xFFFF) {
        // Only one sequence of a block can have a long length.
        assert(seq_store.long_length_type == .none);
        seq_store.long_length_type = .literal_length;
        seq_store.long_length_pos = @intCast(seq_index);
    }
    seq_store.sequences[0].lit_length = @truncate(lit_length);

    seq_store.sequences[0].off_base = off_base;

    assert(match_length <= params.block_size_max);
    assert(match_length >= min_match);
    const ml_base = match_length - min_match;
    if (ml_base > 0xFFFF) {
        assert(seq_store.long_length_type == .none);
        seq_store.long_length_type = .match_length;
        seq_store.long_length_pos = @intCast(seq_index);
    }
    seq_store.sequences[0].ml_base = @truncate(ml_base);

    seq_store.sequences += 1;
}

/// `ZSTD_storeSeq`: copies `lit_length` literals from `literals` and stores
/// the sequence. It may read literals up to `lit_limit`.
pub inline fn storeSeq(
    seq_store: *SeqStore,
    lit_length: usize,
    literals: [*]const u8,
    lit_limit: [*]const u8,
    off_base: u32,
    match_length: usize,
) void {
    const lit_limit_w = @intFromPtr(lit_limit) -% zstd_internal.wildcopy_overlength;
    const lit_end = literals + lit_length;
    assert(seq_store.max_nb_lit <= 128 * 1024);
    assert(@intFromPtr(seq_store.lit) + lit_length <=
        @intFromPtr(seq_store.lit_start) + seq_store.max_nb_lit);
    assert(@intFromPtr(lit_end) <= @intFromPtr(lit_limit));
    if (@intFromPtr(lit_end) <= lit_limit_w) {
        // The common case: copy 16 bytes first, as literals are likely short.
        comptime assert(zstd_internal.wildcopy_overlength >= 16);
        zstd_internal.copy16(seq_store.lit, literals);
        if (lit_length > 16) {
            zstd_internal.wildcopy(
                seq_store.lit + 16,
                literals + 16,
                @as(isize, @intCast(lit_length)) - 16,
                .no_overlap,
            );
        }
    } else {
        safecopyLiterals(seq_store.lit, literals, lit_end, lit_limit_w);
    }
    seq_store.lit += lit_length;

    storeSeqOnly(seq_store, lit_length, off_base, match_length);
}

/// `ZSTD_updateRep`: updates the repeat offsets `rep` after a sequence with
/// `off_base`; `ll0` is 1 when the sequence has no literals.
pub inline fn updateRep(rep: *[rep_num]u32, off_base: u32, ll0: u32) void {
    if (offbaseIsOffset(off_base)) {
        rep[2] = rep[1];
        rep[1] = rep[0];
        rep[0] = offbaseToOffset(off_base);
    } else {
        const rep_code = offbaseToRepcode(off_base) - 1 + ll0;
        // Repeat code 0 leaves the offsets as they are.
        if (rep_code > 0) {
            const current_offset = if (rep_code == rep_num) rep[0] - 1 else rep[rep_code];
            rep[2] = if (rep_code >= 2) rep[1] else rep[2];
            rep[1] = rep[0];
            rep[0] = current_offset;
        }
    }
}

/// `Repcodes_t`.
pub const Repcodes = struct {
    rep: [rep_num]u32,
};

/// `ZSTD_newRep`: the repeat offsets after a sequence, leaving `rep` as it is.
pub inline fn newRep(rep: *const [rep_num]u32, off_base: u32, ll0: u32) Repcodes {
    var new_reps: Repcodes = .{ .rep = rep.* };
    updateRep(&new_reps.rep, off_base, ll0);
    return new_reps;
}

// ---------------------------------------------------------------------------
// Match length counters
// ---------------------------------------------------------------------------

/// `ZSTD_count`: the number of equal bytes at `p_in` and `p_match`, reading
/// `p_in` no further than `p_in_limit`.
pub inline fn count(p_in_start: [*]const u8, p_match_start: [*]const u8, p_in_limit: [*]const u8) usize {
    const word = @sizeOf(usize);
    var p_in = p_in_start;
    var p_match = p_match_start;
    const in_limit = @intFromPtr(p_in_limit);
    const loop_limit = in_limit -% (word - 1);

    if (@intFromPtr(p_in) < loop_limit) {
        {
            const diff = std.mem.readInt(usize, p_match[0..word], native_endian) ^
                std.mem.readInt(usize, p_in[0..word], native_endian);
            if (diff != 0) return nbCommonBytes(diff);
        }
        p_in += word;
        p_match += word;
        while (@intFromPtr(p_in) < loop_limit) {
            const diff = std.mem.readInt(usize, p_match[0..word], native_endian) ^
                std.mem.readInt(usize, p_in[0..word], native_endian);
            if (diff == 0) {
                p_in += word;
                p_match += word;
                continue;
            }
            p_in += nbCommonBytes(diff);
            return @intFromPtr(p_in) - @intFromPtr(p_in_start);
        }
    }
    if (word == 8 and @intFromPtr(p_in) < in_limit -% 3 and
        std.mem.readInt(u32, p_match[0..4], native_endian) ==
            std.mem.readInt(u32, p_in[0..4], native_endian))
    {
        p_in += 4;
        p_match += 4;
    }
    if (@intFromPtr(p_in) < in_limit -% 1 and
        std.mem.readInt(u16, p_match[0..2], native_endian) ==
            std.mem.readInt(u16, p_in[0..2], native_endian))
    {
        p_in += 2;
        p_match += 2;
    }
    if (@intFromPtr(p_in) < in_limit and p_match[0] == p_in[0]) p_in += 1;
    return @intFromPtr(p_in) - @intFromPtr(p_in_start);
}

/// `ZSTD_count_2segments`: counts a match whose `match` side may run from
/// one segment into the next: on reaching `m_end`, the count continues from
/// `i_start`.
pub inline fn count2Segments(
    ip: [*]const u8,
    match: [*]const u8,
    i_end: [*]const u8,
    m_end: [*]const u8,
    i_start: [*]const u8,
) usize {
    const v_end_addr = @min(
        @intFromPtr(ip) +% (@intFromPtr(m_end) -% @intFromPtr(match)),
        @intFromPtr(i_end),
    );
    const v_end: [*]const u8 = @ptrFromInt(v_end_addr);
    const match_length = count(ip, match, v_end);
    if (@intFromPtr(match) + match_length != @intFromPtr(m_end)) return match_length;
    return match_length + count(ip + match_length, i_start, i_end);
}

// ---------------------------------------------------------------------------
// Hashes
// ---------------------------------------------------------------------------

pub const prime3bytes: u32 = 506832829;
pub const prime4bytes: u32 = 2654435761;
pub const prime5bytes: u64 = 889523592379;
pub const prime6bytes: u64 = 227718039650203;
pub const prime7bytes: u64 = 58295818150454627;
pub const prime8bytes: u64 = 0xCF1BBCDCB7A56463;

pub inline fn hash3(u: u32, h: u32, s: u32) u32 {
    assert(h <= 32);
    return ((u << (32 - 24)) *% prime3bytes ^ s) >> @intCast(32 - h);
}

/// Only for the optimal parser.
pub inline fn hash3Ptr(ptr: [*]const u8, h: u32) usize {
    return hash3(std.mem.readInt(u32, ptr[0..4], .little), h, 0);
}

pub inline fn hash3PtrS(ptr: [*]const u8, h: u32, s: u32) usize {
    return hash3(std.mem.readInt(u32, ptr[0..4], .little), h, s);
}

pub inline fn hash4(u: u32, h: u32, s: u32) u32 {
    assert(h <= 32);
    return (u *% prime4bytes ^ s) >> @intCast(32 - h);
}

pub inline fn hash4Ptr(ptr: [*]const u8, h: u32) usize {
    return hash4(std.mem.readInt(u32, ptr[0..4], .little), h, 0);
}

pub inline fn hash4PtrS(ptr: [*]const u8, h: u32, s: u32) usize {
    return hash4(std.mem.readInt(u32, ptr[0..4], .little), h, s);
}

pub inline fn hash5(u: u64, h: u32, s: u64) usize {
    assert(h <= 64);
    return @truncate(((u << (64 - 40)) *% prime5bytes ^ s) >> @intCast(64 - h));
}

pub inline fn hash5Ptr(p: [*]const u8, h: u32) usize {
    return hash5(std.mem.readInt(u64, p[0..8], .little), h, 0);
}

pub inline fn hash5PtrS(p: [*]const u8, h: u32, s: u64) usize {
    return hash5(std.mem.readInt(u64, p[0..8], .little), h, s);
}

pub inline fn hash6(u: u64, h: u32, s: u64) usize {
    assert(h <= 64);
    return @truncate(((u << (64 - 48)) *% prime6bytes ^ s) >> @intCast(64 - h));
}

pub inline fn hash6Ptr(p: [*]const u8, h: u32) usize {
    return hash6(std.mem.readInt(u64, p[0..8], .little), h, 0);
}

pub inline fn hash6PtrS(p: [*]const u8, h: u32, s: u64) usize {
    return hash6(std.mem.readInt(u64, p[0..8], .little), h, s);
}

pub inline fn hash7(u: u64, h: u32, s: u64) usize {
    assert(h <= 64);
    return @truncate(((u << (64 - 56)) *% prime7bytes ^ s) >> @intCast(64 - h));
}

pub inline fn hash7Ptr(p: [*]const u8, h: u32) usize {
    return hash7(std.mem.readInt(u64, p[0..8], .little), h, 0);
}

pub inline fn hash7PtrS(p: [*]const u8, h: u32, s: u64) usize {
    return hash7(std.mem.readInt(u64, p[0..8], .little), h, s);
}

pub inline fn hash8(u: u64, h: u32, s: u64) usize {
    assert(h <= 64);
    return @truncate((u *% prime8bytes ^ s) >> @intCast(64 - h));
}

pub inline fn hash8Ptr(p: [*]const u8, h: u32) usize {
    return hash8(std.mem.readInt(u64, p[0..8], .little), h, 0);
}

pub inline fn hash8PtrS(p: [*]const u8, h: u32, s: u64) usize {
    return hash8(std.mem.readInt(u64, p[0..8], .little), h, s);
}

/// `ZSTD_hashPtr`: the hash of the `mls` bytes at `p` (4 for any `mls`
/// outside 5 to 8), in `h_bits` bits, at most 32. Inlined, so a
/// compile-time `mls` selects the hash at compile time.
pub inline fn hashPtr(p: [*]const u8, h_bits: u32, mls: u32) usize {
    // Some of the hashes take up to 64 bits, but not all.
    assert(h_bits <= 32);
    return switch (mls) {
        5 => hash5Ptr(p, h_bits),
        6 => hash6Ptr(p, h_bits),
        7 => hash7Ptr(p, h_bits),
        8 => hash8Ptr(p, h_bits),
        else => hash4Ptr(p, h_bits),
    };
}

/// `ZSTD_hashPtrSalted`.
pub inline fn hashPtrSalted(p: [*]const u8, h_bits: u32, mls: u32, hash_salt: u64) usize {
    assert(h_bits <= 32);
    return switch (mls) {
        5 => hash5PtrS(p, h_bits, hash_salt),
        6 => hash6PtrS(p, h_bits, hash_salt),
        7 => hash7PtrS(p, h_bits, hash_salt),
        8 => hash8PtrS(p, h_bits, hash_salt),
        else => hash4PtrS(p, h_bits, @truncate(hash_salt)),
    };
}

/// `ZSTD_ipow`: `base` to the power `exponent`, wrapping.
pub fn ipow(base_start: u64, exponent_start: u64) u64 {
    var power: u64 = 1;
    var base = base_start;
    var exponent = exponent_start;
    while (exponent != 0) {
        if (exponent & 1 != 0) power *%= base;
        exponent >>= 1;
        base *%= base;
    }
    return power;
}

/// `ZSTD_rollingHash_append`: adds `buf` to the hash.
pub fn rollingHashAppend(hash_start: u64, buf: []const u8) u64 {
    var hash = hash_start;
    for (buf) |byte| {
        hash *%= prime8bytes;
        hash +%= @as(u64, byte) + roll_hash_char_offset;
    }
    return hash;
}

/// `ZSTD_rollingHash_compute`: the rolling hash of `buf`.
pub fn rollingHashCompute(buf: []const u8) u64 {
    return rollingHashAppend(0, buf);
}

/// `ZSTD_rollingHash_primePower`: the prime power `rollingHashRotate` takes
/// for a hash over `length` bytes.
pub fn rollingHashPrimePower(length: u32) u64 {
    return ipow(prime8bytes, length - 1);
}

/// `ZSTD_rollingHash_rotate`: moves the hash one byte on.
pub inline fn rollingHashRotate(hash_start: u64, to_remove: u8, to_add: u8, prime_power: u64) u64 {
    var hash = hash_start;
    hash -%= (@as(u64, to_remove) + roll_hash_char_offset) *% prime_power;
    hash *%= prime8bytes;
    hash +%= @as(u64, to_add) + roll_hash_char_offset;
    return hash;
}

// ---------------------------------------------------------------------------
// Match state helpers
// ---------------------------------------------------------------------------

/// `ZSTD_matchState_dictMode`: the dictionary mode the block compressor
/// takes for `ms`.
pub fn matchStateDictMode(ms: *const MatchState) DictMode {
    if (ms.window.hasExtDict()) return .ext_dict;
    if (ms.dict_match_state) |dms| {
        return if (dms.dedicated_dict_search) .dedicated_dict_search else .dict_match_state;
    }
    return .no_dict;
}

/// `ZSTD_getLowestMatchIndex`: the lowest index a match may have, in the
/// external dictionary or the prefix.
pub inline fn getLowestMatchIndex(ms: *const MatchState, curr: u32, window_log: u32) u32 {
    const max_distance = @as(u32, 1) << @intCast(window_log);
    const lowest_valid = ms.window.low_limit;
    const within_window = if (curr -% lowest_valid > max_distance) curr - max_distance else lowest_valid;
    // A dictionary is valid whole while any of it is in the window; it is
    // invalidated (loaded_dict_end set to 0) when it is not valid for the
    // whole block.
    const is_dictionary = ms.loaded_dict_end != 0;
    return if (is_dictionary) lowest_valid else within_window;
}

/// `ZSTD_getLowestPrefixIndex`: the lowest index a match in the prefix may have.
pub inline fn getLowestPrefixIndex(ms: *const MatchState, curr: u32, window_log: u32) u32 {
    const max_distance = @as(u32, 1) << @intCast(window_log);
    const lowest_valid = ms.window.dict_limit;
    const within_window = if (curr -% lowest_valid > max_distance) curr - max_distance else lowest_valid;
    // The dictionary counts, for when it and the source are contiguous in memory.
    const is_dictionary = ms.loaded_dict_end != 0;
    return if (is_dictionary) lowest_valid else within_window;
}

/// `ZSTD_index_overlap_check`: whether the 4 bytes at `rep_index` do not
/// straddle the end of the dictionary and the start of the prefix. The
/// subtraction wraps on purpose.
pub inline fn indexOverlapCheck(prefix_lowest_index: u32, rep_index: u32) bool {
    return (prefix_lowest_index -% 1) -% rep_index >= 3;
}

// Short cache: dictionary hash tables keep an 8-bit tag of each position
// beside its index, an independent hash of its bytes. A finder compares the
// tag of the current position first, and reads the dictionary's bytes (often
// a cache miss) only when the tags match. Only dictionaries' hash tables
// carry tags, so only the dict match state finders use them.

/// `ZSTD_writeTaggedIndex`: stores `index` with the tag of `hash_and_tag`
/// at the entry of its hash.
pub inline fn writeTaggedIndex(hash_table: [*]u32, hash_and_tag: usize, index: u32) void {
    const hash = hash_and_tag >> short_cache_tag_bits;
    const tag: u32 = @as(u32, @truncate(hash_and_tag)) & short_cache_tag_mask;
    assert(index >> (32 - short_cache_tag_bits) == 0);
    hash_table[hash] = (index << short_cache_tag_bits) | tag;
}

/// `ZSTD_comparePackedTags`: whether the tags in the low bits are equal.
pub inline fn comparePackedTags(packed_tag1: usize, packed_tag2: usize) bool {
    const tag1 = @as(u32, @truncate(packed_tag1)) & short_cache_tag_mask;
    const tag2 = @as(u32, @truncate(packed_tag2)) & short_cache_tag_mask;
    return tag1 == tag2;
}

/// `ZSTD_hasExtSeqProd`: whether an external sequence producer is registered.
pub fn hasExtSeqProd(cctx_params: *const CCtxParams) bool {
    return cctx_params.ext_seq_prod_func != null;
}

/// `ZSTD_SequencePosition`.
pub const SequencePosition = struct {
    /// The index in the array of sequences.
    idx: u32,
    /// The position inside the sequence at `idx`.
    pos_in_sequence: u32,
    /// The source bytes the sequences so far cover.
    pos_in_src: usize,
};

/// `BlockSummary`.
pub const BlockSummary = struct {
    nb_sequences: usize,
    block_size: usize,
    lit_size: usize,
};

// --------------------------------------------------------
// Tests
// --------------------------------------------------------

const testing = std.testing;

/// A match state and sequence store set up over one block of input as a
/// fresh compression of one block sets them up, for testing a block
/// compressor on its own. The tables are allocated with `gpa` and zeroed.
/// It holds pointers into itself and into `src` and the dictionary, so it
/// stays where `create` put it, and `src` and the dictionary outlive it.
pub const BlockTest = struct {
    gpa: std.mem.Allocator,
    ms: MatchState,
    dict_ms: MatchState,
    seq_store: SeqStore,
    sequences: []SeqDef,
    literals: []u8,
    hash_table: []u32,
    chain_table: []u32,
    dict_hash_table: []u32,
    dict_chain_table: []u32,
    rep: [rep_num]u32,

    pub const Dict = union(enum) {
        none,
        /// Loaded into the context's own tables (raw content, by copy or
        /// reference), then out of the prefix when the block comes: an
        /// external dictionary.
        ext: []const u8,
        /// Loaded into a dictionary's tables with `cparams`, then attached
        /// as the dict match state.
        attached: struct {
            content: []const u8,
            cparams: params.CompressionParameters,
        },
    };

    /// A strategy's table fill (`fast.fillHashTable`, ...).
    pub const FillTables = *const fn (
        ms: *MatchState,
        end: [*]const u8,
        dtlm: DictTableLoadMethod,
        tfp: TableFillPurpose,
    ) void;

    /// The steps of a fresh compression of `src` with `cparams`, as one block:
    /// the match state is reset (window initialised and cleared,
    /// `next_to_update` at its start), the dictionary loaded and attached as
    /// `ZSTD_loadDictionaryContent` and `ZSTD_resetCCtx_byAttachingCDict` do,
    /// with `fill`; then the window takes `src` and the dictionary's validity
    /// and the maximum distance are enforced, as `ZSTD_compress_frameChunk`
    /// does, and `next_to_update` is limited as `ZSTD_buildSeqStore` does.
    /// The repeat offsets are the format's starting ones. The tables have
    /// `1 << hash_log` and `1 << chain_log` entries.
    pub fn create(
        gpa: std.mem.Allocator,
        cparams: params.CompressionParameters,
        src: []const u8,
        dict: Dict,
        fill: ?FillTables,
    ) !*BlockTest {
        const self = try gpa.create(BlockTest);
        self.* = .{
            .gpa = gpa,
            .ms = .{},
            .dict_ms = .{},
            .seq_store = .{},
            .sequences = &.{},
            .literals = &.{},
            .hash_table = &.{},
            .chain_table = &.{},
            .dict_hash_table = &.{},
            .dict_chain_table = &.{},
            .rep = zstd_internal.rep_start_value,
        };
        errdefer self.destroy();
        self.sequences = try gpa.alloc(SeqDef, src.len / min_match + 1);
        self.literals = try gpa.alloc(u8, src.len + zstd_internal.wildcopy_overlength);
        self.hash_table = try zeroedTable(gpa, cparams.hash_log);
        self.chain_table = try zeroedTable(gpa, cparams.chain_log);

        self.seq_store = .{
            .sequences_start = self.sequences.ptr,
            .sequences = self.sequences.ptr,
            .lit_start = self.literals.ptr,
            .lit = self.literals.ptr,
            .max_nb_seq = self.sequences.len,
            .max_nb_lit = src.len,
        };
        const ms = &self.ms;
        ms.window.init();
        ms.window.clear();
        ms.next_to_update = ms.window.dict_limit;
        ms.hash_table = self.hash_table.ptr;
        ms.chain_table = self.chain_table.ptr;
        ms.cparams = cparams;

        switch (dict) {
            .none => {},
            .ext => |content| loadDictContent(ms, content, .fast, .for_cctx, fill.?),
            .attached => |attached| {
                const dms = &self.dict_ms;
                self.dict_hash_table = try zeroedTable(gpa, attached.cparams.hash_log);
                self.dict_chain_table = try zeroedTable(gpa, attached.cparams.chain_log);
                dms.window.init();
                dms.window.clear();
                dms.next_to_update = dms.window.dict_limit;
                dms.hash_table = self.dict_hash_table.ptr;
                dms.chain_table = self.dict_chain_table.ptr;
                dms.cparams = attached.cparams;
                loadDictContent(dms, attached.content, .full, .for_cdict, fill.?);
                const cdict_end: u32 = @intCast(@intFromPtr(dms.window.next_src) -
                    @intFromPtr(dms.window.base));
                if (cdict_end - dms.window.dict_limit != 0) {
                    ms.dict_match_state = dms;
                    if (ms.window.dict_limit < cdict_end) {
                        ms.window.next_src = ms.window.base + cdict_end;
                        ms.window.clear();
                    }
                    ms.loaded_dict_end = ms.window.dict_limit;
                }
            },
        }

        if (!ms.window.update(src, ms.force_non_contiguous)) {
            ms.force_non_contiguous = false;
            ms.next_to_update = ms.window.dict_limit;
        }
        const max_dist = @as(u32, 1) << @intCast(cparams.window_log);
        const block_end = src.ptr + src.len;
        ms.window.checkDictValidity(block_end, max_dist, &ms.loaded_dict_end, &ms.dict_match_state);
        ms.window.enforceMaxDist(src.ptr, max_dist, &ms.loaded_dict_end, &ms.dict_match_state);
        if (ms.next_to_update < ms.window.low_limit) ms.next_to_update = ms.window.low_limit;

        const curr: u32 = @intCast(@intFromPtr(src.ptr) - @intFromPtr(ms.window.base));
        if (curr > ms.next_to_update + 384) {
            ms.next_to_update = curr - @min(192, curr - ms.next_to_update - 384);
        }
        return self;
    }

    fn zeroedTable(gpa: std.mem.Allocator, log: u32) ![]u32 {
        const table = try gpa.alloc(u32, @as(usize, 1) << @intCast(log));
        @memset(table, 0);
        return table;
    }

    /// `ZSTD_loadDictionaryContent`'s steps for the match state alone.
    fn loadDictContent(
        ms: *MatchState,
        dict: []const u8,
        dtlm: DictTableLoadMethod,
        tfp: TableFillPurpose,
        fill: FillTables,
    ) void {
        const iend = dict.ptr + dict.len;
        _ = ms.window.update(dict, false);
        ms.next_to_update = @intCast(@intFromPtr(dict.ptr) - @intFromPtr(ms.window.base));
        ms.loaded_dict_end = @intCast(@intFromPtr(iend) - @intFromPtr(ms.window.base));
        if (dict.len <= hash_read_size) return;
        fill(ms, iend, dtlm, tfp);
        ms.next_to_update = @intCast(@intFromPtr(iend) - @intFromPtr(ms.window.base));
    }

    pub fn destroy(self: *BlockTest) void {
        const gpa = self.gpa;
        gpa.free(self.sequences);
        gpa.free(self.literals);
        gpa.free(self.hash_table);
        gpa.free(self.chain_table);
        gpa.free(self.dict_hash_table);
        gpa.free(self.dict_chain_table);
        self.* = undefined;
        gpa.destroy(self);
    }

    /// Runs `compressor` over `src`, then stores the last literals, as
    /// `ZSTD_buildSeqStore` does; returns the size of the last literals.
    pub fn run(self: *BlockTest, compressor: BlockCompressor, src: []const u8) usize {
        const last_ll_size = compressor(&self.ms, &self.seq_store, &self.rep, src);
        const last_literals = src[src.len - last_ll_size ..];
        @memcpy(self.seq_store.lit[0..last_literals.len], last_literals);
        self.seq_store.lit += last_literals.len;
        return last_ll_size;
    }

    /// The sequences stored.
    pub fn storedSequences(self: *const BlockTest) []const SeqDef {
        const n = (@intFromPtr(self.seq_store.sequences) - @intFromPtr(self.sequences.ptr)) /
            @sizeOf(SeqDef);
        return self.sequences[0..n];
    }

    /// The literals stored, the last ones included.
    pub fn storedLiterals(self: *const BlockTest) []const u8 {
        const n = @intFromPtr(self.seq_store.lit) - @intFromPtr(self.literals.ptr);
        return self.literals[0..n];
    }
};

test "llCode and mlCode against the format's code tables" {
    // Every literal length code's baseline maps to that code, and the
    // length below the next baseline too.
    const ll_base = [_]u32{
        0,      1,      2,      3,       4,  5,  6,  7,  8,  9,  10,   11,    12,    13,    14,    15,
        16,     18,     20,     22,      24, 28, 32, 40, 48, 64, 0x80, 0x100, 0x200, 0x400, 0x800, 0x1000,
        0x2000, 0x4000, 0x8000, 0x10000,
    };
    for (ll_base, 0..) |base, code| {
        try testing.expectEqual(@as(u32, @intCast(code)), llCode(base));
        const last = base + (@as(u32, 1) << @intCast(zstd_internal.ll_bits[code])) - 1;
        try testing.expectEqual(@as(u32, @intCast(code)), llCode(last));
    }
    const ml_base = [_]u32{
        3,      4,      5,      6,      7,       8,  9,  10, 11, 12, 13, 14,   15,    16,    17,    18,
        19,     20,     21,     22,     23,      24, 25, 26, 27, 28, 29, 30,   31,    32,    33,    34,
        35,     37,     39,     41,     43,      47, 51, 59, 67, 83, 99, 0x83, 0x103, 0x203, 0x403, 0x803,
        0x1003, 0x2003, 0x4003, 0x8003, 0x10003,
    };
    for (ml_base, 0..) |base, code| {
        try testing.expectEqual(@as(u32, @intCast(code)), mlCode(base - min_match));
        const last = base + (@as(u32, 1) << @intCast(zstd_internal.ml_bits[code])) - 1;
        try testing.expectEqual(@as(u32, @intCast(code)), mlCode(last - min_match));
    }
}

test "count stops at the first difference and at the limit" {
    var a: [64]u8 = undefined;
    var b: [64]u8 = undefined;
    for (&a, 0..) |*byte, i| byte.* = @truncate(i *% 7 +% 1);
    for (0..a.len + 1) |diff_at| {
        b = a;
        if (diff_at < b.len) b[diff_at] +%= 1;
        for (0..a.len + 1) |limit| {
            const expected = @min(diff_at, limit);
            try testing.expectEqual(expected, count(&a, &b, @as([*]const u8, &a) + limit));
        }
    }
}

test "count2Segments continues from the start of the prefix" {
    // The match runs to the end of the dictionary segment, then on from the
    // start of the prefix.
    var prefix: [40]u8 = undefined;
    for (&prefix, 0..) |*byte, i| byte.* = @truncate(i * 13 + 5);
    var dict: [24]u8 = undefined;
    // The last 10 bytes of the dictionary equal the input at `ip`; the
    // prefix then continues as the input after those 10 bytes does.
    const ip_offset = 20;
    var input: [64]u8 = undefined;
    @memcpy(input[0..40], &prefix);
    @memcpy(input[40..], prefix[0..24]);
    @memset(&dict, 0xAA);
    @memcpy(dict[14..24], input[ip_offset..][0..10]);
    const ip: [*]const u8 = @as([*]const u8, &input) + ip_offset;
    const iend: [*]const u8 = @as([*]const u8, &input) + input.len;
    const match: [*]const u8 = @as([*]const u8, &dict) + 14;
    const dict_end: [*]const u8 = @as([*]const u8, &dict) + dict.len;
    const length = count2Segments(ip, match, iend, dict_end, &input);
    const second = count(ip + 10, &input, iend);
    try testing.expectEqual(10 + second, length);
    // A mismatch before the end of the segment stops there.
    dict[20] ^= 0xFF;
    const short = count2Segments(ip, match, iend, dict_end, &input);
    try testing.expectEqual(@as(usize, 6), short);
}

test "hashes keep their high bits and mix their salt" {
    const bytes = [8]u8{ 1, 2, 3, 4, 5, 6, 7, 8 };
    const u32_value = std.mem.readInt(u32, bytes[0..4], .little);
    const u64_value = std.mem.readInt(u64, &bytes, .little);
    try testing.expectEqual((u32_value *% prime4bytes) >> 12, @as(u32, @intCast(hash4Ptr(&bytes, 20))));
    try testing.expectEqual(
        @as(usize, @truncate((u64_value *% prime8bytes) >> 40)),
        hash8Ptr(&bytes, 24),
    );
    try testing.expectEqual(
        @as(usize, @truncate(((u64_value << 24) *% prime5bytes) >> 47)),
        hashPtr(&bytes, 17, 5),
    );
    // Bytes past the hash's length do not change it.
    var other = bytes;
    other[6] = 99;
    try testing.expectEqual(hashPtr(&bytes, 20, 6), hashPtr(&other, 20, 6));
    try testing.expect(hashPtr(&bytes, 20, 7) != hashPtr(&other, 20, 7));
    try testing.expectEqual(hashPtr(&bytes, 20, 3), hashPtr(&bytes, 20, 4));
    try testing.expectEqual(hashPtrSalted(&bytes, 20, 4, 0), hashPtr(&bytes, 20, 4));
    try testing.expectEqual(hash3Ptr(&bytes, 16), hash3PtrS(&bytes, 16, 0));
}

test "the rolling hash rotates as it recomputes" {
    const data = "the rolling hash moves one byte at a time over this text";
    const length = 16;
    const prime_power = rollingHashPrimePower(length);
    var hash = rollingHashCompute(data[0..length]);
    for (1..data.len - length + 1) |start| {
        hash = rollingHashRotate(hash, data[start - 1], data[start + length - 1], prime_power);
        try testing.expectEqual(rollingHashCompute(data[start..][0..length]), hash);
    }
    try testing.expectEqual(@as(u64, 1), ipow(12345, 0));
    try testing.expectEqual(@as(u64, 3 * 3 * 3 * 3 * 3), ipow(3, 5));
}

test "updateRep follows the repeat code rules" {
    var rep = zstd_internal.rep_start_value;
    updateRep(&rep, offsetToOffbase(100), 0);
    try testing.expectEqual([3]u32{ 100, 1, 4 }, rep);
    // Repeat code 1 with literals keeps the offsets.
    updateRep(&rep, repcode1_to_offbase, 0);
    try testing.expectEqual([3]u32{ 100, 1, 4 }, rep);
    // Repeat code 1 without literals is the second offset.
    updateRep(&rep, repcode1_to_offbase, 1);
    try testing.expectEqual([3]u32{ 1, 100, 4 }, rep);
    updateRep(&rep, repcode3_to_offbase, 0);
    try testing.expectEqual([3]u32{ 4, 1, 100 }, rep);
    // Repeat code 3 without literals is the first offset minus one.
    updateRep(&rep, repcode3_to_offbase, 1);
    try testing.expectEqual([3]u32{ 3, 4, 1 }, rep);
    try testing.expectEqual([3]u32{ 4, 3, 1 }, newRep(&rep, repcode2_to_offbase, 0).rep);
    try testing.expectEqual([3]u32{ 3, 4, 1 }, rep);
}

test "storeSeq copies literals and records one long length" {
    var src: [80_000]u8 = undefined;
    for (&src, 0..) |*byte, i| byte.* = @truncate(i);
    var sequences: [4]SeqDef = undefined;
    var literals: [src.len + 32]u8 = undefined;
    var store: SeqStore = .{
        .sequences_start = &sequences,
        .sequences = &sequences,
        .lit_start = &literals,
        .lit = &literals,
        .max_nb_seq = sequences.len,
        .max_nb_lit = 128 * 1024,
    };
    const iend: [*]const u8 = @as([*]const u8, &src) + src.len;
    storeSeq(&store, 5, &src, iend, offsetToOffbase(9), 4);
    storeSeq(&store, 70_000, @as([*]const u8, &src) + 5, iend, repcode2_to_offbase, 3);
    // The last literals end at the limit: the safe copy.
    storeSeq(&store, 40, iend - 40, iend, repcode1_to_offbase, 10);
    try testing.expectEqualSlices(u8, src[0 .. 5 + 70_000], literals[0 .. 5 + 70_000]);
    try testing.expectEqualSlices(u8, src[src.len - 40 ..], literals[70_005..][0..40]);
    try testing.expectEqual(@intFromPtr(&literals) + 70_045, @intFromPtr(store.lit));
    try testing.expectEqual(LongLengthType.literal_length, store.long_length_type);
    try testing.expectEqual(@as(u32, 1), store.long_length_pos);
    const len = getSequenceLength(&store, &sequences[1]);
    try testing.expectEqual(SequenceLength{ .lit_length = 70_000, .match_length = 3 }, len);
    try testing.expectEqual(@as(u32, 12), sequences[0].off_base);
    try testing.expectEqual(@as(u16, 1), sequences[0].ml_base);
}

test "window: first segment, a new segment, overlap" {
    var buf: [128]u8 = @splat(0);
    var w: Window = undefined;
    w.init();
    try testing.expect(w.isEmpty());
    try testing.expect(!w.update(buf[0..64], false));
    try testing.expectEqual(@as(u32, window_start_index), w.dict_limit);
    try testing.expectEqual(@as(u32, window_start_index), w.low_limit);
    try testing.expectEqual(@intFromPtr(&buf) - window_start_index, @intFromPtr(w.base));
    try testing.expect(!w.hasExtDict());
    // An empty block changes nothing; the next block follows on.
    try testing.expect(w.update(buf[0..0], false));
    try testing.expect(w.update(buf[64..70], false));
    // A gap: the prefix becomes the external dictionary.
    try testing.expect(!w.update(buf[80..112], false));
    try testing.expectEqual(@as(u32, 72), w.dict_limit);
    try testing.expectEqual(@as(u32, 2), w.low_limit);
    try testing.expect(w.hasExtDict());
    try testing.expectEqual(@intFromPtr(&buf) - 2, @intFromPtr(w.dict_base));
    try testing.expectEqual(@intFromPtr(&buf) + 80 - 72, @intFromPtr(w.base));
    // Input over the end of the new dictionary: the dictionary shrinks to nothing.
    try testing.expect(!w.update(buf[100..120], false));
    try testing.expectEqual(@as(u32, 104), w.dict_limit);
    try testing.expectEqual(@as(u32, 104), w.low_limit);
    // A forced new segment, though contiguous.
    try testing.expect(!w.update(buf[120..128], true));
    try testing.expectEqual(@as(u32, 124), w.dict_limit);
    try testing.expectEqual(@as(u32, 104), w.low_limit);
    w.clear();
    try testing.expectEqual(@as(u32, 132), w.dict_limit);
    try testing.expectEqual(w.dict_limit, w.low_limit);
}

test "window: enforceMaxDist and the overflow correction keep the low bits" {
    const buffer = try testing.allocator.alloc(u8, 1 << 20);
    defer testing.allocator.free(buffer);
    var w: Window = undefined;
    w.init();
    _ = w.update(buffer, false);
    const max_dist: u32 = 1 << 16;
    var loaded: u32 = 0;
    var dms: ?*const MatchState = null;
    w.enforceMaxDist(buffer.ptr + buffer.len, max_dist, &loaded, &dms);
    try testing.expectEqual(@as(u32, (1 << 20) + 2 - max_dist), w.low_limit);
    try testing.expectEqual(w.low_limit, w.dict_limit);

    // Pretend the indexes have grown near the limit: move base back.
    const shift: usize = current_max;
    w.base = @ptrFromInt(@intFromPtr(w.base) - shift);
    w.dict_base = w.base;
    w.low_limit += current_max;
    w.dict_limit += current_max;
    const src = buffer.ptr + buffer.len - 16;
    const before: u32 = @intCast(@intFromPtr(src) - @intFromPtr(w.base));
    try testing.expect(w.needOverflowCorrection(17, max_dist, 0, src, buffer.ptr + buffer.len));
    const correction = w.correctOverflow(17, max_dist, src);
    const after: u32 = @intCast(@intFromPtr(src) - @intFromPtr(w.base));
    try testing.expectEqual(before - correction, after);
    try testing.expectEqual(before & ((1 << 17) - 1), after & ((1 << 17) - 1));
    try testing.expect(after >= max_dist + window_start_index);
    try testing.expect(w.low_limit <= after);
    try testing.expectEqual(@as(u32, 1), w.nb_overflow_corrections);
    try testing.expect(!w.needOverflowCorrection(17, max_dist, 0, src, buffer.ptr + buffer.len));
}

test "tagged indexes and packed tags" {
    var table: [16]u32 = @splat(0);
    const hash_and_tag: usize = (5 << short_cache_tag_bits) | 0x3C;
    writeTaggedIndex(&table, hash_and_tag, 1234);
    try testing.expectEqual(@as(u32, (1234 << 8) | 0x3C), table[5]);
    try testing.expect(comparePackedTags(table[5], hash_and_tag));
    try testing.expect(!comparePackedTags(table[5], hash_and_tag ^ 1));
    try testing.expect(indexOverlapCheck(100, 50));
    try testing.expect(!indexOverlapCheck(100, 98));
    try testing.expect(indexOverlapCheck(100, 100));
}

test "raw and RLE blocks" {
    var dst: [16]u8 = undefined;
    const src = "hello";
    try testing.expectEqual(@as(usize, 8), try noCompressBlock(&dst, src, 1));
    try testing.expectEqualSlices(u8, &.{ 1 + (5 << 3), 0, 0 }, dst[0..3]);
    try testing.expectEqualSlices(u8, src, dst[3..8]);
    try testing.expectError(error.DstSizeTooSmall, noCompressBlock(dst[0..7], src, 0));
    try testing.expectEqual(@as(usize, 4), try rleCompressBlock(&dst, 'x', 1000, 0));
    try testing.expectEqual(@as(u24, (1 << 1) + (1000 << 3)), std.mem.readInt(u24, dst[0..3], .little));
    try testing.expectEqual(@as(u8, 'x'), dst[3]);
    try testing.expectEqual(@as(usize, (1000 >> 6) + 2), minGain(1000, .fast));
    try testing.expectEqual(@as(usize, (1000 >> 8) + 2), minGain(1000, .btultra2));
}
