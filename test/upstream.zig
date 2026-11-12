//! The original zstd's C interface, as declared in its zstd.h with
//! ZSTD_STATIC_LINKING_ONLY, for the oracle tests and the benchmark, which
//! link the original built from reference/. C types map to Zig's: `unsigned`
//! is `c_uint`, `int` is `c_int`, `size_t` is `usize`.

pub extern fn ZSTD_versionNumber() c_uint;
pub extern fn ZSTD_compressBound(src_size: usize) usize;
pub extern fn ZSTD_isError(code: usize) c_uint;
pub extern fn ZSTD_compress(
    dst: ?*anyopaque,
    dst_capacity: usize,
    src: ?*const anyopaque,
    src_size: usize,
    level: c_int,
) usize;

pub const ZSTD_CCtx = opaque {};
pub const ZSTD_CDict = opaque {};
pub const ZSTD_CCtx_params = opaque {};

pub const ZSTD_inBuffer = extern struct {
    src: ?*const anyopaque,
    size: usize,
    pos: usize,
};

pub const ZSTD_outBuffer = extern struct {
    dst: ?*anyopaque,
    size: usize,
    pos: usize,
};

pub const ZSTD_bounds = extern struct {
    @"error": usize,
    lower_bound: c_int,
    upper_bound: c_int,
};

pub const ZSTD_compressionParameters = extern struct {
    window_log: c_uint,
    chain_log: c_uint,
    hash_log: c_uint,
    search_log: c_uint,
    min_match: c_uint,
    target_length: c_uint,
    strategy: c_uint,
};

pub const ZSTD_frameParameters = extern struct {
    content_size_flag: c_int,
    checksum_flag: c_int,
    no_dict_id_flag: c_int,
};

pub const ZSTD_parameters = extern struct {
    cparams: ZSTD_compressionParameters,
    fparams: ZSTD_frameParameters,
};

pub const ZSTD_Sequence = extern struct {
    offset: c_uint,
    lit_length: c_uint,
    match_length: c_uint,
    rep: c_uint,
};

pub extern fn ZSTD_getErrorCode(code: usize) c_uint;
pub extern fn ZSTD_getErrorName(code: usize) [*:0]const u8;
pub extern fn ZSTD_minCLevel() c_int;
pub extern fn ZSTD_maxCLevel() c_int;
pub extern fn ZSTD_defaultCLevel() c_int;

