//! The compressor's context and frame layers, from the original's
//! zstd_compress.c: contexts and their parameters, dictionaries, the block
//! loop with its splitters, the entropy coding of a block's sequences, and
//! the frame header and epilogue. The streaming and sequence compression
//! entry points that sit on top of these are in their own part of the file.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");

const params = @import("../params.zig");
const Error = @import("../error.zig").Error;
const zstd_internal = @import("../common/zstd_internal.zig");
const fse = @import("../common/fse.zig");
const bitstream = @import("../common/bitstream.zig");
const huf = @import("../common/huf.zig");
const entropy_common = @import("../common/entropy_common.zig");
const ci = @import("compress_internal.zig");
const cwksp = @import("cwksp.zig");
const clevels = @import("clevels.zig");
const hist = @import("hist.zig");
const fse_compress = @import("fse_compress.zig");
const huf_compress = @import("huf_compress.zig");
const compress_literals = @import("compress_literals.zig");
const compress_sequences = @import("compress_sequences.zig");
const fast = @import("fast.zig");
const double_fast = @import("double_fast.zig");
const lazy = @import("lazy.zig");
const opt = @import("opt.zig");
const ldm = @import("ldm.zig");
const compress_superblock = @import("compress_superblock.zig");
const pre_split = @import("pre_split.zig");
const zstdmt = @import("zstdmt.zig");

const assert = std.debug.assert;
const Cwksp = cwksp.Cwksp;
const CCtx = ci.CCtx;
const CCtxParams = ci.CCtxParams;
const MatchState = ci.MatchState;
const SeqStore = ci.SeqStore;
const SeqDef = ci.SeqDef;
const CompressedBlockState = ci.CompressedBlockState;
const EntropyCTables = ci.EntropyCTables;
const CompressionParameters = params.CompressionParameters;
const Strategy = params.Strategy;
const ParamSwitch = params.ParamSwitch;
const Sequence = params.Sequence;
const rep_num = zstd_internal.rep_num;
const min_match = zstd_internal.min_match;
const block_header_size = zstd_internal.block_header_size;
const kib = 1 << 10;
const mib = 1 << 20;

// ---------------------------------------------------------------------------
// Tuning constants
// ---------------------------------------------------------------------------

/// `ZSTD_HASHLOG3_MAX`: the largest table of 3-byte matches, which only the
/// optimal parser uses; the workspace is sized for it here.
pub const hash_log3_max = 17;

/// `ZSTD_NO_CLEVEL`: parameters that come from no compression level.
const no_clevel = 0;

/// `ZSTD_MAX_INPUT_SIZE`: the largest input `compressBound` takes.
const max_input_size: usize = if (@sizeOf(usize) == 8) 0xFF00FF00FF00FF00 else 0xFF00FF00;

// ---------------------------------------------------------------------------
// The original's structure sizes
// ---------------------------------------------------------------------------

/// The original's context and dictionary structures as a C compiler lays
/// them out for the target, field for field. The port's own structures
/// differ, but the workspace reserves the original's sizes for them, so that
/// `estimate*` and `sizeof*` give the original's numbers and a static
/// workspace of the original's size works.
pub const c_layout = struct {
    const Ptr = ?*anyopaque;
    const Enum = c_uint;

    /// Whether the original keeps a trace context in its contexts: its
    /// `ZSTD_TRACE` is on by default where it can use weak symbols.
    const has_trace = builtin.object_format == .elf and switch (builtin.cpu.arch) {
        .x86_64, .x86, .aarch64, .riscv32, .riscv64 => true,
        else => false,
    } and !builtin.os.tag.isDarwin() and builtin.os.tag != .windows;

    const CCustomMem = extern struct { alloc: Ptr, free: Ptr, opaque_ptr: Ptr };
    const CLdmParams = extern struct { fields: [6]u32 };
    pub const CParams = extern struct {
        format: Enum,
        cparams: [7]c_uint,
        fparams: [3]c_int,
        compression_level: c_int,
        force_window: c_int,
        target_cblock_size: usize,
        src_size_hint: c_int,
        attach_dict_pref: Enum,
        literal_compression_mode: Enum,
        nb_workers: c_int,
        job_size: usize,
        overlap_log: c_int,
        rsyncable: c_int,
        ldm_params: CLdmParams,
        enable_dedicated_dict_search: c_int,
        in_buffer_mode: Enum,
        out_buffer_mode: Enum,
        block_delimiters: Enum,
        validate_sequences: c_int,
        post_block_splitter: Enum,
        pre_block_splitter_level: c_int,
        max_block_size: usize,
        use_row_match_finder: Enum,
        deterministic_ref_prefix: c_int,
        custom_mem: CCustomMem,
        prefetch_cdict_tables: Enum,
        enable_match_finder_fallback: c_int,
        ext_seq_prod_state: Ptr,
        ext_seq_prod_func: Ptr,
        search_for_external_repcodes: Enum,
    };
    const CCwksp = extern struct {
        pointers: [7]Ptr,
        alloc_failed: u8,
        workspace_oversized_duration: c_int,
        phase: Enum,
        is_static: Enum,
    };
    pub const CXxh64State = extern struct {
        total_len: u64,
        v: [4]u64,
        mem64: [4]u64,
        memsize: u32,
        reserved32: u32,
        reserved64: u64,
    };
    const CSeqCollector = extern struct {
        collect_sequences: c_int,
        seq_start: Ptr,
        seq_index: usize,
        max_sequences: usize,
    };
    const CSeqStore = extern struct {
        pointers: [7]Ptr,
        max_nb_seq: usize,
        max_nb_lit: usize,
        long_length_type: Enum,
        long_length_pos: u32,
    };
    pub const CWindow = extern struct {
        pointers: [3]Ptr,
        limits: [3]u32,
    };
    const CLdmMatchCandidate = extern struct {
        split: Ptr,
        hash: u32,
        checksum: u32,
        bucket: Ptr,
    };
    pub const CLdmState = extern struct {
        window: CWindow,
        hash_table: Ptr,
        loaded_dict_end: u32,
        bucket_offsets: Ptr,
        split_indices: [ci.ldm_batch_size]usize,
        match_candidates: [ci.ldm_batch_size]CLdmMatchCandidate,
    };
    const CRawSeqStore = extern struct {
        seq: Ptr,
        counts: [4]usize,
    };
    const COptState = extern struct {
        tables: [6]Ptr,
        sums: [8]u32,
        price_type: Enum,
        symbol_costs: Ptr,
        literal_compression_mode: Enum,
    };
    const CMatchState = extern struct {
        window: CWindow,
        loaded_dict_end: u32,
        next_to_update: u32,
        hash_log3: u32,
        row_hash_log: u32,
        tag_table: Ptr,
        hash_cache: [ci.row_hash_cache_size]u32,
        hash_salt: u64,
        hash_salt_entropy: u32,
        tables: [3]Ptr,
        force_non_contiguous: c_int,
        dedicated_dict_search: c_int,
        opt: COptState,
        dict_match_state: Ptr,
        cparams: [7]c_uint,
        ldm_seq_store: Ptr,
        prefetch_cdict_tables: c_int,
        lazy_skipping: c_int,
    };
    const CBlockState = extern struct {
        prev_cblock: Ptr,
        next_cblock: Ptr,
        match_state: CMatchState,
    };
    const CHufCTables = extern struct {
        ctable: [huf.ctableSizeSt(255)]usize,
        repeat_mode: Enum,
    };
    const CFseCTables = extern struct {
        offcode_ctable: [fse.ctableSizeU32(zstd_internal.off_fse_log, zstd_internal.max_off)]u32,
        matchlength_ctable: [fse.ctableSizeU32(zstd_internal.ml_fse_log, zstd_internal.max_ml)]u32,
        litlength_ctable: [fse.ctableSizeU32(zstd_internal.ll_fse_log, zstd_internal.max_ll)]u32,
        repeat_modes: [3]Enum,
    };
    const CCompressedBlockState = extern struct {
        huf: CHufCTables,
        fse: CFseCTables,
        rep: [rep_num]u32,
    };
    const CBlockSplitCtx = extern struct {
        seq_stores: [5]CSeqStore,
        partitions: [ci.max_nb_block_splits]u32,
        huf_type: Enum,
        huf_des_buffer: [zstd_internal.max_huf_header_size]u8,
        huf_des_size: usize,
        fse_types: [3]Enum,
        fse_tables_buffer: [zstd_internal.max_fse_headers_size]u8,
        fse_tables_size: usize,
        last_count_size: usize,
    };
    const CInBuffer = extern struct { src: Ptr, size: usize, pos: usize };
    const CLocalDict = extern struct {
        dict_buffer: Ptr,
        dict: Ptr,
        dict_size: usize,
        dict_content_type: Enum,
        cdict: Ptr,
    };
    const CPrefixDict = extern struct { dict: Ptr, dict_size: usize, dict_content_type: Enum };

    const CCtxLayout = extern struct {
        stage: Enum,
        cparams_changed: c_int,
        bmi2: c_int,
        params: [3]CParams,
        dict_id: u32,
        dict_content_size: usize,
        workspace: CCwksp,
        block_size_max: usize,
        sizes: [3]u64,
        xxh_state: CXxh64State,
        custom_mem: CCustomMem,
        pool: Ptr,
        static_size: usize,
        seq_collector: CSeqCollector,
        is_first_block: c_int,
        initialized: c_int,
        seq_store: CSeqStore,
        ldm_state: CLdmState,
        ldm_sequences: Ptr,
        max_nb_ldm_sequences: usize,
        extern_seq_store: CRawSeqStore,
        block_state: CBlockState,
        tmp_workspace: Ptr,
        tmp_wksp_size: usize,
        buffered_policy: Enum,
        in_buff: Ptr,
        in_buff_sizes: [4]usize,
        out_buff: Ptr,
        out_buff_sizes: [3]usize,
        stream_stage: Enum,
        frame_ended: u32,
        expected_in_buffer: CInBuffer,
        stable_in_not_consumed: usize,
        expected_out_buffer_size: usize,
        local_dict: CLocalDict,
        cdict: Ptr,
        prefix_dict: CPrefixDict,
        mtctx: if (build_options.multithread) Ptr else void,
        trace_ctx: if (has_trace) u64 else void,
        block_split_ctx: CBlockSplitCtx,
        ext_seq_buf: Ptr,
        ext_seq_buf_capacity: usize,
    };

    const CDictLayout = extern struct {
        dict_content: Ptr,
        dict_content_size: usize,
        dict_content_type: Enum,
        entropy_workspace: Ptr,
        workspace: CCwksp,
        match_state: CMatchState,
        cblock_state: CCompressedBlockState,
        custom_mem: CCustomMem,
        dict_id: u32,
        compression_level: c_int,
        use_row_match_finder: Enum,
    };
};

/// The original's `sizeof(ZSTD_CCtx)`: the space a context takes at the
/// start of a static workspace.
pub const cctx_object_size = @sizeOf(c_layout.CCtxLayout);
/// The original's `sizeof(ZSTD_CDict)`.
pub const cdict_object_size = @sizeOf(c_layout.CDictLayout);
/// The original's `sizeof(ZSTD_compressedBlockState_t)`.
const cblock_state_size = @sizeOf(c_layout.CCompressedBlockState);

