//! A Zig port of Zstandard's compressor.

const std = @import("std");

pub const params = @import("params.zig");
pub const Error = @import("error.zig").Error;
pub const ErrorCode = @import("error.zig").ErrorCode;
pub const errorCode = @import("error.zig").errorCode;

const compress_internal = @import("compress/compress_internal.zig");
const compress_impl = @import("compress/compress.zig");
const pool = @import("common/pool.zig");

/// A compression context: parameters, dictionaries, and the tables and
/// buffers of the frame in progress, in one workspace. Made by `create`
/// (freed by `destroy`) or `initStatic` over a caller's buffer. Methods:
/// parameters (`setParameter`, `getParameter`, `setPledgedSrcSize`,
/// `setParams`, `setCParams`, `setFParams`, `setParametersUsingCCtxParams`,
/// `reset`), dictionaries (`loadDictionary*`, `refCDict`, `refPrefix*`),
/// one-shot compression (`compress2` with those, `compressCCtx`,
/// `compressUsingDict`, `compressAdvanced`, `compressUsingCDict*`), and the
/// block-level API (`compressBegin*`, `compressContinue`, `compressEnd`,
/// `compressBlock`, `copy`), streaming (`compressStream2`,
/// `compressStream2SimpleArgs`, `compressStream`, `flushStream`,
/// `endStream`, `initCStream*`, `resetCStream`, `getFrameProgression`,
/// `toFlushNow`), multithreading (the `nb_workers` parameter with `setIo`
/// or `refThreadPool`), and sequences (`generateSequences`,
/// `registerSequenceProducer`, `compressSequences`,
/// `compressSequencesAndLiterals`).
///
/// Buffers the context references, not copies, and what ends the reference:
/// a dictionary loaded `by_ref` or a referenced `CDict` until it is replaced
/// or cleared (`reset` with parameters, another `loadDictionary*`,
/// `refCDict`, `refPrefix*`) or the context destroyed; a prefix until the
/// next frame is compressed; the `src` of `compressContinue` and
/// `compressBlock` until the frame ends, as later blocks may match into it;
/// the dictionary given to `compressBeginUsingDict`, `compressBeginAdvanced`
/// or `compressBeginUsingCDict*` until the frame ends, and for a context
/// made from that one by `copy`, until the copy's frame ends;
/// a static context's workspace for the context's whole life; with
/// `stable_in_buffer`, a stream's input buffer until its frame ends; a
/// thread pool and an `Io` until the context is destroyed, even after
/// another is set, as the multithreaded context made at the first frame
/// with workers keeps the ones it was made with.
pub const CCtx = compress_internal.CCtx;
/// A streaming context is a compression context (`ZSTD_CStream`).
pub const CStream = CCtx;
/// The input and the output of a streaming call, and what the call does.
pub const InBuffer = params.InBuffer;
pub const OutBuffer = params.OutBuffer;
pub const EndDirective = params.EndDirective;
/// A pool of threads that contexts can share (`CCtx.refThreadPool`).
pub const ThreadPool = pool.ThreadPool;
pub const createThreadPool = pool.createThreadPool;
pub const freeThreadPool = pool.freeThreadPool;
/// Parameters held apart from a context, applied with
/// `CCtx.setParametersUsingCCtxParams`.
pub const CCtxParams = compress_internal.CCtxParams;
/// A dictionary digested for compression, shared by any number of contexts.
pub const CDict = compress_impl.CDict;
/// An external match finder, for `CCtx.registerSequenceProducer`.
pub const SequenceProducer = compress_internal.SequenceProducer;
/// The value a `SequenceProducer` returns when it fails.
pub const sequence_producer_error = compress_internal.sequence_producer_error;