pub extern fn ZSTD_createCCtx() ?*ZSTD_CCtx;
pub extern fn ZSTD_freeCCtx(cctx: ?*ZSTD_CCtx) usize;
pub extern fn ZSTD_CCtx_setParameter(cctx: *ZSTD_CCtx, param: c_uint, value: c_int) usize;
pub extern fn ZSTD_CCtx_getParameter(cctx: *ZSTD_CCtx, param: c_uint, value: *c_int) usize;
pub extern fn ZSTD_CCtx_setPledgedSrcSize(cctx: *ZSTD_CCtx, size: c_ulonglong) usize;
pub extern fn ZSTD_CCtx_reset(cctx: *ZSTD_CCtx, directive: c_uint) usize;
pub extern fn ZSTD_cParam_getBounds(param: c_uint) ZSTD_bounds;
pub extern fn ZSTD_compressCCtx(
    cctx: *ZSTD_CCtx,
    dst: ?*anyopaque,
    dst_capacity: usize,
    src: ?*const anyopaque,
    src_size: usize,
    level: c_int,
) usize;
pub extern fn ZSTD_compress2(
    cctx: *ZSTD_CCtx,
    dst: ?*anyopaque,
    dst_capacity: usize,
    src: ?*const anyopaque,
    src_size: usize,
) usize;
pub extern fn ZSTD_compressStream2(
    cctx: *ZSTD_CCtx,
    output: *ZSTD_outBuffer,
    input: *ZSTD_inBuffer,
    end_op: c_uint,
) usize;
pub extern fn ZSTD_CCtx_loadDictionary(cctx: *ZSTD_CCtx, dict: ?*const anyopaque, size: usize) usize;
pub extern fn ZSTD_CCtx_loadDictionary_advanced(
    cctx: *ZSTD_CCtx,
    dict: ?*const anyopaque,
    size: usize,
    load_method: c_uint,
    content_type: c_uint,
) usize;
pub extern fn ZSTD_CCtx_refPrefix(cctx: *ZSTD_CCtx, prefix: ?*const anyopaque, size: usize) usize;
pub extern fn ZSTD_CCtx_refPrefix_advanced(
    cctx: *ZSTD_CCtx,
    prefix: ?*const anyopaque,
    size: usize,
    content_type: c_uint,
) usize;
pub extern fn ZSTD_CCtx_refCDict(cctx: *ZSTD_CCtx, cdict: ?*const ZSTD_CDict) usize;
pub extern fn ZSTD_createCDict(dict: ?*const anyopaque, size: usize, level: c_int) ?*ZSTD_CDict;
pub extern fn ZSTD_freeCDict(cdict: ?*ZSTD_CDict) usize;
pub extern fn ZSTD_getCParams(
    level: c_int,
    src_size_hint: c_ulonglong,
    dict_size: usize,
) ZSTD_compressionParameters;
pub extern fn ZSTD_getParams(
    level: c_int,
    src_size_hint: c_ulonglong,
    dict_size: usize,
) ZSTD_parameters;
pub extern fn ZSTD_sequenceBound(src_size: usize) usize;
pub extern fn ZSTD_generateSequences(
    cctx: *ZSTD_CCtx,
    out_seqs: [*]ZSTD_Sequence,
    out_seqs_capacity: usize,
    src: ?*const anyopaque,
    src_size: usize,
) usize;

pub extern fn ZSTD_decompress(
    dst: ?*anyopaque,
    dst_capacity: usize,
    src: ?*const anyopaque,
    src_size: usize,
) usize;
pub extern fn ZSTD_decompress_usingDict(
    dctx: *anyopaque,
    dst: ?*anyopaque,
    dst_capacity: usize,
    src: ?*const anyopaque,
    src_size: usize,
    dict: ?*const anyopaque,
    dict_size: usize,
) usize;
pub extern fn ZSTD_createDCtx() ?*anyopaque;
pub extern fn ZSTD_freeDCtx(dctx: ?*anyopaque) usize;
pub extern fn ZSTD_getFrameContentSize(src: ?*const anyopaque, src_size: usize) c_ulonglong;

pub extern fn ZDICT_trainFromBuffer(
    dict_buffer: ?*anyopaque,
    dict_buffer_capacity: usize,
    samples_buffer: ?*const anyopaque,
    samples_sizes: [*]const usize,
    nb_samples: c_uint,
) usize;
pub extern fn ZDICT_isError(code: usize) c_uint;

/// RDG_genBuffer from upstream's programs/datagen.c.
pub extern fn reference_genBuffer(
    buffer: ?*anyopaque,
    size: usize,
    match_proba: f64,
    lit_proba: f64,
    seed: c_uint,
) void;

/// The original's `SeqDef`, one stored sequence.
pub const SeqDef = extern struct {
    off_base: u32,
    lit_length: u16,
    ml_base: u16,
};

/// The original's block compressor run on one block, after the setup of a
/// fresh compression (test/reference.c). `dict_kind`: 0 none, 1 an external
/// dictionary, 2 an attached one. Returns the size of the last literals.
pub extern fn reference_blockTest(
    cparams: *const ZSTD_compressionParameters,
    dict_kind: c_int,
    dict: ?*const anyopaque,
    dict_size: usize,
    dict_cparams: *const ZSTD_compressionParameters,
    src: ?*const anyopaque,
    src_size: usize,
    hash_table: [*]u32,
    chain_table: [*]u32,
    dict_hash_table: ?[*]u32,
    dict_chain_table: ?[*]u32,
    seqs: [*]SeqDef,
    seq_capacity: usize,
    lits: [*]u8,
    lit_capacity: usize,
    rep: *[3]u32,
    nb_seq: *usize,
    nb_lit: *usize,
    long_length_type: *u32,
    long_length_pos: *u32,
) usize;

