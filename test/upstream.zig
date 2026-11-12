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

/// The original's `rawSeq`, a long distance match candidate.
pub const RawSeq = extern struct {
    offset: u32,
    lit_length: u32,
    match_length: u32,
};

/// The optimal parser's block-level driver in test/reference.c.
pub const OptTest = opaque {};

/// What a block of the optimal parser's driver leaves.
pub const OptResult = extern struct {
    seqs: [*]const SeqDef,
    nb_seq: usize,
    lits: [*]const u8,
    nb_lit: usize,
    long_length_type: u32,
    long_length_pos: u32,
    rep: [3]u32,
    next_to_update: u32,
    dict_limit: u32,
    low_limit: u32,
    loaded_dict_end: u32,
    base: [*]const u8,
    lit_freq: [*]const u32,
    lit_length_freq: [*]const u32,
    match_length_freq: [*]const u32,
    off_code_freq: [*]const u32,
    lit_sum: u32,
    lit_length_sum: u32,
    match_length_sum: u32,
    off_code_sum: u32,
    lit_sum_base_price: u32,
    lit_length_sum_base_price: u32,
    match_length_sum_base_price: u32,
    off_code_sum_base_price: u32,
    price_type: u32,
    hash_log3: u32,
    hash_table: [*]const u32,
    chain_table: [*]const u32,
    hash_table3: [*]const u32,
    dict_hash_table: ?[*]const u32,
    dict_chain_table: ?[*]const u32,
    ldm_pos: usize,
    ldm_pos_in_sequence: usize,
};

/// A match state for the optimal parser, set up as a fresh compression sets
/// it up. `dict_kind` as `reference_blockTest`'s; the entropy tables are the
/// previous block's, null for a fresh context's; `ldm` holds the long
/// distance candidates for the whole input. Null when out of memory.
pub extern fn reference_optTestCreate(
    cparams: *const ZSTD_compressionParameters,
    dict_kind: c_int,
    dict: ?*const anyopaque,
    dict_size: usize,
    dict_cparams: *const ZSTD_compressionParameters,
    block_size_max: usize,
    literal_compression_mode: c_uint,
    huf_ctable: ?[*]const usize,
    huf_repeat: c_uint,
    of_ctable: ?[*]const u32,
    ml_ctable: ?[*]const u32,
    ll_ctable: ?[*]const u32,
    ldm: ?[*]const RawSeq,
    nb_ldm: usize,
) ?*OptTest;
pub extern fn reference_optTestFree(t: ?*OptTest) void;
/// Compresses the next block of the input; returns its last literals' size.
pub extern fn reference_optTestBlock(t: *OptTest, src: ?*const anyopaque, src_size: usize) usize;
pub extern fn reference_optTestResult(t: *const OptTest, result: *OptResult) void;
/// Entropy tables as a dictionary's, from `sample`'s byte counts and `seed`;
/// returns 0, or 1 on an error.
pub extern fn reference_optEntropy(
    sample: ?*const anyopaque,
    sample_size: usize,
    seed: c_uint,
    huf_ctable: [*]usize,
    of_ctable: [*]u32,
    ml_ctable: [*]u32,
    ll_ctable: [*]u32,
) c_int;