pub const compress = compress_impl.compress;
pub const compressBound = compress_impl.compressBound;
pub const minCLevel = compress_impl.minCLevel;
pub const maxCLevel = compress_impl.maxCLevel;
pub const defaultCLevel = compress_impl.defaultCLevel;
pub const getCParams = compress_impl.getCParams;
pub const getParams = compress_impl.getParams;
pub const checkCParams = compress_impl.checkCParams;
pub const adjustCParams = compress_impl.adjustCParams;
pub const cParamGetBounds = compress_impl.cParamGetBounds;
pub const estimateCCtxSize = compress_impl.estimateCCtxSize;
pub const estimateCCtxSizeUsingCParams = compress_impl.estimateCCtxSizeUsingCParams;
pub const estimateCCtxSizeUsingCCtxParams = compress_impl.estimateCCtxSizeUsingCCtxParams;
pub const estimateCStreamSize = compress_impl.estimateCStreamSize;
pub const estimateCStreamSizeUsingCParams = compress_impl.estimateCStreamSizeUsingCParams;
pub const estimateCStreamSizeUsingCCtxParams = compress_impl.estimateCStreamSizeUsingCCtxParams;
pub const estimateCDictSize = compress_impl.estimateCDictSize;
pub const estimateCDictSizeAdvanced = compress_impl.estimateCDictSizeAdvanced;
pub const writeSkippableFrame = compress_impl.writeSkippableFrame;
pub const cStreamInSize = compress_impl.cStreamInSize;
pub const cStreamOutSize = compress_impl.cStreamOutSize;
pub const sequenceBound = compress_impl.sequenceBound;
pub const mergeBlockDelimiters = compress_impl.mergeBlockDelimiters;

/// The compressor's parts, public for the oracle tests and the benchmark.
pub const internal = struct {
    pub const compress_internal = @import("compress/compress_internal.zig");
    pub const cwksp = @import("compress/cwksp.zig");
    pub const clevels = @import("compress/clevels.zig");
    pub const fast = @import("compress/fast.zig");
    pub const double_fast = @import("compress/double_fast.zig");
    pub const bitstream = @import("common/bitstream.zig");
    pub const entropy_common = @import("common/entropy_common.zig");
    pub const fse = @import("common/fse.zig");
    pub const huf = @import("common/huf.zig");
    pub const fse_compress = @import("compress/fse_compress.zig");
    pub const hist = @import("compress/hist.zig");
    pub const huf_compress = @import("compress/huf_compress.zig");
    pub const zstd_internal = @import("common/zstd_internal.zig");
    pub const pool = @import("common/pool.zig");
    pub const zstdmt = @import("compress/zstdmt.zig");
    pub const compress_literals = @import("compress/compress_literals.zig");
    pub const compress_sequences = @import("compress/compress_sequences.zig");
    pub const ldm = @import("compress/ldm.zig");
    pub const opt = @import("compress/opt.zig");
    pub const lazy = @import("compress/lazy.zig");
    pub const compress = @import("compress/compress.zig");
    pub const compress_superblock = @import("compress/compress_superblock.zig");
    pub const pre_split = @import("compress/pre_split.zig");
};

test {
    std.testing.refAllDecls(@This());
    _ = @import("common/fse.zig");
    _ = @import("common/huf.zig");
    _ = @import("common/zstd_internal.zig");
    _ = @import("common/pool.zig");
    _ = @import("compress/zstdmt.zig");
    _ = @import("compress/compress_internal.zig");
    _ = @import("compress/cwksp.zig");
    _ = @import("compress/clevels.zig");
    _ = @import("compress/fast.zig");
    _ = @import("compress/double_fast.zig");
    _ = @import("common/bitstream.zig");
    _ = @import("common/entropy_common.zig");
    _ = @import("compress/fse_compress.zig");
    _ = @import("compress/hist.zig");
    _ = @import("compress/huf_compress.zig");
    _ = @import("compress/compress_literals.zig");
    _ = @import("compress/compress_sequences.zig");
    _ = @import("compress/ldm.zig");
    _ = @import("compress/opt.zig");
    _ = @import("compress/lazy.zig");
    _ = @import("compress/compress.zig");
    _ = @import("compress/compress_superblock.zig");
    _ = @import("compress/pre_split.zig");
}