/// The compression parameters `cctx` applied in its last compression.
pub extern fn reference_appliedCParams(
    cctx: *const ZSTD_CCtx,
    cparams: *ZSTD_compressionParameters,
) void;
// The entropy coders' internal functions, exported by the library, and the
// helpers in test/reference.c that reach their inline parts.

pub extern fn HIST_add(count: [*]c_uint, src: ?*const anyopaque, src_size: usize) void;
pub extern fn HIST_count_simple(
    count: [*]c_uint,
    max_symbol_value: *c_uint,
    src: ?*const anyopaque,
    src_size: usize,
) c_uint;
pub extern fn HIST_count(
    count: [*]c_uint,
    max_symbol_value: *c_uint,
    src: ?*const anyopaque,
    src_size: usize,
) usize;
pub extern fn HIST_countFast(
    count: [*]c_uint,
    max_symbol_value: *c_uint,
    src: ?*const anyopaque,
    src_size: usize,
) usize;
pub extern fn HIST_count_wksp(
    count: [*]c_uint,
    max_symbol_value: *c_uint,
    src: ?*const anyopaque,
    src_size: usize,
    workspace: ?*anyopaque,
    workspace_size: usize,
) usize;
pub extern fn HIST_countFast_wksp(
    count: [*]c_uint,
    max_symbol_value: *c_uint,
    src: ?*const anyopaque,
    src_size: usize,
    workspace: ?*anyopaque,
    workspace_size: usize,
) usize;

pub extern fn FSE_optimalTableLog(
    max_table_log: c_uint,
    src_size: usize,
    max_symbol_value: c_uint,
) c_uint;
pub extern fn FSE_optimalTableLog_internal(
    max_table_log: c_uint,
    src_size: usize,
    max_symbol_value: c_uint,
    minus: c_uint,
) c_uint;
pub extern fn FSE_normalizeCount(
    normalized_counter: [*]c_short,
    table_log: c_uint,
    count: [*]const c_uint,
    total: usize,
    max_symbol_value: c_uint,
    use_low_prob_count: c_uint,
) usize;
pub extern fn FSE_NCountWriteBound(max_symbol_value: c_uint, table_log: c_uint) usize;
pub extern fn FSE_writeNCount(
    buffer: ?*anyopaque,
    buffer_size: usize,
    normalized_counter: [*]const c_short,
    max_symbol_value: c_uint,
    table_log: c_uint,
) usize;
pub extern fn FSE_buildCTable_wksp(
    ct: [*]c_uint,
    normalized_counter: [*]const c_short,
    max_symbol_value: c_uint,
    table_log: c_uint,
    workspace: ?*anyopaque,
    workspace_size: usize,
) usize;
pub extern fn FSE_buildCTable_rle(ct: [*]c_uint, symbol_value: u8) usize;
pub extern fn FSE_compress_usingCTable(
    dst: ?*anyopaque,
    dst_size: usize,
    src: ?*const anyopaque,
    src_size: usize,
    ct: [*]const c_uint,
) usize;
pub extern fn FSE_compressBound(size: usize) usize;
pub extern fn FSE_readNCount(
    normalized_counter: [*]c_short,
    max_symbol_value: *c_uint,
    table_log: *c_uint,
    header: ?*const anyopaque,
    header_size: usize,
) usize;