comptime {
    assert(@sizeOf(CCtx) <= cctx_object_size);
    assert(@alignOf(CCtx) <= @alignOf(*anyopaque));
    assert(@sizeOf(CDict) <= cdict_object_size);
    assert(@alignOf(CDict) <= @alignOf(*anyopaque));
    assert(@sizeOf(CompressedBlockState) <= cblock_state_size);
    assert(@alignOf(CompressedBlockState) <= @alignOf(*anyopaque));
    // The tables the workspace sizes with the original's element sizes.
    assert(@sizeOf(SeqDef) == 8);
    assert(@sizeOf(ci.RawSeq) == 12);
    assert(@sizeOf(ci.LdmEntry) == 8);
    assert(@sizeOf(ci.Match) == 8);
    assert(@sizeOf(ci.Optimal) == 28);
    assert(@sizeOf(Sequence) == 16);
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// `ZSTD_COMPRESSBOUND`: the largest a frame of `src_size` bytes can be,
/// compressed in one call; 0 when `src_size` is too large.
pub fn compressBoundMacro(src_size: usize) usize {
    if (src_size >= max_input_size) return 0;
    const margin = if (src_size < 128 * kib) (128 * kib - src_size) >> 11 else 0;
    return src_size + (src_size >> 8) + margin;
}

/// `ZSTD_compressBound`: the largest a frame of `src_size` bytes can be when
/// compressed in one call. Streaming with frequent flushes can exceed it.
pub fn compressBound(src_size: usize) Error!usize {
    const r = compressBoundMacro(src_size);
    if (r == 0) return error.SrcSizeWrong;
    return r;
}

// ---------------------------------------------------------------------------
// Context memory management
// ---------------------------------------------------------------------------

/// `ZSTD_CDict_s`: a dictionary digested for compression: its content, the
/// match state of its tables and the entropy tables of a full dictionary,
/// all in one workspace. Built with the `create*` functions or `initStatic`.
pub const CDict = struct {
    /// The dictionary's content: a copy in the workspace, or the caller's
    /// buffer when loaded by reference, which must then outlive the
    /// dictionary and every context it is attached to.
    dict_content: ?[*]const u8,
    dict_content_size: usize,
    /// The content type the dictionary was made with.
    dict_content_type: params.DictContentType,
    /// `huf.workspace_size` bytes in the workspace.
    entropy_workspace: [*]u8,
    workspace: Cwksp,
    match_state: MatchState,
    cblock_state: CompressedBlockState,
    /// The allocator of the workspace; null for a static dictionary.
    custom_mem: ?std.mem.Allocator,
    dict_id: u32,
    /// 0 when the dictionary was made with the advanced functions.
    compression_level: i32,
    /// Whether the dictionary was made for the row-based match finder; a
    /// context compressing with it uses the same finder unless it loads
    /// the dictionary again.
    use_row_match_finder: ParamSwitch,

    pub const create = createCDict;
    pub const createByReference = createCDictByReference;
    pub const createAdvanced = createCDictAdvanced;
    pub const createAdvanced2 = createCDictAdvanced2;
    pub const initStatic = initStaticCDict;
    pub const destroy = freeCDict;
    pub const sizeof = sizeofCDict;
    pub const getCParams = getCParamsFromCDict;
    pub const getDictId = getDictIdFromCDict;
};

/// `ZSTD_createCCtx`, `ZSTD_createCCtx_advanced`: a context allocated with
/// `gpa`, which it keeps for all its allocations.
pub fn createCCtx(gpa: std.mem.Allocator) Error!*CCtx {
    const cctx = gpa.create(CCtx) catch return error.MemoryAllocation;
    initCCtx(cctx, gpa);
    return cctx;
}

/// `ZSTD_initCCtx`.
fn initCCtx(cctx: *CCtx, gpa: ?std.mem.Allocator) void {
    cctx.* = .{ .custom_mem = gpa };
    // Resetting the parameters of a new context cannot fail.
    cctxReset(cctx, .parameters) catch unreachable;
}

/// `ZSTD_initStaticCCtx`: a context placed in `workspace`, which also holds
/// all its tables and buffers; it never allocates. `workspace` must be
/// aligned on 8 bytes, at least `estimate*` bytes for the compressions it
/// will run, and must outlive the context, which is never destroyed: the
/// caller frees `workspace`. Null when `workspace` is too small or
/// misaligned.
pub fn initStaticCCtx(workspace: []u8) ?*CCtx {
    if (workspace.len <= cctx_object_size) return null;
    if (@intFromPtr(workspace.ptr) & 7 != 0) return null;
    var ws: Cwksp = .{};
    ws.init(workspace, .static_alloc);

    const cctx_bytes = ws.reserveObject(cctx_object_size) orelse return null;
    const cctx: *CCtx = @ptrCast(@alignCast(cctx_bytes));
    // The original zeroes a static context without setting its parameters,
    // so their content size flag is off.
    cctx.* = .{};
    cctx.requested_params.fparams.content_size_flag = false;
    cctx.applied_params.fparams.content_size_flag = false;
    cctx.simple_api_params.fparams.content_size_flag = false;
    Cwksp.move(&cctx.workspace, &ws);
    cctx.static_size = workspace.len;

    // The fixed objects; the temporary workspace never moves, the block
    // states swap places. In a workspace a few bytes larger than the
    // context, the buffers' start, aligned down, falls before the context's
    // end: the original's space check wraps and passes, and it returns a
    // context without them. The port returns null.
    const objects_size = ci.tmp_workspace_size + 2 * cblock_state_size;
    if (@intFromPtr(
        cctx.workspace.alloc_start,
    ) < @intFromPtr(cctx.workspace.table_end)) return null;
    if (!cctx.workspace.checkAvailable(objects_size)) return null;
    cctx.block_state.prev_cblock = @ptrCast(cctx.workspace.reserveObject(cblock_state_size).?);
    cctx.block_state.next_cblock = @ptrCast(cctx.workspace.reserveObject(cblock_state_size).?);
    cctx.tmp_workspace = @alignCast(cctx.workspace.reserveObject(ci.tmp_workspace_size).?);
    cctx.tmp_wksp_size = ci.tmp_workspace_size;
    return cctx;
}

/// `ZSTD_clearAllDicts`: frees and forgets every dictionary.
fn clearAllDicts(cctx: *CCtx) void {
    if (cctx.local_dict.dict_buffer) |buffer| {
        cctx.custom_mem.?.free(buffer[0..cctx.local_dict.dict_size]);
    }
    if (cctx.local_dict.cdict) |cdict| freeCDict(cdict);
    cctx.local_dict = .{};
    cctx.prefix_dict = .{};
    cctx.cdict = null;
}

/// `ZSTD_sizeof_localDict`.
fn sizeofLocalDict(dict: ci.LocalDict) usize {
    const buffer_size = if (dict.dict_buffer != null) dict.dict_size else 0;
    const cdict_size = if (dict.cdict) |cdict| sizeofCDict(cdict) else 0;
    return buffer_size + cdict_size;
}

/// `ZSTD_freeCCtxContent`.
fn freeCCtxContent(cctx: *CCtx) void {
    assert(cctx.static_size == 0);
    clearAllDicts(cctx);
    if (build_options.multithread) {
        if (cctx.mtctx) |mtctx| mtctx.free();
        cctx.mtctx = null;
    }
    cctx.workspace.free(cctx.custom_mem.?);
}

/// `ZSTD_freeCCtx`: frees a context made by `create`, with its dictionaries.
/// A static context cannot be freed: its caller frees its workspace.
pub fn freeCCtx(cctx: *CCtx) Error!void {
    if (cctx.static_size != 0) return error.MemoryAllocation;
    const gpa = cctx.custom_mem.?;
    const cctx_in_workspace = cctx.workspace.ownsBuffer(cctx);
    freeCCtxContent(cctx);
    if (!cctx_in_workspace) gpa.destroy(cctx);
}

/// `ZSTD_sizeof_mtctx`: the multithreaded context's size, for `sizeofCCtx`.
fn sizeofMtctx(cctx: *const CCtx) usize {
    if (!build_options.multithread) return 0;
    return zstdmt.ZstdmtCCtx.sizeof(cctx.mtctx);
}

/// `ZSTD_sizeof_CCtx`, `ZSTD_sizeof_CStream`: the memory the context uses,
/// itself included unless it is in its workspace.
pub fn sizeofCCtx(cctx: *const CCtx) usize {
    const in_workspace = @intFromPtr(cctx.workspace.workspace) == @intFromPtr(cctx);
    return (if (in_workspace) 0 else @as(usize, cctx_object_size)) +
        cctx.workspace.sizeof() +
        sizeofLocalDict(cctx.local_dict) +
        sizeofMtctx(cctx);
}

/// `ZSTD_getSeqStore`.
pub fn getSeqStore(cctx: *const CCtx) *const SeqStore {
    return &cctx.seq_store;
}

/// `ZSTD_rowMatchFinderSupported`: whether `strategy` can use the row-based
/// match finder.
fn rowMatchFinderSupported(strategy: Strategy) bool {
    const strat = @backingInt(strategy);
    return strat >= @backingInt(Strategy.greedy) and strat <= @backingInt(Strategy.lazy2);
}

/// `ZSTD_rowMatchFinderUsed`: whether the compression uses the row-based
/// match finder; `mode` is resolved.
fn rowMatchFinderUsed(strategy: Strategy, mode: ParamSwitch) bool {
    assert(mode != .auto);
    return rowMatchFinderSupported(strategy) and mode == .enable;
}

/// `ZSTD_resolveRowMatchFinderMode`.
fn resolveRowMatchFinderMode(mode: ParamSwitch, cparams: *const CompressionParameters) ParamSwitch {
    // Enabled stays enabled, even without SIMD.
    if (mode != .auto) return mode;
    if (!rowMatchFinderSupported(cparams.strategy)) return .disable;
    if (cparams.window_log > 14) return .enable;
    return .disable;
}

/// `ZSTD_resolveBlockSplitterMode`: the post-splitter is on for the
/// stronger strategies with large windows.
fn resolveBlockSplitterMode(mode: ParamSwitch, cparams: *const CompressionParameters) ParamSwitch {
    if (mode != .auto) return mode;
    const strong = @backingInt(cparams.strategy) >= @backingInt(Strategy.btopt);
    return if (strong and cparams.window_log >= 17) .enable else .disable;
}

/// `ZSTD_allocateChainTable`: whether the match state needs a chain table:
/// always for a dedicated dictionary search dictionary, never for `fast` or
/// the row-based match finder.
fn allocateChainTable(
    strategy: Strategy,
    use_row_match_finder: ParamSwitch,
    for_dds_dict: bool,
) bool {
    assert(use_row_match_finder != .auto);
    return for_dds_dict or
        (strategy != .fast and !rowMatchFinderUsed(strategy, use_row_match_finder));
}

/// `ZSTD_resolveEnableLdm`: long distance matching is on for the stronger
/// strategies with windows of 128 MiB or more.
fn resolveEnableLdm(mode: ParamSwitch, cparams: *const CompressionParameters) ParamSwitch {
    if (mode != .auto) return mode;
    const strong = @backingInt(cparams.strategy) >= @backingInt(Strategy.btopt);
    return if (strong and cparams.window_log >= 27) .enable else .disable;
}

/// `ZSTD_resolveExternalSequenceValidation`.
fn resolveExternalSequenceValidation(mode: bool) bool {
    return mode;
}

/// `ZSTD_resolveMaxBlockSize`.
fn resolveMaxBlockSize(max_block_size: usize) usize {
    return if (max_block_size == 0) params.block_size_max else max_block_size;
}

/// `ZSTD_resolveExternalRepcodeSearch`: the repeat-code search over external
/// sequences is on from level 10.
fn resolveExternalRepcodeSearch(value: ParamSwitch, compression_level: i32) ParamSwitch {
    if (value != .auto) return value;
    return if (compression_level < 10) .disable else .enable;
}

/// `ZSTD_CDictIndicesAreTagged`: whether a dictionary's hash and chain
/// tables carry short cache tags, which a copy into a context removes.
fn cdictIndicesAreTagged(cparams: *const CompressionParameters) bool {
    return cparams.strategy == .fast or cparams.strategy == .dfast;
}

/// `ZSTD_makeCCtxParamsFromCParams`.
fn makeCCtxParamsFromCParams(cparams: CompressionParameters) CCtxParams {
    var cctx_params = cctxParamsInit(params.clevel_default);
    cctx_params.cparams = cparams;

    // The advanced parameters that follow from the compression parameters.
    cctx_params.ldm_params.enable_ldm = resolveEnableLdm(
        cctx_params.ldm_params.enable_ldm,
        &cparams,
    );
    if (cctx_params.ldm_params.enable_ldm == .enable) {
        ldm.adjustParameters(&cctx_params.ldm_params, &cparams);
        assert(cctx_params.ldm_params.hash_log >= cctx_params.ldm_params.bucket_size_log);
        assert(cctx_params.ldm_params.hash_rate_log < 32);
    }
    cctx_params.post_block_splitter =
        resolveBlockSplitterMode(cctx_params.post_block_splitter, &cparams);
    cctx_params.use_row_match_finder =
        resolveRowMatchFinderMode(cctx_params.use_row_match_finder, &cparams);
    cctx_params.validate_sequences =
        resolveExternalSequenceValidation(cctx_params.validate_sequences);
    cctx_params.max_block_size = resolveMaxBlockSize(cctx_params.max_block_size);
    cctx_params.search_for_external_repcodes = resolveExternalRepcodeSearch(
        cctx_params.search_for_external_repcodes,
        cctx_params.compression_level,
    );
    assert(checkCParamsValid(cparams));
    return cctx_params;
}

/// `ZSTD_createCCtxParams`, `ZSTD_createCCtxParams_advanced`: parameters
/// allocated with `gpa`, at the default level.
pub fn createCCtxParams(gpa: std.mem.Allocator) Error!*CCtxParams {
    const cctx_params = gpa.create(CCtxParams) catch return error.MemoryAllocation;
    cctx_params.* = cctxParamsInit(params.clevel_default);
    cctx_params.custom_mem = gpa;
    return cctx_params;
}

/// `ZSTD_freeCCtxParams`: frees parameters made by `createCCtxParams`.
pub fn freeCCtxParams(cctx_params: *CCtxParams) void {
    const gpa = cctx_params.custom_mem.?;
    cctx_params.* = undefined;
    gpa.destroy(cctx_params);
}

/// `ZSTD_CCtxParams_reset`: back to the default level, every other
/// parameter unset. The allocator `createCCtxParams` gave is kept.
pub fn cctxParamsReset(cctx_params: *CCtxParams) void {
    const gpa = cctx_params.custom_mem;
    cctx_params.* = cctxParamsInit(params.clevel_default);
    cctx_params.custom_mem = gpa;
}

/// `ZSTD_CCtxParams_init`: parameters at `compression_level`, every other
/// parameter unset.
pub fn cctxParamsInit(compression_level: i32) CCtxParams {
    return .{ .compression_level = compression_level };
}

/// `ZSTD_CCtxParams_init_internal`: parameters from `parameters` and the
/// level they come from, or `no_clevel`; the parameters left to the
/// compression parameters are resolved.
fn cctxParamsInitInternal(parameters: *const params.Parameters, compression_level: i32) CCtxParams {
    assert(checkCParamsValid(parameters.cparams));
    var cctx_params: CCtxParams = .{
        .cparams = parameters.cparams,
        .fparams = parameters.fparams,
        .compression_level = compression_level,
    };
    const cparams = &parameters.cparams;
    cctx_params.use_row_match_finder =
        resolveRowMatchFinderMode(cctx_params.use_row_match_finder, cparams);
    cctx_params.post_block_splitter =
        resolveBlockSplitterMode(cctx_params.post_block_splitter, cparams);
    cctx_params.ldm_params.enable_ldm = resolveEnableLdm(
        cctx_params.ldm_params.enable_ldm,
        cparams,
    );
    cctx_params.validate_sequences =
        resolveExternalSequenceValidation(cctx_params.validate_sequences);
    cctx_params.max_block_size = resolveMaxBlockSize(cctx_params.max_block_size);
    cctx_params.search_for_external_repcodes = resolveExternalRepcodeSearch(
        cctx_params.search_for_external_repcodes,
        compression_level,
    );
    return cctx_params;
}

/// `ZSTD_CCtxParams_init_advanced`: parameters from `parameters`, which must
/// be valid.
pub fn cctxParamsInitAdvanced(parameters: params.Parameters) Error!CCtxParams {
    try checkCParams(parameters.cparams);
    return cctxParamsInitInternal(&parameters, no_clevel);
}

/// `ZSTD_CCtxParams_setZstdParams`: sets the compression and frame
/// parameters only, from valid `parameters`.
fn cctxParamsSetZstdParams(cctx_params: *CCtxParams, parameters: *const params.Parameters) void {
    assert(checkCParamsValid(parameters.cparams));
    cctx_params.cparams = parameters.cparams;
    cctx_params.fparams = parameters.fparams;
    cctx_params.compression_level = no_clevel;
}

/// `ZSTD_cParam_getBounds`: the values `param` takes.
pub fn cParamGetBounds(param: params.CParameter) params.Bounds {
    const ps_bounds: params.Bounds = .{
        .lower = @backingInt(ParamSwitch.auto),
        .upper = @backingInt(ParamSwitch.disable),
    };
    const flag: params.Bounds = .{ .lower = 0, .upper = 1 };
    const mt = build_options.multithread;
    return switch (param) {
        .compression_level => .{ .lower = minCLevel(), .upper = maxCLevel() },
        .window_log => .{ .lower = params.window_log_min, .upper = params.window_log_max },
        .hash_log => .{ .lower = params.hash_log_min, .upper = params.hash_log_max },
        .chain_log => .{ .lower = params.chain_log_min, .upper = params.chain_log_max },
        .search_log => .{ .lower = params.search_log_min, .upper = params.search_log_max },
        .min_match => .{ .lower = params.min_match_min, .upper = params.min_match_max },
        .target_length => .{
            .lower = params.target_length_min,
            .upper = params.target_length_max,
        },
        .strategy => .{
            .lower = @backingInt(params.strategy_min),
            .upper = @backingInt(params.strategy_max),
        },
        .content_size_flag, .checksum_flag, .dict_id_flag => flag,
        .nb_workers => .{ .lower = 0, .upper = if (mt) @intCast(zstdmt.nbworkers_max) else 0 },
        .job_size => .{ .lower = 0, .upper = if (mt) @intCast(zstdmt.jobsize_max) else 0 },
        .overlap_log => if (mt)
            .{ .lower = params.overlap_log_min, .upper = params.overlap_log_max }
        else
            .{ .lower = 0, .upper = 0 },
        .enable_dedicated_dict_search => flag,
        .enable_long_distance_matching => ps_bounds,
        .ldm_hash_log => .{ .lower = params.ldm_hash_log_min, .upper = params.ldm_hash_log_max },
        .ldm_min_match => .{
            .lower = params.ldm_min_match_min,
            .upper = params.ldm_min_match_max,
        },
        .ldm_bucket_size_log => .{
            .lower = params.ldm_bucket_size_log_min,
            .upper = params.ldm_bucket_size_log_max,
        },
        .ldm_hash_rate_log => .{
            .lower = params.ldm_hash_rate_log_min,
            .upper = params.ldm_hash_rate_log_max,
        },
        .rsyncable, .force_max_window => flag,
        .format => .{
            .lower = @backingInt(params.Format.zstd1),
            .upper = @backingInt(params.Format.zstd1_magicless),
        },
        .force_attach_dict => .{
            .lower = @backingInt(params.DictAttachPref.default),
            .upper = @backingInt(params.DictAttachPref.force_load),
        },
        .literal_compression_mode => ps_bounds,
        .target_cblock_size => .{
            .lower = params.target_cblock_size_min,
            .upper = params.target_cblock_size_max,
        },
        .src_size_hint => .{ .lower = params.src_size_hint_min, .upper = params.src_size_hint_max },
        .stable_in_buffer, .stable_out_buffer => .{
            .lower = @backingInt(zstd_internal.BufferMode.buffered),
            .upper = @backingInt(zstd_internal.BufferMode.stable),
        },
        .block_delimiters => .{
            .lower = @backingInt(params.SequenceFormat.no_block_delimiters),
            .upper = @backingInt(params.SequenceFormat.explicit_block_delimiters),
        },
        .validate_sequences => flag,
        .split_after_sequences => ps_bounds,
        .block_splitter_level => .{ .lower = 0, .upper = params.block_splitter_level_max },
        .use_row_match_finder => ps_bounds,
        .deterministic_ref_prefix => flag,
        .prefetch_cdict_tables => ps_bounds,
        .enable_seq_producer_fallback => flag,
        .max_block_size => .{ .lower = params.block_size_max_min, .upper = params.block_size_max },
        .repcode_resolution => ps_bounds,
    };
}

/// `ZSTD_cParam_withinBounds`.
pub fn cParamWithinBounds(param: params.CParameter, value: i32) bool {
    const bounds = cParamGetBounds(param);
    return value >= bounds.lower and value <= bounds.upper;
}

/// `ZSTD_cParam_clampBounds`: `value` brought into `param`'s bounds.
fn cParamClampBounds(param: params.CParameter, value: i32) i32 {
    const bounds = cParamGetBounds(param);
    return std.math.clamp(value, bounds.lower, bounds.upper);
}

/// `BOUNDCHECK`.
fn boundCheck(param: params.CParameter, value: i32) Error!void {
    if (!cParamWithinBounds(param, value)) return error.ParameterOutOfBound;
}

/// `ZSTD_isUpdateAuthorized`: whether `param` may change while a frame is
/// being compressed; the change applies to the next job of a multithreaded
/// compression.
fn isUpdateAuthorized(param: params.CParameter) bool {
    return switch (param) {
        .compression_level,
        .hash_log,
        .chain_log,
        .search_log,
        .min_match,
        .target_length,
        .strategy,
        .block_splitter_level,
        => true,
        else => false,
    };
}

/// `ZSTD_CCtx_setParameter`: sets `param` for the next frames; returns the
/// value set where the original does. Only the parameters
/// `isUpdateAuthorized` accepts may change while a frame is in progress.
pub fn cctxSetParameter(cctx: *CCtx, param: params.CParameter, value: i32) Error!usize {
    if (cctx.stream_stage != .init) {
        if (isUpdateAuthorized(param)) {
            cctx.cparams_changed = true;
        } else {
            return error.StageWrong;
        }
    }
    if (param == .nb_workers and value != 0 and cctx.static_size != 0) {
        return error.ParameterUnsupported;
    }
    return cctxParamsSetParameter(&cctx.requested_params, param, value);
}

/// The parameter switch `value`, already bound-checked.
fn paramSwitch(value: i32) ParamSwitch {
    return @fromBackingInt(@as(u32, @intCast(value)));
}

/// `ZSTD_CCtxParams_setParameter`: sets `param` in `cctx_params`; returns
/// the value set where the original does (0 for a negative level).
pub fn cctxParamsSetParameter(
    cctx_params: *CCtxParams,
    param: params.CParameter,
    value_in: i32,
) Error!usize {
    var value = value_in;
    const mt = build_options.multithread;
    switch (param) {
        .format => {
            try boundCheck(param, value);
            cctx_params.format = @fromBackingInt(@as(u32, @intCast(value)));
            return @backingInt(cctx_params.format);
        },
        .compression_level => {
            value = cParamClampBounds(param, value);
            cctx_params.compression_level = if (value == 0) params.clevel_default else value;
            if (cctx_params.compression_level >= 0) {
                return @intCast(cctx_params.compression_level);
            }
            // The original's size_t result cannot hold a negative level.
            return 0;
        },
        .window_log => {
            if (value != 0) try boundCheck(param, value);
            cctx_params.cparams.window_log = @intCast(value);
            return cctx_params.cparams.window_log;
        },
        .hash_log => {
            if (value != 0) try boundCheck(param, value);
            cctx_params.cparams.hash_log = @intCast(value);
            return cctx_params.cparams.hash_log;
        },
        .chain_log => {
            if (value != 0) try boundCheck(param, value);
            cctx_params.cparams.chain_log = @intCast(value);
            return cctx_params.cparams.chain_log;
        },
        .search_log => {
            if (value != 0) try boundCheck(param, value);
            cctx_params.cparams.search_log = @intCast(value);
            return @intCast(value);
        },
        .min_match => {
            if (value != 0) try boundCheck(param, value);
            cctx_params.cparams.min_match = @intCast(value);
            return cctx_params.cparams.min_match;
        },
        .target_length => {
            try boundCheck(param, value);
            cctx_params.cparams.target_length = @intCast(value);
            return cctx_params.cparams.target_length;
        },
        .strategy => {
            if (value != 0) try boundCheck(param, value);
            cctx_params.cparams.strategy = @fromBackingInt(@as(u32, @intCast(value)));
            return @backingInt(cctx_params.cparams.strategy);
        },
        .content_size_flag => {
            // The content size is written in the frame header when known.
            cctx_params.fparams.content_size_flag = value != 0;
            return @intFromBool(cctx_params.fparams.content_size_flag);
        },
        .checksum_flag => {
            cctx_params.fparams.checksum_flag = value != 0;
            return @intFromBool(cctx_params.fparams.checksum_flag);
        },
        .dict_id_flag => {
            cctx_params.fparams.no_dict_id_flag = value == 0;
            return @intFromBool(!cctx_params.fparams.no_dict_id_flag);
        },
        .force_max_window => {
            cctx_params.force_window = value != 0;
            return @intFromBool(cctx_params.force_window);
        },
        .force_attach_dict => {
            try boundCheck(param, value);
            cctx_params.attach_dict_pref = @fromBackingInt(@as(u32, @intCast(value)));
            return @backingInt(cctx_params.attach_dict_pref);
        },
        .literal_compression_mode => {
            try boundCheck(param, value);
            cctx_params.literal_compression_mode = paramSwitch(value);
            return @backingInt(cctx_params.literal_compression_mode);
        },
        .nb_workers => {
            if (!mt) {
                if (value != 0) return error.ParameterUnsupported;
                return 0;
            }
            value = cParamClampBounds(param, value);
            cctx_params.nb_workers = value;
            return @intCast(cctx_params.nb_workers);
        },
        .job_size => {
            if (!mt) {
                if (value != 0) return error.ParameterUnsupported;
                return 0;
            }
            // Raised to the smallest job size that is not the default.
            const jobsize_min: i32 = @intCast(zstdmt.jobsize_min);
            if (value != 0 and value < jobsize_min) value = jobsize_min;
            value = cParamClampBounds(param, value);
            assert(value >= 0);
            cctx_params.job_size = @intCast(value);
            return cctx_params.job_size;
        },
        .overlap_log => {
            if (!mt) {
                if (value != 0) return error.ParameterUnsupported;
                return 0;
            }
            value = cParamClampBounds(.overlap_log, value);
            cctx_params.overlap_log = value;
            return @intCast(cctx_params.overlap_log);
        },
        .rsyncable => {
            if (!mt) {
                if (value != 0) return error.ParameterUnsupported;
                return 0;
            }
            // The original clamps to the overlap log's bounds here.
            value = cParamClampBounds(.overlap_log, value);
            cctx_params.rsyncable = value;
            return @intCast(cctx_params.rsyncable);
        },
        .enable_dedicated_dict_search => {
            cctx_params.enable_dedicated_dict_search = value != 0;
            return @intFromBool(cctx_params.enable_dedicated_dict_search);
        },
        .enable_long_distance_matching => {
            try boundCheck(param, value);
            cctx_params.ldm_params.enable_ldm = paramSwitch(value);
            return @backingInt(cctx_params.ldm_params.enable_ldm);
        },
        .ldm_hash_log => {
            if (value != 0) try boundCheck(param, value);
            cctx_params.ldm_params.hash_log = @intCast(value);
            return cctx_params.ldm_params.hash_log;
        },
        .ldm_min_match => {
            if (value != 0) try boundCheck(param, value);
            cctx_params.ldm_params.min_match_length = @intCast(value);
            return cctx_params.ldm_params.min_match_length;
        },
        .ldm_bucket_size_log => {
            if (value != 0) try boundCheck(param, value);
            cctx_params.ldm_params.bucket_size_log = @intCast(value);
            return cctx_params.ldm_params.bucket_size_log;
        },
        .ldm_hash_rate_log => {
            if (value != 0) try boundCheck(param, value);
            cctx_params.ldm_params.hash_rate_log = @intCast(value);
            return cctx_params.ldm_params.hash_rate_log;
        },
        .target_cblock_size => {
            if (value != 0) {
                value = @max(value, params.target_cblock_size_min);
                try boundCheck(param, value);
            }
            cctx_params.target_cblock_size = @as(u32, @intCast(value));
            return cctx_params.target_cblock_size;
        },
        .src_size_hint => {
            if (value != 0) try boundCheck(param, value);
            cctx_params.src_size_hint = value;
            return @intCast(cctx_params.src_size_hint);
        },
        .stable_in_buffer => {
            try boundCheck(param, value);
            cctx_params.in_buffer_mode = @fromBackingInt(@as(u1, @intCast(value)));
            return @backingInt(cctx_params.in_buffer_mode);
        },
        .stable_out_buffer => {
            try boundCheck(param, value);
            cctx_params.out_buffer_mode = @fromBackingInt(@as(u1, @intCast(value)));
            return @backingInt(cctx_params.out_buffer_mode);
        },
        .block_delimiters => {
            try boundCheck(param, value);
            cctx_params.block_delimiters = @fromBackingInt(@as(u32, @intCast(value)));
            return @backingInt(cctx_params.block_delimiters);
        },
        .validate_sequences => {
            try boundCheck(param, value);
            cctx_params.validate_sequences = value != 0;
            return @intFromBool(cctx_params.validate_sequences);
        },
        .split_after_sequences => {
            try boundCheck(param, value);
            cctx_params.post_block_splitter = paramSwitch(value);
            return @backingInt(cctx_params.post_block_splitter);
        },
        .block_splitter_level => {
            try boundCheck(param, value);
            cctx_params.pre_block_splitter_level = value;
            return @intCast(cctx_params.pre_block_splitter_level);
        },
        .use_row_match_finder => {
            try boundCheck(param, value);
            cctx_params.use_row_match_finder = paramSwitch(value);
            return @backingInt(cctx_params.use_row_match_finder);
        },
        .deterministic_ref_prefix => {
            try boundCheck(param, value);
            cctx_params.deterministic_ref_prefix = value != 0;
            return @intFromBool(cctx_params.deterministic_ref_prefix);
        },
        .prefetch_cdict_tables => {
            try boundCheck(param, value);
            cctx_params.prefetch_cdict_tables = paramSwitch(value);
            return @backingInt(cctx_params.prefetch_cdict_tables);
        },
        .enable_seq_producer_fallback => {
            try boundCheck(param, value);
            cctx_params.enable_match_finder_fallback = value != 0;
            return @intFromBool(cctx_params.enable_match_finder_fallback);
        },
        .max_block_size => {
            if (value != 0) try boundCheck(param, value);
            cctx_params.max_block_size = @intCast(value);
            return cctx_params.max_block_size;
        },
        .repcode_resolution => {
            try boundCheck(param, value);
            cctx_params.search_for_external_repcodes = paramSwitch(value);
            return @backingInt(cctx_params.search_for_external_repcodes);
        },
    }
}

/// `ZSTD_CCtx_getParameter`: the value of `param` the next frame asks for.
pub fn cctxGetParameter(cctx: *const CCtx, param: params.CParameter) Error!i32 {
    return cctxParamsGetParameter(&cctx.requested_params, param);
}

/// `ZSTD_CCtxParams_getParameter`.
pub fn cctxParamsGetParameter(cctx_params: *const CCtxParams, param: params.CParameter) Error!i32 {
    const mt = build_options.multithread;
    const p = cctx_params;
    return switch (param) {
        .format => @intCast(@backingInt(p.format)),
        .compression_level => p.compression_level,
        .window_log => @intCast(p.cparams.window_log),
        .hash_log => @intCast(p.cparams.hash_log),
        .chain_log => @intCast(p.cparams.chain_log),
        .search_log => @intCast(p.cparams.search_log),
        .min_match => @intCast(p.cparams.min_match),
        .target_length => @intCast(p.cparams.target_length),
        .strategy => @intCast(@backingInt(p.cparams.strategy)),
        .content_size_flag => @intFromBool(p.fparams.content_size_flag),
        .checksum_flag => @intFromBool(p.fparams.checksum_flag),
        .dict_id_flag => @intFromBool(!p.fparams.no_dict_id_flag),
        .force_max_window => @intFromBool(p.force_window),
        .force_attach_dict => @intCast(@backingInt(p.attach_dict_pref)),
        .literal_compression_mode => @intCast(@backingInt(p.literal_compression_mode)),
        .nb_workers => p.nb_workers,
        .job_size => if (mt) @intCast(p.job_size) else error.ParameterUnsupported,
        .overlap_log => if (mt) p.overlap_log else error.ParameterUnsupported,
        .rsyncable => if (mt) p.rsyncable else error.ParameterUnsupported,
        .enable_dedicated_dict_search => @intFromBool(p.enable_dedicated_dict_search),
        .enable_long_distance_matching => @intCast(@backingInt(p.ldm_params.enable_ldm)),
        .ldm_hash_log => @intCast(p.ldm_params.hash_log),
        .ldm_min_match => @intCast(p.ldm_params.min_match_length),
        .ldm_bucket_size_log => @intCast(p.ldm_params.bucket_size_log),
        .ldm_hash_rate_log => @intCast(p.ldm_params.hash_rate_log),
        .target_cblock_size => @intCast(p.target_cblock_size),
        .src_size_hint => p.src_size_hint,
        .stable_in_buffer => @intCast(@backingInt(p.in_buffer_mode)),
        .stable_out_buffer => @intCast(@backingInt(p.out_buffer_mode)),
        .block_delimiters => @intCast(@backingInt(p.block_delimiters)),
        .validate_sequences => @intFromBool(p.validate_sequences),
        .split_after_sequences => @intCast(@backingInt(p.post_block_splitter)),
        .block_splitter_level => p.pre_block_splitter_level,
        .use_row_match_finder => @intCast(@backingInt(p.use_row_match_finder)),
        .deterministic_ref_prefix => @intFromBool(p.deterministic_ref_prefix),
        .prefetch_cdict_tables => @intCast(@backingInt(p.prefetch_cdict_tables)),
        .enable_seq_producer_fallback => @intFromBool(p.enable_match_finder_fallback),
        .max_block_size => @intCast(p.max_block_size),
        .repcode_resolution => @intCast(@backingInt(p.search_for_external_repcodes)),
    };
}

/// `ZSTD_CCtx_setParametersUsingCCtxParams`: takes `cctx_params` as the
/// parameters of the next frames. Only between frames, and not while a
/// dictionary is referenced, as some parameters come from it.
pub fn cctxSetParametersUsingCCtxParams(cctx: *CCtx, cctx_params: *const CCtxParams) Error!void {
    if (cctx.stream_stage != .init) return error.StageWrong;
    if (cctx.cdict != null) return error.StageWrong;
    cctx.requested_params = cctx_params.*;
}

/// `ZSTD_CCtx_setCParams`: sets all the compression parameters, or none
/// when one is out of bounds.
pub fn cctxSetCParams(cctx: *CCtx, cparams: CompressionParameters) Error!void {
    try checkCParams(cparams);
    _ = try cctxSetParameter(cctx, .window_log, @intCast(cparams.window_log));
    _ = try cctxSetParameter(cctx, .chain_log, @intCast(cparams.chain_log));
    _ = try cctxSetParameter(cctx, .hash_log, @intCast(cparams.hash_log));
    _ = try cctxSetParameter(cctx, .search_log, @intCast(cparams.search_log));
    _ = try cctxSetParameter(cctx, .min_match, @intCast(cparams.min_match));
    _ = try cctxSetParameter(cctx, .target_length, @intCast(cparams.target_length));
    _ = try cctxSetParameter(cctx, .strategy, @intCast(@backingInt(cparams.strategy)));
}

/// `ZSTD_CCtx_setFParams`.
pub fn cctxSetFParams(cctx: *CCtx, fparams: params.FrameParameters) Error!void {
    _ = try cctxSetParameter(cctx, .content_size_flag, @intFromBool(fparams.content_size_flag));
    _ = try cctxSetParameter(cctx, .checksum_flag, @intFromBool(fparams.checksum_flag));
    _ = try cctxSetParameter(cctx, .dict_id_flag, @intFromBool(!fparams.no_dict_id_flag));
}

/// `ZSTD_CCtx_setParams`: sets all of `parameters`, or none when a
/// compression parameter is out of bounds.
pub fn cctxSetParams(cctx: *CCtx, parameters: params.Parameters) Error!void {
    // The compression parameters first, to set all or none; then the frame
    // parameters, which fail outside the init stage; then the compression
    // parameters, which then succeed.
    try checkCParams(parameters.cparams);
    try cctxSetFParams(cctx, parameters.fparams);
    try cctxSetCParams(cctx, parameters.cparams);
}

/// `ZSTD_CCtx_setPledgedSrcSize`: the size of the next frame's content,
/// which it must then have; `params.content_size_unknown` when unknown.
pub fn cctxSetPledgedSrcSize(cctx: *CCtx, pledged_src_size: u64) Error!void {
    if (cctx.stream_stage != .init) return error.StageWrong;
    cctx.pledged_src_size_plus_one = pledged_src_size +% 1;
}

/// `ZSTD_initLocalDict`: digests the dictionary loaded with
/// `loadDictionary*` into a dictionary of the requested parameters, once:
/// it serves every frame until the dictionary changes. The pledged size is
/// not used, as the dictionary may serve many frames.
fn initLocalDict(cctx: *CCtx) Error!void {
    const dl = &cctx.local_dict;
    if (dl.dict == null) {
        assert(dl.dict_buffer == null);
        assert(dl.cdict == null);
        assert(dl.dict_size == 0);
        return;
    }
    if (dl.cdict != null) {
        assert(cctx.cdict == dl.cdict);
        return;
    }
    assert(dl.dict_size > 0);
    assert(cctx.cdict == null);
    assert(cctx.prefix_dict.dict == null);

    // A static context has no allocator: the original allocates with
    // malloc here, the port refuses.
    const gpa = cctx.custom_mem orelse return error.MemoryAllocation;
    dl.cdict = createCDictAdvanced2(
        gpa,
        dl.dict.?[0..dl.dict_size],
        .by_ref,
        dl.dict_content_type,
        &cctx.requested_params,
    ) catch return error.MemoryAllocation;
    cctx.cdict = dl.cdict;
}

/// `ZSTD_CCtx_loadDictionary_advanced`: the dictionary of the next frames,
/// digested on their first use; an empty one clears it. Loaded by
/// reference, `dict` must stay valid until the dictionary is replaced or
/// cleared (`reset` with parameters, another `loadDictionary*`, `refCDict`
/// or `refPrefix*`) or the context destroyed.
pub fn cctxLoadDictionaryAdvanced(
    cctx: *CCtx,
    dict: []const u8,
    dict_load_method: params.DictLoadMethod,
    dict_content_type: params.DictContentType,
) Error!void {
    if (cctx.stream_stage != .init) return error.StageWrong;
    clearAllDicts(cctx);
    if (dict.len == 0) return;
    if (dict_load_method == .by_ref) {
        cctx.local_dict.dict = dict.ptr;
    } else {
        // A copy the context owns.
        if (cctx.static_size != 0) return error.MemoryAllocation;
        const buffer = cctx.custom_mem.?.alloc(u8, dict.len) catch return error.MemoryAllocation;
        @memcpy(buffer, dict);
        cctx.local_dict.dict_buffer = buffer.ptr;
        cctx.local_dict.dict = buffer.ptr;
    }
    cctx.local_dict.dict_size = dict.len;
    cctx.local_dict.dict_content_type = dict_content_type;
}

/// `ZSTD_CCtx_loadDictionary_byReference`.
pub fn cctxLoadDictionaryByReference(cctx: *CCtx, dict: []const u8) Error!void {
    return cctxLoadDictionaryAdvanced(cctx, dict, .by_ref, .auto);
}

/// `ZSTD_CCtx_loadDictionary`.
pub fn cctxLoadDictionary(cctx: *CCtx, dict: []const u8) Error!void {
    return cctxLoadDictionaryAdvanced(cctx, dict, .by_copy, .auto);
}

/// `ZSTD_CCtx_refCDict`: the dictionary of the next frames, with its
/// parameters; null clears it. `cdict` must stay valid until it is replaced
/// or cleared (as for `loadDictionaryAdvanced`) or the context destroyed.
pub fn cctxRefCDict(cctx: *CCtx, cdict: ?*const CDict) Error!void {
    if (cctx.stream_stage != .init) return error.StageWrong;
    // The local dictionary goes, to save memory.
    clearAllDicts(cctx);
    cctx.cdict = cdict;
}

/// The `Io` whose locks multithreaded compression takes, which must stay
/// valid until the context is destroyed. A frame with workers needs one,
/// or a thread pool (`refThreadPool`), whose `Io` serves then. It is taken
/// when the multithreaded context is made, at the first such frame; a
/// later call does not change that context's.
pub fn cctxSetIo(cctx: *CCtx, io: std.Io) void {
    cctx.io = io;
}

/// `ZSTD_CCtx_refThreadPool`: the pool multithreaded compressions run on;
/// it must stay valid until it is replaced or the context destroyed.
pub fn cctxRefThreadPool(cctx: *CCtx, pool: ?*ci.ThreadPool) Error!void {
    if (cctx.stream_stage != .init) return error.StageWrong;
    cctx.pool = pool;
}

/// `ZSTD_CCtx_refPrefix`: raw content the next frame only may refer to.
pub fn cctxRefPrefix(cctx: *CCtx, prefix: []const u8) Error!void {
    return cctxRefPrefixAdvanced(cctx, prefix, .raw_content);
}

/// `ZSTD_CCtx_refPrefix_advanced`: a dictionary for the next frame only;
/// any dictionary loaded before is cleared. `prefix` is referenced, and
/// must stay valid until that frame is compressed or the prefix replaced.
pub fn cctxRefPrefixAdvanced(
    cctx: *CCtx,
    prefix: []const u8,
    dict_content_type: params.DictContentType,
) Error!void {
    if (cctx.stream_stage != .init) return error.StageWrong;
    clearAllDicts(cctx);
    if (prefix.len > 0) {
        cctx.prefix_dict = .{
            .dict = prefix.ptr,
            .dict_size = prefix.len,
            .dict_content_type = dict_content_type,
        };
    }
}

/// `ZSTD_CCtx_reset`: ends the frame in progress, clears the parameters and
/// the dictionaries, or both. Parameters can only be reset between frames.
pub fn cctxReset(cctx: *CCtx, reset: params.ResetDirective) Error!void {
    if (reset == .session_only or reset == .session_and_parameters) {
        cctx.stream_stage = .init;
        cctx.pledged_src_size_plus_one = 0;
    }
    if (reset == .parameters or reset == .session_and_parameters) {
        if (cctx.stream_stage != .init) return error.StageWrong;
        clearAllDicts(cctx);
        cctxParamsReset(&cctx.requested_params);
    }
}

/// `ZSTD_checkCParams`: whether every parameter of `cparams` is in bounds.
pub fn checkCParams(cparams: CompressionParameters) Error!void {
    try boundCheck(.window_log, @bitCast(cparams.window_log));
    try boundCheck(.chain_log, @bitCast(cparams.chain_log));
    try boundCheck(.hash_log, @bitCast(cparams.hash_log));
    try boundCheck(.search_log, @bitCast(cparams.search_log));
    try boundCheck(.min_match, @bitCast(cparams.min_match));
    try boundCheck(.target_length, @bitCast(cparams.target_length));
    try boundCheck(.strategy, @bitCast(@backingInt(cparams.strategy)));
}

fn checkCParamsValid(cparams: CompressionParameters) bool {
    checkCParams(cparams) catch return false;
    return true;
}

/// `ZSTD_clampCParams`: `cparams` brought into bounds.
fn clampCParams(cparams_in: CompressionParameters) CompressionParameters {
    var cparams = cparams_in;
    const clamp = struct {
        fn f(param: params.CParameter, value: u32) u32 {
            const bounds = cParamGetBounds(param);
            const v: i32 = @bitCast(value);
            if (v < bounds.lower) return @intCast(bounds.lower);
            if (v > bounds.upper) return @intCast(bounds.upper);
            return value;
        }
    }.f;
    cparams.window_log = clamp(.window_log, cparams.window_log);
    cparams.chain_log = clamp(.chain_log, cparams.chain_log);
    cparams.hash_log = clamp(.hash_log, cparams.hash_log);
    cparams.search_log = clamp(.search_log, cparams.search_log);
    cparams.min_match = clamp(.min_match, cparams.min_match);
    cparams.target_length = clamp(.target_length, cparams.target_length);
    cparams.strategy = @fromBackingInt(clamp(.strategy, @backingInt(cparams.strategy)));
    return cparams;
}

/// `ZSTD_cycleLog`: the log of the cycle of a chain table's indexes;
/// `hash_log` is at least 2.
pub fn cycleLog(hash_log: u32, strategy: Strategy) u32 {
    const bt_scale: u32 = @intFromBool(@backingInt(strategy) >= @backingInt(Strategy.btlazy2));
    return hash_log - bt_scale;
}

/// `ZSTD_dictAndWindowLog`: a window log large enough for the source and
/// the dictionary. The whole dictionary is valid while one byte of it is in
/// the window, so the tables must reach both, and the hash and chain logs
/// are downsized against this log. `src_size` is known.
fn dictAndWindowLog(window_log: u32, src_size: u64, dict_size: u64) u32 {
    const max_window_size: u64 = @as(u64, 1) << params.window_log_max;
    if (dict_size == 0) return window_log;
    assert(window_log <= params.window_log_max);
    assert(src_size != params.content_size_unknown);
    const window_size: u64 = @as(u64, 1) << @intCast(window_log);
    const dict_and_window_size = dict_size +% window_size;
    if (window_size >= dict_size +% src_size) return window_log;
    if (dict_and_window_size >= max_window_size) return params.window_log_max;
    return ci.highbit32(@as(u32, @truncate(dict_and_window_size)) - 1) + 1;
}

/// `ZSTD_adjustCParams_internal`: `cpar` fitted to a source of `src_size`
/// (`params.content_size_unknown` when unknown; 0 means 0) and a dictionary
/// of `dict_size`, mostly downsized to save memory and setup time. `cpar` is
/// valid.
fn adjustCParamsInternal(
    cpar_in: CompressionParameters,
    src_size_in: u64,
    dict_size_in: usize,
    mode: ci.CParamMode,
    use_row_match_finder_in: ParamSwitch,
) CompressionParameters {
    var cpar = cpar_in;
    var src_size = src_size_in;
    var dict_size: u64 = dict_size_in;
    var use_row_match_finder = use_row_match_finder_in;
    const min_src_size: u64 = 513;
    const max_window_resize: u64 = @as(u64, 1) << (params.window_log_max - 1);
    assert(checkCParamsValid(cpar));

    switch (mode) {
        // Nothing is assumed of an unknown source size; smaller parameters
        // were already chosen for a dictionary.
        .unknown, .no_attach_dict => {},
        // A dictionary is made for small sources by default.
        .create_cdict => {
            if (dict_size != 0 and src_size == params.content_size_unknown) src_size = min_src_size;
        },
        // The dictionary has its own tables, with parameters already chosen.
        .attach_dict => dict_size = 0,
    }

    // A small input takes a smaller window, to use less memory.
    if (src_size <= max_window_resize and dict_size <= max_window_resize) {
        const t_size: u32 = @truncate(src_size + dict_size);
        const hash_size_min: u32 = 1 << params.hash_log_min;
        const src_log: u32 = if (t_size < hash_size_min)
            params.hash_log_min
        else
            ci.highbit32(t_size - 1) + 1;
        if (cpar.window_log > src_log) cpar.window_log = src_log;
    }
    if (src_size != params.content_size_unknown) {
        const dict_and_window_log = dictAndWindowLog(cpar.window_log, src_size, dict_size);
        const cycle_log = cycleLog(cpar.chain_log, cpar.strategy);
        if (cpar.hash_log > dict_and_window_log + 1) cpar.hash_log = dict_and_window_log + 1;
        if (cycle_log > dict_and_window_log) cpar.chain_log -= cycle_log - dict_and_window_log;
    }

    // The smallest window a frame header can describe.
    if (cpar.window_log < zstd_internal.window_log_absolute_min) {
        cpar.window_log = zstd_internal.window_log_absolute_min;
    }

    // A tagged index takes 8 bits of 32, so the hash and chain logs are at
    // most 24.
    if (mode == .create_cdict and cdictIndicesAreTagged(&cpar)) {
        const max_short_cache_hash_log = 32 - ci.short_cache_tag_bits;
        if (cpar.hash_log > max_short_cache_hash_log) cpar.hash_log = max_short_cache_hash_log;
        if (cpar.chain_log > max_short_cache_hash_log) cpar.chain_log = max_short_cache_hash_log;
    }

    // Whether the row-based match finder is used is not known yet: unless it
    // is turned off, take it as used. It is then only turned off for small
    // sources, where a smaller hash log costs no ratio.
    if (use_row_match_finder == .auto) use_row_match_finder = .enable;

    // The row's hash and its tag take at most 32 bits:
    // hash_log - row_log + 8 <= 32.
    if (rowMatchFinderUsed(cpar.strategy, use_row_match_finder)) {
        // Rows of 32 entries from a search log of 5.
        const row_log = std.math.clamp(cpar.search_log, 4, 6);
        const max_row_hash_log = 32 - lazy.row_hash_tag_bits;
        const max_hash_log = max_row_hash_log + row_log;
        assert(cpar.hash_log >= row_log);
        if (cpar.hash_log > max_hash_log) cpar.hash_log = max_hash_log;
    }
    return cpar;
}

/// `ZSTD_adjustCParams`: `cpar`, brought into bounds, fitted to a source of
/// `src_size` (0 for unknown) and a dictionary of `dict_size`.
pub fn adjustCParams(
    cpar: CompressionParameters,
    src_size: u64,
    dict_size: usize,
) CompressionParameters {
    const size = if (src_size == 0) params.content_size_unknown else src_size;
    return adjustCParamsInternal(clampCParams(cpar), size, dict_size, .unknown, .auto);
}

/// `ZSTD_overrideCParams`: the fields of `overrides` that are not 0 replace
/// those of `cparams`.
fn overrideCParams(cparams: *CompressionParameters, overrides: *const CompressionParameters) void {
    if (overrides.window_log != 0) cparams.window_log = overrides.window_log;
    if (overrides.hash_log != 0) cparams.hash_log = overrides.hash_log;
    if (overrides.chain_log != 0) cparams.chain_log = overrides.chain_log;
    if (overrides.search_log != 0) cparams.search_log = overrides.search_log;
    if (overrides.min_match != 0) cparams.min_match = overrides.min_match;
    if (overrides.target_length != 0) cparams.target_length = overrides.target_length;
    if (@backingInt(overrides.strategy) != 0) cparams.strategy = overrides.strategy;
}

/// `ZSTD_getCParamsFromCCtxParams`: the compression parameters of
/// `cctx_params`' level for the sizes, with its own set ones applied.
pub fn getCParamsFromCCtxParams(
    cctx_params: *const CCtxParams,
    src_size_hint_in: u64,
    dict_size: usize,
    mode: ci.CParamMode,
) CompressionParameters {
    var src_size_hint = src_size_hint_in;
    if (src_size_hint == params.content_size_unknown and cctx_params.src_size_hint > 0) {
        src_size_hint = @intCast(cctx_params.src_size_hint);
    }
    var cparams = getCParamsInternal(cctx_params.compression_level, src_size_hint, dict_size, mode);
    if (cctx_params.ldm_params.enable_ldm == .enable) cparams.window_log = ldm.default_window_log;
    overrideCParams(&cparams, &cctx_params.cparams);
    assert(checkCParamsValid(cparams));
    // A size hint of 0 means 0.
    return adjustCParamsInternal(
        cparams,
        src_size_hint,
        dict_size,
        mode,
        cctx_params.use_row_match_finder,
    );
}

/// `ZSTD_sizeof_matchState`: the workspace a match state's tables take.
fn sizeofMatchState(
    cparams: *const CompressionParameters,
    use_row_match_finder: ParamSwitch,
    enable_dedicated_dict_search: bool,
    for_cctx: bool,
) usize {
    // No chain table for `fast` or the row-based match finder.
    const chain_size: usize = if (allocateChainTable(
        cparams.strategy,
        use_row_match_finder,
        enable_dedicated_dict_search and !for_cctx,
    )) @as(usize, 1) << @intCast(cparams.chain_log) else 0;
    const h_size = @as(usize, 1) << @intCast(cparams.hash_log);
    const hash_log3: u32 = if (for_cctx and cparams.min_match == 3)
        @min(hash_log3_max, cparams.window_log)
    else
        0;
    const h3_size: usize = if (hash_log3 != 0) @as(usize, 1) << @intCast(hash_log3) else 0;
    const table_space = chain_size * @sizeOf(u32) + h_size * @sizeOf(u32) + h3_size * @sizeOf(u32);
    const opt_potential_space =
        cwksp.aligned64AllocSize((zstd_internal.max_ml + 1) * @sizeOf(u32)) +
        cwksp.aligned64AllocSize((zstd_internal.max_ll + 1) * @sizeOf(u32)) +
        cwksp.aligned64AllocSize((zstd_internal.max_off + 1) * @sizeOf(u32)) +
        cwksp.aligned64AllocSize((1 << zstd_internal.lit_bits) * @sizeOf(u32)) +
        cwksp.aligned64AllocSize(ci.opt_size * @sizeOf(ci.Match)) +
        cwksp.aligned64AllocSize(ci.opt_size * @sizeOf(ci.Optimal));
    const lazy_additional_space = if (rowMatchFinderUsed(cparams.strategy, use_row_match_finder))
        cwksp.aligned64AllocSize(h_size)
    else
        0;
    const opt_space = if (for_cctx and @backingInt(cparams.strategy) >= @backingInt(Strategy.btopt))
        opt_potential_space
    else
        0;
    const slack_space = cwksp.slackSpaceRequired();

    // Tables are multiples of 64 bytes.
    comptime assert(params.hash_log_min >= 4 and params.window_log_min >= 4 and
        params.chain_log_min >= 4);
    assert(use_row_match_finder != .auto);
    return table_space + opt_space + slack_space + lazy_additional_space;
}

/// `ZSTD_maxNbSeq`: the most sequences a block can have, a tighter bound
/// than `sequenceBound` for a minimum match above 3.
fn maxNbSeq(block_size: usize, min_match_length: u32, use_sequence_producer: bool) usize {
    const divider: usize = if (min_match_length == 3 or use_sequence_producer) 3 else 4;
    return block_size / divider;
}

/// `ZSTD_estimateCCtxSize_usingCCtxParams_internal`: the workspace (and for
/// a static context, the context itself) a compression with these
/// parameters takes.
fn estimateCCtxSizeUsingCCtxParamsInternal(
    cparams: *const CompressionParameters,
    ldm_params: *const ci.LdmParams,
    is_static: bool,
    use_row_match_finder: ParamSwitch,
    buff_in_size: usize,
    buff_out_size: usize,
    pledged_src_size: u64,
    use_sequence_producer: bool,
    max_block_size: usize,
) usize {
    const window_size: usize = @intCast(std.math.clamp(
        pledged_src_size,
        1,
        @as(u64, 1) << @intCast(cparams.window_log),
    ));
    const block_size = @min(resolveMaxBlockSize(max_block_size), window_size);
    const max_nb_seq = maxNbSeq(block_size, cparams.min_match, use_sequence_producer);
    const token_space = cwksp.allocSize(zstd_internal.wildcopy_overlength + block_size) +
        cwksp.aligned64AllocSize(max_nb_seq * @sizeOf(SeqDef)) +
        3 * cwksp.allocSize(max_nb_seq * @sizeOf(u8));
    const tmp_work_space = cwksp.allocSize(ci.tmp_workspace_size);
    const block_state_space = 2 * cwksp.allocSize(cblock_state_size);
    const match_state_size = sizeofMatchState(cparams, use_row_match_finder, false, true);

    const ldm_space = ldm.getTableSize(ldm_params.*);
    const max_nb_ldm_seq = ldm.getMaxNbSeq(ldm_params.*, block_size);
    const ldm_seq_space = if (ldm_params.enable_ldm == .enable)
        cwksp.aligned64AllocSize(max_nb_ldm_seq * @sizeOf(ci.RawSeq))
    else
        0;

    const buffer_space = cwksp.allocSize(buff_in_size) + cwksp.allocSize(buff_out_size);
    const cctx_space = if (is_static) cwksp.allocSize(cctx_object_size) else 0;

    const max_nb_external_seq = sequenceBound(block_size);
    const external_seq_space = if (use_sequence_producer)
        cwksp.aligned64AllocSize(max_nb_external_seq * @sizeOf(Sequence))
    else
        0;

    return cctx_space + tmp_work_space + block_state_space + ldm_space + ldm_seq_space +
        match_state_size + token_space + buffer_space + external_seq_space;
}

/// `ZSTD_estimateCCtxSize_usingCCtxParams`: the size of a static context
/// for one-shot compressions with `cctx_params`, single-threaded only.
pub fn estimateCCtxSizeUsingCCtxParams(cctx_params: *const CCtxParams) Error!usize {
    const cparams = getCParamsFromCCtxParams(
        cctx_params,
        params.content_size_unknown,
        0,
        .no_attach_dict,
    );
    const use_row_match_finder = resolveRowMatchFinderMode(
        cctx_params.use_row_match_finder,
        &cparams,
    );
    if (cctx_params.nb_workers > 0) return error.Generic;
    // One-shot compression needs no buffers.
    return estimateCCtxSizeUsingCCtxParamsInternal(
        &cparams,
        &cctx_params.ldm_params,
        true,
        use_row_match_finder,
        0,
        0,
        params.content_size_unknown,
        ci.hasExtSeqProd(cctx_params),
        cctx_params.max_block_size,
    );
}

/// `ZSTD_estimateCCtxSize_usingCParams`: the size of a static context for
/// one-shot compressions with `cparams`, with or without the row-based
/// match finder, whichever is larger.
pub fn estimateCCtxSizeUsingCParams(cparams: CompressionParameters) usize {
    var initial_params = makeCCtxParamsFromCParams(cparams);
    // Single-threaded parameters always have an estimate.
    if (rowMatchFinderSupported(cparams.strategy)) {
        initial_params.use_row_match_finder = .disable;
        const no_row_size = estimateCCtxSizeUsingCCtxParams(&initial_params) catch unreachable;
        initial_params.use_row_match_finder = .enable;
        const row_size = estimateCCtxSizeUsingCCtxParams(&initial_params) catch unreachable;
        return @max(no_row_size, row_size);
    }
    return estimateCCtxSizeUsingCCtxParams(&initial_params) catch unreachable;
}

/// `ZSTD_estimateCCtxSize_internal`: the largest size over the source size
/// classes of `compression_level`.
fn estimateCCtxSizeInternal(compression_level: i32) usize {
    const src_size_tiers = [4]u64{ 16 * kib, 128 * kib, 256 * kib, params.content_size_unknown };
    var largest_size: usize = 0;
    for (src_size_tiers) |tier| {
        const cparams = getCParamsInternal(compression_level, tier, 0, .no_attach_dict);
        largest_size = @max(estimateCCtxSizeUsingCParams(cparams), largest_size);
    }
    return largest_size;
}

/// `ZSTD_estimateCCtxSize`: the size of a static context for one-shot
/// compressions at `compression_level` or below, of any size.
pub fn estimateCCtxSize(compression_level: i32) usize {
    var mem_budget: usize = 0;
    // The estimate grows with the level.
    var level = @min(compression_level, 1);
    while (level <= compression_level) : (level += 1) {
        const new_mb = estimateCCtxSizeInternal(level);
        if (new_mb > mem_budget) mem_budget = new_mb;
    }
    return mem_budget;
}

/// `ZSTD_estimateCStreamSize_usingCCtxParams`: the size of a static context
/// for streaming with `cctx_params`, single-threaded only.
pub fn estimateCStreamSizeUsingCCtxParams(cctx_params: *const CCtxParams) Error!usize {
    if (cctx_params.nb_workers > 0) return error.Generic;
    const cparams = getCParamsFromCCtxParams(
        cctx_params,
        params.content_size_unknown,
        0,
        .no_attach_dict,
    );
    const window_size = @as(usize, 1) << @intCast(cparams.window_log);
    const block_size = @min(resolveMaxBlockSize(cctx_params.max_block_size), window_size);
    const in_buff_size =
        if (cctx_params.in_buffer_mode == .buffered) window_size + block_size else 0;
    const out_buff_size = if (cctx_params.out_buffer_mode == .buffered)
        compressBoundMacro(block_size) + 1
    else
        0;
    // The original resolves the row match finder from the requested
    // parameters here, not the ones just computed.
    const use_row_match_finder = resolveRowMatchFinderMode(
        cctx_params.use_row_match_finder,
        &cctx_params.cparams,
    );
    return estimateCCtxSizeUsingCCtxParamsInternal(
        &cparams,
        &cctx_params.ldm_params,
        true,
        use_row_match_finder,
        in_buff_size,
        out_buff_size,
        params.content_size_unknown,
        ci.hasExtSeqProd(cctx_params),
        cctx_params.max_block_size,
    );
}

/// `ZSTD_estimateCStreamSize_usingCParams`.
pub fn estimateCStreamSizeUsingCParams(cparams: CompressionParameters) usize {
    var initial_params = makeCCtxParamsFromCParams(cparams);
    if (rowMatchFinderSupported(cparams.strategy)) {
        initial_params.use_row_match_finder = .disable;
        const no_row_size = estimateCStreamSizeUsingCCtxParams(&initial_params) catch unreachable;
        initial_params.use_row_match_finder = .enable;
        const row_size = estimateCStreamSizeUsingCCtxParams(&initial_params) catch unreachable;
        return @max(no_row_size, row_size);
    }
    return estimateCStreamSizeUsingCCtxParams(&initial_params) catch unreachable;
}

/// `ZSTD_estimateCStreamSize_internal`.
fn estimateCStreamSizeInternal(compression_level: i32) usize {
    const cparams = getCParamsInternal(
        compression_level,
        params.content_size_unknown,
        0,
        .no_attach_dict,
    );
    return estimateCStreamSizeUsingCParams(cparams);
}

/// `ZSTD_estimateCStreamSize`: the size of a static context for streaming
/// at `compression_level` or below.
pub fn estimateCStreamSize(compression_level: i32) usize {
    var mem_budget: usize = 0;
    var level = @min(compression_level, 1);
    while (level <= compression_level) : (level += 1) {
        const new_mb = estimateCStreamSizeInternal(level);
        if (new_mb > mem_budget) mem_budget = new_mb;
    }
    return mem_budget;
}

/// `ZSTD_getFrameProgression`: how much of the frame in progress has been
/// read, compressed and written.
pub fn getFrameProgression(cctx: *const CCtx) params.FrameProgression {
    if (build_options.multithread and cctx.applied_params.nb_workers > 0) {
        return cctx.mtctx.?.getFrameProgression();
    }
    const buffered = if (cctx.in_buff_size == 0) 0 else cctx.in_buff_pos - cctx.in_to_compress;
    // One more than a block when the pledged size is a block, as the
    // input target is then.
    assert(buffered <= params.block_size_max + 1);
    return .{
        .ingested = cctx.consumed_src_size + buffered,
        .consumed = cctx.consumed_src_size,
        .produced = cctx.produced_csize,
        // Simplified, as in the original: some may still be in the output buffer.
        .flushed = cctx.produced_csize,
        .current_job_id = 0,
        .nb_active_workers = 0,
    };
}

/// `ZSTD_toFlushNow`: the bytes ready to flush; only multithreaded
/// compression reports any.
pub fn toFlushNow(cctx: *CCtx) usize {
    if (build_options.multithread and cctx.applied_params.nb_workers > 0) {
        return cctx.mtctx.?.toFlushNow();
    }
    return 0;
}

fn assertEqualCParams(cparams1: CompressionParameters, cparams2: CompressionParameters) void {
    assert(std.meta.eql(cparams1, cparams2));
}

/// `ZSTD_reset_compressedBlockState`: the starting repeat offsets, and no
/// entropy table to repeat.
pub fn resetCompressedBlockState(bs: *CompressedBlockState) void {
    bs.rep = zstd_internal.rep_start_value;
    bs.entropy.huf.repeat_mode = .none;
    bs.entropy.fse.offcode_repeat_mode = .none;
    bs.entropy.fse.matchlength_repeat_mode = .none;
    bs.entropy.fse.litlength_repeat_mode = .none;
}

/// `ZSTD_invalidateMatchState`: drops every match in the tables; the window
/// must be set.
fn invalidateMatchState(ms: *MatchState) void {
    ms.window.clear();
    ms.next_to_update = ms.window.dict_limit;
    ms.loaded_dict_end = 0;
    // Resets the optimal parser's statistics.
    ms.opt.lit_length_sum = 0;
    ms.dict_match_state = null;
}

/// `ZSTD_compResetPolicy_e`: whether a match state reset clears the tables,
/// or leaves them for an operation that overwrites them (a copy from a
/// dictionary).
const CompResetPolicy = enum { make_clean, leave_dirty };

/// `ZSTD_indexResetPolicy_e`: whether indexing continues where it stopped
/// or starts again from the start.
const IndexResetPolicy = enum { @"continue", reset };

/// `ZSTD_resetTarget_e`.
const ResetTarget = enum { cdict, cctx };

/// `ZSTD_bitmix`: mixes the bits of `val`, after XXH3's rrmxmx.
fn bitmix(val_in: u64, len: u64) u64 {
    var val = val_in;
    val ^= std.math.rotr(u64, val, 49) ^ std.math.rotr(u64, val, 24);
    val *%= 0x9FB21C651E98DF25;
    val ^= (val >> 35) +% len;
    val *%= 0x9FB21C651E98DF25;
    return val ^ (val >> 28);
}

/// `ZSTD_advanceHashSalt`: a new salt from the salt and the entropy
/// collected.
fn advanceHashSalt(ms: *MatchState) void {
    ms.hash_salt = bitmix(ms.hash_salt, 8) ^ bitmix(ms.hash_salt_entropy, 4);
}

/// `ZSTD_reset_matchState`: reserves and prepares a match state's tables in
/// `ws`.
fn resetMatchState(
    ms: *MatchState,
    ws: *Cwksp,
    cparams: *const CompressionParameters,
    use_row_match_finder: ParamSwitch,
    crp: CompResetPolicy,
    force_reset_index: IndexResetPolicy,
    for_who: ResetTarget,
) Error!void {
    // No chain table for `fast` or the row-based match finder.
    const chain_size: usize = if (allocateChainTable(
        cparams.strategy,
        use_row_match_finder,
        ms.dedicated_dict_search and for_who == .cdict,
    )) @as(usize, 1) << @intCast(cparams.chain_log) else 0;
    const h_size = @as(usize, 1) << @intCast(cparams.hash_log);
    const hash_log3: u32 = if (for_who == .cctx and cparams.min_match == 3)
        @min(hash_log3_max, cparams.window_log)
    else
        0;
    const h3_size: usize = if (hash_log3 != 0) @as(usize, 1) << @intCast(hash_log3) else 0;

    assert(use_row_match_finder != .auto);
    if (force_reset_index == .reset) {
        ms.window.init();
        ws.markTablesDirty();
    }

    ms.hash_log3 = hash_log3;
    ms.lazy_skipping = false;

    invalidateMatchState(ms);

    assert(!ws.reserveFailed());

    ws.clearTables();

    // A failed reservation leaves its pointer unset, as the failure is
    // checked once for all three.
    ms.hash_table = @ptrCast(ws.reserveTable(h_size * @sizeOf(u32)) orelse undefined);
    ms.chain_table = @ptrCast(ws.reserveTable(chain_size * @sizeOf(u32)) orelse undefined);
    ms.hash_table3 = @ptrCast(ws.reserveTable(h3_size * @sizeOf(u32)) orelse undefined);
    if (ws.reserveFailed()) return error.MemoryAllocation;

    if (crp != .leave_dirty) ws.cleanTables();

    if (rowMatchFinderUsed(cparams.strategy, use_row_match_finder)) {
        // The row-based match finder's table of tags.
        const tag_table_size = h_size;
        // A context gets a new salt; a dictionary's is always 0.
        if (for_who == .cctx) {
            ms.tag_table = ws.reserveAlignedInitOnce(tag_table_size) orelse
                return error.MemoryAllocation;
            advanceHashSalt(ms);
        } else {
            // Unsalted tags are always cleared.
            const tags = ws.reserveAligned64(tag_table_size) orelse return error.MemoryAllocation;
            @memset(tags[0..tag_table_size], 0);
            ms.tag_table = tags;
            ms.hash_salt = 0;
        }
        // Rows of 32 entries from a search log of 5.
        const row_log = std.math.clamp(cparams.search_log, 4, 6);
        assert(cparams.hash_log >= row_log);
        ms.row_hash_log = cparams.hash_log - row_log;
    }

    // The optimal parser's space.
    if (for_who == .cctx and @backingInt(cparams.strategy) >= @backingInt(Strategy.btopt)) {
        const lit_freq = ws.reserveAligned64((1 << zstd_internal.lit_bits) * @sizeOf(u32));
        const lit_length_freq = ws.reserveAligned64((zstd_internal.max_ll + 1) * @sizeOf(u32));
        const match_length_freq = ws.reserveAligned64((zstd_internal.max_ml + 1) * @sizeOf(u32));
        const off_code_freq = ws.reserveAligned64((zstd_internal.max_off + 1) * @sizeOf(u32));
        const match_table = ws.reserveAligned64(ci.opt_size * @sizeOf(ci.Match));
        const price_table = ws.reserveAligned64(ci.opt_size * @sizeOf(ci.Optimal));
        if (ws.reserveFailed()) return error.MemoryAllocation;
        ms.opt.lit_freq = @ptrCast(lit_freq.?);
        ms.opt.lit_length_freq = @ptrCast(lit_length_freq.?);
        ms.opt.match_length_freq = @ptrCast(match_length_freq.?);
        ms.opt.off_code_freq = @ptrCast(off_code_freq.?);
        ms.opt.match_table = @ptrCast(match_table.?);
        ms.opt.price_table = @ptrCast(price_table.?);
    }

    ms.cparams = cparams.*;

    if (ws.reserveFailed()) return error.MemoryAllocation;
}

/// `ZSTD_INDEXOVERFLOW_MARGIN`.
const index_overflow_margin = 16 * mib;

/// `ZSTD_indexTooCloseToMax`: whether the indexes are near enough the limit
/// that clearing the tables beats correcting them later. A context reused
/// for many inputs smaller than the margin clears before it corrects.
fn indexTooCloseToMax(w: ci.Window) bool {
    const index = @intFromPtr(w.next_src) -% @intFromPtr(w.base);
    return index > ci.current_max - index_overflow_margin;
}

/// `ZSTD_dictTooBig`: whether a dictionary is too large to load in one go;
/// the tables are then cleared, so as much of it as possible loads.
fn dictTooBig(loaded_dict_size: usize) bool {
    return loaded_dict_size > ci.chunk_size_max;
}

/// `ZSTD_resetCCtx_internal`: prepares the context's workspace, tables and
/// state for a frame with `cctx_params_in`, fully validated.
/// `loaded_dict_size` is the size of a dictionary to load into the context,
/// or 0 when there is none or it is attached or copied.
fn resetCCtxInternal(
    zc: *CCtx,
    cctx_params_in: *const CCtxParams,
    pledged_src_size: u64,
    loaded_dict_size: usize,
    crp: CompResetPolicy,
    zbuff: ci.BufferedPolicy,
) Error!void {
    const ws = &zc.workspace;
    assert(checkCParamsValid(cctx_params_in.cparams));

    zc.is_first_block = true;

    // The applied parameters, adjusted below for long distance matching.
    zc.applied_params = cctx_params_in.*;
    const cctx_params = &zc.applied_params;

    assert(cctx_params.use_row_match_finder != .auto);
    assert(cctx_params.post_block_splitter != .auto);
    assert(cctx_params.ldm_params.enable_ldm != .auto);
    assert(cctx_params.max_block_size != 0);
    if (cctx_params.ldm_params.enable_ldm == .enable) {
        ldm.adjustParameters(&zc.applied_params.ldm_params, &cctx_params.cparams);
        assert(cctx_params.ldm_params.hash_log >= cctx_params.ldm_params.bucket_size_log);
        assert(cctx_params.ldm_params.hash_rate_log < 32);
    }

    const window_size: usize = @intCast(@max(1, @min(
        @as(u64, 1) << @intCast(cctx_params.cparams.window_log),
        pledged_src_size,
    )));
    const block_size = @min(cctx_params.max_block_size, window_size);
    const max_nb_seq = maxNbSeq(
        block_size,
        cctx_params.cparams.min_match,
        ci.hasExtSeqProd(cctx_params),
    );
    const buff_out_size = if (zbuff == .buffered and cctx_params.out_buffer_mode == .buffered)
        compressBoundMacro(block_size) + 1
    else
        0;
    const buff_in_size = if (zbuff == .buffered and cctx_params.in_buffer_mode == .buffered)
        window_size + block_size
    else
        0;
    const max_nb_ldm_seq = ldm.getMaxNbSeq(cctx_params.ldm_params, block_size);

    const index_too_close = indexTooCloseToMax(zc.block_state.match_state.window);
    const dict_too_big = dictTooBig(loaded_dict_size);
    var needs_index_reset: IndexResetPolicy =
        if (index_too_close or dict_too_big or !zc.initialized)
            .reset
        else
            .@"continue";

    const needed_space = estimateCCtxSizeUsingCCtxParamsInternal(
        &cctx_params.cparams,
        &cctx_params.ldm_params,
        zc.static_size != 0,
        cctx_params.use_row_match_finder,
        buff_in_size,
        buff_out_size,
        pledged_src_size,
        ci.hasExtSeqProd(cctx_params),
        cctx_params.max_block_size,
    );

    if (zc.static_size == 0) ws.bumpOversizedDuration(0);

    // A new workspace when this one is too small, or too large for too long.
    const workspace_too_small = ws.sizeof() < needed_space;
    const workspace_wasteful = ws.checkWasteful(needed_space);
    if (workspace_too_small or workspace_wasteful) {
        if (zc.static_size != 0) return error.MemoryAllocation;

        needs_index_reset = .reset;

        ws.free(zc.custom_mem.?);
        try ws.create(needed_space, zc.custom_mem.?);

        // The fixed objects; the temporary workspace never moves, the block
        // states swap places.
        assert(ws.checkAvailable(2 * cblock_state_size));
        const prev = ws.reserveObject(cblock_state_size) orelse return error.MemoryAllocation;
        zc.block_state.prev_cblock = @ptrCast(prev);
        const next = ws.reserveObject(cblock_state_size) orelse return error.MemoryAllocation;
        zc.block_state.next_cblock = @ptrCast(next);
        const tmp = ws.reserveObject(ci.tmp_workspace_size) orelse return error.MemoryAllocation;
        zc.tmp_workspace = @alignCast(tmp);
        zc.tmp_wksp_size = ci.tmp_workspace_size;
    }

    ws.clear();

    zc.block_state.match_state.cparams = cctx_params.cparams;
    zc.block_state.match_state.prefetch_cdict_tables = cctx_params.prefetch_cdict_tables == .enable;
    zc.pledged_src_size_plus_one = pledged_src_size +% 1;
    zc.consumed_src_size = 0;
    zc.produced_csize = 0;
    if (pledged_src_size == params.content_size_unknown) {
        zc.applied_params.fparams.content_size_flag = false;
    }
    zc.block_size_max = block_size;

    zc.xxh_state = .init(0);
    zc.stage = .init;
    zc.dict_id = 0;
    zc.dict_content_size = 0;

    resetCompressedBlockState(zc.block_state.prev_cblock);

    try resetMatchState(
        &zc.block_state.match_state,
        ws,
        &cctx_params.cparams,
        cctx_params.use_row_match_finder,
        crp,
        needs_index_reset,
        .cctx,
    );

    // Every reservation fits in the space estimated, as checked below, so
    // a failed one leaves its pointer unset.
    zc.seq_store.sequences_start = @ptrCast(
        ws.reserveAligned64(max_nb_seq * @sizeOf(SeqDef)) orelse undefined,
    );

    // The long distance matcher's hash table.
    if (cctx_params.ldm_params.enable_ldm == .enable) {
        const ldm_h_size = @as(usize, 1) << @intCast(cctx_params.ldm_params.hash_log);
        const table = ws.reserveAligned64(ldm_h_size * @sizeOf(ci.LdmEntry));
        if (table) |t| @memset(t[0 .. ldm_h_size * @sizeOf(ci.LdmEntry)], 0);
        zc.ldm_state.hash_table = @ptrCast(table orelse undefined);
        zc.ldm_sequences = @ptrCast(
            ws.reserveAligned64(max_nb_ldm_seq * @sizeOf(ci.RawSeq)) orelse undefined,
        );
        zc.max_nb_ldm_sequences = max_nb_ldm_seq;

        zc.ldm_state.window.init();
        zc.ldm_state.loaded_dict_end = 0;
    }

    // The external sequence producer's output.
    if (ci.hasExtSeqProd(cctx_params)) {
        const max_nb_external_seq = sequenceBound(block_size);
        zc.ext_seq_buf_capacity = max_nb_external_seq;
        zc.ext_seq_buf = @ptrCast(ws.reserveAligned64(max_nb_external_seq * @sizeOf(Sequence)));
    }

    // Buffers. Literals are copied with wildcopy, so their buffer has
    // `wildcopy_overlength` more bytes.
    zc.seq_store.lit_start = ws.reserveBuffer(block_size + zstd_internal.wildcopy_overlength) orelse
        undefined;
    zc.seq_store.max_nb_lit = block_size;

    zc.buffered_policy = zbuff;
    zc.in_buff_size = buff_in_size;
    zc.in_buff = ws.reserveBuffer(buff_in_size) orelse undefined;
    zc.out_buff_size = buff_out_size;
    zc.out_buff = ws.reserveBuffer(buff_out_size) orelse undefined;

    // The long distance matcher's bucket offsets.
    if (cctx_params.ldm_params.enable_ldm == .enable) {
        const num_buckets = @as(usize, 1) <<
            @intCast(cctx_params.ldm_params.hash_log - cctx_params.ldm_params.bucket_size_log);
        const offsets = ws.reserveBuffer(num_buckets);
        if (offsets) |o| @memset(o[0..num_buckets], 0);
        zc.ldm_state.bucket_offsets = offsets orelse undefined;
    }

    // The sequences.
    referenceExternalSequences(zc, null, 0);
    zc.seq_store.max_nb_seq = max_nb_seq;
    zc.seq_store.ll_code = ws.reserveBuffer(max_nb_seq) orelse undefined;
    zc.seq_store.ml_code = ws.reserveBuffer(max_nb_seq) orelse undefined;
    zc.seq_store.of_code = ws.reserveBuffer(max_nb_seq) orelse undefined;

    // Every reservation fits in the space estimated, so none failed.
    assert(!ws.reserveFailed());
    assert(ws.estimatedSpaceWithinBounds(needed_space));

    zc.initialized = true;
}

/// `ZSTD_invalidateRepCodes`: the next block uses no repeat offset of the
/// blocks before. Not for a context with an external dictionary.
pub fn invalidateRepCodes(cctx: *CCtx) void {
    cctx.block_state.prev_cblock.rep = @splat(0);
    assert(!cctx.block_state.match_state.window.hasExtDict());
}

/// `attachDictSizeCutoffs`: the source sizes, by strategy, above which
/// copying a dictionary's tables into the context is faster than using
/// them in place.
const attach_dict_size_cutoffs = [_]usize{
    8 * kib, // unused
    8 * kib, // fast
    16 * kib, // dfast
    32 * kib, // greedy
    32 * kib, // lazy
    32 * kib, // lazy2
    32 * kib, // btlazy2
    32 * kib, // btopt
    8 * kib, // btultra
    8 * kib, // btultra2
};

/// `ZSTD_shouldAttachDict`: whether a frame of `pledged_src_size` uses the
/// dictionary's tables in place rather than a copy of them.
fn shouldAttachDict(
    cdict: *const CDict,
    cctx_params: *const CCtxParams,
    pledged_src_size: u64,
) bool {
    const cutoff = attach_dict_size_cutoffs[@backingInt(cdict.match_state.cparams.strategy)];
    const dedicated_dict_search = cdict.match_state.dedicated_dict_search;
    // `Window.enforceMaxDist` does not handle a dict match state, so a
    // forced window copies.
    return dedicated_dict_search or
        ((pledged_src_size <= cutoff or
            pledged_src_size == params.content_size_unknown or
            cctx_params.attach_dict_pref == .force_attach) and
            cctx_params.attach_dict_pref != .force_copy and
            !cctx_params.force_window);
}

/// `ZSTD_resetCCtx_byAttachingCDict`: prepares the context for a frame that
/// uses `cdict`'s tables in place, as its dict match state.
fn resetCCtxByAttachingCDict(
    cctx: *CCtx,
    cdict: *const CDict,
    cctx_params_in: CCtxParams,
    pledged_src_size: u64,
    zbuff: ci.BufferedPolicy,
) Error!void {
    var cctx_params = cctx_params_in;
    {
        var adjusted_cdict_cparams = cdict.match_state.cparams;
        const window_log = cctx_params.cparams.window_log;
        assert(window_log != 0);
        // The context's tables are sized for the input only: the
        // dictionary has its own. A pledged size of 0 means 0.
        if (cdict.match_state.dedicated_dict_search) {
            dedicatedDictSearchRevertCParams(&adjusted_cdict_cparams);
        }
        cctx_params.cparams = adjustCParamsInternal(
            adjusted_cdict_cparams,
            pledged_src_size,
            cdict.dict_content_size,
            .attach_dict,
            cctx_params.use_row_match_finder,
        );
        cctx_params.cparams.window_log = window_log;
        // The dictionary decides.
        cctx_params.use_row_match_finder = cdict.use_row_match_finder;
        try resetCCtxInternal(cctx, &cctx_params, pledged_src_size, 0, .make_clean, zbuff);
        assert(cctx.applied_params.cparams.strategy == adjusted_cdict_cparams.strategy);
    }

    {
        const cdict_end: u32 = @intCast(@intFromPtr(cdict.match_state.window.next_src) -
            @intFromPtr(cdict.match_state.window.base));
        const cdict_len = cdict_end - cdict.match_state.window.dict_limit;
        // An empty dictionary is not attached.
        if (cdict_len != 0) {
            const ms = &cctx.block_state.match_state;
            ms.dict_match_state = &cdict.match_state;
            // The context's indexes start after the dictionary's, so that
            // its matches never have negative indexes in the context.
            if (ms.window.dict_limit < cdict_end) {
                ms.window.next_src = ms.window.base + cdict_end;
                ms.window.clear();
            }
            // In the context's referential.
            ms.loaded_dict_end = ms.window.dict_limit;
        }
    }

    cctx.dict_id = cdict.dict_id;
    cctx.dict_content_size = cdict.dict_content_size;

    cctx.block_state.prev_cblock.* = cdict.cblock_state;
}

/// `ZSTD_copyCDictTableIntoCCtx`: copies a dictionary's table, without the
/// short cache tags where it has them.
fn copyCDictTableIntoCCtx(
    dst: [*]u32,
    src: [*]const u32,
    table_size: usize,
    cparams: *const CompressionParameters,
) void {
    if (cdictIndicesAreTagged(cparams)) {
        for (dst[0..table_size], src[0..table_size]) |*d, tagged_index| {
            d.* = tagged_index >> ci.short_cache_tag_bits;
        }
    } else {
        @memcpy(dst[0..table_size], src[0..table_size]);
    }
}

/// `ZSTD_resetCCtx_byCopyingCDict`: prepares the context for a frame with
/// a copy of `cdict`'s tables.
fn resetCCtxByCopyingCDict(
    cctx: *CCtx,
    cdict: *const CDict,
    cctx_params_in: CCtxParams,
    pledged_src_size: u64,
    zbuff: ci.BufferedPolicy,
) Error!void {
    var cctx_params = cctx_params_in;
    const cdict_cparams = &cdict.match_state.cparams;

    assert(!cdict.match_state.dedicated_dict_search);

    {
        const window_log = cctx_params.cparams.window_log;
        assert(window_log != 0);
        // Only the parameters of the tables are copied.
        cctx_params.cparams = cdict_cparams.*;
        cctx_params.cparams.window_log = window_log;
        cctx_params.use_row_match_finder = cdict.use_row_match_finder;
        try resetCCtxInternal(cctx, &cctx_params, pledged_src_size, 0, .leave_dirty, zbuff);
        assert(cctx.applied_params.cparams.strategy == cdict_cparams.strategy);
        assert(cctx.applied_params.cparams.hash_log == cdict_cparams.hash_log);
        assert(cctx.applied_params.cparams.chain_log == cdict_cparams.chain_log);
    }

    cctx.workspace.markTablesDirty();
    assert(cctx_params.use_row_match_finder != .auto);

    // The tables.
    {
        // A dedicated dictionary search dictionary is never copied.
        const chain_size: usize = if (allocateChainTable(
            cdict_cparams.strategy,
            cdict.use_row_match_finder,
            false,
        )) @as(usize, 1) << @intCast(cdict_cparams.chain_log) else 0;
        const h_size = @as(usize, 1) << @intCast(cdict_cparams.hash_log);
        const ms = &cctx.block_state.match_state;

        copyCDictTableIntoCCtx(ms.hash_table, cdict.match_state.hash_table, h_size, cdict_cparams);

        // No chain table copied into a context that does not use one.
        if (allocateChainTable(
            cctx.applied_params.cparams.strategy,
            cctx.applied_params.use_row_match_finder,
            false,
        )) {
            copyCDictTableIntoCCtx(
                ms.chain_table,
                cdict.match_state.chain_table,
                chain_size,
                cdict_cparams,
            );
        }
        if (rowMatchFinderUsed(cdict_cparams.strategy, cdict.use_row_match_finder)) {
            const tag_table_size = h_size;
            @memcpy(
                ms.tag_table[0..tag_table_size],
                cdict.match_state.tag_table[0..tag_table_size],
            );
            ms.hash_salt = cdict.match_state.hash_salt;
        }
    }

    // The dictionary never fills the table of 3-byte matches.
    {
        const ms = &cctx.block_state.match_state;
        assert(ms.hash_log3 <= 31);
        const h3_log = ms.hash_log3;
        const h3_size: usize = if (h3_log != 0) @as(usize, 1) << @intCast(h3_log) else 0;
        assert(cdict.match_state.hash_log3 == 0);
        @memset(ms.hash_table3[0..h3_size], 0);
    }

    cctx.workspace.markTablesClean();

    // The dictionary's position.
    {
        const src_ms = &cdict.match_state;
        const dst_ms = &cctx.block_state.match_state;
        dst_ms.window = src_ms.window;
        dst_ms.next_to_update = src_ms.next_to_update;
        dst_ms.loaded_dict_end = src_ms.loaded_dict_end;
    }

    cctx.dict_id = cdict.dict_id;
    cctx.dict_content_size = cdict.dict_content_size;

    cctx.block_state.prev_cblock.* = cdict.cblock_state;
}

/// `ZSTD_resetCCtx_usingCDict`: prepares the context for a frame with
/// `cdict`, attached or copied, whichever suits the frame.
fn resetCCtxUsingCDict(
    cctx: *CCtx,
    cdict: *const CDict,
    cctx_params: *const CCtxParams,
    pledged_src_size: u64,
    zbuff: ci.BufferedPolicy,
) Error!void {
    if (shouldAttachDict(cdict, cctx_params, pledged_src_size)) {
        return resetCCtxByAttachingCDict(cctx, cdict, cctx_params.*, pledged_src_size, zbuff);
    }
    return resetCCtxByCopyingCDict(cctx, cdict, cctx_params.*, pledged_src_size, zbuff);
}

/// `ZSTD_copyCCtx_internal`: makes `dst_cctx` a copy of `src_cctx`'s
/// tables, entropy tables and dictionary, for a frame with `fparams`. Only
/// between `compressBegin*` and the first `compressContinue`.
fn copyCCtxInternal(
    dst_cctx: *CCtx,
    src_cctx: *const CCtx,
    fparams: params.FrameParameters,
    pledged_src_size: u64,
    zbuff: ci.BufferedPolicy,
) Error!void {
    if (src_cctx.stage != .init) return error.StageWrong;
    dst_cctx.custom_mem = src_cctx.custom_mem;
    {
        var cctx_params = dst_cctx.requested_params;
        // Only the parameters of the tables are copied.
        cctx_params.cparams = src_cctx.applied_params.cparams;
        assert(src_cctx.applied_params.use_row_match_finder != .auto);
        assert(src_cctx.applied_params.post_block_splitter != .auto);
        assert(src_cctx.applied_params.ldm_params.enable_ldm != .auto);
        cctx_params.use_row_match_finder = src_cctx.applied_params.use_row_match_finder;
        cctx_params.post_block_splitter = src_cctx.applied_params.post_block_splitter;
        cctx_params.ldm_params = src_cctx.applied_params.ldm_params;
        cctx_params.fparams = fparams;
        cctx_params.max_block_size = src_cctx.applied_params.max_block_size;
        // The original carries on when this reset fails.
        resetCCtxInternal(
            dst_cctx,
            &cctx_params,
            pledged_src_size,
            0,
            .leave_dirty,
            zbuff,
        ) catch {};
        assert(
            dst_cctx.applied_params.cparams.window_log ==
                src_cctx.applied_params.cparams.window_log,
        );
        assert(
            dst_cctx.applied_params.cparams.strategy == src_cctx.applied_params.cparams.strategy,
        );
        assert(
            dst_cctx.applied_params.cparams.hash_log == src_cctx.applied_params.cparams.hash_log,
        );
        assert(
            dst_cctx.applied_params.cparams.chain_log == src_cctx.applied_params.cparams.chain_log,
        );
        assert(
            dst_cctx.block_state.match_state.hash_log3 ==
                src_cctx.block_state.match_state.hash_log3,
        );
    }

    dst_cctx.workspace.markTablesDirty();

    // The tables.
    {
        const src_params = &src_cctx.applied_params;
        const chain_size: usize = if (allocateChainTable(
            src_params.cparams.strategy,
            src_params.use_row_match_finder,
            false,
        )) @as(usize, 1) << @intCast(src_params.cparams.chain_log) else 0;
        const h_size = @as(usize, 1) << @intCast(src_params.cparams.hash_log);
        const h3_log = src_cctx.block_state.match_state.hash_log3;
        const h3_size: usize = if (h3_log != 0) @as(usize, 1) << @intCast(h3_log) else 0;
        const dst_ms = &dst_cctx.block_state.match_state;
        const src_ms = &src_cctx.block_state.match_state;
        @memcpy(dst_ms.hash_table[0..h_size], src_ms.hash_table[0..h_size]);
        @memcpy(dst_ms.chain_table[0..chain_size], src_ms.chain_table[0..chain_size]);
        @memcpy(dst_ms.hash_table3[0..h3_size], src_ms.hash_table3[0..h3_size]);
    }

    dst_cctx.workspace.markTablesClean();

    // The dictionary's position.
    {
        const src_ms = &src_cctx.block_state.match_state;
        const dst_ms = &dst_cctx.block_state.match_state;
        dst_ms.window = src_ms.window;
        dst_ms.next_to_update = src_ms.next_to_update;
        dst_ms.loaded_dict_end = src_ms.loaded_dict_end;
    }
    dst_cctx.dict_id = src_cctx.dict_id;
    dst_cctx.dict_content_size = src_cctx.dict_content_size;

    dst_cctx.block_state.prev_cblock.* = src_cctx.block_state.prev_cblock.*;
}

/// `ZSTD_copyCCtx`: makes `dst_cctx` ready to compress a frame of
/// `pledged_src_size` (0 for unknown) with `src_cctx`'s parameters,
/// dictionary and tables. `src_cctx` must be between `compressBegin*` and
/// its first `compressContinue`.
pub fn copyCCtx(dst_cctx: *CCtx, src_cctx: *const CCtx, pledged_src_size_in: u64) Error!void {
    var fparams: params.FrameParameters = .{
        .content_size_flag = true,
        .checksum_flag = false,
        .no_dict_id_flag = false,
    };
    const zbuff = src_cctx.buffered_policy;
    const pledged_src_size = if (pledged_src_size_in == 0)
        params.content_size_unknown
    else
        pledged_src_size_in;
    fparams.content_size_flag = pledged_src_size != params.content_size_unknown;
    return copyCCtxInternal(dst_cctx, src_cctx, fparams, pledged_src_size, zbuff);
}

/// `ZSTD_ROWSIZE`: tables are reduced 16 entries at a time.
const reduce_row_size = 16;

/// `ZSTD_reduceTable_internal`: lowers every index of `table` by
/// `reducer_value`, or to 0 below it. `preserve_mark` keeps btlazy2's
/// unsorted mark. `size` is a multiple of `reduce_row_size`.
inline fn reduceTableInternal(
    table: [*]u32,
    size: u32,
    reducer_value: u32,
    comptime preserve_mark: bool,
) void {
    const nb_rows = size / reduce_row_size;
    // The special indexes below `window_start_index` stay.
    const reducer_threshold = reducer_value + ci.window_start_index;
    assert(size & (reduce_row_size - 1) == 0);
    assert(size < 1 << 31);

    const Row = @Vector(reduce_row_size, u32);
    const threshold: Row = @splat(reducer_threshold);
    const reducer: Row = @splat(reducer_value);
    const zero: Row = @splat(0);
    const mark: Row = @splat(ci.dubt_unsorted_mark);
    var row: usize = 0;
    while (row < nb_rows) : (row += 1) {
        const cells = table[row * reduce_row_size ..][0..reduce_row_size];
        const values: Row = cells.*;
        // Below the threshold the subtraction wraps, but that lane is 0.
        const reduced = @select(u32, values < threshold, zero, values -% reducer);
        cells.* = if (preserve_mark) @select(u32, values == mark, mark, reduced) else reduced;
    }
}

/// `ZSTD_reduceTable`.
fn reduceTable(table: [*]u32, size: u32, reducer_value: u32) void {
    reduceTableInternal(table, size, reducer_value, false);
}

/// `ZSTD_reduceTable_btlazy2`.
fn reduceTableBtlazy2(table: [*]u32, size: u32, reducer_value: u32) void {
    reduceTableInternal(table, size, reducer_value, true);
}

/// `ZSTD_reduceIndex`: lowers every index of the match state's tables by
/// `reducer_value`, ahead of an overflow.
fn reduceIndex(ms: *MatchState, cctx_params: *const CCtxParams, reducer_value: u32) void {
    {
        const h_size = @as(u32, 1) << @intCast(cctx_params.cparams.hash_log);
        reduceTable(ms.hash_table, h_size, reducer_value);
    }

    if (allocateChainTable(
        cctx_params.cparams.strategy,
        cctx_params.use_row_match_finder,
        ms.dedicated_dict_search,
    )) {
        const chain_size = @as(u32, 1) << @intCast(cctx_params.cparams.chain_log);
        if (cctx_params.cparams.strategy == .btlazy2) {
            reduceTableBtlazy2(ms.chain_table, chain_size, reducer_value);
        } else {
            reduceTable(ms.chain_table, chain_size, reducer_value);
        }
    }

    if (ms.hash_log3 != 0) {
        const h3_size = @as(u32, 1) << @intCast(ms.hash_log3);
        reduceTable(ms.hash_table3, h3_size, reducer_value);
    }
}

// ---------------------------------------------------------------------------
// Block entropy compression
// ---------------------------------------------------------------------------

/// The number of sequences in `seq_store`.
fn nbSequences(seq_store: *const SeqStore) usize {
    return (@intFromPtr(seq_store.sequences) - @intFromPtr(seq_store.sequences_start)) /
        @sizeOf(SeqDef);
}

/// The number of literals in `seq_store`.
fn nbLiterals(seq_store: *const SeqStore) usize {
    return @intFromPtr(seq_store.lit) - @intFromPtr(seq_store.lit_start);
}

/// `ZSTD_seqToCodes`: fills the store's code tables from its sequences.
/// Returns whether an offset is too long for one flush of the bit
/// register, which only happens on 32-bit targets.
pub fn seqToCodes(seq_store: *const SeqStore) bool {
    const nb_seq = nbSequences(seq_store);
    var long_offsets = false;
    assert(nb_seq <= seq_store.max_nb_seq);
    for (seq_store.sequences_start[0..nb_seq], 0..) |seq, u| {
        const of_code = ci.highbit32(seq.off_base);
        seq_store.ll_code[u] = @intCast(ci.llCode(seq.lit_length));
        seq_store.of_code[u] = @intCast(of_code);
        seq_store.ml_code[u] = @intCast(ci.mlCode(seq.ml_base));
        assert(!(@sizeOf(usize) == 8 and of_code >= bitstream.accumulator_min));
        if (@sizeOf(usize) == 4 and of_code >= bitstream.accumulator_min) long_offsets = true;
    }
    if (seq_store.long_length_type == .literal_length) {
        seq_store.ll_code[seq_store.long_length_pos] = zstd_internal.max_ll;
    }
    if (seq_store.long_length_type == .match_length) {
        seq_store.ml_code[seq_store.long_length_pos] = zstd_internal.max_ml;
    }
    return long_offsets;
}

/// `ZSTD_useTargetCBlockSize`.
fn useTargetCBlockSize(cctx_params: *const CCtxParams) bool {
    return cctx_params.target_cblock_size != 0;
}

/// `ZSTD_blockSplitterEnabled`: the parameter is resolved.
fn blockSplitterEnabled(cctx_params: *const CCtxParams) bool {
    assert(cctx_params.post_block_splitter != .auto);
    return cctx_params.post_block_splitter == .enable;
}

/// `ZSTD_symbolEncodingTypeStats_t`: the encoding types of a block's three
/// code tables and the size of their descriptions.
const SymbolEncodingTypeStats = struct {
    ll_type: SymbolEncodingType,
    of_type: SymbolEncodingType,
    ml_type: SymbolEncodingType,
    size: usize,
    /// The size of the last new table's description, for the 1.3.4
    /// decoder's limit (see `entropyCompressSeqStoreInternal`).
    last_count_size: usize,
    long_offsets: bool,
};

const SymbolEncodingType = zstd_internal.SymbolEncodingType;

/// The words of a workspace's first `max_seq + 1` counts.
const count_workspace_bytes = (zstd_internal.max_seq + 1) * @sizeOf(u32);

/// `ZSTD_buildSequencesStatistics`: chooses the encoding of the three code
/// tables of `nb_seq` sequences (at least 1), builds them in `next_entropy`
/// and writes their descriptions to `dst`.
fn buildSequencesStatistics(
    seq_store: *const SeqStore,
    nb_seq: usize,
    prev_entropy: *const ci.FseCTables,
    next_entropy: *ci.FseCTables,
    dst: []u8,
    strategy: Strategy,
    count_workspace: []u32,
    entropy_workspace: []u8,
) Error!SymbolEncodingTypeStats {
    var op: usize = 0;
    var stats: SymbolEncodingTypeStats = .{
        .ll_type = .basic,
        .of_type = .basic,
        .ml_type = .basic,
        .size = 0,
        .last_count_size = 0,
        .long_offsets = seqToCodes(seq_store),
    };
    const ll_codes = seq_store.ll_code[0..nb_seq];
    const of_codes = seq_store.of_code[0..nb_seq];
    const ml_codes = seq_store.ml_code[0..nb_seq];
    assert(nb_seq != 0);

    // Literal lengths.
    {
        var max: u32 = zstd_internal.max_ll;
        const most_frequent = hist.countFastWksp(
            count_workspace,
            &max,
            ll_codes,
            entropy_workspace,
        ) catch
            unreachable;
        next_entropy.litlength_repeat_mode = prev_entropy.litlength_repeat_mode;
        stats.ll_type = compress_sequences.selectEncodingType(
            &next_entropy.litlength_repeat_mode,
            count_workspace,
            max,
            most_frequent,
            nb_seq,
            zstd_internal.ll_fse_log,
            &prev_entropy.litlength_ctable,
            &zstd_internal.ll_default_norm,
            zstd_internal.ll_default_norm_log,
            .allowed,
            strategy,
        );
        // Tables are never copied.
        assert(!(@backingInt(stats.ll_type) < @backingInt(SymbolEncodingType.compressed) and
            next_entropy.litlength_repeat_mode != .none));
        const count_size = try compress_sequences.buildCTable(
            dst[op..],
            &next_entropy.litlength_ctable,
            zstd_internal.ll_fse_log,
            stats.ll_type,
            count_workspace,
            max,
            ll_codes,
            &zstd_internal.ll_default_norm,
            zstd_internal.ll_default_norm_log,
            zstd_internal.max_ll,
            &prev_entropy.litlength_ctable,
            entropy_workspace,
        );
        if (stats.ll_type == .compressed) stats.last_count_size = count_size;
        op += count_size;
    }
    // Offsets.
    {
        var max: u32 = zstd_internal.max_off;
        const most_frequent = hist.countFastWksp(
            count_workspace,
            &max,
            of_codes,
            entropy_workspace,
        ) catch
            unreachable;
        // The default table only reaches offset code `default_max_off`.
        const default_policy: compress_sequences.DefaultPolicy =
            if (max <= zstd_internal.default_max_off) .allowed else .disallowed;
        next_entropy.offcode_repeat_mode = prev_entropy.offcode_repeat_mode;
        stats.of_type = compress_sequences.selectEncodingType(
            &next_entropy.offcode_repeat_mode,
            count_workspace,
            max,
            most_frequent,
            nb_seq,
            zstd_internal.off_fse_log,
            &prev_entropy.offcode_ctable,
            &zstd_internal.of_default_norm,
            zstd_internal.of_default_norm_log,
            default_policy,
            strategy,
        );
        assert(!(@backingInt(stats.of_type) < @backingInt(SymbolEncodingType.compressed) and
            next_entropy.offcode_repeat_mode != .none));
        const count_size = try compress_sequences.buildCTable(
            dst[op..],
            &next_entropy.offcode_ctable,
            zstd_internal.off_fse_log,
            stats.of_type,
            count_workspace,
            max,
            of_codes,
            &zstd_internal.of_default_norm,
            zstd_internal.of_default_norm_log,
            zstd_internal.default_max_off,
            &prev_entropy.offcode_ctable,
            entropy_workspace,
        );
        if (stats.of_type == .compressed) stats.last_count_size = count_size;
        op += count_size;
    }
    // Match lengths.
    {
        var max: u32 = zstd_internal.max_ml;
        const most_frequent = hist.countFastWksp(
            count_workspace,
            &max,
            ml_codes,
            entropy_workspace,
        ) catch
            unreachable;
        next_entropy.matchlength_repeat_mode = prev_entropy.matchlength_repeat_mode;
        stats.ml_type = compress_sequences.selectEncodingType(
            &next_entropy.matchlength_repeat_mode,
            count_workspace,
            max,
            most_frequent,
            nb_seq,
            zstd_internal.ml_fse_log,
            &prev_entropy.matchlength_ctable,
            &zstd_internal.ml_default_norm,
            zstd_internal.ml_default_norm_log,
            .allowed,
            strategy,
        );
        assert(!(@backingInt(stats.ml_type) < @backingInt(SymbolEncodingType.compressed) and
            next_entropy.matchlength_repeat_mode != .none));
        const count_size = try compress_sequences.buildCTable(
            dst[op..],
            &next_entropy.matchlength_ctable,
            zstd_internal.ml_fse_log,
            stats.ml_type,
            count_workspace,
            max,
            ml_codes,
            &zstd_internal.ml_default_norm,
            zstd_internal.ml_default_norm_log,
            zstd_internal.max_ml,
            &prev_entropy.matchlength_ctable,
            entropy_workspace,
        );
        if (stats.ml_type == .compressed) stats.last_count_size = count_size;
        op += count_size;
    }
    stats.size = op;
    return stats;
}

/// `SUSPECT_UNCOMPRESSIBLE_LITERAL_RATIO`: with this many literals per
/// sequence or more, the literals are probably not compressible.
const suspect_uncompressible_literal_ratio = 20;

/// The counts and the rest of an entropy workspace.
fn splitEntropyWorkspace(entropy_workspace: []align(4) u8) struct { []u32, []u8 } {
    return .{
        std.mem.bytesAsSlice(u32, entropy_workspace[0..count_workspace_bytes]),
        entropy_workspace[count_workspace_bytes..],
    };
}

/// `ZSTD_entropyCompressSeqStore_internal`: writes the literals and
/// sequences sections of a block. Returns their size, or 0 when the block
/// must be stored raw.
fn entropyCompressSeqStoreInternal(
    dst: []u8,
    literals: []const u8,
    seq_store: *const SeqStore,
    prev_entropy: *const EntropyCTables,
    next_entropy: *EntropyCTables,
    cctx_params: *const CCtxParams,
    entropy_workspace_in: []align(4) u8,
    bmi2: bool,
) Error!usize {
    const strategy = cctx_params.cparams.strategy;
    const count, const entropy_workspace = splitEntropyWorkspace(entropy_workspace_in);
    const nb_seq = nbSequences(seq_store);
    const sequences = seq_store.sequences_start[0..nb_seq];
    var op: usize = 0;
    var last_count_size: usize = 0;
    var long_offsets = false;
    comptime assert(
        huf.workspace_size >= 1 << @max(zstd_internal.ml_fse_log, zstd_internal.ll_fse_log),
    );
    assert(entropy_workspace.len >= huf.workspace_size);

    // The literals.
    {
        // Suspected from the ratio of literals to sequences.
        const suspect_uncompressible = nb_seq == 0 or
            literals.len / nb_seq >= suspect_uncompressible_literal_ratio;
        const c_size = try compress_literals.compressLiterals(
            dst,
            literals,
            entropy_workspace,
            &prev_entropy.huf,
            &next_entropy.huf,
            cctx_params.cparams.strategy,
            ci.literalsCompressionIsDisabled(cctx_params),
            suspect_uncompressible,
            bmi2,
        );
        assert(c_size <= dst.len);
        op += c_size;
    }

    // The sequences header: up to 3 bytes of count, 1 of encoding types.
    if (dst.len - op < 3 + 1) return error.DstSizeTooSmall;
    if (nb_seq < 128) {
        dst[op] = @intCast(nb_seq);
        op += 1;
    } else if (nb_seq < zstd_internal.long_nb_seq) {
        dst[op] = @intCast((nb_seq >> 8) + 0x80);
        dst[op + 1] = @truncate(nb_seq);
        op += 2;
    } else {
        dst[op] = 0xFF;
        std.mem.writeInt(
            u16,
            dst[op + 1 ..][0..2],
            @intCast(nb_seq - zstd_internal.long_nb_seq),
            .little,
        );
        op += 3;
    }
    if (nb_seq == 0) {
        // The tables repeat.
        next_entropy.fse = prev_entropy.fse;
        return op;
    }
    {
        const seq_head = op;
        op += 1;
        const stats = try buildSequencesStatistics(
            seq_store,
            nb_seq,
            &prev_entropy.fse,
            &next_entropy.fse,
            dst[op..],
            strategy,
            count,
            entropy_workspace,
        );
        dst[seq_head] = (@as(u8, @backingInt(stats.ll_type)) << 6) +
            (@as(u8, @backingInt(stats.of_type)) << 4) +
            (@as(u8, @backingInt(stats.ml_type)) << 2);
        last_count_size = stats.last_count_size;
        op += stats.size;
        long_offsets = stats.long_offsets;
    }

    {
        const bitstream_size = try compress_sequences.encodeSequences(
            dst[op..],
            &next_entropy.fse.matchlength_ctable,
            seq_store.ml_code[0..nb_seq],
            &next_entropy.fse.offcode_ctable,
            seq_store.of_code[0..nb_seq],
            &next_entropy.fse.litlength_ctable,
            seq_store.ll_code[0..nb_seq],
            sequences,
            long_offsets,
            bmi2,
        );
        op += bitstream_size;
        // Decoders up to 1.3.4 refuse a table description read from fewer
        // than 4 bytes: with a last table of 2 bytes and a bit stream of
        // one, the block is stored raw instead.
        if (last_count_size != 0 and last_count_size + bitstream_size < 4) {
            assert(last_count_size + bitstream_size == 3);
            return 0;
        }
    }
    return op;
}

/// `ZSTD_entropyCompressSeqStore_wExtLitBuffer`: as the internal function,
/// with 0 also when the block does not shrink enough or does not fit where
/// a raw block would.
fn entropyCompressSeqStoreWExtLitBuffer(
    dst: []u8,
    literals: []const u8,
    block_size: usize,
    seq_store: *const SeqStore,
    prev_entropy: *const EntropyCTables,
    next_entropy: *EntropyCTables,
    cctx_params: *const CCtxParams,
    entropy_workspace: []align(4) u8,
    bmi2: bool,
) Error!usize {
    const c_size = entropyCompressSeqStoreInternal(
        dst,
        literals,
        seq_store,
        prev_entropy,
        next_entropy,
        cctx_params,
        entropy_workspace,
        bmi2,
    ) catch |err| switch (err) {
        // Out of space where a raw block fits: the block does not compress.
        error.DstSizeTooSmall => if (block_size <= dst.len) return 0 else return err,
        else => return err,
    };
    if (c_size == 0) return 0;

    const max_c_size = block_size - ci.minGain(block_size, cctx_params.cparams.strategy);
    if (c_size >= max_c_size) return 0;
    // Decoders before 1.5.4 refuse a compressed block of exactly
    // `block_size_max`, which the gain above rules out.
    assert(c_size < params.block_size_max);
    return c_size;
}

/// `ZSTD_entropyCompressSeqStore`.
fn entropyCompressSeqStore(
    seq_store: *const SeqStore,
    prev_entropy: *const EntropyCTables,
    next_entropy: *EntropyCTables,
    cctx_params: *const CCtxParams,
    dst: []u8,
    src_size: usize,
    entropy_workspace: []align(4) u8,
    bmi2: bool,
) Error!usize {
    return entropyCompressSeqStoreWExtLitBuffer(
        dst,
        seq_store.lit_start[0..nbLiterals(seq_store)],
        src_size,
        seq_store,
        prev_entropy,
        next_entropy,
        cctx_params,
        entropy_workspace,
        bmi2,
    );
}

/// The context's temporary workspace.
fn tmpWorkspace(cctx: *const CCtx) []align(8) u8 {
    return cctx.tmp_workspace[0..cctx.tmp_wksp_size];
}

/// `ZSTD_selectBlockCompressor`: the match finder of `strat` for
/// `dict_mode`; `strat` is valid and `use_row_match_finder` resolved.
pub fn selectBlockCompressor(
    strat: Strategy,
    use_row_match_finder: ParamSwitch,
    dict_mode: ci.DictMode,
) ci.BlockCompressor {
    const strategy_count = @backingInt(params.strategy_max) + 1;
    const block_compressor = comptime [4][strategy_count]?ci.BlockCompressor{
        .{
            // The default for 0.
            fast.compressBlockFast,
            fast.compressBlockFast,
            double_fast.compressBlockDoubleFast,
            lazy.compressBlockGreedy,
            lazy.compressBlockLazy,
            lazy.compressBlockLazy2,
            lazy.compressBlockBtlazy2,
            opt.compressBlockBtopt,
            opt.compressBlockBtultra,
            opt.compressBlockBtultra2,
        },
        .{
            fast.compressBlockFastExtDict,
            fast.compressBlockFastExtDict,
            double_fast.compressBlockDoubleFastExtDict,
            lazy.compressBlockGreedyExtDict,
            lazy.compressBlockLazyExtDict,
            lazy.compressBlockLazy2ExtDict,
            lazy.compressBlockBtlazy2ExtDict,
            opt.compressBlockBtoptExtDict,
            opt.compressBlockBtultraExtDict,
            opt.compressBlockBtultraExtDict,
        },
        .{
            fast.compressBlockFastDictMatchState,
            fast.compressBlockFastDictMatchState,
            double_fast.compressBlockDoubleFastDictMatchState,
            lazy.compressBlockGreedyDictMatchState,
            lazy.compressBlockLazyDictMatchState,
            lazy.compressBlockLazy2DictMatchState,
            lazy.compressBlockBtlazy2DictMatchState,
            opt.compressBlockBtoptDictMatchState,
            opt.compressBlockBtultraDictMatchState,
            opt.compressBlockBtultraDictMatchState,
        },
        .{
            null,
            null,
            null,
            lazy.compressBlockGreedyDedicatedDictSearch,
            lazy.compressBlockLazyDedicatedDictSearch,
            lazy.compressBlockLazy2DedicatedDictSearch,
            null,
            null,
            null,
            null,
        },
    };
    comptime assert(@backingInt(Strategy.fast) == 1);

    assert(cParamWithinBounds(.strategy, @intCast(@backingInt(strat))));
    const selected_compressor = if (rowMatchFinderUsed(strat, use_row_match_finder)) selected: {
        const row_based_block_compressors = comptime [4][3]ci.BlockCompressor{
            .{
                lazy.compressBlockGreedyRow,
                lazy.compressBlockLazyRow,
                lazy.compressBlockLazy2Row,
            },
            .{
                lazy.compressBlockGreedyExtDictRow,
                lazy.compressBlockLazyExtDictRow,
                lazy.compressBlockLazy2ExtDictRow,
            },
            .{
                lazy.compressBlockGreedyDictMatchStateRow,
                lazy.compressBlockLazyDictMatchStateRow,
                lazy.compressBlockLazy2DictMatchStateRow,
            },
            .{
                lazy.compressBlockGreedyDedicatedDictSearchRow,
                lazy.compressBlockLazyDedicatedDictSearchRow,
                lazy.compressBlockLazy2DedicatedDictSearchRow,
            },
        };
        assert(use_row_match_finder != .auto);
        break :selected row_based_block_compressors[@backingInt(dict_mode)][
            @backingInt(strat) - @backingInt(Strategy.greedy)
        ];
    } else block_compressor[@backingInt(dict_mode)][@backingInt(strat)].?;
    return selected_compressor;
}

/// `ZSTD_storeLastLiterals`.
fn storeLastLiterals(seq_store: *SeqStore, anchor: []const u8) void {
    @memcpy(seq_store.lit[0..anchor.len], anchor);
    seq_store.lit += anchor.len;
}

/// `ZSTD_postProcessSequenceProducerResult`: checks what an external
/// sequence producer returned, `nb_external_seqs` sequences in `out_seqs`,
/// and ends them with a block delimiter. Returns the number of sequences
/// with the delimiter.
fn postProcessSequenceProducerResult(
    out_seqs: []Sequence,
    nb_external_seqs: usize,
    src_size: usize,
) Error!usize {
    if (nb_external_seqs > out_seqs.len) return error.SequenceProducerFailed;
    if (nb_external_seqs == 0 and src_size > 0) return error.SequenceProducerFailed;

    if (src_size == 0) {
        out_seqs[0] = std.mem.zeroes(Sequence);
        return 1;
    }

    const last_seq = out_seqs[nb_external_seqs - 1];
    if (last_seq.offset == 0 and last_seq.match_length == 0) return nb_external_seqs;

    // `sequenceBound` leaves room for the delimiter after any valid parse.
    if (nb_external_seqs == out_seqs.len) return error.SequenceProducerFailed;

    out_seqs[nb_external_seqs] = std.mem.zeroes(Sequence);
    return nb_external_seqs + 1;
}

/// `ZSTD_fastSequenceLengthSum`: the bytes `seqs` cover, with no stop at a
/// block delimiter.
fn fastSequenceLengthSum(seqs: []const Sequence) usize {
    var match_len_sum: usize = 0;
    var lit_len_sum: usize = 0;
    for (seqs) |seq| {
        lit_len_sum += seq.lit_length;
        match_len_sum += seq.match_length;
    }
    return lit_len_sum + match_len_sum;
}

/// `ZSTD_validateSeqStore`: every match is long enough.
fn validateSeqStore(seq_store: *const SeqStore, cparams: *const CompressionParameters) void {
    if (!std.debug.runtime_safety) return;
    const match_len_lower_bound: u32 = if (cparams.min_match == 3) 3 else 4;
    for (seq_store.sequences_start[0..nbSequences(seq_store)]) |*seq| {
        const seq_length = ci.getSequenceLength(seq_store, seq);
        assert(seq_length.match_length >= match_len_lower_bound);
    }
}

/// `ZSTD_buildSeqStore`: finds the sequences of a block of `src` into the
/// context's sequence store. A block too small to compress is
/// `.no_compress`.
fn buildSeqStore(zc: *CCtx, src: []const u8) Error!ci.BuildSeqStore {
    const ms = &zc.block_state.match_state;
    assert(src.len <= params.block_size_max);
    // The match state has the applied parameters.
    assertEqualCParams(zc.applied_params.cparams, ms.cparams);
    // One more than the smallest compressed block and its header, to make up
    // for the smallest block size lowered from 3 to 2.
    if (src.len < zstd_internal.min_cblock_size + block_header_size + 1 + 1) {
        if (@backingInt(zc.applied_params.cparams.strategy) >= @backingInt(Strategy.btopt)) {
            ldm.skipRawSeqStoreBytes(&zc.extern_seq_store, src.len);
        } else {
            ldm.skipSequences(&zc.extern_seq_store, src.len, zc.applied_params.cparams.min_match);
        }
        return .no_compress;
    }
    ci.resetSeqStore(&zc.seq_store);
    // The optimal parser reads the dictionary's statistics.
    ms.opt.symbol_costs = &zc.block_state.prev_cblock.entropy;
    // And how literals will be compressed.
    ms.opt.literal_compression_mode = zc.applied_params.literal_compression_mode;
    // An attached dictionary stays adjacent to the window, or goes.
    assert(ms.dict_match_state == null or ms.loaded_dict_end == ms.window.dict_limit);

    // Updates are limited after a very long match.
    {
        const curr: u32 = @intCast(@intFromPtr(src.ptr) - @intFromPtr(ms.window.base));
        if (curr > ms.next_to_update + 384) {
            ms.next_to_update = curr - @min(192, curr - ms.next_to_update - 384);
        }
    }

    // The sequences.
    const dict_mode = ci.matchStateDictMode(ms);
    var last_ll_size: usize = undefined;
    zc.block_state.next_cblock.rep = zc.block_state.prev_cblock.rep;
    if (zc.extern_seq_store.pos < zc.extern_seq_store.size) {
        assert(zc.applied_params.ldm_params.enable_ldm == .disable);
        // Long distance matching with an external producer is not
        // implemented.
        if (ci.hasExtSeqProd(&zc.applied_params)) return error.ParameterCombinationUnsupported;
        last_ll_size = ldm.blockCompress(
            &zc.extern_seq_store,
            ms,
            &zc.seq_store,
            &zc.block_state.next_cblock.rep,
            selectBlockCompressor(
                zc.applied_params.cparams.strategy,
                zc.applied_params.use_row_match_finder,
                dict_mode,
            ),
            src,
        );
        assert(zc.extern_seq_store.pos <= zc.extern_seq_store.size);
    } else if (zc.applied_params.ldm_params.enable_ldm == .enable) {
        var ldm_seq_store = ci.null_raw_seq_store;
        if (ci.hasExtSeqProd(&zc.applied_params)) return error.ParameterCombinationUnsupported;
        ldm_seq_store.seq = zc.ldm_sequences;
        ldm_seq_store.capacity = zc.max_nb_ldm_sequences;
        try ldm.generateSequences(
            &zc.ldm_state,
            &ldm_seq_store,
            &zc.applied_params.ldm_params,
            src,
        );
        last_ll_size = ldm.blockCompress(
            &ldm_seq_store,
            ms,
            &zc.seq_store,
            &zc.block_state.next_cblock.rep,
            selectBlockCompressor(
                zc.applied_params.cparams.strategy,
                zc.applied_params.use_row_match_finder,
                dict_mode,
            ),
            src,
        );
        assert(ldm_seq_store.pos == ldm_seq_store.size);
    } else if (zc.applied_params.ext_seq_prod) |producer| {
        assert(zc.ext_seq_buf_capacity >= sequenceBound(src.len));
        const ext_seq_buf = zc.ext_seq_buf.?[0..zc.ext_seq_buf_capacity];
        const window_size = @as(u32, 1) << @intCast(zc.applied_params.cparams.window_log);
        // Dictionaries are not passed to producers.
        const nb_external_seqs = producer.produce(
            ext_seq_buf,
            src,
            &.{},
            zc.applied_params.compression_level,
            window_size,
        );
        if (postProcessSequenceProducerResult(
            ext_seq_buf,
            nb_external_seqs,
            src.len,
        )) |nb_post_processed_seqs| {
            // The sequences cover the block, last literals included.
            var seq_pos: ci.SequencePosition = .{ .idx = 0, .pos_in_sequence = 0, .pos_in_src = 0 };
            const seq_len_sum = fastSequenceLengthSum(ext_seq_buf[0..nb_post_processed_seqs]);
            if (seq_len_sum > src.len) return error.ExternalSequencesInvalid;
            _ = try transferSequencesWBlockDelim(
                zc,
                &seq_pos,
                ext_seq_buf[0..nb_post_processed_seqs],
                src,
                zc.applied_params.search_for_external_repcodes,
            );
            ms.ldm_seq_store = null;
            return .compress;
        } else |err| {
            if (!zc.applied_params.enable_match_finder_fallback) return err;
            // The internal match finder takes over.
            const block_compressor = selectBlockCompressor(
                zc.applied_params.cparams.strategy,
                zc.applied_params.use_row_match_finder,
                dict_mode,
            );
            ms.ldm_seq_store = null;
            last_ll_size = block_compressor(
                ms,
                &zc.seq_store,
                &zc.block_state.next_cblock.rep,
                src,
            );
        }
    } else {
        const block_compressor = selectBlockCompressor(
            zc.applied_params.cparams.strategy,
            zc.applied_params.use_row_match_finder,
            dict_mode,
        );
        ms.ldm_seq_store = null;
        last_ll_size = block_compressor(ms, &zc.seq_store, &zc.block_state.next_cblock.rep, src);
    }
    storeLastLiterals(&zc.seq_store, src[src.len - last_ll_size ..]);
    validateSeqStore(&zc.seq_store, &zc.applied_params.cparams);
    return .compress;
}

/// `ZSTD_copyBlockSequences`: appends the block's sequences, with raw
/// offsets, and a delimiter holding its last literals, to the collector.
fn copyBlockSequences(
    seq_collector: *ci.SeqCollector,
    seq_store: *const SeqStore,
    prev_repcodes: *const [rep_num]u32,
) Error!void {
    const in_seqs = seq_store.sequences_start;
    const nb_in_sequences = nbSequences(seq_store);
    const nb_in_literals = nbLiterals(seq_store);

    const out_seqs = seq_collector.seq_start + seq_collector.seq_index;
    const nb_out_sequences = nb_in_sequences + 1;
    var nb_out_literals: usize = 0;

    // Room for every sequence and the delimiter.
    assert(seq_collector.seq_index <= seq_collector.max_sequences);
    if (nb_out_sequences > seq_collector.max_sequences - seq_collector.seq_index) {
        return error.DstSizeTooSmall;
    }

    var repcodes: ci.Repcodes = .{ .rep = prev_repcodes.* };
    for (0..nb_in_sequences) |i| {
        var raw_offset: u32 = undefined;
        out_seqs[i].lit_length = in_seqs[i].lit_length;
        out_seqs[i].match_length = @as(u32, in_seqs[i].ml_base) + min_match;
        out_seqs[i].rep = 0;

        // One length of a block can be 64 KiB or more.
        if (i == seq_store.long_length_pos) {
            if (seq_store.long_length_type == .literal_length) {
                out_seqs[i].lit_length += 0x10000;
            } else if (seq_store.long_length_type == .match_length) {
                out_seqs[i].match_length += 0x10000;
            }
        }

        // The raw offset, which a repeat code refers to.
        if (ci.offbaseIsRepcode(in_seqs[i].off_base)) {
            const repcode = ci.offbaseToRepcode(in_seqs[i].off_base);
            assert(repcode > 0);
            out_seqs[i].rep = repcode;
            if (out_seqs[i].lit_length != 0) {
                raw_offset = repcodes.rep[repcode - 1];
            } else if (repcode == 3) {
                assert(repcodes.rep[0] > 1);
                raw_offset = repcodes.rep[0] - 1;
            } else {
                raw_offset = repcodes.rep[repcode];
            }
        } else {
            raw_offset = ci.offbaseToOffset(in_seqs[i].off_base);
        }
        out_seqs[i].offset = raw_offset;

        ci.updateRep(&repcodes.rep, in_seqs[i].off_base, @intFromBool(in_seqs[i].lit_length == 0));

        nb_out_literals += out_seqs[i].lit_length;
    }
    // The last literals, in a delimiter (which may hold none).
    assert(nb_in_literals >= nb_out_literals);
    {
        const last_ll_size = nb_in_literals - nb_out_literals;
        out_seqs[nb_in_sequences].lit_length = @intCast(last_ll_size);
        out_seqs[nb_in_sequences].match_length = 0;
        out_seqs[nb_in_sequences].offset = 0;
    }
    seq_collector.seq_index += nb_out_sequences;
    assert(seq_collector.seq_index <= seq_collector.max_sequences);
}

/// `ZSTD_sequenceBound`: the most sequences, delimiters included,
/// `generateSequences` writes for `src_size` bytes.
pub fn sequenceBound(src_size: usize) usize {
    const max_nb_seq = (src_size / params.min_match_min) + 1;
    const max_nb_delims = (src_size / params.block_size_max_min) + 1;
    return max_nb_seq + max_nb_delims;
}

/// `ZSTD_generateSequences`: the sequences a compression of `src` with the
/// context's parameters finds, with a delimiter after each block. Returns
/// the number written to `out_seqs`, which holds `sequenceBound` of them
/// for any input. Allocates a scratch output with `gpa`.
pub fn generateSequences(
    zc: *CCtx,
    gpa: std.mem.Allocator,
    out_seqs: []Sequence,
    src: []const u8,
) Error!usize {
    const dst_capacity = compressBoundMacro(src.len);
    {
        const target_cblock_size = try cctxGetParameter(zc, .target_cblock_size);
        if (target_cblock_size != 0) return error.ParameterUnsupported;
    }
    {
        const nb_workers = try cctxGetParameter(zc, .nb_workers);
        if (nb_workers != 0) return error.ParameterUnsupported;
    }

    const dst = gpa.alloc(u8, dst_capacity) catch return error.MemoryAllocation;
    defer gpa.free(dst);

    zc.seq_collector = .{
        .collect_sequences = true,
        .seq_start = out_seqs.ptr,
        .seq_index = 0,
        .max_sequences = out_seqs.len,
    };

    _ = try compress2(zc, dst, src);
    assert(zc.seq_collector.seq_index <= sequenceBound(src.len));
    return zc.seq_collector.seq_index;
}

/// `ZSTD_mergeBlockDelimiters`: removes the delimiters from `sequences`,
/// their literals going to the next sequence. Returns the number left.
pub fn mergeBlockDelimiters(sequences: []Sequence) usize {
    var out: usize = 0;
    for (0..sequences.len) |in| {
        if (sequences[in].offset == 0 and sequences[in].match_length == 0) {
            if (in != sequences.len - 1) sequences[in + 1].lit_length += sequences[in].lit_length;
        } else {
            sequences[out] = sequences[in];
            out += 1;
        }
    }
    return out;
}

/// `ZSTD_isRLE`: whether `src`, not empty, is one byte repeated.
fn isRle(src: []const u8) bool {
    const value = src[0];
    if (src.len == 1) return true;
    const Word = @Vector(@sizeOf(usize) * 4, u8);
    const unroll_size = @sizeOf(Word);
    const prefix_length = src.len & (unroll_size - 1);
    // The prefix first, then whole words.
    if (prefix_length != 0 and
        ci.count(src.ptr + 1, src.ptr, src.ptr + prefix_length) != prefix_length - 1)
    {
        return false;
    }
    const values: Word = @splat(value);
    var i = prefix_length;
    while (i != src.len) : (i += unroll_size) {
        const word: Word = src[i..][0..unroll_size].*;
        if (!@reduce(.And, word == values)) return false;
    }
    return true;
}

/// `ZSTD_maybeRLE`: whether the block may be RLE, judged from its
/// sequences; it can be wrong either way.
fn maybeRle(seq_store: *const SeqStore) bool {
    return nbSequences(seq_store) < 4 and nbLiterals(seq_store) < 10;
}

/// `ZSTD_blockState_confirmRepcodesAndEntropyTables`: the next block state
/// becomes the previous.
fn blockStateConfirmRepcodesAndEntropyTables(bs: *ci.BlockState) void {
    const tmp = bs.prev_cblock;
    bs.prev_cblock = bs.next_cblock;
    bs.next_cblock = tmp;
}

/// `writeBlockHeader`: the header of a compressed block of `c_size`
/// bytes, or of an RLE block of `block_size` when `c_size` is 1.
fn writeBlockHeader(op: []u8, c_size: usize, block_size: usize, last_block: u32) void {
    const c_block_header: u32 = if (c_size == 1)
        last_block + (@as(u32, @backingInt(zstd_internal.BlockType.rle)) << 1) +
            @as(u32, @truncate(block_size << 3))
    else
        last_block + (@as(u32, @backingInt(zstd_internal.BlockType.compressed)) << 1) +
            @as(u32, @truncate(c_size << 3));
    writeLe24(op, c_block_header);
}

fn writeLe24(dst: []u8, value: u32) void {
    std.mem.writeInt(u16, dst[0..2], @truncate(value), .little);
    dst[2] = @truncate(value >> 16);
}

/// `COMPRESS_LITERALS_SIZE_MIN`: fewer literals are not worth an attempt.
const compress_literals_size_min = 63;

/// `ZSTD_buildBlockEntropyStats_literals`: chooses how to code the
/// literals and writes their Huffman description to `huf_metadata`.
/// Returns the description's size.
fn buildBlockEntropyStatsLiterals(
    src: []const u8,
    prev_huf: *const ci.HufCTables,
    next_huf: *ci.HufCTables,
    huf_metadata: *ci.HufCTablesMetadata,
    literals_compression_is_disabled: bool,
    workspace: []align(4) u8,
    huf_flags: huf.Flags,
) Error!usize {
    const count_wksp_size = (huf.symbol_value_max + 1) * @sizeOf(u32);
    const count_wksp = std.mem.bytesAsSlice(u32, workspace[0..count_wksp_size]);
    const node_wksp = workspace[count_wksp_size..];
    var max_symbol_value: u32 = huf.symbol_value_max;
    var huff_log: u32 = zstd_internal.lit_huf_log;
    var repeat = prev_huf.repeat_mode;

    // Assume the existing table is reused.
    next_huf.* = prev_huf.*;

    if (literals_compression_is_disabled) {
        huf_metadata.h_type = .basic;
        return 0;
    }

    // Too small to be worth an attempt.
    {
        const min_lit_size: usize =
            if (prev_huf.repeat_mode == .valid) 6 else compress_literals_size_min;
        if (src.len <= min_lit_size) {
            huf_metadata.h_type = .basic;
            return 0;
        }
    }

    // The symbols' statistics.
    {
        const largest = try hist.countWksp(count_wksp, &max_symbol_value, src, workspace);
        if (largest == src.len) {
            // One symbol only.
            huf_metadata.h_type = .rle;
            return 0;
        }
        if (largest <= (src.len >> 7) + 4) {
            // Likely not compressible.
            huf_metadata.h_type = .basic;
            return 0;
        }
    }

    // The previous table may not cover every symbol.
    if (repeat == .check and !huf_compress.validateCTable(
        &prev_huf.ctable,
        count_wksp,
        max_symbol_value,
    )) {
        repeat = .none;
    }

    // The Huffman tree.
    @memset(&next_huf.ctable, std.mem.zeroes(huf.CElt));
    huff_log = huf_compress.optimalTableLog(
        huff_log,
        src.len,
        max_symbol_value,
        node_wksp,
        &next_huf.ctable,
        count_wksp,
        huf_flags,
    );
    assert(huff_log <= zstd_internal.lit_huf_log);
    huff_log = try huf_compress.buildCTableWksp(
        &next_huf.ctable,
        count_wksp,
        max_symbol_value,
        huff_log,
        node_wksp,
    );

    // The table and its description, against repeating the previous one.
    const new_c_size = huf_compress.estimateCompressedSize(
        &next_huf.ctable,
        count_wksp,
        max_symbol_value,
    );
    const h_size = try huf_compress.writeCTableWksp(
        &huf_metadata.huf_des_buffer,
        &next_huf.ctable,
        max_symbol_value,
        huff_log,
        node_wksp,
    );
    if (repeat != .none) {
        const old_c_size = huf_compress.estimateCompressedSize(
            &prev_huf.ctable,
            count_wksp,
            max_symbol_value,
        );
        if (old_c_size < src.len and (old_c_size <= h_size + new_c_size or h_size + 12 >=
            src.len))
        {
            next_huf.* = prev_huf.*;
            huf_metadata.h_type = .repeat;
            return 0;
        }
    }
    if (new_c_size + h_size >= src.len) {
        next_huf.* = prev_huf.*;
        huf_metadata.h_type = .basic;
        return 0;
    }
    huf_metadata.h_type = .compressed;
    next_huf.repeat_mode = .check;
    return h_size;
}

/// `ZSTD_buildDummySequencesStatistics`: the statistics of a block without
/// sequences.
fn buildDummySequencesStatistics(next_entropy: *ci.FseCTables) SymbolEncodingTypeStats {
    next_entropy.litlength_repeat_mode = .none;
    next_entropy.offcode_repeat_mode = .none;
    next_entropy.matchlength_repeat_mode = .none;
    return .{
        .ll_type = .basic,
        .of_type = .basic,
        .ml_type = .basic,
        .size = 0,
        .last_count_size = 0,
        .long_offsets = false,
    };
}

/// `ZSTD_buildBlockEntropyStats_sequences`: chooses how to code the
/// sequences and writes their table descriptions to `fse_metadata`.
/// Returns the descriptions' size.
fn buildBlockEntropyStatsSequences(
    seq_store: *const SeqStore,
    prev_entropy: *const ci.FseCTables,
    next_entropy: *ci.FseCTables,
    cctx_params: *const CCtxParams,
    fse_metadata: *ci.FseCTablesMetadata,
    workspace: []align(4) u8,
) Error!usize {
    const strategy = cctx_params.cparams.strategy;
    const nb_seq = nbSequences(seq_store);
    const count_workspace, const entropy_workspace = splitEntropyWorkspace(workspace);
    const stats = if (nb_seq != 0)
        try buildSequencesStatistics(
            seq_store,
            nb_seq,
            prev_entropy,
            next_entropy,
            &fse_metadata.fse_tables_buffer,
            strategy,
            count_workspace,
            entropy_workspace,
        )
    else
        buildDummySequencesStatistics(next_entropy);
    fse_metadata.ll_type = stats.ll_type;
    fse_metadata.of_type = stats.of_type;
    fse_metadata.ml_type = stats.ml_type;
    fse_metadata.last_count_size = stats.last_count_size;
    return stats.size;
}

/// `HUF_OPTIMAL_DEPTH_THRESHOLD`.
const huf_optimal_depth_threshold: Strategy = .btultra;

/// `ZSTD_buildBlockEntropyStats`: chooses how to code the block's literals
/// and sequences, with their table descriptions in `entropy_metadata`.
/// `workspace` holds `ci.entropy_workspace_size` bytes.
pub fn buildBlockEntropyStats(
    seq_store: *const SeqStore,
    prev_entropy: *const EntropyCTables,
    next_entropy: *EntropyCTables,
    cctx_params: *const CCtxParams,
    entropy_metadata: *ci.EntropyCTablesMetadata,
    workspace: []align(4) u8,
) Error!void {
    const lit_size = nbLiterals(seq_store);
    const huf_use_opt_depth = @backingInt(cctx_params.cparams.strategy) >=
        @backingInt(huf_optimal_depth_threshold);
    const huf_flags: huf.Flags = .{ .optimal_depth = huf_use_opt_depth };

    entropy_metadata.huf_metadata.huf_des_size = try buildBlockEntropyStatsLiterals(
        seq_store.lit_start[0..lit_size],
        &prev_entropy.huf,
        &next_entropy.huf,
        &entropy_metadata.huf_metadata,
        ci.literalsCompressionIsDisabled(cctx_params),
        workspace,
        huf_flags,
    );
    entropy_metadata.fse_metadata.fse_tables_size = try buildBlockEntropyStatsSequences(
        seq_store,
        &prev_entropy.fse,
        &next_entropy.fse,
        cctx_params,
        &entropy_metadata.fse_metadata,
        workspace,
    );
}

/// `ZSTD_estimateBlockSize_literal`: the estimated size of the literals
/// section, header included.
fn estimateBlockSizeLiteral(
    literals: []const u8,
    huf_tables: *const ci.HufCTables,
    huf_metadata: *const ci.HufCTablesMetadata,
    workspace: []align(4) u8,
    write_entropy: bool,
) usize {
    const count_wksp = std.mem.bytesAsSlice(
        u32,
        workspace[0 .. (huf.symbol_value_max + 1) * @sizeOf(u32)],
    );
    var max_symbol_value: u32 = huf.symbol_value_max;
    const lit_size = literals.len;
    const literal_section_header_size: usize = 3 + @as(usize, @intFromBool(lit_size >= 1 * kib)) +
        @intFromBool(lit_size >= 16 * kib);
    const single_stream = lit_size < 256;

    switch (huf_metadata.h_type) {
        .basic => return lit_size,
        .rle => return 1,
        .compressed, .repeat => {
            _ = hist.countWksp(
                count_wksp,
                &max_symbol_value,
                literals,
                workspace,
            ) catch return lit_size;
            var c_lit_size_estimate = huf_compress.estimateCompressedSize(
                &huf_tables.ctable,
                count_wksp,
                max_symbol_value,
            );
            if (write_entropy) c_lit_size_estimate += huf_metadata.huf_des_size;
            // Four streams have a jump table of 6 bytes.
            if (!single_stream) c_lit_size_estimate += 6;
            return c_lit_size_estimate + literal_section_header_size;
        },
    }
}

/// `ZSTD_estimateBlockSize_symbolType`: the estimated size of one code
/// table's symbols and extra bits. `additional_bits` is null for offsets,
/// whose code is their number of extra bits.
fn estimateBlockSizeSymbolType(
    h_type: SymbolEncodingType,
    code_table: []const u8,
    max_code: u32,
    fse_ctable: []const u32,
    additional_bits: ?[]const u8,
    default_norm: []const i16,
    default_norm_log: u32,
    default_max: u32,
    workspace: []align(4) u8,
) usize {
    const count_wksp = std.mem.bytesAsSlice(u32, workspace[0..count_workspace_bytes]);
    const nb_seq = code_table.len;
    var max = max_code;

    _ = hist.countFastWksp(count_wksp, &max, code_table, workspace) catch unreachable;
    const symbol_bits: Error!usize = switch (h_type) {
        .basic => basic: {
            // The type was chosen, so it is valid.
            assert(max <= default_max);
            break :basic compress_sequences.crossEntropyCost(
                default_norm,
                default_norm_log,
                count_wksp,
                max,
            );
        },
        .rle => 0,
        .compressed, .repeat => compress_sequences.fseBitCost(fse_ctable, count_wksp, max),
    };
    var c_symbol_type_size_estimate_in_bits = symbol_bits catch return nb_seq * 10;
    for (code_table) |code| {
        c_symbol_type_size_estimate_in_bits += if (additional_bits) |bits| bits[code] else code;
    }
    return c_symbol_type_size_estimate_in_bits >> 3;
}

/// `ZSTD_estimateBlockSize_sequences`: the estimated size of the sequences
/// section, header included.
fn estimateBlockSizeSequences(
    of_code_table: []const u8,
    ll_code_table: []const u8,
    ml_code_table: []const u8,
    fse_tables: *const ci.FseCTables,
    fse_metadata: *const ci.FseCTablesMetadata,
    workspace: []align(4) u8,
    write_entropy: bool,
) usize {
    const nb_seq = of_code_table.len;
    const sequences_section_header_size: usize = 1 + 1 + @as(usize, @intFromBool(nb_seq >= 128)) +
        @intFromBool(nb_seq >= zstd_internal.long_nb_seq);
    var c_seq_size_estimate: usize = 0;
    c_seq_size_estimate += estimateBlockSizeSymbolType(
        fse_metadata.of_type,
        of_code_table,
        zstd_internal.max_off,
        &fse_tables.offcode_ctable,
        null,
        &zstd_internal.of_default_norm,
        zstd_internal.of_default_norm_log,
        zstd_internal.default_max_off,
        workspace,
    );
    c_seq_size_estimate += estimateBlockSizeSymbolType(
        fse_metadata.ll_type,
        ll_code_table,
        zstd_internal.max_ll,
        &fse_tables.litlength_ctable,
        &zstd_internal.ll_bits,
        &zstd_internal.ll_default_norm,
        zstd_internal.ll_default_norm_log,
        zstd_internal.max_ll,
        workspace,
    );
    c_seq_size_estimate += estimateBlockSizeSymbolType(
        fse_metadata.ml_type,
        ml_code_table,
        zstd_internal.max_ml,
        &fse_tables.matchlength_ctable,
        &zstd_internal.ml_bits,
        &zstd_internal.ml_default_norm,
        zstd_internal.ml_default_norm_log,
        zstd_internal.max_ml,
        workspace,
    );
    if (write_entropy) c_seq_size_estimate += fse_metadata.fse_tables_size;
    return c_seq_size_estimate + sequences_section_header_size;
}

/// `ZSTD_estimateBlockSize`: the estimated size of a block of these
/// literals and codes, header included.
fn estimateBlockSize(
    literals: []const u8,
    of_code_table: []const u8,
    ll_code_table: []const u8,
    ml_code_table: []const u8,
    entropy: *const EntropyCTables,
    entropy_metadata: *const ci.EntropyCTablesMetadata,
    workspace: []align(4) u8,
    write_lit_entropy: bool,
    write_seq_entropy: bool,
) usize {
    const literals_size = estimateBlockSizeLiteral(
        literals,
        &entropy.huf,
        &entropy_metadata.huf_metadata,
        workspace,
        write_lit_entropy,
    );
    const seq_size = estimateBlockSizeSequences(
        of_code_table,
        ll_code_table,
        ml_code_table,
        &entropy.fse,
        &entropy_metadata.fse_metadata,
        workspace,
        write_seq_entropy,
    );
    return seq_size + literals_size + block_header_size;
}

/// `ZSTD_buildEntropyStatisticsAndEstimateSubBlockSize`: the estimated
/// compressed size of `seq_store`, a part of the block.
fn buildEntropyStatisticsAndEstimateSubBlockSize(seq_store: *SeqStore, zc: *CCtx) Error!usize {
    const entropy_metadata = &zc.block_split_ctx.entropy_metadata;
    try buildBlockEntropyStats(
        seq_store,
        &zc.block_state.prev_cblock.entropy,
        &zc.block_state.next_cblock.entropy,
        &zc.applied_params,
        entropy_metadata,
        tmpWorkspace(zc),
    );
    const nb_seq = nbSequences(seq_store);
    return estimateBlockSize(
        seq_store.lit_start[0..nbLiterals(seq_store)],
        seq_store.of_code[0..nb_seq],
        seq_store.ll_code[0..nb_seq],
        seq_store.ml_code[0..nb_seq],
        &zc.block_state.next_cblock.entropy,
        entropy_metadata,
        tmpWorkspace(zc),
        entropy_metadata.huf_metadata.h_type == .compressed,
        true,
    );
}

/// `ZSTD_countSeqStoreLiteralsBytes`: the literals of the store's
/// sequences, without its last literals.
fn countSeqStoreLiteralsBytes(seq_store: *const SeqStore) usize {
    var literals_bytes: usize = 0;
    for (seq_store.sequences_start[0..nbSequences(seq_store)], 0..) |seq, i| {
        literals_bytes += seq.lit_length;
        if (i == seq_store.long_length_pos and seq_store.long_length_type == .literal_length) {
            literals_bytes += 0x10000;
        }
    }
    return literals_bytes;
}

/// `ZSTD_countSeqStoreMatchBytes`.
fn countSeqStoreMatchBytes(seq_store: *const SeqStore) usize {
    var match_bytes: usize = 0;
    for (seq_store.sequences_start[0..nbSequences(seq_store)], 0..) |seq, i| {
        match_bytes += @as(usize, seq.ml_base) + min_match;
        if (i == seq_store.long_length_pos and seq_store.long_length_type == .match_length) {
            match_bytes += 0x10000;
        }
    }
    return match_bytes;
}

/// `ZSTD_deriveSeqStoreChunk`: `result` becomes the sequences
/// `[start_idx, end_idx)` of `original`, with their literals; the chunk
/// that ends the block has its last literals too. `result` points into
/// `original`'s buffers.
fn deriveSeqStoreChunk(
    result: *SeqStore,
    original: *const SeqStore,
    start_idx: usize,
    end_idx: usize,
) void {
    result.* = original.*;
    if (start_idx > 0) {
        result.sequences = original.sequences_start + start_idx;
        result.lit_start += countSeqStoreLiteralsBytes(result);
    }

    // The long length's position, in the chunk.
    if (original.long_length_type != .none) {
        if (original.long_length_pos < start_idx or original.long_length_pos > end_idx) {
            result.long_length_type = .none;
        } else {
            result.long_length_pos -= @intCast(start_idx);
        }
    }
    result.sequences_start = original.sequences_start + start_idx;
    result.sequences = original.sequences_start + end_idx;
    if (end_idx == nbSequences(original)) {
        // The last literals are the block's.
        assert(result.lit == original.lit);
    } else {
        const literals_bytes = countSeqStoreLiteralsBytes(result);
        result.lit = result.lit_start + literals_bytes;
    }
    result.ll_code += start_idx;
    result.ml_code += start_idx;
    result.of_code += start_idx;
}

/// `ZSTD_resolveRepcodeToRawOffset`: the offset the repeat code `off_base`
/// refers to with history `rep`. It can be 0, an invalid offset, which
/// `seqStoreResolveOffCodes` discards.
fn resolveRepcodeToRawOffset(rep: *const [rep_num]u32, off_base: u32, ll0: u32) u32 {
    // 0 to 3.
    const adjusted_rep_code = ci.offbaseToRepcode(off_base) - 1 + ll0;
    assert(ci.offbaseIsRepcode(off_base));
    if (adjusted_rep_code == rep_num) {
        assert(ll0 != 0);
        // The first repeat offset minus one.
        return rep[0] -% 1;
    }
    return rep[adjusted_rep_code];
}

/// `ZSTD_seqStore_resolveOffCodes`: replaces the repeat codes of a part of
/// a block that refer to offsets the decoder will not have, after earlier
/// parts were stored raw or RLE, by their raw offsets. `d_repcodes` follows
/// the decoder's history, `c_repcodes` the compressor's.
fn seqStoreResolveOffCodes(
    d_repcodes: *ci.Repcodes,
    c_repcodes: *ci.Repcodes,
    seq_store: *const SeqStore,
    nb_seq: u32,
) void {
    const long_lit_len_idx = if (seq_store.long_length_type == .literal_length)
        seq_store.long_length_pos
    else
        nb_seq;
    var idx: u32 = 0;
    while (idx < nb_seq) : (idx += 1) {
        const seq = &seq_store.sequences_start[idx];
        const ll0: u32 = @intFromBool(seq.lit_length == 0 and idx != long_lit_len_idx);
        const off_base = seq.off_base;
        assert(off_base > 0);
        if (ci.offbaseIsRepcode(off_base)) {
            const d_raw_offset = resolveRepcodeToRawOffset(&d_repcodes.rep, off_base, ll0);
            const c_raw_offset = resolveRepcodeToRawOffset(&c_repcodes.rep, off_base, ll0);
            // The offset the compressor meant.
            if (d_raw_offset != c_raw_offset) seq.off_base = ci.offsetToOffbase(c_raw_offset);
        }
        // The compressor's history follows the store as found; the
        // decoder's, the store as written.
        ci.updateRep(&d_repcodes.rep, seq.off_base, ll0);
        ci.updateRep(&c_repcodes.rep, off_base, ll0);
    }
}

/// `ZSTD_compressSeqStore_singleBlock`: writes `seq_store` as one block of
/// `src`, header included.
fn compressSeqStoreSingleBlock(
    zc: *CCtx,
    seq_store: *const SeqStore,
    d_rep: *ci.Repcodes,
    c_rep: *ci.Repcodes,
    dst: []u8,
    src: []const u8,
    last_block: u32,
    is_partition: bool,
) Error!usize {
    const rle_max_length = 25;
    var c_size: usize = undefined;

    // A raw or RLE block leaves the decoder's history as it was.
    const d_rep_original = d_rep.*;
    if (is_partition) seqStoreResolveOffCodes(
        d_rep,
        c_rep,
        seq_store,
        @intCast(nbSequences(seq_store)),
    );

    if (dst.len < block_header_size) return error.DstSizeTooSmall;
    var c_seqs_size = try entropyCompressSeqStore(
        seq_store,
        &zc.block_state.prev_cblock.entropy,
        &zc.block_state.next_cblock.entropy,
        &zc.applied_params,
        dst[block_header_size..],
        src.len,
        tmpWorkspace(zc),
        zc.bmi2,
    );

    // Decoders up to 1.4.3 refuse a first block that is RLE.
    if (!zc.is_first_block and c_seqs_size < rle_max_length and isRle(src)) c_seqs_size = 1;

    // Sequences are collected without the block split.
    if (zc.seq_collector.collect_sequences) {
        try copyBlockSequences(&zc.seq_collector, seq_store, &d_rep_original.rep);
        blockStateConfirmRepcodesAndEntropyTables(&zc.block_state);
        return 0;
    }

    if (c_seqs_size == 0) {
        c_size = try ci.noCompressBlock(dst, src, last_block);
        d_rep.* = d_rep_original;
    } else if (c_seqs_size == 1) {
        c_size = try ci.rleCompressBlock(dst, src[0], src.len, last_block);
        d_rep.* = d_rep_original;
    } else {
        blockStateConfirmRepcodesAndEntropyTables(&zc.block_state);
        writeBlockHeader(dst, c_seqs_size, src.len, last_block);
        c_size = block_header_size + c_seqs_size;
    }

    if (zc.block_state.prev_cblock.entropy.fse.offcode_repeat_mode == .valid) {
        zc.block_state.prev_cblock.entropy.fse.offcode_repeat_mode = .check;
    }
    return c_size;
}

/// `seqStoreSplits`: where the recursive split search is.
const SeqStoreSplits = struct {
    split_locations: []u32,
    idx: usize,
};

/// `MIN_SEQUENCES_BLOCK_SPLITTING`: fewer sequences are not split.
const min_sequences_block_splitting = 300;

/// `ZSTD_deriveBlockSplitsHelper`: splits `[start_idx, end_idx)` in halves
/// while their estimated sizes beat the whole's. The depth is bounded by
/// `min_sequences_block_splitting`, the splits by `max_nb_block_splits`,
/// which a block of `block_size_max` cannot reach.
fn deriveBlockSplitsHelper(
    splits: *SeqStoreSplits,
    start_idx: usize,
    end_idx: usize,
    zc: *CCtx,
    orig_seq_store: *const SeqStore,
) void {
    const full_seq_store_chunk = &zc.block_split_ctx.full_seq_store_chunk;
    const first_half_seq_store = &zc.block_split_ctx.first_half_seq_store;
    const second_half_seq_store = &zc.block_split_ctx.second_half_seq_store;
    const mid_idx = (start_idx + end_idx) / 2;

    assert(end_idx >= start_idx);
    if (end_idx - start_idx < min_sequences_block_splitting or splits.idx >=
        ci.max_nb_block_splits)
    {
        return;
    }
    deriveSeqStoreChunk(full_seq_store_chunk, orig_seq_store, start_idx, end_idx);
    deriveSeqStoreChunk(first_half_seq_store, orig_seq_store, start_idx, mid_idx);
    deriveSeqStoreChunk(second_half_seq_store, orig_seq_store, mid_idx, end_idx);
    const estimated_original_size = buildEntropyStatisticsAndEstimateSubBlockSize(
        full_seq_store_chunk,
        zc,
    );
    const estimated_first_half_size = buildEntropyStatisticsAndEstimateSubBlockSize(
        first_half_seq_store,
        zc,
    );
    const estimated_second_half_size = buildEntropyStatisticsAndEstimateSubBlockSize(
        second_half_seq_store,
        zc,
    );
    const original = estimated_original_size catch return;
    const first_half = estimated_first_half_size catch return;
    const second_half = estimated_second_half_size catch return;
    if (first_half + second_half < original) {
        deriveBlockSplitsHelper(splits, start_idx, mid_idx, zc, orig_seq_store);
        splits.split_locations[splits.idx] = @intCast(mid_idx);
        splits.idx += 1;
        deriveBlockSplitsHelper(splits, mid_idx, end_idx, zc, orig_seq_store);
    }
}

/// `ZSTD_deriveBlockSplits`: fills `partitions` with the indexes the block
/// is split at, then `nb_seq`. Returns the number of splits.
fn deriveBlockSplits(zc: *CCtx, partitions: []u32, nb_seq: u32) usize {
    var splits: SeqStoreSplits = .{ .split_locations = partitions, .idx = 0 };
    // Not with 4 sequences or fewer.
    if (nb_seq <= 4) return 0;
    deriveBlockSplitsHelper(&splits, 0, nb_seq, zc, &zc.seq_store);
    splits.split_locations[splits.idx] = nb_seq;
    return splits.idx;
}

/// `ZSTD_compressBlock_splitBlock_internal`: writes the block's sequences
/// as one or more blocks, where splitting them beats the estimate of one.
fn compressBlockSplitBlockInternal(
    zc: *CCtx,
    dst_in: []u8,
    src: []const u8,
    last_block: u32,
    nb_seq: u32,
) Error!usize {
    var c_size: usize = 0;
    var ip: usize = 0;
    var dst = dst_in;
    var src_bytes_total: usize = 0;
    const partitions = &zc.block_split_ctx.partitions;
    const next_seq_store = &zc.block_split_ctx.next_seq_store;
    const curr_seq_store = &zc.block_split_ctx.curr_seq_store;
    const num_splits = deriveBlockSplits(zc, partitions, nb_seq);

    // Raw and RLE parts leave repeat codes the decoder will not have.
    // `c_rep` follows every part, so it has the offsets such a code refers
    // to; `d_rep` follows the compressed parts only, with the codes
    // replaced, and goes to the next block. See `seqStoreResolveOffCodes`.
    var d_rep: ci.Repcodes = .{ .rep = zc.block_state.prev_cblock.rep };
    var c_rep: ci.Repcodes = .{ .rep = zc.block_state.prev_cblock.rep };
    next_seq_store.* = .{};

    if (num_splits == 0) {
        const c_size_single_block = try compressSeqStoreSingleBlock(
            zc,
            &zc.seq_store,
            &d_rep,
            &c_rep,
            dst,
            src,
            last_block,
            false,
        );
        assert(zc.block_size_max <= params.block_size_max);
        assert(c_size_single_block <= zc.block_size_max + block_header_size);
        return c_size_single_block;
    }

    deriveSeqStoreChunk(curr_seq_store, &zc.seq_store, 0, partitions[0]);
    for (0..num_splits + 1) |i| {
        const last_partition = i == num_splits;
        var last_block_entire_src: u32 = 0;

        var src_bytes =
            countSeqStoreLiteralsBytes(curr_seq_store) + countSeqStoreMatchBytes(curr_seq_store);
        src_bytes_total += src_bytes;
        if (last_partition) {
            // The last part has the block's last literals.
            src_bytes += src.len - src_bytes_total;
            last_block_entire_src = last_block;
        } else {
            deriveSeqStoreChunk(next_seq_store, &zc.seq_store, partitions[i], partitions[i + 1]);
        }

        const c_size_chunk = try compressSeqStoreSingleBlock(
            zc,
            curr_seq_store,
            &d_rep,
            &c_rep,
            dst,
            src[ip..][0..src_bytes],
            last_block_entire_src,
            true,
        );

        ip += src_bytes;
        dst = dst[c_size_chunk..];
        c_size += c_size_chunk;
        curr_seq_store.* = next_seq_store.*;
        assert(c_size_chunk <= zc.block_size_max + block_header_size);
    }
    // The decoder's history goes to the next block.
    zc.block_state.prev_cblock.rep = d_rep.rep;
    return c_size;
}

/// `ZSTD_compressBlock_splitBlock`: compresses a block of `src` with the
/// post-splitter, header included.
fn compressBlockSplitBlock(zc: *CCtx, dst: []u8, src: []const u8, last_block: u32) Error!usize {
    assert(zc.applied_params.post_block_splitter == .enable);

    const bss = try buildSeqStore(zc, src);
    if (bss == .no_compress) {
        if (zc.block_state.prev_cblock.entropy.fse.offcode_repeat_mode == .valid) {
            zc.block_state.prev_cblock.entropy.fse.offcode_repeat_mode = .check;
        }
        if (zc.seq_collector.collect_sequences) return error.SequenceProducerFailed;
        return ci.noCompressBlock(dst, src, last_block);
    }
    const nb_seq: u32 = @intCast(nbSequences(&zc.seq_store));
    return compressBlockSplitBlockInternal(zc, dst, src, last_block, nb_seq);
}

/// `ZSTD_compressBlock_internal`: compresses a block of `src` without its
/// header. Returns 0 for a block to store raw, 1 for an RLE block (its byte
/// written), or the compressed size.
fn compressBlockInternal(zc: *CCtx, dst: []u8, src: []const u8, frame: bool) Error!usize {
    // An estimate of the largest RLE block, not the real bound.
    const rle_max_length = 25;
    var c_size: usize = 0;

    compressed: {
        const bss = try buildSeqStore(zc, src);
        if (bss == .no_compress) {
            if (zc.seq_collector.collect_sequences) return error.SequenceProducerFailed;
            break :compressed;
        }

        if (zc.seq_collector.collect_sequences) {
            try copyBlockSequences(
                &zc.seq_collector,
                getSeqStore(zc),
                &zc.block_state.prev_cblock.rep,
            );
            blockStateConfirmRepcodesAndEntropyTables(&zc.block_state);
            return 0;
        }

        // The literals and sequences.
        c_size = entropyCompressSeqStore(
            &zc.seq_store,
            &zc.block_state.prev_cblock.entropy,
            &zc.block_state.next_cblock.entropy,
            &zc.applied_params,
            dst,
            src.len,
            tmpWorkspace(zc),
            zc.bmi2,
        ) catch |err| {
            // The original checks the offset table after a failure too.
            if (zc.block_state.prev_cblock.entropy.fse.offcode_repeat_mode == .valid) {
                zc.block_state.prev_cblock.entropy.fse.offcode_repeat_mode = .check;
            }
            return err;
        };

        // Decoders up to 1.4.3 refuse a first block that is RLE.
        if (frame and !zc.is_first_block and c_size < rle_max_length and isRle(src)) {
            c_size = 1;
            dst[0] = src[0];
        }
    }

    if (c_size > 1) blockStateConfirmRepcodesAndEntropyTables(&zc.block_state);
    // A dictionary's offset table must have the codes of the first block;
    // after it, the table may lack the codes of larger offsets.
    if (zc.block_state.prev_cblock.entropy.fse.offcode_repeat_mode == .valid) {
        zc.block_state.prev_cblock.entropy.fse.offcode_repeat_mode = .check;
    }
    return c_size;
}

/// `ZSTD_compressBlock_targetCBlockSize_body`: compresses a found block in
/// super-blocks of about the target size, as an RLE block or raw when that
/// does not pay. Header included.
fn compressBlockTargetCBlockSizeBody(
    zc: *CCtx,
    dst: []u8,
    src: []const u8,
    bss: ci.BuildSeqStore,
    last_block: u32,
) Error!usize {
    if (bss == .compress) {
        // Decoders up to 1.4.3 refuse a first block that is RLE.
        if (!zc.is_first_block and maybeRle(&zc.seq_store) and isRle(src)) {
            return ci.rleCompressBlock(dst, src[0], src.len, last_block);
        }
        // Super-blocks are not bound by `compressBound`, so a raw block is
        // written instead when they are not smaller than one: on 0, on
        // `DstSizeTooSmall` (they may have grown past a raw block; the raw
        // block fails if it does not fit either), and when they grew.
        superblock: {
            const c_size = compress_superblock.compressSuperBlock(
                zc,
                dst,
                src,
                last_block,
            ) catch |err|
                switch (err) {
                    error.DstSizeTooSmall => break :superblock,
                    else => return err,
                };
            const max_c_size = src.len - ci.minGain(src.len, zc.applied_params.cparams.strategy);
            if (c_size != 0 and c_size < max_c_size + block_header_size) {
                blockStateConfirmRepcodesAndEntropyTables(&zc.block_state);
                return c_size;
            }
        }
    }
    // A raw block, which the decoder can stream.
    return ci.noCompressBlock(dst, src, last_block);
}

/// `ZSTD_compressBlock_targetCBlockSize`.
fn compressBlockTargetCBlockSize(
    zc: *CCtx,
    dst: []u8,
    src: []const u8,
    last_block: u32,
) Error!usize {
    const bss = try buildSeqStore(zc, src);
    const c_size = try compressBlockTargetCBlockSizeBody(zc, dst, src, bss, last_block);
    if (zc.block_state.prev_cblock.entropy.fse.offcode_repeat_mode == .valid) {
        zc.block_state.prev_cblock.entropy.fse.offcode_repeat_mode = .check;
    }
    return c_size;
}

/// `ZSTD_overflowCorrectIfNeeded`: lowers every index ahead of an
/// overflow, dropping the dictionaries.
fn overflowCorrectIfNeeded(
    ms: *MatchState,
    ws: *Cwksp,
    cctx_params: *const CCtxParams,
    ip: [*]const u8,
    iend: [*]const u8,
) void {
    const cycle_log = cycleLog(cctx_params.cparams.chain_log, cctx_params.cparams.strategy);
    const max_dist = @as(u32, 1) << @intCast(cctx_params.cparams.window_log);
    if (ms.window.needOverflowCorrection(cycle_log, max_dist, ms.loaded_dict_end, ip, iend)) {
        const correction = ms.window.correctOverflow(cycle_log, max_dist, ip);
        comptime assert(params.chain_log_max <= 30);
        comptime assert(params.window_log_max_32 <= 30);
        comptime assert(params.window_log_max <= 31);
        ws.markTablesDirty();
        reduceIndex(ms, cctx_params, correction);
        ws.markTablesClean();
        if (ms.next_to_update < correction) {
            ms.next_to_update = 0;
        } else {
            ms.next_to_update -= correction;
        }
        // The dictionaries go.
        ms.loaded_dict_end = 0;
        ms.dict_match_state = null;
    }
}

/// `ZSTD_optimalBlockSize`: the size of the next block of `src`, cut by the
/// pre-splitter where the data changes. Only full blocks are split, and
/// only with at least 3 bytes saved so far, so incompressible data is not.
fn optimalBlockSize(
    cctx: *CCtx,
    src: []const u8,
    block_size_max: usize,
    split_level_in: i32,
    strat: Strategy,
    savings: i64,
) usize {
    // The split level by strategy, `fast` to `btultra2`.
    const split_levels = [_]i32{ 0, 0, 1, 2, 2, 3, 3, 4, 4, 4 };
    var split_level = split_level_in;
    if (src.len < 128 * kib or block_size_max < 128 * kib) return @min(src.len, block_size_max);
    // The first full block is never split.
    if (savings < 3) return 128 * kib;
    if (split_level == 1) return 128 * kib;
    if (split_level == 0) {
        assert(@backingInt(Strategy.fast) <= @backingInt(strat) and
            @backingInt(strat) <= @backingInt(Strategy.btultra2));
        split_level = split_levels[@backingInt(strat)];
    } else {
        assert(2 <= split_level and split_level <= 6);
        split_level -= 2;
    }
    return pre_split.splitBlock(src[0..block_size_max], @intCast(split_level), tmpWorkspace(cctx));
}

/// `ZSTD_compress_frameChunk`: compresses all of `src` in blocks, after the
/// frame header. Returns the size written.
fn compressFrameChunk(
    cctx: *CCtx,
    dst_in: []u8,
    src: []const u8,
    last_frame_chunk: u32,
) Error!usize {
    const block_size_max = cctx.block_size_max;
    var remaining = src.len;
    var ip = src.ptr;
    var dst = dst_in;
    var op: usize = 0;
    const max_dist = @as(u32, 1) << @intCast(cctx.applied_params.cparams.window_log);
    var savings: i64 = @as(i64, @intCast(cctx.consumed_src_size)) -
        @as(i64, @intCast(cctx.produced_csize));

    assert(cctx.applied_params.cparams.window_log <= params.window_log_max);

    if (cctx.applied_params.fparams.checksum_flag and src.len != 0) cctx.xxh_state.update(src);

    while (remaining != 0) {
        const ms = &cctx.block_state.match_state;
        const block_size = optimalBlockSize(
            cctx,
            ip[0..remaining],
            block_size_max,
            cctx.applied_params.pre_block_splitter_level,
            cctx.applied_params.cparams.strategy,
            savings,
        );
        const last_block: u32 = last_frame_chunk & @intFromBool(block_size == remaining);
        assert(block_size <= remaining);

        // One more than the smallest block, to make up for the smallest
        // block size lowered from 3 to 2.
        if (dst.len < block_header_size + zstd_internal.min_cblock_size + 1) {
            return error.DstSizeTooSmall;
        }

        overflowCorrectIfNeeded(ms, &cctx.workspace, &cctx.applied_params, ip, ip + block_size);
        ms.window.checkDictValidity(
            ip + block_size,
            max_dist,
            &ms.loaded_dict_end,
            &ms.dict_match_state,
        );
        ms.window.enforceMaxDist(ip, max_dist, &ms.loaded_dict_end, &ms.dict_match_state);

        // Table updates resume no lower than the low limit.
        if (ms.next_to_update < ms.window.low_limit) ms.next_to_update = ms.window.low_limit;

        const block = ip[0..block_size];
        var c_size: usize = undefined;
        if (useTargetCBlockSize(&cctx.applied_params)) {
            c_size = try compressBlockTargetCBlockSize(cctx, dst, block, last_block);
            assert(c_size > 0);
            assert(c_size <= block_size + block_header_size);
        } else if (blockSplitterEnabled(&cctx.applied_params)) {
            c_size = try compressBlockSplitBlock(cctx, dst, block, last_block);
            assert(c_size > 0 or cctx.seq_collector.collect_sequences);
        } else {
            c_size = try compressBlockInternal(cctx, dst[block_header_size..], block, true);
            if (c_size == 0) {
                // Not compressible.
                c_size = try ci.noCompressBlock(dst, block, last_block);
            } else {
                writeBlockHeader(dst, c_size, block_size, last_block);
                c_size += block_header_size;
            }
        }

        // Splitting incompressible data would add block headers: the
        // savings so far must cover them.
        savings += @as(i64, @intCast(block_size)) - @as(i64, @intCast(c_size));

        ip += block_size;
        remaining -= block_size;
        op += c_size;
        assert(dst.len >= c_size);
        dst = dst[c_size..];
        cctx.is_first_block = false;
    }

    if (last_frame_chunk != 0 and op > 0) cctx.stage = .ending;
    return op;
}

/// `ZSTD_writeFrameHeader`: writes the frame header for a content of
/// `pledged_src_size` (`params.content_size_unknown` when unknown).
fn writeFrameHeader(
    dst: []u8,
    cctx_params: *const CCtxParams,
    pledged_src_size: u64,
    dict_id: u32,
) Error!usize {
    const dict_id_size_code_length: u32 = @as(u32, @intFromBool(dict_id > 0)) +
        @intFromBool(dict_id >= 256) + @intFromBool(dict_id >= 65536);
    const dict_id_size_code: u32 =
        if (cctx_params.fparams.no_dict_id_flag) 0 else dict_id_size_code_length;
    const checksum_flag: u32 = @intFromBool(cctx_params.fparams.checksum_flag);
    const window_size = @as(u32, 1) << @intCast(cctx_params.cparams.window_log);
    const single_segment =
        cctx_params.fparams.content_size_flag and window_size >= pledged_src_size;
    const window_log_byte: u8 = @intCast((cctx_params.cparams.window_log -
        zstd_internal.window_log_absolute_min) << 3);
    const fcs_code: u32 = if (cctx_params.fparams.content_size_flag)
        @as(u32, @intFromBool(pledged_src_size >= 256)) +
            @intFromBool(pledged_src_size >= 65536 + 256) +
            @intFromBool(pledged_src_size >= 0xFFFFFFFF)
    else
        0;
    const frame_header_description_byte: u8 = @intCast(dict_id_size_code + (checksum_flag << 2) +
        (@as(u32, @intFromBool(single_segment)) << 5) + (fcs_code << 6));
    var pos: usize = 0;

    assert(
        !(cctx_params.fparams.content_size_flag and pledged_src_size ==
            params.content_size_unknown),
    );
    if (dst.len < params.frame_header_size_max) return error.DstSizeTooSmall;
    if (cctx_params.format == .zstd1) {
        std.mem.writeInt(u32, dst[0..4], params.magic_number, .little);
        pos = 4;
    }
    dst[pos] = frame_header_description_byte;
    pos += 1;
    if (!single_segment) {
        dst[pos] = window_log_byte;
        pos += 1;
    }
    switch (dict_id_size_code) {
        0 => {},
        1 => {
            dst[pos] = @truncate(dict_id);
            pos += 1;
        },
        2 => {
            std.mem.writeInt(u16, dst[pos..][0..2], @truncate(dict_id), .little);
            pos += 2;
        },
        3 => {
            std.mem.writeInt(u32, dst[pos..][0..4], dict_id, .little);
            pos += 4;
        },
        else => unreachable,
    }
    switch (fcs_code) {
        0 => if (single_segment) {
            dst[pos] = @truncate(pledged_src_size);
            pos += 1;
        },
        1 => {
            std.mem.writeInt(u16, dst[pos..][0..2], @truncate(pledged_src_size - 256), .little);
            pos += 2;
        },
        2 => {
            std.mem.writeInt(u32, dst[pos..][0..4], @truncate(pledged_src_size), .little);
            pos += 4;
        },
        3 => {
            std.mem.writeInt(u64, dst[pos..][0..8], pledged_src_size, .little);
            pos += 8;
        },
        else => unreachable,
    }
    return pos;
}

/// `ZSTD_writeSkippableFrame`: writes `src` as a skippable frame with the
/// magic number `magic_skippable_start + magic_variant` (0 to 15).
pub fn writeSkippableFrame(dst: []u8, src: []const u8, magic_variant: u32) Error!usize {
    if (dst.len < src.len + params.skippable_header_size) return error.DstSizeTooSmall;
    if (src.len > 0xFFFFFFFF) return error.SrcSizeWrong;
    if (magic_variant > 15) return error.ParameterOutOfBound;

    std.mem.writeInt(u32, dst[0..4], params.magic_skippable_start + magic_variant, .little);
    std.mem.writeInt(u32, dst[4..8], @intCast(src.len), .little);
    @memcpy(dst[8..][0..src.len], src);
    return src.len + params.skippable_header_size;
}

/// `ZSTD_writeLastEmptyBlock`: an empty last block, which ends a frame.
pub fn writeLastEmptyBlock(dst: []u8) Error!usize {
    if (dst.len < block_header_size) return error.DstSizeTooSmall;
    const c_block_header24: u32 = 1 + (@as(u32, @backingInt(zstd_internal.BlockType.raw)) << 1);
    writeLe24(dst, c_block_header24);
    return block_header_size;
}

/// `ZSTD_referenceExternalSequences`: sequences for the next blocks to use,
/// in place of long distance matching. `seq` is the caller's, valid until
/// those blocks are compressed or the context reset.
pub fn referenceExternalSequences(cctx: *CCtx, seq: ?[*]ci.RawSeq, nb_seq: usize) void {
    assert(cctx.stage == .init);
    assert(nb_seq == 0 or cctx.applied_params.ldm_params.enable_ldm != .enable);
    cctx.extern_seq_store = .{
        .seq = seq,
        .size = nb_seq,
        .capacity = nb_seq,
        .pos = 0,
        .pos_in_sequence = 0,
    };
}

/// `ZSTD_compressContinue_internal`: compresses `src`, as frame blocks
/// after the frame header if not yet written, or as one bare block.
fn compressContinueInternal(
    cctx: *CCtx,
    dst_in: []u8,
    src: []const u8,
    frame: bool,
    last_frame_chunk: u32,
) Error!usize {
    const ms = &cctx.block_state.match_state;
    var fh_size: usize = 0;
    var dst = dst_in;

    // `compressBegin*` first.
    if (cctx.stage == .created) return error.StageWrong;

    if (frame and cctx.stage == .init) {
        fh_size = try writeFrameHeader(
            dst,
            &cctx.applied_params,
            cctx.pledged_src_size_plus_one -% 1,
            cctx.dict_id,
        );
        assert(fh_size <= dst.len);
        dst = dst[fh_size..];
        cctx.stage = .ongoing;
    }

    // No empty block without input.
    if (src.len == 0) return fh_size;

    if (!ms.window.update(src, ms.force_non_contiguous)) {
        ms.force_non_contiguous = false;
        ms.next_to_update = ms.window.dict_limit;
    }
    if (cctx.applied_params.ldm_params.enable_ldm == .enable) {
        _ = cctx.ldm_state.window.update(src, false);
    }

    // Overflow correction for the block mode.
    if (!frame) overflowCorrectIfNeeded(
        ms,
        &cctx.workspace,
        &cctx.applied_params,
        src.ptr,
        src.ptr + src.len,
    );

    const c_size = if (frame)
        try compressFrameChunk(cctx, dst, src, last_frame_chunk)
    else
        try compressBlockInternal(cctx, dst, src, false);
    cctx.consumed_src_size += src.len;
    cctx.produced_csize += c_size + fh_size;
    assert(
        !(cctx.applied_params.fparams.content_size_flag and cctx.pledged_src_size_plus_one == 0),
    );
    // The content may not exceed the size pledged.
    if (cctx.pledged_src_size_plus_one != 0) {
        if (cctx.consumed_src_size + 1 > cctx.pledged_src_size_plus_one) return error.SrcSizeWrong;
    }
    return c_size + fh_size;
}

/// `ZSTD_compressContinue_public`, `ZSTD_compressContinue`: compresses
/// `src` into the frame `compressBegin*` started. `src` is referenced by
/// the window: the next calls may match into it, so it must stay valid and
/// unchanged until the frame ends, unless the next `src` follows it in the
/// same buffer.
pub fn compressContinue(cctx: *CCtx, dst: []u8, src: []const u8) Error!usize {
    return compressContinueInternal(cctx, dst, src, true, 0);
}

/// `ZSTD_getBlockSize`: the largest block `compressBlock` takes.
pub fn getBlockSize(cctx: *const CCtx) usize {
    const cparams = cctx.applied_params.cparams;
    assert(checkCParamsValid(cparams));
    return @min(cctx.applied_params.max_block_size, @as(usize, 1) << @intCast(cparams.window_log));
}

/// `ZSTD_compressBlock`: compresses `src` into one bare block, without its
/// header, after `compressBegin*`. Returns 0 when it does not compress: the
/// caller then stores it raw. `src` is referenced as by `compressContinue`.
pub fn compressBlock(cctx: *CCtx, dst: []u8, src: []const u8) Error!usize {
    const block_size_max = getBlockSize(cctx);
    if (src.len > block_size_max) return error.SrcSizeWrong;
    return compressContinueInternal(cctx, dst, src, false, 0);
}

// ---------------------------------------------------------------------------
// Dictionaries
// ---------------------------------------------------------------------------

/// `ZSTD_loadDictionaryContent`: loads `src_in` into the match state's
/// tables (and the long distance matcher's, when it is on and `ls` given),
/// as its window's content. Only the end of a dictionary too large for the
/// indexes or the tables is loaded. `src_in` is referenced by the window
/// and must outlive its use.
fn loadDictionaryContent(
    ms: *MatchState,
    ls: ?*ci.LdmState,
    ws: *Cwksp,
    cctx_params: *const CCtxParams,
    src_in: []const u8,
    dtlm: ci.DictTableLoadMethod,
    tfp: ci.TableFillPurpose,
) Error!void {
    var src = src_in;
    const iend = src.ptr + src.len;
    const load_ldm_dict = cctx_params.ldm_params.enable_ldm == .enable and ls != null;

    assertEqualCParams(cctx_params.cparams, ms.cparams);

    // A large dictionary must not overflow the indexes: they may go up to
    // `current_max` exactly, where overflow correction starts at once.
    {
        var max_dict_size: u32 = ci.current_max - ci.window_start_index;
        // A dictionary with short cache tags in its tables keeps its
        // indexes clear of the tags.
        if (cdictIndicesAreTagged(&cctx_params.cparams) and tfp == .for_cdict) {
            const short_cache_max_dict_size = (@as(u32, 1) << (32 - ci.short_cache_tag_bits)) -
                ci.window_start_index;
            max_dict_size = @min(max_dict_size, short_cache_max_dict_size);
            assert(!load_ldm_dict);
        }
        if (src.len > max_dict_size) src = src[src.len - max_dict_size ..];
    }

    if (src.len > ci.chunk_size_max) {
        // The windows were cleared for so large a source.
        assert(ms.window.isEmpty());
        if (load_ldm_dict) assert(ls.?.window.isEmpty());
    }
    _ = ms.window.update(src, false);

    if (load_ldm_dict) {
        // All of the dictionary goes to the long distance matcher.
        const l = ls.?;
        _ = l.window.update(src, false);
        l.loaded_dict_end = if (cctx_params.force_window)
            0
        else
            @intCast(@intFromPtr(iend) - @intFromPtr(l.window.base));
        ldm.fillHashTable(l, src, &cctx_params.ldm_params);
    }

    // The tables index the end of the dictionary they reach.
    {
        const max_dict_log = @min(
            @max(cctx_params.cparams.hash_log + 3, cctx_params.cparams.chain_log + 1),
            31,
        );
        const max_dict_size = @as(u32, 1) << @intCast(max_dict_log);
        if (src.len > max_dict_size) src = src[src.len - max_dict_size ..];
    }

    ms.next_to_update = @intCast(@intFromPtr(src.ptr) - @intFromPtr(ms.window.base));
    ms.loaded_dict_end = if (cctx_params.force_window)
        0
    else
        @intCast(@intFromPtr(iend) - @intFromPtr(ms.window.base));
    ms.force_non_contiguous = cctx_params.deterministic_ref_prefix;

    if (src.len <= ci.hash_read_size) return;

    overflowCorrectIfNeeded(ms, ws, cctx_params, src.ptr, iend);

    switch (cctx_params.cparams.strategy) {
        .fast => fast.fillHashTable(ms, iend, dtlm, tfp),
        .dfast => double_fast.fillDoubleHashTable(ms, iend, dtlm, tfp),
        .greedy, .lazy, .lazy2 => {
            assert(src.len >= ci.hash_read_size);
            if (ms.dedicated_dict_search) {
                lazy.dedicatedDictSearchLazyLoadDictionary(ms, iend - ci.hash_read_size);
            } else {
                assert(cctx_params.use_row_match_finder != .auto);
                if (cctx_params.use_row_match_finder == .enable) {
                    const tag_table_size = @as(usize, 1) << @intCast(cctx_params.cparams.hash_log);
                    @memset(ms.tag_table[0..tag_table_size], 0);
                    lazy.rowUpdate(ms, iend - ci.hash_read_size);
                } else {
                    _ = lazy.insertAndFindFirstIndex(ms, iend - ci.hash_read_size);
                }
            }
        },
        // The dictionary's tree is fully sorted.
        .btlazy2, .btopt, .btultra, .btultra2 => {
            assert(src.len >= ci.hash_read_size);
            opt.updateTree(ms, iend - ci.hash_read_size, iend);
        },
        _ => unreachable,
    }

    ms.next_to_update = @intCast(@intFromPtr(iend) - @intFromPtr(ms.window.base));
}

/// `ZSTD_dictNCountRepeat`: a dictionary's table is valid to repeat only
/// when it gives every symbol to `max_symbol_value` a probability.
fn dictNCountRepeat(
    normalized_counter: []const i16,
    dict_max_symbol_value: u32,
    max_symbol_value: u32,
) fse.Repeat {
    if (dict_max_symbol_value < max_symbol_value) return .check;
    for (normalized_counter[0 .. max_symbol_value + 1]) |count| {
        if (count == 0) return .check;
    }
    return .valid;
}

/// `ZSTD_loadCEntropy`: loads the entropy tables and repeat offsets of a
/// full dictionary into `bs`. Returns the size of the dictionary before its
/// content. `workspace` holds `huf.workspace_size` bytes.
pub fn loadCEntropy(bs: *CompressedBlockState, workspace: []u8, dict: []const u8) Error!usize {
    var offcode_ncount: [zstd_internal.max_off + 1]i16 = undefined;
    var offcode_max_value: u32 = zstd_internal.max_off;
    // After the magic number and the dictionary id.
    var dict_ptr: usize = 8;
    bs.entropy.huf.repeat_mode = .check;

    {
        var max_symbol_value: u32 = 255;
        var has_zero_weights = true;
        const huf_header_size = huf_compress.readCTable(
            &bs.entropy.huf.ctable,
            &max_symbol_value,
            dict[dict_ptr..],
            &has_zero_weights,
        ) catch return error.DictionaryCorrupted;
        // Only a table that gives every symbol a weight is valid to repeat.
        if (!has_zero_weights and max_symbol_value == 255) bs.entropy.huf.repeat_mode = .valid;
        dict_ptr += huf_header_size;
    }

    {
        var offcode_log: u32 = undefined;
        const offcode_header_size = entropy_common.readNCount(
            &offcode_ncount,
            &offcode_max_value,
            &offcode_log,
            dict[dict_ptr..],
        ) catch return error.DictionaryCorrupted;
        if (offcode_log > zstd_internal.off_fse_log) return error.DictionaryCorrupted;
        // Every offset symbol, so the table holds no garbage.
        fse_compress.buildCTableWksp(
            &bs.entropy.fse.offcode_ctable,
            &offcode_ncount,
            zstd_internal.max_off,
            offcode_log,
            workspace[0..huf.workspace_size],
        ) catch return error.DictionaryCorrupted;
        // The offset table's repeat mode needs the content size, below.
        dict_ptr += offcode_header_size;
    }

    {
        var matchlength_ncount: [zstd_internal.max_ml + 1]i16 = undefined;
        var matchlength_max_value: u32 = zstd_internal.max_ml;
        var matchlength_log: u32 = undefined;
        const matchlength_header_size = entropy_common.readNCount(
            &matchlength_ncount,
            &matchlength_max_value,
            &matchlength_log,
            dict[dict_ptr..],
        ) catch return error.DictionaryCorrupted;
        if (matchlength_log > zstd_internal.ml_fse_log) return error.DictionaryCorrupted;
        fse_compress.buildCTableWksp(
            &bs.entropy.fse.matchlength_ctable,
            &matchlength_ncount,
            matchlength_max_value,
            matchlength_log,
            workspace[0..huf.workspace_size],
        ) catch return error.DictionaryCorrupted;
        bs.entropy.fse.matchlength_repeat_mode =
            dictNCountRepeat(&matchlength_ncount, matchlength_max_value, zstd_internal.max_ml);
        dict_ptr += matchlength_header_size;
    }

    {
        var litlength_ncount: [zstd_internal.max_ll + 1]i16 = undefined;
        var litlength_max_value: u32 = zstd_internal.max_ll;
        var litlength_log: u32 = undefined;
        const litlength_header_size = entropy_common.readNCount(
            &litlength_ncount,
            &litlength_max_value,
            &litlength_log,
            dict[dict_ptr..],
        ) catch return error.DictionaryCorrupted;
        if (litlength_log > zstd_internal.ll_fse_log) return error.DictionaryCorrupted;
        fse_compress.buildCTableWksp(
            &bs.entropy.fse.litlength_ctable,
            &litlength_ncount,
            litlength_max_value,
            litlength_log,
            workspace[0..huf.workspace_size],
        ) catch return error.DictionaryCorrupted;
        bs.entropy.fse.litlength_repeat_mode =
            dictNCountRepeat(&litlength_ncount, litlength_max_value, zstd_internal.max_ll);
        dict_ptr += litlength_header_size;
    }

    if (dict_ptr + 12 > dict.len) return error.DictionaryCorrupted;
    bs.rep[0] = std.mem.readInt(u32, dict[dict_ptr..][0..4], .little);
    bs.rep[1] = std.mem.readInt(u32, dict[dict_ptr + 4 ..][0..4], .little);
    bs.rep[2] = std.mem.readInt(u32, dict[dict_ptr + 8 ..][0..4], .little);
    dict_ptr += 12;

    {
        const dict_content_size = dict.len - dict_ptr;
        var offcode_max: u32 = zstd_internal.max_off;
        if (dict_content_size <= std.math.maxInt(u32) - 128 * kib) {
            // The largest offset a block after the dictionary can have.
            const max_offset: u32 = @as(u32, @intCast(dict_content_size)) + 128 * kib;
            offcode_max = ci.highbit32(max_offset);
        }
        // Valid when every offset to the content size plus a block has a code.
        bs.entropy.fse.offcode_repeat_mode =
            dictNCountRepeat(
                &offcode_ncount,
                offcode_max_value,
                @min(offcode_max, zstd_internal.max_off),
            );

        // Every repeat offset is in the content, and not 0.
        for (bs.rep) |rep| {
            if (rep == 0) return error.DictionaryCorrupted;
            if (rep > dict_content_size) return error.DictionaryCorrupted;
        }
    }
    return dict_ptr;
}

/// `ZSTD_loadZstdDictionary`: loads a full dictionary, its entropy tables
/// into `bs` and its content into the match state. Returns its id, 0 when
/// the frame parameters leave it out. `dict` starts with the dictionary
/// magic number and is at least 8 bytes.
fn loadZstdDictionary(
    bs: *CompressedBlockState,
    ms: *MatchState,
    ws: *Cwksp,
    cctx_params: *const CCtxParams,
    dict: []const u8,
    dtlm: ci.DictTableLoadMethod,
    tfp: ci.TableFillPurpose,
    workspace: []u8,
) Error!u32 {
    comptime assert(
        huf.workspace_size >= 1 << @max(zstd_internal.ml_fse_log, zstd_internal.ll_fse_log),
    );
    assert(dict.len >= 8);
    assert(std.mem.readInt(u32, dict[0..4], .little) == params.magic_dictionary);

    const dict_id: u32 = if (cctx_params.fparams.no_dict_id_flag)
        0
    else
        std.mem.readInt(u32, dict[4..8], .little);
    const e_size = try loadCEntropy(bs, workspace, dict);
    try loadDictionaryContent(ms, null, ws, cctx_params, dict[e_size..], dtlm, tfp);
    return dict_id;
}

/// `ZSTD_compress_insertDictionary`: loads `dict` as `dict_content_type`
/// says: raw content, or a full dictionary when it starts with the magic
/// number. Returns the dictionary id, 0 for raw content. A dictionary of
/// fewer than 8 bytes is ignored, unless it must be a full one.
fn compressInsertDictionary(
    bs: *CompressedBlockState,
    ms: *MatchState,
    ls: ?*ci.LdmState,
    ws: *Cwksp,
    cctx_params: *const CCtxParams,
    dict: ?[]const u8,
    dict_content_type: params.DictContentType,
    dtlm: ci.DictTableLoadMethod,
    tfp: ci.TableFillPurpose,
    workspace: []u8,
) Error!u32 {
    const d = dict orelse &.{};
    if (dict == null or d.len < 8) {
        if (dict_content_type == .full_dict) return error.DictionaryWrong;
        return 0;
    }

    resetCompressedBlockState(bs);

    if (dict_content_type == .raw_content) {
        try loadDictionaryContent(ms, ls, ws, cctx_params, d, dtlm, tfp);
        return 0;
    }

    if (std.mem.readInt(u32, d[0..4], .little) != params.magic_dictionary) {
        if (dict_content_type == .auto) {
            try loadDictionaryContent(ms, ls, ws, cctx_params, d, dtlm, tfp);
            return 0;
        }
        assert(dict_content_type == .full_dict);
        return error.DictionaryWrong;
    }

    return loadZstdDictionary(bs, ms, ws, cctx_params, d, dtlm, tfp, workspace);
}

/// `ZSTD_USE_CDICT_PARAMS_SRCSIZE_CUTOFF`,
/// `ZSTD_USE_CDICT_PARAMS_DICTSIZE_MULTIPLIER`: below these source sizes, a
/// frame takes the dictionary's parameters.
const use_cdict_params_srcsize_cutoff = 128 * kib;
const use_cdict_params_dictsize_multiplier = 6;

/// Whether a frame of `pledged_src_size` uses `cdict`'s parameters.
fn usesCDictParams(cdict: *const CDict, pledged_src_size: u64) bool {
    return pledged_src_size < use_cdict_params_srcsize_cutoff or
        pledged_src_size < @as(
            u64,
            cdict.dict_content_size,
        ) * use_cdict_params_dictsize_multiplier or
        pledged_src_size == params.content_size_unknown or
        cdict.compression_level == 0;
}

/// `ZSTD_compressBegin_internal`: starts a frame with `cctx_params`, fully
/// validated, and either `dict` or `cdict` (or neither). `dict` is
/// referenced by the window until the frame ends.
fn compressBeginInternal(
    cctx: *CCtx,
    dict: ?[]const u8,
    dict_content_type: params.DictContentType,
    dtlm: ci.DictTableLoadMethod,
    cdict: ?*const CDict,
    cctx_params: *const CCtxParams,
    pledged_src_size: u64,
    zbuff: ci.BufferedPolicy,
) Error!void {
    const dict_content_size = if (cdict) |cd| cd.dict_content_size else if (dict) |d| d.len else 0;
    assert(checkCParamsValid(cctx_params.cparams));
    assert(!(dict != null and cdict != null));
    if (cdict) |cd| {
        if (cd.dict_content_size > 0 and usesCDictParams(cd, pledged_src_size) and
            cctx_params.attach_dict_pref != .force_load)
        {
            return resetCCtxUsingCDict(cctx, cd, cctx_params, pledged_src_size, zbuff);
        }
    }

    try resetCCtxInternal(
        cctx,
        cctx_params,
        pledged_src_size,
        dict_content_size,
        .make_clean,
        zbuff,
    );
    const dict_id = if (cdict) |cd|
        try compressInsertDictionary(
            cctx.block_state.prev_cblock,
            &cctx.block_state.match_state,
            &cctx.ldm_state,
            &cctx.workspace,
            &cctx.applied_params,
            if (cd.dict_content) |content| content[0..cd.dict_content_size] else null,
            cd.dict_content_type,
            dtlm,
            .for_cctx,
            tmpWorkspace(cctx),
        )
    else
        try compressInsertDictionary(
            cctx.block_state.prev_cblock,
            &cctx.block_state.match_state,
            &cctx.ldm_state,
            &cctx.workspace,
            &cctx.applied_params,
            dict,
            dict_content_type,
            dtlm,
            .for_cctx,
            tmpWorkspace(cctx),
        );
    cctx.dict_id = dict_id;
    cctx.dict_content_size = dict_content_size;
}

/// `ZSTD_compressBegin_advanced_internal`.
pub fn compressBeginAdvancedInternal(
    cctx: *CCtx,
    dict: ?[]const u8,
    dict_content_type: params.DictContentType,
    dtlm: ci.DictTableLoadMethod,
    cdict: ?*const CDict,
    cctx_params: *const CCtxParams,
    pledged_src_size: u64,
) Error!void {
    try checkCParams(cctx_params.cparams);
    return compressBeginInternal(
        cctx,
        dict,
        dict_content_type,
        dtlm,
        cdict,
        cctx_params,
        pledged_src_size,
        .not_buffered,
    );
}

/// `ZSTD_compressBegin_advanced`: starts a frame of `pledged_src_size`
/// (`params.content_size_unknown` when unknown) with `parameters` and an
/// optional dictionary, referenced until the frame ends.
pub fn compressBeginAdvanced(
    cctx: *CCtx,
    dict: ?[]const u8,
    parameters: params.Parameters,
    pledged_src_size: u64,
) Error!void {
    const cctx_params = cctxParamsInitInternal(&parameters, no_clevel);
    return compressBeginAdvancedInternal(
        cctx,
        dict,
        .auto,
        .fast,
        null,
        &cctx_params,
        pledged_src_size,
    );
}

/// `ZSTD_compressBegin_usingDict`: starts a frame of unknown size at
/// `compression_level`, with an optional dictionary referenced until the
/// frame ends.
pub fn compressBeginUsingDict(cctx: *CCtx, dict: ?[]const u8, compression_level: i32) Error!void {
    const dict_size = if (dict) |d| d.len else 0;
    const parameters = getParamsInternal(
        compression_level,
        params.content_size_unknown,
        dict_size,
        .no_attach_dict,
    );
    const cctx_params = cctxParamsInitInternal(
        &parameters,
        if (compression_level == 0) params.clevel_default else compression_level,
    );
    return compressBeginInternal(
        cctx,
        dict,
        .auto,
        .fast,
        null,
        &cctx_params,
        params.content_size_unknown,
        .not_buffered,
    );
}

/// `ZSTD_compressBegin`: starts a frame of unknown size at
/// `compression_level`.
pub fn compressBegin(cctx: *CCtx, compression_level: i32) Error!void {
    return compressBeginUsingDict(cctx, null, compression_level);
}

/// `ZSTD_writeEpilogue`: ends the frame: a last empty block if needed, and
/// the checksum.
fn writeEpilogue(cctx: *CCtx, dst: []u8) Error!usize {
    var op: usize = 0;
    var dst_capacity = dst.len;

    if (cctx.stage == .created) return error.StageWrong;

    // An empty frame.
    if (cctx.stage == .init) {
        const fh_size = try writeFrameHeader(dst, &cctx.applied_params, 0, 0);
        dst_capacity -= fh_size;
        op += fh_size;
        cctx.stage = .ongoing;
    }

    if (cctx.stage != .ending) {
        // An empty last block.
        const c_block_header24: u32 = 1 + (@as(u32, @backingInt(zstd_internal.BlockType.raw)) << 1);
        comptime assert(block_header_size == 3);
        if (dst_capacity < 3) return error.DstSizeTooSmall;
        writeLe24(dst[op..], c_block_header24);
        op += block_header_size;
        dst_capacity -= block_header_size;
    }

    if (cctx.applied_params.fparams.checksum_flag) {
        const checksum: u32 = @truncate(cctx.xxh_state.final());
        if (dst_capacity < 4) return error.DstSizeTooSmall;
        std.mem.writeInt(u32, dst[op..][0..4], checksum, .little);
        op += 4;
    }

    // Back to created, without a frame started.
    cctx.stage = .created;
    return op;
}

/// `ZSTD_compressEnd_public`, `ZSTD_compressEnd`: compresses the last
/// `src` of the frame and ends it. The content must be the size pledged.
pub fn compressEnd(cctx: *CCtx, dst: []u8, src: []const u8) Error!usize {
    const c_size = try compressContinueInternal(cctx, dst, src, true, 1);
    const end_result = try writeEpilogue(cctx, dst[c_size..]);
    assert(
        !(cctx.applied_params.fparams.content_size_flag and cctx.pledged_src_size_plus_one == 0),
    );
    if (cctx.pledged_src_size_plus_one != 0) {
        if (cctx.pledged_src_size_plus_one != cctx.consumed_src_size + 1) return error.SrcSizeWrong;
    }
    return c_size + end_result;
}

/// `ZSTD_compress_advanced`: compresses `src` into one frame with
/// `parameters` and an optional dictionary.
pub fn compressAdvanced(
    cctx: *CCtx,
    dst: []u8,
    src: []const u8,
    dict: ?[]const u8,
    parameters: params.Parameters,
) Error!usize {
    try checkCParams(parameters.cparams);
    cctx.simple_api_params = cctxParamsInitInternal(&parameters, no_clevel);
    return compressAdvancedInternal(cctx, dst, src, dict, &cctx.simple_api_params);
}

/// `ZSTD_compress_advanced_internal`.
pub fn compressAdvancedInternal(
    cctx: *CCtx,
    dst: []u8,
    src: []const u8,
    dict: ?[]const u8,
    cctx_params: *const CCtxParams,
) Error!usize {
    try compressBeginInternal(cctx, dict, .auto, .fast, null, cctx_params, src.len, .not_buffered);
    return compressEnd(cctx, dst, src);
}

/// `ZSTD_compress_usingDict`: compresses `src` into one frame at
/// `compression_level` with an optional dictionary.
pub fn compressUsingDict(
    cctx: *CCtx,
    dst: []u8,
    src: []const u8,
    dict: ?[]const u8,
    compression_level: i32,
) Error!usize {
    const dict_size = if (dict) |d| d.len else 0;
    const parameters = getParamsInternal(compression_level, src.len, dict_size, .no_attach_dict);
    assert(parameters.fparams.content_size_flag);
    cctx.simple_api_params = cctxParamsInitInternal(
        &parameters,
        if (compression_level == 0) params.clevel_default else compression_level,
    );
    return compressAdvancedInternal(cctx, dst, src, dict, &cctx.simple_api_params);
}

/// `ZSTD_compressCCtx`: compresses `src` into one frame at
/// `compression_level`, ignoring the context's parameters.
pub fn compressCCtx(cctx: *CCtx, dst: []u8, src: []const u8, compression_level: i32) Error!usize {
    return compressUsingDict(cctx, dst, src, null, compression_level);
}

/// `ZSTD_compress`: compresses `src` into one frame at `compression_level`,
/// with a context allocated with `gpa` for the call.
pub fn compress(
    gpa: std.mem.Allocator,
    dst: []u8,
    src: []const u8,
    compression_level: i32,
) Error!usize {
    const cctx = try createCCtx(gpa);
    defer freeCCtx(cctx) catch unreachable;
    return compressCCtx(cctx, dst, src, compression_level);
}

// ---------------------------------------------------------------------------
// Digested dictionaries
// ---------------------------------------------------------------------------

/// The size the dictionary's content takes in its workspace when copied.
fn cdictContentSpace(dict_size: usize, dict_load_method: params.DictLoadMethod) usize {
    return if (dict_load_method == .by_ref)
        0
    else
        cwksp.allocSize(cwksp.alignSize(dict_size, @sizeOf(*anyopaque)));
}

/// `ZSTD_estimateCDictSize_advanced`: the size of a dictionary of
/// `dict_size` bytes made with `cparams`.
pub fn estimateCDictSizeAdvanced(
    dict_size: usize,
    cparams: CompressionParameters,
    dict_load_method: params.DictLoadMethod,
) usize {
    // Sized for the dedicated dictionary search, which with the row-based
    // match finder takes more.
    return cwksp.allocSize(cdict_object_size) +
        cwksp.allocSize(huf.workspace_size) +
        sizeofMatchState(&cparams, resolveRowMatchFinderMode(.auto, &cparams), true, false) +
        cdictContentSpace(dict_size, dict_load_method);
}

/// `ZSTD_estimateCDictSize`: the size of a dictionary of `dict_size` bytes
/// made with `createCDict` at `compression_level`.
pub fn estimateCDictSize(dict_size: usize, compression_level: i32) usize {
    const cparams = getCParamsInternal(
        compression_level,
        params.content_size_unknown,
        dict_size,
        .create_cdict,
    );
    return estimateCDictSizeAdvanced(dict_size, cparams, .by_copy);
}

/// `ZSTD_sizeof_CDict`: the memory the dictionary uses, itself included.
pub fn sizeofCDict(cdict: ?*const CDict) usize {
    const cd = cdict orelse return 0;
    // The dictionary may be in its workspace.
    const in_workspace = @intFromPtr(cd.workspace.workspace) == @intFromPtr(cd);
    return (if (in_workspace) 0 else @as(usize, cdict_object_size)) + cd.workspace.sizeof();
}

/// `ZSTD_initCDict_internal`: loads the dictionary into `cdict`'s
/// workspace.
fn initCDictInternal(
    cdict: *CDict,
    dict_buffer: ?[]const u8,
    dict_load_method: params.DictLoadMethod,
    dict_content_type: params.DictContentType,
    cctx_params_in: CCtxParams,
) Error!void {
    var cctx_params = cctx_params_in;
    const dict = dict_buffer orelse &.{};
    assert(checkCParamsValid(cctx_params.cparams));
    cdict.match_state.cparams = cctx_params.cparams;
    cdict.match_state.dedicated_dict_search = cctx_params.enable_dedicated_dict_search;
    if (dict_load_method == .by_ref or dict_buffer == null or dict.len == 0) {
        cdict.dict_content = if (dict_buffer) |d| d.ptr else null;
    } else {
        const internal_buffer = cdict.workspace.reserveObject(
            cwksp.alignSize(dict.len, @sizeOf(*anyopaque)),
        ) orelse
            return error.MemoryAllocation;
        @memcpy(internal_buffer[0..dict.len], dict);
        cdict.dict_content = internal_buffer;
    }
    cdict.dict_content_size = dict.len;
    cdict.dict_content_type = dict_content_type;

    cdict.entropy_workspace = cdict.workspace.reserveObject(huf.workspace_size) orelse undefined;

    // No dictionary yet.
    resetCompressedBlockState(&cdict.cblock_state);
    try resetMatchState(
        &cdict.match_state,
        &cdict.workspace,
        &cctx_params.cparams,
        cctx_params.use_row_match_finder,
        .make_clean,
        .reset,
        .cdict,
    );
    // A dictionary of fewer than 8 bytes is not loaded.
    cctx_params.compression_level = params.clevel_default;
    cctx_params.fparams.content_size_flag = true;
    cdict.dict_id = try compressInsertDictionary(
        &cdict.cblock_state,
        &cdict.match_state,
        null,
        &cdict.workspace,
        &cctx_params,
        if (cdict.dict_content) |content| content[0..cdict.dict_content_size] else null,
        dict_content_type,
        .full,
        .for_cdict,
        cdict.entropy_workspace[0..huf.workspace_size],
    );
}

/// `ZSTD_createCDict_advanced_internal`: an empty dictionary in a new
/// workspace sized for these parameters.
fn createCDictAdvancedInternal(
    gpa: std.mem.Allocator,
    dict_size: usize,
    dict_load_method: params.DictLoadMethod,
    cparams: CompressionParameters,
    use_row_match_finder: ParamSwitch,
    enable_dedicated_dict_search: bool,
) ?*CDict {
    const workspace_size = cwksp.allocSize(cdict_object_size) +
        cwksp.allocSize(huf.workspace_size) +
        sizeofMatchState(&cparams, use_row_match_finder, enable_dedicated_dict_search, false) +
        cdictContentSpace(dict_size, dict_load_method);
    var ws: Cwksp = .{};
    ws.create(workspace_size, gpa) catch return null;

    const cdict_bytes = ws.reserveObject(cdict_object_size).?;
    const cdict: *CDict = @ptrCast(@alignCast(cdict_bytes));
    cdict.* = .{
        .dict_content = null,
        .dict_content_size = 0,
        .dict_content_type = .auto,
        .entropy_workspace = undefined,
        .workspace = .{},
        .match_state = .{},
        .cblock_state = undefined,
        .custom_mem = gpa,
        .dict_id = 0,
        // Made with the advanced functions.
        .compression_level = no_clevel,
        .use_row_match_finder = use_row_match_finder,
    };
    Cwksp.move(&cdict.workspace, &ws);
    return cdict;
}

/// `ZSTD_createCDict_advanced`: digests `dict` with `cparams`, allocating
/// with `gpa`. Null on failure. Loaded by reference, `dict` must outlive
/// the dictionary and every context it serves.
pub fn createCDictAdvanced(
    gpa: std.mem.Allocator,
    dict: ?[]const u8,
    dict_load_method: params.DictLoadMethod,
    dict_content_type: params.DictContentType,
    cparams: CompressionParameters,
) ?*CDict {
    var cctx_params = cctxParamsInit(0);
    cctx_params.cparams = cparams;
    cctx_params.custom_mem = gpa;
    return createCDictAdvanced2Internal(
        gpa,
        dict,
        dict_load_method,
        dict_content_type,
        &cctx_params,
    );
}

/// `ZSTD_createCDict_advanced2`: digests `dict` with the parameters of
/// `original_cctx_params` that apply to dictionaries, allocating with
/// `gpa`. Loaded by reference, `dict` must outlive the dictionary and every
/// context it serves.
pub fn createCDictAdvanced2(
    gpa: std.mem.Allocator,
    dict: []const u8,
    dict_load_method: params.DictLoadMethod,
    dict_content_type: params.DictContentType,
    original_cctx_params: *const CCtxParams,
) Error!*CDict {
    return createCDictAdvanced2Internal(
        gpa,
        dict,
        dict_load_method,
        dict_content_type,
        original_cctx_params,
    ) orelse
        error.MemoryAllocation;
}

fn createCDictAdvanced2Internal(
    gpa: std.mem.Allocator,
    dict: ?[]const u8,
    dict_load_method: params.DictLoadMethod,
    dict_content_type: params.DictContentType,
    original_cctx_params: *const CCtxParams,
) ?*CDict {
    var cctx_params = original_cctx_params.*;
    const dict_size = if (dict) |d| d.len else 0;
    var cparams: CompressionParameters = undefined;

    if (cctx_params.enable_dedicated_dict_search) {
        cparams = dedicatedDictSearchGetCParams(cctx_params.compression_level, dict_size);
        overrideCParams(&cparams, &cctx_params.cparams);
    } else {
        cparams = getCParamsFromCCtxParams(
            &cctx_params,
            params.content_size_unknown,
            dict_size,
            .create_cdict,
        );
    }

    if (!dedicatedDictSearchIsSupported(&cparams)) {
        // Without the dedicated dictionary search.
        cctx_params.enable_dedicated_dict_search = false;
        cparams = getCParamsFromCCtxParams(
            &cctx_params,
            params.content_size_unknown,
            dict_size,
            .create_cdict,
        );
    }

    cctx_params.cparams = cparams;
    cctx_params.use_row_match_finder = resolveRowMatchFinderMode(
        cctx_params.use_row_match_finder,
        &cparams,
    );

    const cdict = createCDictAdvancedInternal(
        gpa,
        dict_size,
        dict_load_method,
        cctx_params.cparams,
        cctx_params.use_row_match_finder,
        cctx_params.enable_dedicated_dict_search,
    ) orelse return null;

    initCDictInternal(cdict, dict, dict_load_method, dict_content_type, cctx_params) catch {
        freeCDict(cdict);
        return null;
    };
    return cdict;
}

/// `ZSTD_createCDict`: digests a copy of `dict` for `compression_level`,
/// allocating with `gpa`.
pub fn createCDict(gpa: std.mem.Allocator, dict: []const u8, compression_level: i32) Error!*CDict {
    const cparams = getCParamsInternal(
        compression_level,
        params.content_size_unknown,
        dict.len,
        .create_cdict,
    );
    const cdict = createCDictAdvanced(gpa, dict, .by_copy, .auto, cparams) orelse
        return error.MemoryAllocation;
    cdict.compression_level = if (compression_level ==
        0) params.clevel_default else compression_level;
    return cdict;
}

/// `ZSTD_createCDict_byReference`: as `createCDict`, referencing `dict`,
/// which must outlive the dictionary and every context it serves.
pub fn createCDictByReference(
    gpa: std.mem.Allocator,
    dict: []const u8,
    compression_level: i32,
) Error!*CDict {
    const cparams = getCParamsInternal(
        compression_level,
        params.content_size_unknown,
        dict.len,
        .create_cdict,
    );
    const cdict = createCDictAdvanced(gpa, dict, .by_ref, .auto, cparams) orelse
        return error.MemoryAllocation;
    cdict.compression_level = if (compression_level ==
        0) params.clevel_default else compression_level;
    return cdict;
}

/// `ZSTD_freeCDict`: frees a dictionary made by a `create` function. A
/// static dictionary is not freed: its caller frees its workspace.
pub fn freeCDict(cdict: *CDict) void {
    const gpa = cdict.custom_mem orelse return;
    const cdict_in_workspace = cdict.workspace.ownsBuffer(cdict);
    cdict.workspace.free(gpa);
    if (!cdict_in_workspace) gpa.destroy(cdict);
}

/// `ZSTD_initStaticCDict`: digests `dict` with `cparams` in `workspace`,
/// which must be aligned on 8 bytes, at least `estimateCDictSizeAdvanced`
/// bytes, and outlive the dictionary and every context it serves; so must
/// `dict` when loaded by reference. Null when `workspace` is too small or
/// misaligned, or the dictionary is invalid.
pub fn initStaticCDict(
    workspace: []u8,
    dict: []const u8,
    dict_load_method: params.DictLoadMethod,
    dict_content_type: params.DictContentType,
    cparams: CompressionParameters,
) ?*const CDict {
    const use_row_match_finder = resolveRowMatchFinderMode(.auto, &cparams);
    // Sized for the dedicated dictionary search with the row-based finder.
    const match_state_size = sizeofMatchState(&cparams, use_row_match_finder, true, false);
    const needed_size = cwksp.allocSize(cdict_object_size) +
        cdictContentSpace(dict.len, dict_load_method) +
        cwksp.allocSize(huf.workspace_size) +
        match_state_size;

    if (@intFromPtr(workspace.ptr) & 7 != 0) return null;

    var ws: Cwksp = .{};
    ws.init(workspace, .static_alloc);
    const cdict_bytes = ws.reserveObject(cdict_object_size) orelse return null;
    const cdict: *CDict = @ptrCast(@alignCast(cdict_bytes));
    cdict.* = .{
        .dict_content = null,
        .dict_content_size = 0,
        .dict_content_type = .auto,
        .entropy_workspace = undefined,
        .workspace = .{},
        .match_state = .{},
        .cblock_state = undefined,
        .custom_mem = null,
        .dict_id = 0,
        .compression_level = no_clevel,
        .use_row_match_finder = use_row_match_finder,
    };
    Cwksp.move(&cdict.workspace, &ws);

    if (workspace.len < needed_size) return null;

    var cctx_params = cctxParamsInit(0);
    cctx_params.cparams = cparams;
    cctx_params.use_row_match_finder = use_row_match_finder;

    initCDictInternal(
        cdict,
        dict,
        dict_load_method,
        dict_content_type,
        cctx_params,
    ) catch return null;
    return cdict;
}

/// `ZSTD_getCParamsFromCDict`: the parameters the dictionary was made with.
pub fn getCParamsFromCDict(cdict: *const CDict) CompressionParameters {
    return cdict.match_state.cparams;
}

/// `ZSTD_getDictID_fromCDict`: the dictionary's id; 0 for raw content.
pub fn getDictIdFromCDict(cdict: ?*const CDict) u32 {
    const cd = cdict orelse return 0;
    return cd.dict_id;
}

/// `ZSTD_compressBegin_usingCDict_internal`: starts a frame of
/// `pledged_src_size` with `cdict`, which must outlive the frame.
fn compressBeginUsingCDictInternal(
    cctx: *CCtx,
    cdict: ?*const CDict,
    fparams: params.FrameParameters,
    pledged_src_size: u64,
) Error!void {
    const cd = cdict orelse return error.DictionaryWrong;
    // The parameters from the dictionary.
    const parameters: params.Parameters = .{
        .fparams = fparams,
        .cparams = if (usesCDictParams(cd, pledged_src_size))
            getCParamsFromCDict(cd)
        else
            getCParams(cd.compression_level, pledged_src_size, cd.dict_content_size),
    };
    var cctx_params = cctxParamsInitInternal(&parameters, cd.compression_level);
    // A window that holds the dictionary and the source when its size is
    // known, up to 19, the window log of level 1 for the largest sources.
    if (pledged_src_size != params.content_size_unknown) {
        const limited_src_size: u32 = @intCast(@min(pledged_src_size, 1 << 19));
        const limited_src_log: u32 = if (limited_src_size > 1) ci.highbit32(
            limited_src_size - 1,
        ) + 1 else 1;
        cctx_params.cparams.window_log = @max(cctx_params.cparams.window_log, limited_src_log);
    }
    return compressBeginInternal(
        cctx,
        null,
        .auto,
        .fast,
        cd,
        &cctx_params,
        pledged_src_size,
        .not_buffered,
    );
}

/// `ZSTD_compressBegin_usingCDict_advanced`.
pub fn compressBeginUsingCDictAdvanced(
    cctx: *CCtx,
    cdict: *const CDict,
    fparams: params.FrameParameters,
    pledged_src_size: u64,
) Error!void {
    return compressBeginUsingCDictInternal(cctx, cdict, fparams, pledged_src_size);
}

/// `ZSTD_compressBegin_usingCDict`: starts a frame of unknown size with
/// `cdict`, without content size or checksum.
pub fn compressBeginUsingCDict(cctx: *CCtx, cdict: *const CDict) Error!void {
    const fparams: params.FrameParameters = .{
        .content_size_flag = false,
        .checksum_flag = false,
        .no_dict_id_flag = false,
    };
    return compressBeginUsingCDictInternal(cctx, cdict, fparams, params.content_size_unknown);
}

/// `ZSTD_compress_usingCDict_internal`.
fn compressUsingCDictInternal(
    cctx: *CCtx,
    dst: []u8,
    src: []const u8,
    cdict: ?*const CDict,
    fparams: params.FrameParameters,
) Error!usize {
    try compressBeginUsingCDictInternal(cctx, cdict, fparams, src.len);
    return compressEnd(cctx, dst, src);
}

/// `ZSTD_compress_usingCDict_advanced`.
pub fn compressUsingCDictAdvanced(
    cctx: *CCtx,
    dst: []u8,
    src: []const u8,
    cdict: *const CDict,
    fparams: params.FrameParameters,
) Error!usize {
    return compressUsingCDictInternal(cctx, dst, src, cdict, fparams);
}

/// `ZSTD_compress_usingCDict`: compresses `src` into one frame with the
/// dictionary's parameters, with the content size and no checksum.
pub fn compressUsingCDict(
    cctx: *CCtx,
    dst: []u8,
    src: []const u8,
    cdict: *const CDict,
) Error!usize {
    const fparams: params.FrameParameters = .{
        .content_size_flag = true,
        .checksum_flag = false,
        .no_dict_id_flag = false,
    };
    return compressUsingCDictInternal(cctx, dst, src, cdict, fparams);
}

// ---------------------------------------------------------------------------
// Streaming
// ---------------------------------------------------------------------------

/// `ZSTD_createCStream`, `ZSTD_createCStream_advanced`: a streaming
/// context is a compression context.
pub const createCStream = createCCtx;
/// `ZSTD_initStaticCStream`.
pub const initStaticCStream = initStaticCCtx;
/// `ZSTD_freeCStream`.
pub const freeCStream = freeCCtx;
/// `ZSTD_sizeof_CStream`.
pub const sizeofCStream = sizeofCCtx;

/// `ZSTD_CStreamInSize`: the input size that fills one block.
pub fn cStreamInSize() usize {
    return params.block_size_max;
}

/// `ZSTD_CStreamOutSize`: an output size that always takes a whole
/// block, its header and a checksum.
pub fn cStreamOutSize() usize {
    return compressBoundMacro(params.block_size_max) + block_header_size + 4;
}

/// `ZSTD_getCParamMode`: whether `cdict` is attached for a frame of
/// `pledged_src_size`.
fn getCParamMode(
    cdict: ?*const CDict,
    cctx_params: *const CCtxParams,
    pledged_src_size: u64,
) ci.CParamMode {
    if (cdict) |cd| {
        if (shouldAttachDict(cd, cctx_params, pledged_src_size)) return .attach_dict;
    }
    return .no_attach_dict;
}

/// `ZSTD_resetCStream`: ends the frame in progress and pledges the next
/// one's size, where 0 means unknown, as in the original.
pub fn resetCStream(zcs: *CCtx, pss: u64) Error!void {
    const pledged_src_size = if (pss == 0) params.content_size_unknown else pss;
    try cctxReset(zcs, .session_only);
    try cctxSetPledgedSrcSize(zcs, pledged_src_size);
}

/// `ZSTD_initCStream_internal`: starts a stream with `cctx_params`, whose
/// compression parameters must be valid, and either a dictionary copied
/// from `dict` or `cdict`, not both.
pub fn initCStreamInternal(
    zcs: *CCtx,
    dict: ?[]const u8,
    cdict: ?*const CDict,
    cctx_params: *const CCtxParams,
    pledged_src_size: u64,
) Error!void {
    try cctxReset(zcs, .session_only);
    try cctxSetPledgedSrcSize(zcs, pledged_src_size);
    assert(checkCParamsValid(cctx_params.cparams));
    zcs.requested_params = cctx_params.*;
    assert(dict == null or cdict == null);
    if (dict) |d| {
        try cctxLoadDictionary(zcs, d);
    } else {
        // No `cdict` clears the dictionary.
        try cctxRefCDict(zcs, cdict);
    }
}

/// `ZSTD_initCStream_usingCDict_advanced`: starts a stream with `cdict`,
/// which must outlive it, and `fparams`.
pub fn initCStreamUsingCDictAdvanced(
    zcs: *CCtx,
    cdict: ?*const CDict,
    fparams: params.FrameParameters,
    pledged_src_size: u64,
) Error!void {
    try cctxReset(zcs, .session_only);
    try cctxSetPledgedSrcSize(zcs, pledged_src_size);
    zcs.requested_params.fparams = fparams;
    try cctxRefCDict(zcs, cdict);
}

/// `ZSTD_initCStream_usingCDict`: starts a stream with `cdict`, which
/// must outlive it.
pub fn initCStreamUsingCDict(zcs: *CCtx, cdict: ?*const CDict) Error!void {
    try cctxReset(zcs, .session_only);
    try cctxRefCDict(zcs, cdict);
}

/// `ZSTD_initCStream_advanced`: starts a stream with `parameters` and a
/// dictionary copied from `dict` (none when empty). The pledged size must
/// be exact; 0 means unknown when the content size flag is off.
pub fn initCStreamAdvanced(
    zcs: *CCtx,
    dict: []const u8,
    parameters: params.Parameters,
    pss: u64,
) Error!void {
    const pledged_src_size = if (pss == 0 and !parameters.fparams.content_size_flag)
        params.content_size_unknown
    else
        pss;
    try cctxReset(zcs, .session_only);
    try cctxSetPledgedSrcSize(zcs, pledged_src_size);
    try checkCParams(parameters.cparams);
    cctxParamsSetZstdParams(&zcs.requested_params, &parameters);
    try cctxLoadDictionary(zcs, dict);
}

/// `ZSTD_initCStream_usingDict`: starts a stream at `compression_level`
/// with a dictionary copied from `dict` (none when empty).
pub fn initCStreamUsingDict(zcs: *CCtx, dict: []const u8, compression_level: i32) Error!void {
    try cctxReset(zcs, .session_only);
    _ = try cctxSetParameter(zcs, .compression_level, compression_level);
    try cctxLoadDictionary(zcs, dict);
}

/// `ZSTD_initCStream_srcSize`: starts a stream at `compression_level`
/// without a dictionary, pledging its size, where 0 means unknown.
pub fn initCStreamSrcSize(zcs: *CCtx, compression_level: i32, pss: u64) Error!void {
    const pledged_src_size = if (pss == 0) params.content_size_unknown else pss;
    try cctxReset(zcs, .session_only);
    try cctxRefCDict(zcs, null);
    _ = try cctxSetParameter(zcs, .compression_level, compression_level);
    try cctxSetPledgedSrcSize(zcs, pledged_src_size);
}

/// `ZSTD_initCStream`: starts a stream at `compression_level` without a
/// dictionary.
pub fn initCStream(zcs: *CCtx, compression_level: i32) Error!void {
    try cctxReset(zcs, .session_only);
    try cctxRefCDict(zcs, null);
    _ = try cctxSetParameter(zcs, .compression_level, compression_level);
}

/// `ZSTD_nextInputSizeHint`: the input that would complete the block being
/// gathered.
fn nextInputSizeHint(cctx: *const CCtx) usize {
    if (cctx.applied_params.in_buffer_mode == .stable) {
        // Wraps, as in the original, while a stable input is held back
        // before the first frame or past a smaller block size.
        return cctx.block_size_max -% cctx.stable_in_not_consumed;
    }
    var hint_in_size = cctx.in_buff_target - cctx.in_buff_pos;
    if (hint_in_size == 0) hint_in_size = cctx.block_size_max;
    return hint_in_size;
}

/// `ZSTD_compressBound` where the original compares its result: an error
/// is a size larger than any buffer.
fn boundOrMax(src_size: usize) usize {
    return compressBound(src_size) catch std.math.maxInt(usize);
}

/// `ZSTD_compressStream_generic`: the single-threaded stream. Gathers the
/// input into blocks (or reads a stable input in place), compresses each
/// block into the output, or into the context's buffer when the output may
/// be too small, and flushes that buffer. `.flush` compresses what is
/// gathered; `.end` also ends the frame. Returns a hint of the next input
/// size, or 0 once the frame is complete. On an error, `input.pos` and
/// `output.pos` are left as they were, but for a stable input's bytes held
/// back, which are given back first.
fn compressStreamGeneric(
    zcs: *CCtx,
    output: *params.OutBuffer,
    input: *params.InBuffer,
    flush_mode: params.EndDirective,
) Error!usize {
    const iend = input.src.len;
    var ip = input.pos;
    const oend = output.dst.len;
    var op = output.pos;
    var some_more_work = true;

    if (zcs.applied_params.in_buffer_mode == .stable) {
        assert(input.pos >= zcs.stable_in_not_consumed);
        input.pos -= zcs.stable_in_not_consumed;
        ip -= zcs.stable_in_not_consumed;
        zcs.stable_in_not_consumed = 0;
    }
    if (zcs.applied_params.in_buffer_mode == .buffered) assert(zcs.in_buff_size > 0);
    if (zcs.applied_params.out_buffer_mode == .buffered) assert(zcs.out_buff_size > 0);

    while (some_more_work) {
        stage: switch (zcs.stream_stage) {
            .init => return error.InitMissing,
            .load => {
                if (flush_mode == .end and
                    (oend - op >= boundOrMax(iend - ip) or
                        // A stable output may take `error.DstSizeTooSmall`.
                        zcs.applied_params.out_buffer_mode == .stable) and
                    zcs.in_buff_pos == 0)
                {
                    // The whole frame straight into the output.
                    const c_size = try compressEnd(zcs, output.dst[op..oend], input.src[ip..iend]);
                    ip = iend;
                    op += c_size;
                    zcs.frame_ended = true;
                    // A session reset cannot fail.
                    cctxReset(zcs, .session_only) catch unreachable;
                    some_more_work = false;
                    break :stage;
                }
                if (zcs.applied_params.in_buffer_mode == .buffered) {
                    // Fill the input buffer up to the block.
                    const to_load = zcs.in_buff_target - zcs.in_buff_pos;
                    const loaded = @min(to_load, iend - ip);
                    @memcpy(zcs.in_buff[zcs.in_buff_pos..][0..loaded], input.src[ip..][0..loaded]);
                    zcs.in_buff_pos += loaded;
                    ip += loaded;
                    if (flush_mode == .@"continue" and zcs.in_buff_pos < zcs.in_buff_target) {
                        // Not a whole block yet.
                        some_more_work = false;
                        break :stage;
                    }
                    if (flush_mode == .flush and zcs.in_buff_pos == zcs.in_to_compress) {
                        // Nothing to flush.
                        some_more_work = false;
                        break :stage;
                    }
                } else {
                    assert(zcs.applied_params.in_buffer_mode == .stable);
                    if (flush_mode == .@"continue" and iend - ip < zcs.block_size_max) {
                        // Not a whole block yet: the input is reported
                        // consumed, and read again at the next call.
                        zcs.stable_in_not_consumed = iend - ip;
                        ip = iend;
                        some_more_work = false;
                        break :stage;
                    }
                    if (flush_mode == .flush and ip == iend) {
                        some_more_work = false;
                        break :stage;
                    }
                }

                // One block, which cannot be stopped halfway.
                const input_buffered = zcs.applied_params.in_buffer_mode == .buffered;
                const i_size = if (input_buffered)
                    zcs.in_buff_pos - zcs.in_to_compress
                else
                    @min(iend - ip, zcs.block_size_max);
                // Straight into the output when it surely fits, or when a
                // stable output must; else into the buffer, then flushed.
                const into_output = oend - op >= boundOrMax(i_size) or
                    zcs.applied_params.out_buffer_mode == .stable;
                const c_dst = if (into_output)
                    output.dst[op..oend]
                else
                    zcs.out_buff[0..zcs.out_buff_size];
                var c_size: usize = undefined;
                if (input_buffered) {
                    const last_block = flush_mode == .end and ip == iend;
                    const block = zcs.in_buff[zcs.in_to_compress..][0..i_size];
                    c_size = if (last_block)
                        try compressEnd(zcs, c_dst, block)
                    else
                        try compressContinue(zcs, c_dst, block);
                    zcs.frame_ended = last_block;
                    // The next block, from the buffer's start when it
                    // would not fit.
                    zcs.in_buff_target = zcs.in_buff_pos + zcs.block_size_max;
                    if (zcs.in_buff_target > zcs.in_buff_size) {
                        zcs.in_buff_pos = 0;
                        zcs.in_buff_target = zcs.block_size_max;
                    }
                    if (!last_block) assert(zcs.in_buff_target <= zcs.in_buff_size);
                    zcs.in_to_compress = zcs.in_buff_pos;
                } else {
                    const last_block = flush_mode == .end and ip + i_size == iend;
                    const block = input.src[ip..][0..i_size];
                    c_size = if (last_block)
                        try compressEnd(zcs, c_dst, block)
                    else
                        try compressContinue(zcs, c_dst, block);
                    ip += i_size;
                    zcs.frame_ended = last_block;
                }
                if (into_output) {
                    op += c_size;
                    if (zcs.frame_ended) {
                        some_more_work = false;
                        cctxReset(zcs, .session_only) catch unreachable;
                    }
                    break :stage;
                }
                zcs.out_buff_content_size = c_size;
                zcs.out_buff_flushed_size = 0;
                zcs.stream_stage = .flush;
                continue :stage .flush;
            },
            .flush => {
                assert(zcs.applied_params.out_buffer_mode == .buffered);
                const to_flush = zcs.out_buff_content_size - zcs.out_buff_flushed_size;
                const flushed = @min(oend - op, to_flush);
                @memcpy(
                    output.dst[op..][0..flushed],
                    zcs.out_buff[zcs.out_buff_flushed_size..][0..flushed],
                );
                op += flushed;
                zcs.out_buff_flushed_size += flushed;
                if (to_flush != flushed) {
                    // The output is full.
                    assert(op == oend);
                    some_more_work = false;
                    break :stage;
                }
                zcs.out_buff_content_size = 0;
                zcs.out_buff_flushed_size = 0;
                if (zcs.frame_ended) {
                    some_more_work = false;
                    cctxReset(zcs, .session_only) catch unreachable;
                    break :stage;
                }
                zcs.stream_stage = .load;
            },
        }
    }

    input.pos = ip;
    output.pos = op;
    if (zcs.frame_ended) return 0;
    return nextInputSizeHint(zcs);
}

/// `ZSTD_nextInputSizeHint_MTorST`.
fn nextInputSizeHintMTorST(cctx: *const CCtx) usize {
    if (build_options.multithread and cctx.applied_params.nb_workers >= 1) {
        return cctx.mtctx.?.nextInputSizeHint();
    }
    return nextInputSizeHint(cctx);
}

/// `ZSTD_compressStream`: `compressStream2` with `.continue`, returning a
/// hint of the next input size.
pub fn compressStream(
    zcs: *CCtx,
    output: *params.OutBuffer,
    input: *params.InBuffer,
) Error!usize {
    _ = try compressStream2(zcs, output, input, .@"continue");
    return nextInputSizeHintMTorST(zcs);
}

/// `ZSTD_setBufferExpectations`: the buffers the next call must pass in
/// the stable modes.
fn setBufferExpectations(
    cctx: *CCtx,
    output: *const params.OutBuffer,
    input: *const params.InBuffer,
) void {
    if (cctx.applied_params.in_buffer_mode == .stable) cctx.expected_in_buffer = input.*;
    if (cctx.applied_params.out_buffer_mode == .stable) {
        cctx.expected_out_buffer_size = output.dst.len - output.pos;
    }
}

/// `ZSTD_checkBufferStability`: whether the buffers are the ones the last
/// call left, in the stable modes.
fn checkBufferStability(
    cctx: *const CCtx,
    output: *const params.OutBuffer,
    input: *const params.InBuffer,
) Error!void {
    if (cctx.applied_params.in_buffer_mode == .stable) {
        const expect = cctx.expected_in_buffer;
        if (expect.src.ptr != input.src.ptr or expect.pos != input.pos) {
            return error.StabilityConditionNotRespected;
        }
    }
    if (cctx.applied_params.out_buffer_mode == .stable) {
        if (cctx.expected_out_buffer_size != output.dst.len - output.pos) {
            return error.StabilityConditionNotRespected;
        }
    }
}

/// `ZSTD_CCtx_init_compressStream2`: starts a frame with the requested
/// parameters and dictionaries; for `.end`, `in_size` becomes the pledged
/// size. The prefix is used by this frame only. A frame with workers needs
/// an allocator, so not a static context, and an `Io` (`CCtx.setIo`, or a
/// referenced thread pool's): without one it fails with
/// `error.ParameterCombinationUnsupported`.
pub fn cctxInitCompressStream2(
    cctx: *CCtx,
    end_op: params.EndDirective,
    in_size: usize,
) Error!void {
    var cctx_params = cctx.requested_params;
    const prefix_dict = cctx.prefix_dict;
    try initLocalDict(cctx);
    // Single use.
    cctx.prefix_dict = .{};
    assert(prefix_dict.dict == null or cctx.cdict == null);
    if (cctx.cdict) |cdict| {
        // A dictionary's level wins, unless it is the local one.
        if (cctx.local_dict.cdict == null) cctx_params.compression_level = cdict.compression_level;
    }
    // The pledged size is the input's.
    if (end_op == .end) cctx.pledged_src_size_plus_one = @as(u64, in_size) + 1;

    {
        const dict_size = if (prefix_dict.dict != null)
            prefix_dict.dict_size
        else if (cctx.cdict) |cdict| cdict.dict_content_size else 0;
        const mode = getCParamMode(cctx.cdict, &cctx_params, cctx.pledged_src_size_plus_one -% 1);
        cctx_params.cparams = getCParamsFromCCtxParams(
            &cctx_params,
            cctx.pledged_src_size_plus_one -% 1,
            dict_size,
            mode,
        );
    }

    cctx_params.post_block_splitter = resolveBlockSplitterMode(
        cctx_params.post_block_splitter,
        &cctx_params.cparams,
    );
    cctx_params.ldm_params.enable_ldm = resolveEnableLdm(
        cctx_params.ldm_params.enable_ldm,
        &cctx_params.cparams,
    );
    cctx_params.use_row_match_finder = resolveRowMatchFinderMode(
        cctx_params.use_row_match_finder,
        &cctx_params.cparams,
    );
    cctx_params.validate_sequences = resolveExternalSequenceValidation(
        cctx_params.validate_sequences,
    );
    cctx_params.max_block_size = resolveMaxBlockSize(cctx_params.max_block_size);
    cctx_params.search_for_external_repcodes = resolveExternalRepcodeSearch(
        cctx_params.search_for_external_repcodes,
        cctx_params.compression_level,
    );

    if (build_options.multithread) {
        // An external producer fails before the job size is looked at.
        if (ci.hasExtSeqProd(&cctx_params) and cctx_params.nb_workers >= 1) {
            return error.ParameterCombinationUnsupported;
        }
        // No threads for a small source.
        if (cctx.pledged_src_size_plus_one -% 1 <= zstdmt.jobsize_min) cctx_params.nb_workers = 0;
        if (cctx_params.nb_workers > 0) {
            if (cctx.mtctx == null) {
                const gpa = cctx.custom_mem orelse return error.MemoryAllocation;
                const io = cctx.io orelse if (cctx.pool) |pool| pool.io else {
                    return error.ParameterCombinationUnsupported;
                };
                cctx.mtctx = zstdmt.createCCtxAdvanced(
                    @intCast(cctx_params.nb_workers),
                    gpa,
                    io,
                    cctx.pool,
                ) orelse return error.MemoryAllocation;
            }
            try cctx.mtctx.?.initCStreamInternal(
                if (prefix_dict.dict) |d| d[0..prefix_dict.dict_size] else null,
                prefix_dict.dict_content_type,
                cctx.cdict,
                cctx_params,
                cctx.pledged_src_size_plus_one -% 1,
            );
            cctx.dict_id = if (cctx.cdict) |cdict| cdict.dict_id else 0;
            cctx.dict_content_size = if (cctx.cdict) |cdict|
                cdict.dict_content_size
            else
                prefix_dict.dict_size;
            cctx.consumed_src_size = 0;
            cctx.produced_csize = 0;
            cctx.stream_stage = .load;
            cctx.applied_params = cctx_params;
            return;
        }
    }

    const pledged_src_size = cctx.pledged_src_size_plus_one -% 1;
    assert(checkCParamsValid(cctx_params.cparams));
    try compressBeginInternal(
        cctx,
        if (prefix_dict.dict) |d| d[0..prefix_dict.dict_size] else null,
        prefix_dict.dict_content_type,
        .fast,
        cctx.cdict,
        &cctx_params,
        pledged_src_size,
        .buffered,
    );
    assert(cctx.applied_params.nb_workers == 0);
    cctx.in_to_compress = 0;
    cctx.in_buff_pos = 0;
    if (cctx.applied_params.in_buffer_mode == .buffered) {
        // A small input is not flushed when it fills a block, which would
        // need an empty block to end the frame.
        cctx.in_buff_target = cctx.block_size_max + @intFromBool(
            cctx.block_size_max == pledged_src_size,
        );
    } else {
        cctx.in_buff_target = 0;
    }
    cctx.out_buff_content_size = 0;
    cctx.out_buff_flushed_size = 0;
    cctx.stream_stage = .load;
    cctx.frame_ended = false;
}

/// `ZSTD_compressStream2`: compresses from `input.src[input.pos..]` into
/// `output.dst[output.pos..]`, moving both positions. `.continue` takes
/// input and leaves the encoder free to hold it; `.flush` compresses all
/// the input taken and flushes it, as far as the output allows; `.end`
/// also ends the frame, and the next call starts a new one. Returns at
/// least the bytes still to flush: 0 after a `.flush` or `.end` means it is
/// done. The first call of a frame starts it with the parameters set then.
///
/// With `stable_in_buffer`, `input.src` must stay valid, unchanged, at the
/// same address and with the same `pos` from one call to the next until the
/// frame ends; with `stable_out_buffer`, `output.dst` must stay the same
/// buffer with the same space after `pos`. A break of either promise fails
/// with `error.StabilityConditionNotRespected`.
pub fn compressStream2(
    cctx: *CCtx,
    output: *params.OutBuffer,
    input: *params.InBuffer,
    end_op: params.EndDirective,
) Error!usize {
    if (output.pos > output.dst.len) return error.DstSizeTooSmall;
    if (input.pos > input.src.len) return error.SrcSizeWrong;

    // The frame starts at the first call.
    if (cctx.stream_stage == .init) {
        const input_size = input.src.len - input.pos;
        const total_input_size = input_size + cctx.stable_in_not_consumed;
        if (cctx.requested_params.in_buffer_mode == .stable and end_op == .@"continue" and
            total_input_size < params.block_size_max)
        {
            // Not a block yet: wait for more, or a flush, to pick the
            // parameters from the size.
            if (cctx.stable_in_not_consumed != 0) {
                if (input.src.ptr != cctx.expected_in_buffer.src.ptr) {
                    return error.StabilityConditionNotRespected;
                }
                if (input.pos != cctx.expected_in_buffer.src.len) {
                    return error.StabilityConditionNotRespected;
                }
            }
            // Reported consumed, and read again when the frame starts.
            input.pos = input.src.len;
            cctx.expected_in_buffer = input.*;
            cctx.stable_in_not_consumed += input_size;
            // At least the frame header is to come.
            return params.frameHeaderSizeMin(cctx.requested_params.format);
        }
        try cctxInitCompressStream2(cctx, end_op, total_input_size);
        setBufferExpectations(cctx, output, input);
    }

    try checkBufferStability(cctx, output, input);
    if (build_options.multithread and cctx.applied_params.nb_workers > 0) {
        return compressStream2Mt(cctx, output, input, end_op);
    }
    _ = try compressStreamGeneric(cctx, output, input, end_op);
    setBufferExpectations(cctx, output, input);
    return cctx.out_buff_content_size - cctx.out_buff_flushed_size;
}

/// The multithreaded half of `ZSTD_compressStream2`: `.continue` returns
/// after any progress, `.flush` and `.end` once all is flushed or the
/// output is full.
fn compressStream2Mt(
    cctx: *CCtx,
    output: *params.OutBuffer,
    input: *params.InBuffer,
    end_op: params.EndDirective,
) Error!usize {
    const mtctx = cctx.mtctx.?;
    if (cctx.cparams_changed) {
        mtctx.updateCParamsWhileCompressing(&cctx.requested_params);
        cctx.cparams_changed = false;
    }
    if (cctx.stable_in_not_consumed != 0) {
        assert(cctx.applied_params.in_buffer_mode == .stable);
        // The input held back before the frame started.
        assert(input.pos >= cctx.stable_in_not_consumed);
        input.pos -= cctx.stable_in_not_consumed;
        cctx.stable_in_not_consumed = 0;
    }
    var flush_min: usize = undefined;
    while (true) {
        const ipos = input.pos;
        const opos = output.pos;
        const result = mtctx.compressStreamGeneric(output, input, end_op);
        cctx.consumed_src_size += input.pos - ipos;
        cctx.produced_csize += output.pos - opos;
        flush_min = result catch |err| {
            cctxReset(cctx, .session_only) catch unreachable;
            return err;
        };
        // The frame is complete.
        if (end_op == .end and flush_min == 0) cctxReset(cctx, .session_only) catch unreachable;

        if (end_op == .@"continue") {
            // Some progress is enough.
            if (input.pos != ipos or output.pos != opos or input.pos == input.src.len or
                output.pos == output.dst.len) break;
        } else {
            if (flush_min == 0 or output.pos == output.dst.len) break;
        }
    }
    setBufferExpectations(cctx, output, input);
    return flush_min;
}

/// `ZSTD_compressStream2_simpleArgs`: `compressStream2` on `dst` and `src`
/// from the positions `dst_pos` and `src_pos`, which it moves.
pub fn compressStream2SimpleArgs(
    cctx: *CCtx,
    dst: []u8,
    dst_pos: *usize,
    src: []const u8,
    src_pos: *usize,
    end_op: params.EndDirective,
) Error!usize {
    var output: params.OutBuffer = .{ .dst = dst, .pos = dst_pos.* };
    var input: params.InBuffer = .{ .src = src, .pos = src_pos.* };
    const result = compressStream2(cctx, &output, &input, end_op);
    dst_pos.* = output.pos;
    src_pos.* = input.pos;
    return result;
}

/// `ZSTD_compress2`: compresses `src` into one frame with the requested
/// parameters and dictionaries, as `compressStream2` with `.end` and
/// stable buffers, so a single-threaded frame goes straight from `src` to
/// `dst`. Ends any frame in progress first.
pub fn compress2(cctx: *CCtx, dst: []u8, src: []const u8) Error!usize {
    const original_in_buffer_mode = cctx.requested_params.in_buffer_mode;
    const original_out_buffer_mode = cctx.requested_params.out_buffer_mode;
    cctxReset(cctx, .session_only) catch unreachable;
    cctx.requested_params.in_buffer_mode = .stable;
    cctx.requested_params.out_buffer_mode = .stable;
    var o_pos: usize = 0;
    var i_pos: usize = 0;
    const result = compressStream2SimpleArgs(cctx, dst, &o_pos, src, &i_pos, .end);
    cctx.requested_params.in_buffer_mode = original_in_buffer_mode;
    cctx.requested_params.out_buffer_mode = original_out_buffer_mode;

    // Not complete: the output is too small.
    if (try result != 0) {
        assert(o_pos == dst.len);
        return error.DstSizeTooSmall;
    }
    assert(i_pos == src.len);
    return o_pos;
}

// ---------------------------------------------------------------------------
// Sequences from the caller
// ---------------------------------------------------------------------------

/// `ZSTD_validateSequence`: whether a sequence `pos_in_src` bytes into the
/// frame has an offset the decoder can reach and a long enough match.
fn validateSequence(
    off_base: u32,
    match_length: u32,
    min_match_param: u32,
    pos_in_src: usize,
    window_log: u32,
    dict_size: usize,
    use_sequence_producer: bool,
) Error!void {
    const window_size = @as(u32, 1) << @intCast(window_log);
    // Until the output reaches the window size, offsets reach into the
    // dictionary, even beyond the window size; then, the window size.
    const offset_bound: usize =
        if (pos_in_src > window_size) window_size else pos_in_src + dict_size;
    const match_len_lower_bound: u32 = if (min_match_param == 3 or use_sequence_producer) 3 else 4;
    if (off_base > offset_bound + rep_num) return error.ExternalSequencesInvalid;
    if (match_length < match_len_lower_bound) return error.ExternalSequencesInvalid;
}

/// `ZSTD_finalizeOffBase`: the off_base of a raw offset, a repeat code
/// where it matches one.
fn finalizeOffBase(raw_offset: u32, rep: *const [rep_num]u32, ll0: u32) u32 {
    var off_base = ci.offsetToOffbase(raw_offset);
    if (ll0 == 0 and raw_offset == rep[0]) {
        off_base = ci.repcode1_to_offbase;
    } else if (raw_offset == rep[1]) {
        off_base = ci.repcodeToOffbase(2 - ll0);
    } else if (raw_offset == rep[2]) {
        off_base = ci.repcodeToOffbase(3 - ll0);
    } else if (ll0 != 0 and raw_offset == rep[0] -% 1) {
        off_base = ci.repcode3_to_offbase;
    }
    return off_base;
}

/// `ZSTD_transferSequences_wBlockDelim`: stores the sequences of
/// `in_seqs` from `seq_pos` to the next block delimiter, whose literals end
/// the block of `src`. Their lengths must add up to `src.len`. Returns
/// `src.len`.
fn transferSequencesWBlockDelim(
    cctx: *CCtx,
    seq_pos: *ci.SequencePosition,
    in_seqs: []const Sequence,
    src: []const u8,
    external_rep_search: ParamSwitch,
) Error!usize {
    var idx: u32 = seq_pos.idx;
    const start_idx = idx;
    var ip = src.ptr;
    const iend = src.ptr + src.len;
    var updated_repcodes: ci.Repcodes = .{ .rep = cctx.block_state.prev_cblock.rep };
    const dict_size: u32 = if (cctx.cdict) |cdict|
        @intCast(cdict.dict_content_size)
    else if (cctx.prefix_dict.dict != null)
        @intCast(cctx.prefix_dict.dict_size)
    else
        0;

    while (idx < in_seqs.len and (in_seqs[idx].match_length != 0 or
        in_seqs[idx].offset != 0)) : (idx += 1)
    {
        const lit_length = in_seqs[idx].lit_length;
        const match_length = in_seqs[idx].match_length;
        var off_base: u32 = undefined;

        if (external_rep_search == .disable) {
            off_base = ci.offsetToOffbase(in_seqs[idx].offset);
        } else {
            const ll0: u32 = @intFromBool(lit_length == 0);
            off_base = finalizeOffBase(in_seqs[idx].offset, &updated_repcodes.rep, ll0);
            ci.updateRep(&updated_repcodes.rep, off_base, ll0);
        }

        if (cctx.applied_params.validate_sequences) {
            seq_pos.pos_in_src += lit_length + match_length;
            try validateSequence(
                off_base,
                match_length,
                cctx.applied_params.cparams.min_match,
                seq_pos.pos_in_src,
                cctx.applied_params.cparams.window_log,
                dict_size,
                ci.hasExtSeqProd(&cctx.applied_params),
            );
        }
        // Too many sequences for the store; a larger minimum match helps.
        if (idx - seq_pos.idx >= cctx.seq_store.max_nb_seq) return error.ExternalSequencesInvalid;
        ci.storeSeq(&cctx.seq_store, lit_length, ip, iend, off_base, match_length);
        ip += match_length + lit_length;
    }
    if (idx == in_seqs.len) return error.ExternalSequencesInvalid;

    // The repeat offsets, when the search skipped them.
    assert(external_rep_search != .auto);
    assert(idx >= start_idx);
    if (external_rep_search == .disable and idx != start_idx) {
        const rep = &updated_repcodes.rep;
        // The last sequence before the delimiter.
        const last_seq_idx = idx - 1;
        if (last_seq_idx >= start_idx + 2) {
            rep[2] = in_seqs[last_seq_idx - 2].offset;
            rep[1] = in_seqs[last_seq_idx - 1].offset;
            rep[0] = in_seqs[last_seq_idx].offset;
        } else if (last_seq_idx == start_idx + 1) {
            rep[2] = rep[0];
            rep[1] = in_seqs[last_seq_idx - 1].offset;
            rep[0] = in_seqs[last_seq_idx].offset;
        } else {
            assert(last_seq_idx == start_idx);
            rep[2] = rep[1];
            rep[1] = rep[0];
            rep[0] = in_seqs[last_seq_idx].offset;
        }
    }

    cctx.block_state.next_cblock.rep = updated_repcodes.rep;

    if (in_seqs[idx].lit_length != 0) {
        storeLastLiterals(&cctx.seq_store, ip[0..in_seqs[idx].lit_length]);
        ip += in_seqs[idx].lit_length;
        seq_pos.pos_in_src += in_seqs[idx].lit_length;
    }
    if (ip != iend) return error.ExternalSequencesInvalid;
    seq_pos.idx = idx + 1;
    return src.len;
}

/// `ZSTD_transferSequences_noDelim`: stores the sequences of `in_seqs`
/// from `seq_pos` that cover the block `src`, splitting the last one where
/// the block ends; a match is split only when it is longer than the block,
/// else the block ends before it. Returns the bytes of `src` the sequences
/// cover, at most `src.len`. Repeat offsets are always resolved.
fn transferSequencesNoDelim(
    cctx: *CCtx,
    seq_pos: *ci.SequencePosition,
    in_seqs: []const Sequence,
    src: []const u8,
    external_rep_search: ParamSwitch,
) Error!usize {
    _ = external_rep_search;
    var idx: u32 = seq_pos.idx;
    var start_pos_in_sequence: u32 = seq_pos.pos_in_sequence;
    var end_pos_in_sequence: u32 = seq_pos.pos_in_sequence + @as(u32, @intCast(src.len));
    const istart = src.ptr;
    var ip = istart;
    // Moved back when the block ends before the match it reaches into.
    var iend = istart + src.len;
    var updated_repcodes: ci.Repcodes = .{ .rep = cctx.block_state.prev_cblock.rep };
    var bytes_adjustment: u32 = 0;
    var final_match_split = false;
    const min_match_param = cctx.applied_params.cparams.min_match;
    const dict_size: usize = if (cctx.cdict) |cdict|
        cdict.dict_content_size
    else if (cctx.prefix_dict.dict != null)
        cctx.prefix_dict.dict_size
    else
        0;

    while (end_pos_in_sequence != 0 and idx < in_seqs.len and !final_match_split) {
        const curr_seq = in_seqs[idx];
        var lit_length = curr_seq.lit_length;
        var match_length = curr_seq.match_length;
        const raw_offset = curr_seq.offset;

        if (end_pos_in_sequence >= curr_seq.lit_length + curr_seq.match_length) {
            // The whole sequence, less what an earlier block took.
            if (start_pos_in_sequence >= lit_length) {
                start_pos_in_sequence -= lit_length;
                lit_length = 0;
                match_length -= start_pos_in_sequence;
            } else {
                lit_length -= start_pos_in_sequence;
            }
            end_pos_in_sequence -= curr_seq.lit_length + curr_seq.match_length;
            start_pos_in_sequence = 0;
        } else {
            // The block ends inside this sequence.
            if (end_pos_in_sequence > lit_length) {
                lit_length = if (start_pos_in_sequence >= lit_length)
                    0
                else
                    lit_length - start_pos_in_sequence;
                var first_half_match_length = end_pos_in_sequence - start_pos_in_sequence -
                    lit_length;
                if (match_length > src.len and first_half_match_length >= min_match_param) {
                    // Split the match, keeping both halves at least the
                    // minimum match long.
                    const second_half_match_length = curr_seq.match_length +
                        curr_seq.lit_length - end_pos_in_sequence;
                    if (second_half_match_length < min_match_param) {
                        end_pos_in_sequence -= min_match_param - second_half_match_length;
                        bytes_adjustment = min_match_param - second_half_match_length;
                        first_half_match_length -= bytes_adjustment;
                    }
                    match_length = first_half_match_length;
                    // Stored, then the loop ends, keeping the position.
                    final_match_split = true;
                } else {
                    // End the block before the match, at the sequence's
                    // literals' end, and store the literals last.
                    bytes_adjustment = end_pos_in_sequence - curr_seq.lit_length;
                    end_pos_in_sequence = curr_seq.lit_length;
                    break;
                }
            } else {
                // The block ends inside the literals, stored last.
                break;
            }
        }

        const ll0: u32 = @intFromBool(lit_length == 0);
        const off_base = finalizeOffBase(raw_offset, &updated_repcodes.rep, ll0);
        ci.updateRep(&updated_repcodes.rep, off_base, ll0);

        if (cctx.applied_params.validate_sequences) {
            seq_pos.pos_in_src += lit_length + match_length;
            try validateSequence(
                off_base,
                match_length,
                min_match_param,
                seq_pos.pos_in_src,
                cctx.applied_params.cparams.window_log,
                dict_size,
                ci.hasExtSeqProd(&cctx.applied_params),
            );
        }
        // Too many sequences for the store; a larger minimum match helps.
        if (idx - seq_pos.idx >= cctx.seq_store.max_nb_seq) return error.ExternalSequencesInvalid;
        ci.storeSeq(&cctx.seq_store, lit_length, ip, iend, off_base, match_length);
        ip += match_length + lit_length;
        if (!final_match_split) idx += 1;
    }
    assert(idx == in_seqs.len or
        end_pos_in_sequence <= in_seqs[idx].lit_length + in_seqs[idx].match_length);
    seq_pos.idx = idx;
    seq_pos.pos_in_sequence = end_pos_in_sequence;
    cctx.block_state.next_cblock.rep = updated_repcodes.rep;

    iend -= bytes_adjustment;
    if (ip != iend) {
        // The last literals.
        const last_ll_size = @intFromPtr(iend) - @intFromPtr(ip);
        storeLastLiterals(&cctx.seq_store, ip[0..last_ll_size]);
        seq_pos.pos_in_src += last_ll_size;
    }
    return @intFromPtr(iend) - @intFromPtr(istart);
}

/// `blockSize_explicitDelimiter`: the size of the block that ends at the
/// next block delimiter from `seq_pos`, which must be there.
fn blockSizeExplicitDelimiter(
    in_seqs: []const Sequence,
    seq_pos: ci.SequencePosition,
) Error!usize {
    var end = false;
    var block_size: usize = 0;
    var spos: usize = seq_pos.idx;
    assert(spos <= in_seqs.len);
    while (spos < in_seqs.len) : (spos += 1) {
        end = in_seqs[spos].offset == 0;
        block_size += in_seqs[spos].lit_length + in_seqs[spos].match_length;
        if (end) {
            // A delimiter has neither an offset nor a match.
            if (in_seqs[spos].match_length != 0) return error.ExternalSequencesInvalid;
            break;
        }
    }
    if (!end) return error.ExternalSequencesInvalid;
    return block_size;
}

/// `determine_blockSize`: the size of the next block: at most
/// `block_size` of the `remaining` bytes without delimiters, the
/// delimiters' block with them.
fn determineBlockSize(
    mode: params.SequenceFormat,
    block_size: usize,
    remaining: usize,
    in_seqs: []const Sequence,
    seq_pos: ci.SequencePosition,
) Error!usize {
    if (mode == .no_block_delimiters) return @min(remaining, block_size);
    const explicit_block_size = try blockSizeExplicitDelimiter(in_seqs, seq_pos);
    if (explicit_block_size > block_size) return error.ExternalSequencesInvalid;
    if (explicit_block_size > remaining) return error.ExternalSequencesInvalid;
    return explicit_block_size;
}

/// `ZSTD_compressSequences_internal`: the blocks of `src`, made from
/// `in_seqs`. Returns their size, headers included.
fn compressSequencesInternal(
    cctx: *CCtx,
    dst: []u8,
    in_seqs: []const Sequence,
    src: []const u8,
) Error!usize {
    var c_size: usize = 0;
    var remaining = src.len;
    var seq_pos: ci.SequencePosition = .{ .idx = 0, .pos_in_sequence = 0, .pos_in_src = 0 };
    var ip: usize = 0;
    var op: usize = 0;
    const raw: u32 = @backingInt(zstd_internal.BlockType.raw);
    const compressed: u32 = @backingInt(zstd_internal.BlockType.compressed);

    // An empty frame: one empty raw block.
    if (remaining == 0) {
        const c_block_header24: u32 = 1 + (raw << 1);
        if (dst.len < 4) return error.DstSizeTooSmall;
        std.mem.writeInt(u32, dst[0..4], c_block_header24, .little);
        op += block_header_size;
        c_size += block_header_size;
    }

    while (remaining != 0) {
        var block_size = try determineBlockSize(
            cctx.applied_params.block_delimiters,
            cctx.block_size_max,
            remaining,
            in_seqs,
            seq_pos,
        );
        const last_block: u32 = @intFromBool(block_size == remaining);
        assert(block_size <= remaining);
        ci.resetSeqStore(&cctx.seq_store);

        const block_src = src[ip..][0..block_size];
        const rep_search = cctx.applied_params.search_for_external_repcodes;
        block_size = switch (cctx.applied_params.block_delimiters) {
            .explicit_block_delimiters => try transferSequencesWBlockDelim(
                cctx,
                &seq_pos,
                in_seqs,
                block_src,
                rep_search,
            ),
            .no_block_delimiters => try transferSequencesNoDelim(
                cctx,
                &seq_pos,
                in_seqs,
                block_src,
                rep_search,
            ),
        };

        // A block too small to compress is stored raw. The minimum block
        // has one byte more than elsewhere.
        if (block_size < zstd_internal.min_cblock_size + block_header_size + 1 + 1) {
            const c_block_size = try ci.noCompressBlock(
                dst[op..],
                src[ip..][0..block_size],
                last_block,
            );
            c_size += c_block_size;
            ip += block_size;
            op += c_block_size;
            remaining -= block_size;
            continue;
        }

        if (dst.len - op < block_header_size) return error.DstSizeTooSmall;
        var compressed_seqs_size = try entropyCompressSeqStore(
            &cctx.seq_store,
            &cctx.block_state.prev_cblock.entropy,
            &cctx.block_state.next_cblock.entropy,
            &cctx.applied_params,
            dst[op + block_header_size ..],
            block_size,
            tmpWorkspace(cctx),
            cctx.bmi2,
        );

        // Decoders up to 1.4.3 refuse a first block that is RLE.
        if (!cctx.is_first_block and maybeRle(&cctx.seq_store) and
            isRle(src[ip..][0..block_size]))
        {
            compressed_seqs_size = 1;
        }

        var c_block_size: usize = undefined;
        if (compressed_seqs_size == 0) {
            c_block_size = try ci.noCompressBlock(dst[op..], src[ip..][0..block_size], last_block);
        } else if (compressed_seqs_size == 1) {
            c_block_size = try ci.rleCompressBlock(dst[op..], src[ip], block_size, last_block);
        } else {
            blockStateConfirmRepcodesAndEntropyTables(&cctx.block_state);
            if (cctx.block_state.prev_cblock.entropy.fse.offcode_repeat_mode == .valid) {
                cctx.block_state.prev_cblock.entropy.fse.offcode_repeat_mode = .check;
            }
            const c_block_header: u32 = last_block + (compressed << 1) +
                @as(u32, @intCast(compressed_seqs_size << 3));
            writeLe24(dst[op..], c_block_header);
            c_block_size = block_header_size + compressed_seqs_size;
        }

        c_size += c_block_size;
        if (last_block != 0) break;
        ip += block_size;
        op += c_block_size;
        remaining -= block_size;
        cctx.is_first_block = false;
    }
    return c_size;
}

/// `ZSTD_compressSequences`: compresses `src` into one frame with the
/// requested parameters, made of the sequences `in_seqs` rather than ones
/// a match finder finds. The sequences, with block delimiters or without,
/// as `block_delimiters` says, must cover `src` exactly; with
/// `validate_sequences`, every offset and match length is checked.
pub fn compressSequences(
    cctx: *CCtx,
    dst: []u8,
    in_seqs: []const Sequence,
    src: []const u8,
) Error!usize {
    try cctxInitCompressStream2(cctx, .end, src.len);
    const frame_header_size = try writeFrameHeader(
        dst,
        &cctx.applied_params,
        src.len,
        cctx.dict_id,
    );
    var op = frame_header_size;
    if (cctx.applied_params.fparams.checksum_flag and src.len != 0) cctx.xxh_state.update(src);

    op += try compressSequencesInternal(cctx, dst[op..], in_seqs, src);

    if (cctx.applied_params.fparams.checksum_flag) {
        const checksum: u32 = @truncate(cctx.xxh_state.final());
        if (dst.len - op < 4) return error.DstSizeTooSmall;
        std.mem.writeInt(u32, dst[op..][0..4], checksum, .little);
        op += 4;
    }
    return op;
}

/// Whether the original's AVX2 paths of the sequence conversion are taken,
/// as `@Vector`.
const sequence_vectors = build_options.intrinsics and builtin.cpu.arch == .x86_64 and
    std.Target.x86.featureSetHas(builtin.cpu.features, .avx2);

/// `convertSequences_noRepcodes`: `in_seqs` as stored sequences with new
/// offsets only. Returns 0, or for the one length over 0xFFFF its index
/// plus 1, plus `in_seqs.len` for a literal length.
fn convertSequencesNoRepcodes(dst_seqs: []SeqDef, in_seqs: []const Sequence) usize {
    var long_len: usize = 0;
    var i: usize = 0;
    if (sequence_vectors) {
        // Two sequences at a time: the offset plus `rep_num`, the match
        // length less `min_match`; the lengths compared signed, as the
        // original's vectors do.
        const V = @Vector(8, u32);
        const minus_min_match = @as(u32, 0) -% min_match;
        const addition: V = .{ rep_num, 0, minus_min_match, 0, rep_num, 0, minus_min_match, 0 };
        const limit: @Vector(8, i32) = @splat(65535);
        while (i + 1 < in_seqs.len) : (i += 2) {
            const vin: V = @bitCast(std.mem.toBytes(in_seqs[i..][0..2].*));
            const vadd = vin +% addition;
            const over = @as(@Vector(8, i32), @bitCast(vadd)) > limit;
            dst_seqs[i] = .{
                .off_base = vadd[0],
                .lit_length = @truncate(vadd[1]),
                .ml_base = @truncate(vadd[2]),
            };
            dst_seqs[i + 1] = .{
                .off_base = vadd[4],
                .lit_length = @truncate(vadd[5]),
                .ml_base = @truncate(vadd[6]),
            };
            // A long length: which one.
            if (over[1] or over[2] or over[5] or over[6]) {
                for (i..i + 2) |n| {
                    if (in_seqs[n].match_length > 65535 + min_match) {
                        assert(long_len == 0);
                        long_len = n + 1;
                    }
                    if (in_seqs[n].lit_length > 65535) {
                        assert(long_len == 0);
                        long_len = n + in_seqs.len + 1;
                    }
                }
            }
        }
    }
    while (i < in_seqs.len) : (i += 1) {
        dst_seqs[i].off_base = ci.offsetToOffbase(in_seqs[i].offset);
        dst_seqs[i].lit_length = @truncate(in_seqs[i].lit_length);
        dst_seqs[i].ml_base = @truncate(in_seqs[i].match_length - min_match);
        if (in_seqs[i].match_length > 65535 + min_match) {
            assert(long_len == 0);
            long_len = i + 1;
        }
        if (in_seqs[i].lit_length > 65535) {
            assert(long_len == 0);
            long_len = i + in_seqs.len + 1;
        }
    }
    return long_len;
}

/// `ZSTD_convertBlockSequences`: stores the sequences of one block,
/// `in_seqs`, which ends with its delimiter, with their repeat offsets
/// resolved when `repcode_resolution`; the sequences are not validated.
pub fn convertBlockSequences(
    cctx: *CCtx,
    in_seqs: []const Sequence,
    repcode_resolution: bool,
) Error!void {
    // Too many sequences for the store; a larger minimum match helps.
    if (in_seqs.len >= cctx.seq_store.max_nb_seq) return error.ExternalSequencesInvalid;
    var updated_repcodes: ci.Repcodes = .{ .rep = cctx.block_state.prev_cblock.rep };

    // The caller found the block's delimiter.
    assert(in_seqs.len >= 1);
    assert(in_seqs[in_seqs.len - 1].match_length == 0);
    assert(in_seqs[in_seqs.len - 1].offset == 0);
    const nb_seqs = in_seqs.len - 1;

    if (!repcode_resolution) {
        const seq_store = &cctx.seq_store;
        const longl = convertSequencesNoRepcodes(
            seq_store.sequences_start[0..nb_seqs],
            in_seqs[0..nb_seqs],
        );
        seq_store.sequences = seq_store.sequences_start + nb_seqs;
        if (longl != 0) {
            assert(seq_store.long_length_type == .none);
            if (longl <= nb_seqs) {
                seq_store.long_length_type = .match_length;
                seq_store.long_length_pos = @intCast(longl - 1);
            } else {
                assert(longl <= 2 * nb_seqs);
                seq_store.long_length_type = .literal_length;
                seq_store.long_length_pos = @intCast(longl - nb_seqs - 1);
            }
        }
    } else {
        for (in_seqs[0..nb_seqs]) |seq| {
            const ll0: u32 = @intFromBool(seq.lit_length == 0);
            const off_base = finalizeOffBase(seq.offset, &updated_repcodes.rep, ll0);
            ci.storeSeqOnly(&cctx.seq_store, seq.lit_length, off_base, seq.match_length);
            ci.updateRep(&updated_repcodes.rep, off_base, ll0);
        }
    }

    // The repeat offsets, when the conversion skipped them.
    if (!repcode_resolution and in_seqs.len > 1) {
        const rep = &updated_repcodes.rep;
        if (in_seqs.len >= 4) {
            // The last full sequence.
            const last_seq_idx = in_seqs.len - 2;
            rep[2] = in_seqs[last_seq_idx - 2].offset;
            rep[1] = in_seqs[last_seq_idx - 1].offset;
            rep[0] = in_seqs[last_seq_idx].offset;
        } else if (in_seqs.len == 3) {
            rep[2] = rep[0];
            rep[1] = in_seqs[0].offset;
            rep[0] = in_seqs[1].offset;
        } else {
            assert(in_seqs.len == 2);
            rep[2] = rep[1];
            rep[1] = rep[0];
            rep[0] = in_seqs[0].offset;
        }
    }

    cctx.block_state.next_cblock.rep = updated_repcodes.rep;
}

/// `BlockSummary`.
pub const BlockSummary = struct {
    /// The block's sequences, its delimiter included.
    nb_sequences: usize,
    block_size: usize,
    lit_size: usize,
};

/// `ZSTD_get1BlockSummary`: the first block of `seqs`, up to the first
/// sequence without a match, its delimiter, which must be there.
pub fn get1BlockSummary(seqs: []const Sequence) Error!BlockSummary {
    var i: usize = 0;
    var l_sum: usize = 0;
    var m_sum: usize = 0;
    if (sequence_vectors) {
        // Two sequences at a time, the sums in 32-bit lanes, as the
        // original's vectors keep them.
        const V = @Vector(8, u32);
        const zero_vec: V = @splat(0);
        var sum_vec = zero_vec;
        while (i + 2 <= seqs.len) : (i += 2) {
            const data: V = @bitCast(std.mem.toBytes(seqs[i..][0..2].*));
            // The end of the block, in either.
            const is_zero = data == zero_vec;
            if (is_zero[2] or is_zero[6]) break;
            sum_vec +%= data;
        }
        l_sum = sum_vec[1] +% sum_vec[5];
        m_sum = sum_vec[2] +% sum_vec[6];
    }
    while (i < seqs.len) : (i += 1) {
        l_sum += seqs[i].lit_length;
        m_sum += seqs[i].match_length;
        if (seqs[i].match_length == 0) {
            if (!sequence_vectors) assert(seqs[i].offset == 0);
            break;
        }
    }
    // No delimiter.
    if (i == seqs.len) return error.ExternalSequencesInvalid;
    return .{ .nb_sequences = i + 1, .block_size = l_sum + m_sum, .lit_size = l_sum };
}

/// `ZSTD_compressSequencesAndLiterals_internal`: the blocks of the
/// sequences `in_seqs`, with block delimiters, and their `literals`.
/// Returns their size, headers included.
fn compressSequencesAndLiteralsInternal(
    cctx: *CCtx,
    dst: []u8,
    in_seqs_all: []const Sequence,
    literals_all: []const u8,
    src_size: usize,
) Error!usize {
    var remaining = src_size;
    var c_size: usize = 0;
    var op: usize = 0;
    var in_seqs = in_seqs_all;
    var literals = literals_all;
    const repcode_resolution = cctx.applied_params.search_for_external_repcodes == .enable;
    assert(cctx.applied_params.search_for_external_repcodes != .auto);
    const compressed: u32 = @backingInt(zstd_internal.BlockType.compressed);

    // At least the delimiter of one block.
    if (in_seqs.len == 0) return error.ExternalSequencesInvalid;

    // An empty frame: one empty raw block.
    if (in_seqs.len == 1 and in_seqs[0].lit_length == 0) {
        const c_block_header24: u32 = 1 + (@as(u32, @backingInt(zstd_internal.BlockType.raw)) << 1);
        if (dst.len < 3) return error.DstSizeTooSmall;
        writeLe24(dst, c_block_header24);
        op += block_header_size;
        c_size += block_header_size;
    }

    while (in_seqs.len != 0) {
        const block = try get1BlockSummary(in_seqs);
        const last_block: u32 = @intFromBool(block.nb_sequences == in_seqs.len);
        assert(block.nb_sequences <= in_seqs.len);
        if (block.lit_size > literals.len) return error.ExternalSequencesInvalid;
        ci.resetSeqStore(&cctx.seq_store);

        try convertBlockSequences(cctx, in_seqs[0..block.nb_sequences], repcode_resolution);
        in_seqs = in_seqs[block.nb_sequences..];
        // Wraps when the sequences cover more than `src_size`, which the
        // check at the end refuses.
        remaining -%= block.block_size;

        // A small block is still compressed: without the source, it cannot
        // be stored raw.
        if (dst.len - op < block_header_size) return error.DstSizeTooSmall;
        var compressed_seqs_size = try entropyCompressSeqStoreInternal(
            dst[op + block_header_size ..],
            literals[0..block.lit_size],
            &cctx.seq_store,
            &cctx.block_state.prev_cblock.entropy,
            &cctx.block_state.next_cblock.entropy,
            &cctx.applied_params,
            tmpWorkspace(cctx),
            cctx.bmi2,
        );
        // The format forbids a compressed block larger than a block.
        if (compressed_seqs_size > cctx.block_size_max) compressed_seqs_size = 0;
        literals = literals[block.lit_size..];

        // Nor can a block that does not compress.
        if (compressed_seqs_size == 0) return error.CannotProduceUncompressedBlock;
        assert(compressed_seqs_size > 1);
        blockStateConfirmRepcodesAndEntropyTables(&cctx.block_state);
        if (cctx.block_state.prev_cblock.entropy.fse.offcode_repeat_mode == .valid) {
            cctx.block_state.prev_cblock.entropy.fse.offcode_repeat_mode = .check;
        }
        const c_block_header: u32 = last_block + (compressed << 1) +
            @as(u32, @intCast(compressed_seqs_size << 3));
        writeLe24(dst[op..], c_block_header);
        const c_block_size = block_header_size + compressed_seqs_size;

        c_size += c_block_size;
        op += c_block_size;
        cctx.is_first_block = false;
        if (last_block != 0) {
            assert(in_seqs.len == 0);
            break;
        }
    }

    // The literals and the sequences must cover the frame exactly.
    if (literals.len != 0) return error.ExternalSequencesInvalid;
    if (remaining != 0) return error.ExternalSequencesInvalid;
    return c_size;
}

/// `ZSTD_compressSequencesAndLiterals`: compresses a frame of
/// `decompressed_size` bytes, given only as the sequences `in_seqs` (with
/// block delimiters, the parameter `block_delimiters` set so) and their
/// `literals`, one after the other. The sequences are not validated, and
/// the frame has no checksum: the content is never seen. Every block must
/// compress. `lit_capacity` is the size of the caller's literals buffer,
/// at least `literals.len`, as in the original, though the port reads
/// only `literals`.
pub fn compressSequencesAndLiterals(
    cctx: *CCtx,
    dst: []u8,
    in_seqs: []const Sequence,
    literals: []const u8,
    lit_capacity: usize,
    decompressed_size: usize,
) Error!usize {
    if (lit_capacity < literals.len) return error.WorkSpaceTooSmall;
    try cctxInitCompressStream2(cctx, .end, decompressed_size);

    if (cctx.applied_params.block_delimiters == .no_block_delimiters) {
        return error.FrameParameterUnsupported;
    }
    if (cctx.applied_params.validate_sequences) return error.ParameterUnsupported;
    if (cctx.applied_params.fparams.checksum_flag) return error.FrameParameterUnsupported;

    const frame_header_size = try writeFrameHeader(
        dst,
        &cctx.applied_params,
        decompressed_size,
        cctx.dict_id,
    );
    const c_blocks_size = try compressSequencesAndLiteralsInternal(
        cctx,
        dst[frame_header_size..],
        in_seqs,
        literals,
        decompressed_size,
    );
    return frame_header_size + c_blocks_size;
}

// ---------------------------------------------------------------------------
// The end of a stream
// ---------------------------------------------------------------------------

/// `inBuffer_forEndFlush`: the input of a flush or an end, the stable
/// input itself in that mode.
fn inBufferForEndFlush(zcs: *const CCtx) params.InBuffer {
    if (zcs.applied_params.in_buffer_mode == .stable) return zcs.expected_in_buffer;
    return .{ .src = &.{} };
}

/// `ZSTD_flushStream`: `compressStream2` with `.flush` and no more input.
/// Returns the bytes still to flush.
pub fn flushStream(zcs: *CCtx, output: *params.OutBuffer) Error!usize {
    var input = inBufferForEndFlush(zcs);
    // Nothing more is taken.
    input.src = input.src[0..input.pos];
    return compressStream2(zcs, output, &input, .flush);
}

/// `ZSTD_endStream`: `compressStream2` with `.end`, with no more input
/// but a stable input's. Returns the bytes still to write, 0 once the
/// frame is complete; for a single thread, the last block's header and the
/// checksum count when they are still to come.
pub fn endStream(zcs: *CCtx, output: *params.OutBuffer) Error!usize {
    var input = inBufferForEndFlush(zcs);
    const remaining_to_flush = try compressStream2(zcs, output, &input, .end);
    // A lower bound for several threads.
    if (zcs.applied_params.nb_workers > 0) return remaining_to_flush;
    const last_block_size: usize = if (zcs.frame_ended) 0 else block_header_size;
    const checksum_size: usize = if (zcs.frame_ended)
        0
    else
        @as(usize, @intFromBool(zcs.applied_params.fparams.checksum_flag)) * 4;
    return remaining_to_flush + last_block_size + checksum_size;
}

// ---------------------------------------------------------------------------
// Levels and their parameters
// ---------------------------------------------------------------------------

/// `ZSTD_maxCLevel`.
pub fn maxCLevel() i32 {
    return clevels.max_clevel;
}

/// `ZSTD_minCLevel`: the fastest level.
pub fn minCLevel() i32 {
    return -@as(i32, params.target_length_max);
}

/// `ZSTD_defaultCLevel`.
pub fn defaultCLevel() i32 {
    return params.clevel_default;
}

/// `ZSTD_dedicatedDictSearch_getCParams`: the parameters of a dictionary
/// for the dedicated search, whose hash table holds buckets.
fn dedicatedDictSearchGetCParams(compression_level: i32, dict_size: usize) CompressionParameters {
    var cparams = getCParamsInternal(compression_level, 0, dict_size, .create_cdict);
    switch (cparams.strategy) {
        .greedy, .lazy, .lazy2 => cparams.hash_log += lazy.lazy_ddss_bucket_log,
        else => {},
    }
    return cparams;
}

/// `ZSTD_dedicatedDictSearch_isSupported`.
fn dedicatedDictSearchIsSupported(cparams: *const CompressionParameters) bool {
    const strat = @backingInt(cparams.strategy);
    return strat >= @backingInt(Strategy.greedy) and strat <= @backingInt(Strategy.lazy2) and
        cparams.hash_log > cparams.chain_log and cparams.chain_log <= 24;
}

/// `ZSTD_dedicatedDictSearch_revertCParams`: the parameters of a context
/// using a dedicated search dictionary, whose tables do not grow.
fn dedicatedDictSearchRevertCParams(cparams: *CompressionParameters) void {
    switch (cparams.strategy) {
        .greedy, .lazy, .lazy2 => {
            cparams.hash_log -= lazy.lazy_ddss_bucket_log;
            if (cparams.hash_log < params.hash_log_min) cparams.hash_log = params.hash_log_min;
        },
        else => {},
    }
}

/// `ZSTD_getCParamRowSize`: the size that picks the parameter table.
fn getCParamRowSize(src_size_hint: u64, dict_size_in: usize, mode: ci.CParamMode) u64 {
    const dict_size: u64 = if (mode == .attach_dict) 0 else dict_size_in;
    const unknown = src_size_hint == params.content_size_unknown;
    const added_size: u64 = if (unknown and dict_size > 0) 500 else 0;
    return if (unknown and dict_size == 0)
        params.content_size_unknown
    else
        src_size_hint +% dict_size +% added_size;
}

/// `ZSTD_getCParams_internal`: the parameters of `compression_level` for a
/// source of `src_size_hint` (0 means 0, `params.content_size_unknown`
/// unknown) and a dictionary of `dict_size` (0 for none), as `mode` counts
/// the dictionary.
fn getCParamsInternal(
    compression_level: i32,
    src_size_hint: u64,
    dict_size: usize,
    mode: ci.CParamMode,
) CompressionParameters {
    const r_size = getCParamRowSize(src_size_hint, dict_size, mode);
    const table_id: usize = @as(usize, @intFromBool(r_size <= 256 * kib)) +
        @intFromBool(r_size <= 128 * kib) + @intFromBool(r_size <= 16 * kib);

    const row: usize = if (compression_level == 0)
        params.clevel_default
    else if (compression_level < 0)
        // The base of the fast levels.
        0
    else if (compression_level > clevels.max_clevel)
        clevels.max_clevel
    else
        @intCast(compression_level);

    var cp = clevels.default_cparameters[table_id][row];
    // The acceleration of the fast levels.
    if (compression_level < 0) {
        const clamped_compression_level = @max(minCLevel(), compression_level);
        cp.target_length = @intCast(-clamped_compression_level);
    }
    return adjustCParamsInternal(cp, src_size_hint, dict_size, mode, .auto);
}

/// `ZSTD_getCParams`: the parameters of `compression_level` for a source
/// of `src_size_hint` and a dictionary of `dict_size`, 0 when unknown.
pub fn getCParams(
    compression_level: i32,
    src_size_hint: u64,
    dict_size: usize,
) CompressionParameters {
    const size = if (src_size_hint == 0) params.content_size_unknown else src_size_hint;
    return getCParamsInternal(compression_level, size, dict_size, .unknown);
}

/// `ZSTD_getParams_internal`.
fn getParamsInternal(
    compression_level: i32,
    src_size_hint: u64,
    dict_size: usize,
    mode: ci.CParamMode,
) params.Parameters {
    return .{
        .cparams = getCParamsInternal(compression_level, src_size_hint, dict_size, mode),
        .fparams = .{ .content_size_flag = true, .checksum_flag = false, .no_dict_id_flag = false },
    };
}

/// `ZSTD_getParams`: as `getCParams`, with the default frame parameters.
pub fn getParams(compression_level: i32, src_size_hint: u64, dict_size: usize) params.Parameters {
    const size = if (src_size_hint == 0) params.content_size_unknown else src_size_hint;
    return getParamsInternal(compression_level, size, dict_size, .unknown);
}

/// `ZSTD_registerSequenceProducer`: the external match finder of the next
/// frames, or none; kept until the parameters are reset.
pub fn registerSequenceProducer(zc: *CCtx, producer: ?ci.SequenceProducer) void {
    cctxParamsRegisterSequenceProducer(&zc.requested_params, producer);
}

/// `ZSTD_CCtxParams_registerSequenceProducer`.
pub fn cctxParamsRegisterSequenceProducer(
    cctx_params: *CCtxParams,
    producer: ?ci.SequenceProducer,
) void {
    cctx_params.ext_seq_prod = producer;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test {
    std.testing.refAllDecls(@This());
}