pub extern fn HUF_readStats(
    huff_weight: [*]u8,
    hw_size: usize,
    rank_stats: [*]u32,
    nb_symbols: *u32,
    table_log: *u32,
    src: ?*const anyopaque,
    src_size: usize,
) usize;
pub extern fn HUF_readStats_wksp(
    huff_weight: [*]u8,
    hw_size: usize,
    rank_stats: [*]u32,
    nb_symbols: *u32,
    table_log: *u32,
    src: ?*const anyopaque,
    src_size: usize,
    workspace: ?*anyopaque,
    workspace_size: usize,
    flags: c_int,
) usize;
pub extern fn HUF_optimalTableLog(
    max_table_log: c_uint,
    src_size: usize,
    max_symbol_value: c_uint,
    workspace: ?*anyopaque,
    workspace_size: usize,
    table: [*]usize,
    count: [*]const c_uint,
    flags: c_int,
) c_uint;
pub extern fn HUF_writeCTable_wksp(
    dst: ?*anyopaque,
    max_dst_size: usize,
    ctable: [*]const usize,
    max_symbol_value: c_uint,
    huff_log: c_uint,
    workspace: ?*anyopaque,
    workspace_size: usize,
) usize;
pub extern fn HUF_readCTable(
    ctable: [*]usize,
    max_symbol_value: *c_uint,
    src: ?*const anyopaque,
    src_size: usize,
    has_zero_weights: *c_uint,
) usize;
pub extern fn HUF_getNbBitsFromCTable(ctable: [*]const usize, symbol_value: u32) u32;
pub extern fn HUF_buildCTable_wksp(
    ctable: [*]usize,
    count: [*]const c_uint,
    max_symbol_value: u32,
    max_nb_bits: u32,
    workspace: ?*anyopaque,
    workspace_size: usize,
) usize;
pub extern fn HUF_estimateCompressedSize(
    ctable: [*]const usize,
    count: [*]const c_uint,
    max_symbol_value: c_uint,
) usize;
pub extern fn HUF_validateCTable(
    ctable: [*]const usize,
    count: [*]const c_uint,
    max_symbol_value: c_uint,
) c_int;
pub extern fn HUF_compressBound(size: usize) usize;
pub extern fn HUF_compress1X_usingCTable(
    dst: ?*anyopaque,
    dst_size: usize,
    src: ?*const anyopaque,
    src_size: usize,
    ctable: [*]const usize,
    flags: c_int,
) usize;
pub extern fn HUF_compress4X_usingCTable(
    dst: ?*anyopaque,
    dst_size: usize,
    src: ?*const anyopaque,
    src_size: usize,
    ctable: [*]const usize,
    flags: c_int,
) usize;
pub extern fn HUF_compress1X_repeat(
    dst: ?*anyopaque,
    dst_size: usize,
    src: ?*const anyopaque,
    src_size: usize,
    max_symbol_value: c_uint,
    huff_log: c_uint,
    workspace: ?*anyopaque,
    workspace_size: usize,
    huf_table: ?[*]usize,
    repeat: ?*c_uint,
    flags: c_int,
) usize;
pub extern fn HUF_compress4X_repeat(
    dst: ?*anyopaque,
    dst_size: usize,
    src: ?*const anyopaque,
    src_size: usize,
    max_symbol_value: c_uint,
    huff_log: c_uint,
    workspace: ?*anyopaque,
    workspace_size: usize,
    huf_table: ?[*]usize,
    repeat: ?*c_uint,
    flags: c_int,
) usize;
pub extern fn HUF_cardinality(count: [*]const c_uint, max_symbol_value: c_uint) c_uint;
pub extern fn HUF_minTableLog(symbol_cardinality: c_uint) c_uint;

pub extern fn reference_bitWrite(
    dst: ?*anyopaque,
    dst_capacity: usize,
    values: [*]const usize,
    widths: [*]const c_uint,
    ops: [*]const u8,
    n: usize,
) usize;
pub extern fn reference_fseEncode(
    dst: ?*anyopaque,
    dst_capacity: usize,
    ct: [*]const c_uint,
    symbols: [*]const u8,
    extra: [*]const c_uint,
    extra_bits: [*]const c_uint,
    n: usize,
    init2: c_int,
) usize;
pub extern fn reference_fseBitCost(
    ct: [*]const c_uint,
    table_log: c_uint,
    symbol: c_uint,
    accuracy_log: c_uint,
) c_uint;
pub extern fn reference_fseGetMaxNbBits(ct: [*]const c_uint, symbol: c_uint) c_uint;

// Long distance matching: helpers in test/reference.c over the original's
// zstd_ldm.c. Parameters go as six numbers: enable, hash log, bucket size
// log, minimum match length, hash rate log, window log.

/// `rawSeq`.
pub const RawSeq = extern struct {
    offset: u32,
    lit_length: u32,
    match_length: u32,
};

/// `ldmEntry_t`.
pub const LdmEntry = extern struct {
    offset: u32,
    checksum: u32,
};

pub const ReferenceLdm = opaque {};

pub extern fn reference_ldm_adjustParameters(
    p: *[6]c_uint,
    cparams: *const ZSTD_compressionParameters,
) void;
pub extern fn reference_ldm_getTableSize(p: *const [6]c_uint) usize;
pub extern fn reference_ldm_getMaxNbSeq(p: *const [6]c_uint, max_chunk_size: usize) usize;
pub extern fn reference_ldm_gearInit(
    state: *[2]u64,
    min_match_length: c_uint,
    hash_rate_log: c_uint,
) void;
pub extern fn reference_ldm_gearReset(
    state: *[2]u64,
    data: [*]const u8,
    min_match_length: usize,
) void;
pub extern fn reference_ldm_gearFeed(
    state: *[2]u64,
    data: [*]const u8,
    size: usize,
    splits: *[64]usize,
    num_splits: *c_uint,
) usize;
pub extern fn reference_ldm_skipSequences(
    seqs: [*]RawSeq,
    size: usize,
    pos: *usize,
    src_size: usize,
    min_match: c_uint,
) void;
pub extern fn reference_ldm_skipRawSeqStoreBytes(
    seqs: [*]RawSeq,
    size: usize,
    pos: *usize,
    pos_in_sequence: *usize,
    nb_bytes: usize,
) void;
pub extern fn reference_ldm_maybeSplitSequence(
    seqs: [*]RawSeq,
    size: usize,
    pos: *usize,
    remaining: c_uint,
    min_match: c_uint,
    out: *RawSeq,
) void;
pub extern fn reference_ldm_create(p: *const [6]c_uint) ?*ReferenceLdm;
pub extern fn reference_ldm_free(ldm: ?*ReferenceLdm) void;
pub extern fn reference_ldm_hashTable(ldm: *const ReferenceLdm) [*]const LdmEntry;
pub extern fn reference_ldm_bucketOffsets(ldm: *const ReferenceLdm) [*]const u8;
pub extern fn reference_ldm_window(ldm: *const ReferenceLdm, out: *[7]usize) void;
pub extern fn reference_ldm_shiftIndexes(ldm: *ReferenceLdm, shift: c_uint) void;
pub extern fn reference_ldm_update(ldm: *ReferenceLdm, src: [*]const u8, size: usize) c_uint;
pub extern fn reference_ldm_loadDictionary(
    ldm: *ReferenceLdm,
    dict: [*]const u8,
    size: usize,
    force_window: c_int,
) void;
pub extern fn reference_ldm_fillHashTable(ldm: *ReferenceLdm, src: [*]const u8, size: usize) void;
pub extern fn reference_ldm_generateSequences(
    ldm: *ReferenceLdm,
    src: [*]const u8,
    size: usize,
    capacity: usize,
    seqs: *[*]const RawSeq,
    nb_seqs: *usize,
) usize;
/// One block compressed with long distance matching after the setup of a
/// fresh compression without a dictionary (test/reference.c). Returns the
/// size of the last literals, or the generator's error code.
pub extern fn reference_ldmBlockTest(
    cparams: *const ZSTD_compressionParameters,
    ldm: *ReferenceLdm,
    src: [*]const u8,
    src_size: usize,
    raw_capacity: usize,
    hash_table: [*]u32,
    chain_table: [*]u32,
    seqs: [*]SeqDef,
    seq_capacity: usize,
    lits: [*]u8,
    lit_capacity: usize,
    rep: *[3]u32,
    nb_seq: *usize,
    nb_lit: *usize,
    long_length_type: *u32,
    long_length_pos: *u32,
    nb_raw: *usize,
) usize;
