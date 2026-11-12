//! Multithreaded compression, from the original's zstdmt_compress.c: the
//! input is cut into jobs, each compressed by a worker of a thread pool with
//! its own context, as a run of blocks of one frame. Each job but the first
//! starts with the end of the previous job's input as a prefix (the
//! overlap), and the jobs' outputs are written in order.
//!
//! The output depends only on the input, the parameters and the order of
//! the calls: where jobs start and end follows the job size, the caller's
//! flushes and, with `rsyncable`, the content; the long distance matcher and
//! the checksum see the jobs one after the other, in order. The threads'
//! timing only changes when output becomes available.
//!
//! Without `build_options.multithread`, as the original without
//! `ZSTD_MULTITHREAD`, `createCCtxAdvanced` returns null and the rest is not
//! compiled.

const std = @import("std");
const build_options = @import("build_options");

const params = @import("../params.zig");
const Error = @import("../error.zig").Error;
const zstd_internal = @import("../common/zstd_internal.zig");
const pool = @import("../common/pool.zig");
const ci = @import("compress_internal.zig");
const compress = @import("compress.zig");
const ldm = @import("ldm.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const CCtx = ci.CCtx;
const CCtxParams = ci.CCtxParams;
const CDict = compress.CDict;
const RawSeq = ci.RawSeq;
const RawSeqStore = ci.RawSeqStore;
const Window = ci.Window;
const ThreadPool = pool.ThreadPool;
const kib = 1 << 10;
const mib = 1 << 20;

/// `ZSTDMT_NBWORKERS_MAX`: the most workers a context takes.
pub const nbworkers_max: u32 = if (@sizeOf(usize) == 4) 64 else 256;
/// `ZSTDMT_JOBSIZE_MIN`: the smallest job size that can be set; a frame
/// pledged no larger is compressed in one thread.
pub const jobsize_min: usize = 512 * kib;
/// `ZSTDMT_JOBLOG_MAX`.
pub const joblog_max: u32 = if (@sizeOf(usize) == 4) 29 else 30;
/// `ZSTDMT_JOBSIZE_MAX`.
pub const jobsize_max: usize = if (@sizeOf(usize) == 4) 512 * mib else 1024 * mib;

/// The original's `ZSTDMT_CCtx`: a multithreaded compression context.
pub const ZstdmtCCtx = if (build_options.multithread) MtCCtx else opaque {};

/// `ZSTDMT_createCCtx_advanced`: a context for `nb_workers` workers (at
/// most `nbworkers_max`), running them on `thread_pool` when given, which
/// must then outlive the context, or else on a pool of its own. Null when
/// `nb_workers` is 0, memory or threads could not be had, or the library is
/// built without multithreading.
pub fn createCCtxAdvanced(
    nb_workers: u32,
    gpa: Allocator,
    io: Io,
    thread_pool: ?*ThreadPool,
) ?*ZstdmtCCtx {
    if (build_options.multithread) return MtCCtx.create(nb_workers, gpa, io, thread_pool);
    return null;
}

// ---------------------------------------------------------------------------
// The buffer pool
// ---------------------------------------------------------------------------

/// `buffer_s`: a buffer of the pool, or a section of the round buffer.
/// `start` is null for no buffer.
const Buffer = struct {
    start: ?[*]u8 = null,
    capacity: usize = 0,
};

/// The pool's buffers are aligned for the sequences the sequence pool keeps
/// in them.
const buffer_alignment = 8;

/// `g_nullBuffer`.
const null_buffer: Buffer = .{};

/// Frees a buffer of the pool.
fn freeBuffer(gpa: Allocator, buffer: Buffer) void {
    const start = buffer.start orelse return;
    const aligned: [*]align(buffer_alignment) u8 = @alignCast(start);
    gpa.free(aligned[0..buffer.capacity]);
}

/// `ZSTDMT_bufferPool`: buffers kept for reuse, shared by the context and
/// its workers.
const BufferPool = struct {
    pool_mutex: Io.Mutex,
    buffer_size: usize,
    total_buffers: u32,
    nb_buffers: u32,
    gpa: Allocator,
    io: Io,
    buffers: []Buffer,

    /// `ZSTDMT_createBufferPool`.
    fn create(gpa: Allocator, io: Io, max_nb_buffers: u32) ?*BufferPool {
        const buf_pool = gpa.create(BufferPool) catch return null;
        const buffers = gpa.alloc(Buffer, max_nb_buffers) catch {
            gpa.destroy(buf_pool);
            return null;
        };
        @memset(buffers, null_buffer);
        buf_pool.* = .{
            .pool_mutex = .init,
            .buffer_size = 64 * kib,
            .total_buffers = max_nb_buffers,
            .nb_buffers = 0,
            .gpa = gpa,
            .io = io,
            .buffers = buffers,
        };
        return buf_pool;
    }

    /// `ZSTDMT_freeBufferPool`.
    fn free(buf_pool: ?*BufferPool) void {
        const p = buf_pool orelse return;
        for (p.buffers) |buffer| freeBuffer(p.gpa, buffer);
        p.gpa.free(p.buffers);
        p.gpa.destroy(p);
    }

    /// `ZSTDMT_sizeof_bufferPool`: right only between compressions.
    fn sizeof(buf_pool: *BufferPool) usize {
        const pool_size = @sizeOf(c_layout.BufferPool);
        const array_size = buf_pool.total_buffers * @sizeOf(c_layout.Buffer);
        var total_buffer_size: usize = 0;
        buf_pool.pool_mutex.lockUncancelable(buf_pool.io);
        for (buf_pool.buffers) |buffer| total_buffer_size += buffer.capacity;
        buf_pool.pool_mutex.unlock(buf_pool.io);
        return pool_size + array_size + total_buffer_size;
    }

    /// `ZSTDMT_setBufferSize`: the size of every buffer from now on, at
    /// least. Buffers of one size are interchangeable, which saves
    /// allocations.
    fn setBufferSize(buf_pool: *BufferPool, b_size: usize) void {
        buf_pool.pool_mutex.lockUncancelable(buf_pool.io);
        buf_pool.buffer_size = b_size;
        buf_pool.pool_mutex.unlock(buf_pool.io);
    }

    /// `ZSTDMT_expandBufferPool`: `src_buf_pool` if it holds
    /// `max_nb_buffers` buffers, else a larger, empty one with its buffer
    /// size. `src_buf_pool` is freed then; null when the new one could not
    /// be had.
    fn expand(src_buf_pool: ?*BufferPool, max_nb_buffers: u32) ?*BufferPool {
        const src = src_buf_pool orelse return null;
        if (src.total_buffers >= max_nb_buffers) return src;
        const gpa = src.gpa;
        const io = src.io;
        const b_size = src.buffer_size;
        free(src);
        const new_buf_pool = create(gpa, io, max_nb_buffers) orelse return null;
        new_buf_pool.setBufferSize(b_size);
        return new_buf_pool;
    }

    /// `ZSTDMT_getBuffer`: a buffer of the pool's size; its start is null
    /// when it could not be allocated.
    fn getBuffer(buf_pool: *BufferPool) Buffer {
        const b_size = buf_pool.buffer_size;
        buf_pool.pool_mutex.lockUncancelable(buf_pool.io);
        if (buf_pool.nb_buffers != 0) {
            buf_pool.nb_buffers -= 1;
            const buf = buf_pool.buffers[buf_pool.nb_buffers];
            const avail_buffer_size = buf.capacity;
            buf_pool.buffers[buf_pool.nb_buffers] = null_buffer;
            // Large enough, but not too large.
            if (avail_buffer_size >= b_size and (avail_buffer_size >> 3) <= b_size) {
                buf_pool.pool_mutex.unlock(buf_pool.io);
                return buf;
            }
            freeBuffer(buf_pool.gpa, buf);
        }
        buf_pool.pool_mutex.unlock(buf_pool.io);
        const start = buf_pool.gpa.alignedAlloc(u8, .fromByteUnits(buffer_alignment), b_size) catch
            return null_buffer;
        return .{ .start = start.ptr, .capacity = b_size };
    }

    /// `ZSTDMT_releaseBuffer`: keeps `buf` for reuse, or frees it when the
    /// pool is full.
    fn releaseBuffer(buf_pool: *BufferPool, buf: Buffer) void {
        if (buf.start == null) return;
        buf_pool.pool_mutex.lockUncancelable(buf_pool.io);
        if (buf_pool.nb_buffers < buf_pool.total_buffers) {
            buf_pool.buffers[buf_pool.nb_buffers] = buf;
            buf_pool.nb_buffers += 1;
            buf_pool.pool_mutex.unlock(buf_pool.io);
            return;
        }
        buf_pool.pool_mutex.unlock(buf_pool.io);
        freeBuffer(buf_pool.gpa, buf);
    }
};

/// `BUF_POOL_MAX_NB_BUFFERS`: two output buffers per worker, since one is
/// flushed after its job ends; one for the input being loaded, one for the
/// next input while a job is handed over, and one stuck in the queue.
fn bufPoolMaxNbBuffers(nb_workers: u32) u32 {
    return 2 * nb_workers + 3;
}

/// `SEQ_POOL_MAX_NB_BUFFERS`: a worker's sequences are free for reuse as
/// soon as it releases them, so one buffer per worker.
fn seqPoolMaxNbBuffers(nb_workers: u32) u32 {
    return nb_workers;
}

// ---------------------------------------------------------------------------
// The sequence pool: buffers of long distance matches
// ---------------------------------------------------------------------------

/// `ZSTDMT_seqPool`.
const SeqPool = BufferPool;

/// `bufferToSeq`.
fn bufferToSeq(buffer: Buffer) RawSeqStore {
    var seq = ci.null_raw_seq_store;
    seq.seq = if (buffer.start) |start| @ptrCast(@alignCast(start)) else null;
    seq.capacity = buffer.capacity / @sizeOf(RawSeq);
    return seq;
}

/// `seqToBuffer`.
fn seqToBuffer(seq: RawSeqStore) Buffer {
    return .{
        .start = if (seq.seq) |s| @ptrCast(s) else null,
        .capacity = seq.capacity * @sizeOf(RawSeq),
    };
}

/// `ZSTDMT_getSeq`: an empty store, without a buffer when long distance
/// matching is off.
fn getSeq(seq_pool: *SeqPool) RawSeqStore {
    if (seq_pool.buffer_size == 0) return ci.null_raw_seq_store;
    return bufferToSeq(seq_pool.getBuffer());
}

/// `ZSTDMT_releaseSeq`.
fn releaseSeq(seq_pool: *SeqPool, seq: RawSeqStore) void {
    seq_pool.releaseBuffer(seqToBuffer(seq));
}

/// `ZSTDMT_setNbSeq`.
fn setNbSeq(seq_pool: *SeqPool, nb_seq: usize) void {
    seq_pool.setBufferSize(nb_seq * @sizeOf(RawSeq));
}

/// `ZSTDMT_createSeqPool`.
fn createSeqPool(gpa: Allocator, io: Io, nb_workers: u32) ?*SeqPool {
    const seq_pool = BufferPool.create(gpa, io, seqPoolMaxNbBuffers(nb_workers)) orelse return null;
    setNbSeq(seq_pool, 0);
    return seq_pool;
}

/// `ZSTDMT_expandSeqPool`.
fn expandSeqPool(seq_pool: ?*SeqPool, nb_workers: u32) ?*SeqPool {
    return BufferPool.expand(seq_pool, seqPoolMaxNbBuffers(nb_workers));
}

// ---------------------------------------------------------------------------
// The context pool
// ---------------------------------------------------------------------------

/// `ZSTDMT_CCtxPool`: the workers' contexts, kept for reuse and shared by
/// the context and its workers. Every context borrowed must be back before
/// the pool is freed.
const CCtxPool = struct {
    pool_mutex: Io.Mutex,
    total_cctx: u32,
    avail_cctx: u32,
    gpa: Allocator,
    io: Io,
    cctxs: []?*CCtx,

    /// `ZSTDMT_freeCCtxPool`.
    fn free(cctx_pool: ?*CCtxPool) void {
        const p = cctx_pool orelse return;
        for (p.cctxs) |cctx| {
            if (cctx) |c| compress.freeCCtx(c) catch unreachable;
        }
        p.gpa.free(p.cctxs);
        p.gpa.destroy(p);
    }

    /// `ZSTDMT_createCCtxPool`: a pool for `nb_workers` contexts, with one
    /// made, for a single thread.
    fn create(gpa: Allocator, io: Io, nb_workers: u32) ?*CCtxPool {
        assert(nb_workers > 0);
        const cctx_pool = gpa.create(CCtxPool) catch return null;
        const cctxs = gpa.alloc(?*CCtx, nb_workers) catch {
            gpa.destroy(cctx_pool);
            return null;
        };
        @memset(cctxs, null);
        cctx_pool.* = .{
            .pool_mutex = .init,
            .total_cctx = nb_workers,
            .avail_cctx = 0,
            .gpa = gpa,
            .io = io,
            .cctxs = cctxs,
        };
        cctxs[0] = compress.createCCtx(gpa) catch {
            free(cctx_pool);
            return null;
        };
        cctx_pool.avail_cctx = 1;
        return cctx_pool;
    }

    /// `ZSTDMT_expandCCtxPool`: `src_pool` if it has room for `nb_workers`
    /// contexts, else a new pool; `src_pool` is freed then.
    fn expand(src_pool: ?*CCtxPool, nb_workers: u32) ?*CCtxPool {
        const src = src_pool orelse return null;
        if (nb_workers <= src.total_cctx) return src;
        const gpa = src.gpa;
        const io = src.io;
        free(src);
        return create(gpa, io, nb_workers);
    }

    /// `ZSTDMT_sizeof_CCtxPool`: right only between compressions.
    fn sizeof(cctx_pool: *CCtxPool) usize {
        cctx_pool.pool_mutex.lockUncancelable(cctx_pool.io);
        defer cctx_pool.pool_mutex.unlock(cctx_pool.io);
        const pool_size = @sizeOf(c_layout.CCtxPool);
        const array_size = cctx_pool.total_cctx * @sizeOf(c_layout.Ptr);
        var total_cctx_size: usize = 0;
        for (cctx_pool.cctxs) |cctx| {
            if (cctx) |c| total_cctx_size += compress.sizeofCCtx(c);
        }
        return pool_size + array_size + total_cctx_size;
    }

    /// `ZSTDMT_getCCtx`: a kept context, or a new one; null when it could
    /// not be made.
    fn getCCtx(cctx_pool: *CCtxPool) ?*CCtx {
        cctx_pool.pool_mutex.lockUncancelable(cctx_pool.io);
        if (cctx_pool.avail_cctx != 0) {
            cctx_pool.avail_cctx -= 1;
            const cctx = cctx_pool.cctxs[cctx_pool.avail_cctx];
            cctx_pool.pool_mutex.unlock(cctx_pool.io);
            return cctx;
        }
        cctx_pool.pool_mutex.unlock(cctx_pool.io);
        return compress.createCCtx(cctx_pool.gpa) catch null;
    }

    /// `ZSTDMT_releaseCCtx`: keeps `cctx` for reuse, or frees it when the
    /// pool is full.
    fn releaseCCtx(cctx_pool: *CCtxPool, cctx: ?*CCtx) void {
        const c = cctx orelse return;
        cctx_pool.pool_mutex.lockUncancelable(cctx_pool.io);
        defer cctx_pool.pool_mutex.unlock(cctx_pool.io);
        if (cctx_pool.avail_cctx < cctx_pool.total_cctx) {
            cctx_pool.cctxs[cctx_pool.avail_cctx] = c;
            cctx_pool.avail_cctx += 1;
        } else {
            compress.freeCCtx(c) catch unreachable;
        }
    }
};

// ---------------------------------------------------------------------------
// The serial state: what the jobs do one after the other
// ---------------------------------------------------------------------------

/// `Range`: bytes the context or a job reads, in the round buffer, or the
/// caller's dictionary, valid until the job that reads them has ended.
const Range = struct {
    start: ?[*]const u8 = null,
    size: usize = 0,

    fn slice(range: Range) []const u8 {
        const start = range.start orelse return &.{};
        return start[0..range.size];
    }
};

/// `kNullRange`.
const null_range: Range = .{};

/// `SerialState`: long distance matching and the checksum, which see the
/// jobs' inputs in order. Every field is guarded by `mutex`.
const SerialState = struct {
    mutex: Io.Mutex,
    cond: Io.Condition,
    params: CCtxParams,
    ldm_state: ci.LdmState,
    xxh_state: std.hash.XxHash64,
    next_job_id: u32,
    /// Guards `ldm_window`; taken after `mutex` when both are.
    ldm_window_mutex: Io.Mutex,
    /// Signaled when `ldm_window` changes.
    ldm_window_cond: Io.Condition,
    /// A copy of `ldm_state.window` for the context, which waits until
    /// the window no longer covers the buffer it wants to fill.
    ldm_window: Window,
    /// The long distance matcher's tables, which `ldm_state` points into;
    /// empty until first needed.
    ldm_hash_table: []ci.LdmEntry,
    ldm_bucket_offsets: []u8,
    gpa: Allocator,
    io: Io,

    /// `ZSTDMT_serialState_init`.
    fn init(gpa: Allocator, io: Io) SerialState {
        return .{
            .mutex = .init,
            .cond = .init,
            .params = .{},
            .ldm_state = .{},
            .xxh_state = .init(0),
            .next_job_id = 0,
            .ldm_window_mutex = .init,
            .ldm_window_cond = .init,
            .ldm_window = undefined,
            .ldm_hash_table = &.{},
            .ldm_bucket_offsets = &.{},
            .gpa = gpa,
            .io = io,
        };
    }

    /// `ZSTDMT_serialState_free`.
    fn free(serial: *SerialState) void {
        serial.gpa.free(serial.ldm_hash_table);
        serial.gpa.free(serial.ldm_bucket_offsets);
    }

    /// `ZSTDMT_serialState_reset`: readies the state for a frame of jobs of
    /// at most `job_size` bytes, loading a raw content dictionary into the
    /// long distance matcher. `dict` is the caller's, valid until the frame
    /// ends.
    fn reset(
        serial: *SerialState,
        seq_pool: *SeqPool,
        cctx_params_in: CCtxParams,
        job_size: usize,
        dict: ?[]const u8,
        dict_content_type: params.DictContentType,
    ) Error!void {
        var cctx_params = cctx_params_in;
        if (cctx_params.ldm_params.enable_ldm == .enable) {
            ldm.adjustParameters(&cctx_params.ldm_params, &cctx_params.cparams);
            assert(cctx_params.ldm_params.hash_log >= cctx_params.ldm_params.bucket_size_log);
            assert(cctx_params.ldm_params.hash_rate_log < 32);
        } else {
            cctx_params.ldm_params = std.mem.zeroes(ci.LdmParams);
        }
        serial.next_job_id = 0;
        if (cctx_params.fparams.checksum_flag) serial.xxh_state = .init(0);
        if (cctx_params.ldm_params.enable_ldm == .enable) {
            const gpa = serial.gpa;
            const hash_log = cctx_params.ldm_params.hash_log;
            const hash_size = @as(usize, 1) << @intCast(hash_log);
            const bucket_log = hash_log - cctx_params.ldm_params.bucket_size_log;
            const prev_bucket_log = serial.params.ldm_params.hash_log -%
                serial.params.ldm_params.bucket_size_log;
            const num_buckets = @as(usize, 1) << @intCast(bucket_log);
            // The sequence buffers.
            setNbSeq(seq_pool, ldm.getMaxNbSeq(cctx_params.ldm_params, job_size));
            Window.init(&serial.ldm_state.window);
            // The tables, larger if need be.
            if (serial.ldm_hash_table.len == 0 or serial.params.ldm_params.hash_log < hash_log) {
                gpa.free(serial.ldm_hash_table);
                serial.ldm_hash_table = &.{};
                serial.ldm_hash_table = gpa.alloc(ci.LdmEntry, hash_size) catch &.{};
            }
            if (serial.ldm_bucket_offsets.len == 0 or prev_bucket_log < bucket_log) {
                gpa.free(serial.ldm_bucket_offsets);
                serial.ldm_bucket_offsets = &.{};
                serial.ldm_bucket_offsets = gpa.alloc(u8, num_buckets) catch &.{};
            }
            if (serial.ldm_hash_table.len == 0 or serial.ldm_bucket_offsets.len == 0) {
                return error.MemoryAllocation;
            }
            @memset(serial.ldm_hash_table[0..hash_size], .{ .offset = 0, .checksum = 0 });
            @memset(serial.ldm_bucket_offsets[0..num_buckets], 0);
            serial.ldm_state.hash_table = serial.ldm_hash_table.ptr;
            serial.ldm_state.bucket_offsets = serial.ldm_bucket_offsets.ptr;

            // The window and the hash table, from the dictionary.
            serial.ldm_state.loaded_dict_end = 0;
            if (dict) |d| {
                // Other dictionaries are not loaded.
                if (d.len > 0 and dict_content_type == .raw_content) {
                    _ = serial.ldm_state.window.update(d, false);
                    ldm.fillHashTable(&serial.ldm_state, d, &cctx_params.ldm_params);
                    const dict_end = @intFromPtr(d.ptr) + d.len;
                    serial.ldm_state.loaded_dict_end = if (cctx_params.force_window)
                        0
                    else
                        @intCast(dict_end -% @intFromPtr(serial.ldm_state.window.base));
                }
            }

            serial.ldm_window = serial.ldm_state.window;
        }

        serial.params = cctx_params;
        serial.params.job_size = @as(u32, @truncate(job_size));
    }

    /// `ZSTDMT_serialState_genSequences`: waits for job `job_id`'s turn,
    /// then finds its long distance matches and adds its input to the
    /// checksum, unless a later job failed and skipped it.
    fn genSequences(serial: *SerialState, seq_store: *RawSeqStore, src: Range, job_id: u32) void {
        const io = serial.io;
        serial.mutex.lockUncancelable(io);
        while (serial.next_job_id < job_id) serial.cond.waitUncancelable(io, &serial.mutex);
        if (serial.next_job_id == job_id) {
            if (serial.params.ldm_params.enable_ldm == .enable) {
                assert(seq_store.seq != null and seq_store.pos == 0 and
                    seq_store.size == 0 and seq_store.capacity > 0);
                assert(src.size <= serial.params.job_size);
                _ = serial.ldm_state.window.update(src.slice(), false);
                // The buffer is large enough for every match.
                ldm.generateSequences(
                    &serial.ldm_state,
                    seq_store,
                    &serial.params.ldm_params,
                    src.slice(),
                ) catch unreachable;
                // The context may wait for the window to move on.
                serial.ldm_window_mutex.lockUncancelable(io);
                serial.ldm_window = serial.ldm_state.window;
                serial.ldm_window_cond.signal(io);
                serial.ldm_window_mutex.unlock(io);
            }
            if (serial.params.fparams.checksum_flag and src.size > 0) {
                serial.xxh_state.update(src.slice());
            }
        }
        // The next job's turn.
        serial.next_job_id += 1;
        serial.cond.broadcast(io);
        serial.mutex.unlock(io);
    }

    /// `ZSTDMT_serialState_applySequences`: hands the job's long distance
    /// matches to its context, which must be started.
    fn applySequences(serial: *const SerialState, job_cctx: *CCtx, seq_store: *const RawSeqStore) void {
        if (seq_store.size > 0) {
            assert(serial.params.ldm_params.enable_ldm == .enable);
            compress.referenceExternalSequences(job_cctx, seq_store.seq, seq_store.size);
        }
    }

    /// `ZSTDMT_serialState_ensureFinished`: a job that failed before its
    /// turn gives the turn on, and empties the window the context waits on.
    fn ensureFinished(serial: *SerialState, job_id: u32, failed: bool) void {
        const io = serial.io;
        serial.mutex.lockUncancelable(io);
        if (serial.next_job_id <= job_id) {
            assert(failed);
            serial.next_job_id = job_id + 1;
            serial.cond.broadcast(io);

            serial.ldm_window_mutex.lockUncancelable(io);
            serial.ldm_window.clear();
            serial.ldm_window_cond.signal(io);
            serial.ldm_window_mutex.unlock(io);
        }
        serial.mutex.unlock(io);
    }
};

// ---------------------------------------------------------------------------
// The worker
// ---------------------------------------------------------------------------

/// `ZSTDMT_jobDescription`. The context sets every field before handing
/// the job over; then `consumed`, `c_size` and `c_error` are shared,
/// guarded by `job_mutex`, the worker sets `dst_buff`, and only the
/// context touches `dst_flushed` and `frame_checksum_needed`.
const JobDescription = struct {
    /// The input compressed so far; equal to `src.size` once the job ends.
    consumed: usize = 0,
    /// The output written so far.
    c_size: usize = 0,
    /// The job's failure, in place of the original's error code in `cSize`.
    c_error: ?Error = null,
    job_mutex: Io.Mutex = .init,
    /// Signaled when output is written and when the job ends.
    job_cond: Io.Condition = .init,
    cctx_pool: ?*CCtxPool = null,
    buf_pool: ?*BufferPool = null,
    seq_pool: ?*SeqPool = null,
    serial: ?*SerialState = null,
    io: Io = undefined,
    /// The output, from the buffer pool.
    dst_buff: Buffer = .{},
    /// The end of the previous input, or a raw content dictionary, which
    /// the job's input may refer to.
    prefix: Range = .{},
    src: Range = .{},
    job_id: u32 = 0,
    first_job: bool = false,
    last_job: bool = false,
    params: CCtxParams = .{},
    /// The dictionary, for the first job only; valid until the frame ends.
    cdict: ?*const CDict = null,
    full_frame_size: u64 = 0,
    dst_flushed: usize = 0,
    frame_checksum_needed: bool = false,

    fn failed(job: *const JobDescription) bool {
        return job.c_error != null;
    }
};

/// `ZSTDMT_compressionJob`: compresses one job, a pool function.
fn compressionJob(context: ?*anyopaque) void {
    const job: *JobDescription = @ptrCast(@alignCast(context.?));
    const io = job.io;
    const cctx = job.cctx_pool.?.getCCtx();
    var raw_seq_store = getSeq(job.seq_pool.?);

    const last_cblock_size = compressJobBlocks(job, cctx, &raw_seq_store) catch |err| blk: {
        job.job_mutex.lockUncancelable(io);
        job.c_error = err;
        job.job_mutex.unlock(io);
        break :blk 0;
    };

    job.serial.?.ensureFinished(job.job_id, job.failed());
    releaseSeq(job.seq_pool.?, raw_seq_store);
    job.cctx_pool.?.releaseCCtx(cctx);
    job.job_mutex.lockUncancelable(io);
    assert(!job.failed() or last_cblock_size == 0);
    job.c_size += last_cblock_size;
    // The job is done once all its input is consumed.
    job.consumed = job.src.size;
    job.job_cond.signal(io);
    job.job_mutex.unlock(io);
}

/// The body of `compressionJob`: returns the size of the last chunk's
/// blocks, which the caller adds to the job's output once the job is done
/// with its resources.
fn compressJobBlocks(job: *JobDescription, cctx_or_null: ?*CCtx, raw_seq_store: *RawSeqStore) Error!usize {
    const io = job.io;
    // Copied, as `job.params` must not change.
    var job_params = job.params;
    var dst_buff = job.dst_buff;

    const cctx = cctx_or_null orelse return error.MemoryAllocation;
    if (dst_buff.start == null) {
        // A streaming job: the output buffer comes from the pool.
        dst_buff = job.buf_pool.?.getBuffer();
        if (dst_buff.start == null) return error.MemoryAllocation;
        // Read by the context when it flushes the whole job.
        job.dst_buff = dst_buff;
    }
    if (job_params.ldm_params.enable_ldm == .enable and raw_seq_store.seq == null) {
        return error.MemoryAllocation;
    }

    // The checksum is computed outside the jobs, but the first job's frame
    // header announces it.
    if (job.job_id != 0) job_params.fparams.checksum_flag = false;
    // Long distance matching is done outside the jobs too.
    job_params.ldm_params.enable_ldm = .disable;
    job_params.nb_workers = 0;

    // The serial step, as early as possible.
    job.serial.?.genSequences(raw_seq_store, job.src, job.job_id);

    if (job.cdict) |cdict| {
        // Only the first job has the dictionary.
        assert(job.first_job);
        try compress.compressBeginAdvancedInternal(
            cctx,
            null,
            .auto,
            .fast,
            cdict,
            &job_params,
            job.full_frame_size,
        );
    } else {
        const pledged_src_size: u64 = if (job.first_job) job.full_frame_size else job.src.size;
        _ = try compress.cctxParamsSetParameter(
            &job_params,
            .force_max_window,
            @intFromBool(!job.first_job),
        );
        if (!job.first_job) {
            _ = try compress.cctxParamsSetParameter(&job_params, .deterministic_ref_prefix, 0);
        }
        try compress.compressBeginAdvancedInternal(
            cctx,
            if (job.prefix.start) |start| start[0..job.prefix.size] else null,
            .raw_content,
            .fast,
            null,
            &job_params,
            pledged_src_size,
        );
    }

    // External sequences only after the context is started.
    job.serial.?.applySequences(cctx, raw_seq_store);

    const ostart = dst_buff.start.?;
    const oend = ostart + dst_buff.capacity;
    if (!job.first_job) {
        // The frame header is written, then overwritten: only the first
        // job's is kept.
        _ = try compress.compressContinue(cctx, ostart[0..dst_buff.capacity], job.src.slice()[0..0]);
        compress.invalidateRepCodes(cctx);
    }

    // The job in chunks of several blocks, so that output is ready sooner.
    const chunk_size: usize = 4 * params.block_size_max;
    comptime assert(std.math.isPowerOfTwo(chunk_size));
    const nb_chunks: usize = (job.src.size + (chunk_size - 1)) / chunk_size;
    const src = job.src.slice();
    var ip: usize = 0;
    var op = ostart;
    assert(job.c_size == 0);
    var chunk_nb: usize = 1;
    while (chunk_nb < nb_chunks) : (chunk_nb += 1) {
        const c_size = try compress.compressContinue(
            cctx,
            op[0 .. @intFromPtr(oend) - @intFromPtr(op)],
            src[ip..][0..chunk_size],
        );
        ip += chunk_size;
        op += c_size;
        assert(@intFromPtr(op) < @intFromPtr(oend));
        // Progress, for the flush.
        job.job_mutex.lockUncancelable(io);
        job.c_size += c_size;
        job.consumed = chunk_size * chunk_nb;
        job.job_cond.signal(io);
        job.job_mutex.unlock(io);
    }

    var last_cblock_size: usize = 0;
    // The last job must end the frame, even when empty.
    if (nb_chunks > 0 or job.last_job) {
        const last_block_size1 = job.src.size & (chunk_size - 1);
        const last_block_size = if (last_block_size1 == 0 and job.src.size >= chunk_size)
            chunk_size
        else
            last_block_size1;
        const dst = op[0 .. @intFromPtr(oend) - @intFromPtr(op)];
        const last = src[ip..][0..last_block_size];
        last_cblock_size = if (job.last_job)
            try compress.compressEnd(cctx, dst, last)
        else
            try compress.compressContinue(cctx, dst, last);
    }
    // Repeat codes are invalidated only without an external dictionary.
    if (!job.first_job) assert(!cctx.block_state.match_state.window.hasExtDict());
    return last_cblock_size;
}

// ---------------------------------------------------------------------------
// The context
// ---------------------------------------------------------------------------

/// `InBuff_t`: the input being gathered for the next job.
const InBuff = struct {
    /// What the next job may refer to: the end of the previous job's input
    /// or the caller's raw content dictionary, never written to.
    prefix: Range = .{},
    /// The part of the round buffer being filled.
    buffer: Buffer = .{},
    filled: usize = 0,
};

/// `RoundBuff_t`: the input of every job, in turn, in one buffer. Jobs read
/// their pieces of it; `tryGetInputRange` hands out the next piece once no
/// job uses it any more.
const RoundBuff = struct {
    buffer: ?[*]u8 = null,
    capacity: usize = 0,
    /// Where `InBuff.buffer` is, moved past it when the job is handed over;
    /// at most `capacity`.
    pos: usize = 0,
};

/// `kNullRoundBuff`.
const null_round_buff: RoundBuff = .{};

/// `RSYNC_LENGTH`: the bytes the rolling hash covers.
const rsync_length = 32;
/// `RSYNC_MIN_BLOCK_LOG`: no job shorter than a block, which keeps the ratio
/// and keeps the output within `compressBound`.
const rsync_min_block_log = params.block_size_log_max;
const rsync_min_block_size = 1 << rsync_min_block_log;

/// `RSyncState_t`.
const RSyncState = struct {
    hash: u64 = 0,
    hit_mask: u64 = 0,
    prime_power: u64 = 0,
};

/// `ZSTDMT_CCtx_s`.
const MtCCtx = struct {
    factory: ?*ThreadPool,
    /// The jobs, `job_id_mask + 1` of them, a power of 2; a job's id is its
    /// number in the frame, and its slot the id's low bits.
    jobs: []JobDescription,
    buf_pool: ?*BufferPool,
    cctx_pool: ?*CCtxPool,
    seq_pool: ?*SeqPool,
    params: CCtxParams,
    target_section_size: usize,
    target_prefix_size: usize,
    /// A job is prepared, but no worker was free for it: no new job until
    /// it is handed over.
    job_ready: bool,
    in_buff: InBuff,
    round_buff: RoundBuff,
    serial: SerialState,
    rsync: RSyncState,
    job_id_mask: u32,
    done_job_id: u32,
    next_job_id: u32,
    frame_ended: bool,
    all_jobs_completed: bool,
    frame_content_size: u64,
    consumed: u64,
    produced: u64,
    gpa: Allocator,
    io: Io,
    /// A dictionary the context made, for a dictionary passed as bytes.
    cdict_local: ?*CDict,
    /// The frame's dictionary: `cdict_local` or the caller's, valid until
    /// the frame ends.
    cdict: ?*const CDict,
    /// Whether `factory` is the caller's.
    provided_factory: bool,

    /// `ZSTDMT_createCCtx_advanced_internal`.
    fn create(nb_workers_in: u32, gpa: Allocator, io: Io, thread_pool: ?*ThreadPool) ?*MtCCtx {
        if (nb_workers_in < 1) return null;
        const nb_workers = @min(nb_workers_in, nbworkers_max);
        var nb_jobs: u32 = nb_workers + 2;

        const mtctx = gpa.create(MtCCtx) catch return null;
        mtctx.* = .{
            .factory = null,
            .jobs = &.{},
            .buf_pool = null,
            .cctx_pool = null,
            .seq_pool = null,
            .params = .{},
            .target_section_size = 0,
            .target_prefix_size = 0,
            .job_ready = false,
            .in_buff = .{},
            .round_buff = null_round_buff,
            .serial = .init(gpa, io),
            .rsync = .{},
            .job_id_mask = 0,
            .done_job_id = 0,
            .next_job_id = 0,
            .frame_ended = false,
            .all_jobs_completed = true,
            .frame_content_size = 0,
            .consumed = 0,
            .produced = 0,
            .gpa = gpa,
            .io = io,
            .cdict_local = null,
            .cdict = null,
            .provided_factory = false,
        };
        cctxParamSetNbWorkers(&mtctx.params, nb_workers);
        if (thread_pool) |p| {
            mtctx.factory = p;
            mtctx.provided_factory = true;
        } else {
            mtctx.factory = ThreadPool.create(gpa, io, nb_workers, 0);
            mtctx.provided_factory = false;
        }
        mtctx.jobs = createJobsTable(gpa, &nb_jobs) orelse &.{};
        assert(std.math.isPowerOfTwo(nb_jobs));
        mtctx.job_id_mask = nb_jobs - 1;
        mtctx.buf_pool = BufferPool.create(gpa, io, bufPoolMaxNbBuffers(nb_workers));
        mtctx.cctx_pool = CCtxPool.create(gpa, io, nb_workers);
        mtctx.seq_pool = createSeqPool(gpa, io, nb_workers);
        if (mtctx.factory == null or mtctx.jobs.len == 0 or mtctx.buf_pool == null or
            mtctx.cctx_pool == null or mtctx.seq_pool == null)
        {
            mtctx.free();
            return null;
        }
        return mtctx;
    }

    /// `ZSTDMT_freeCCtx`: stops the workers, unless the pool is the
    /// caller's, and frees the context.
    pub fn free(mtctx: *MtCCtx) void {
        if (!mtctx.provided_factory) {
            if (mtctx.factory) |factory| factory.free();
        }
        // The jobs' resources go back to the pools first.
        mtctx.releaseAllJobResources();
        freeJobsTable(mtctx.gpa, mtctx.jobs);
        BufferPool.free(mtctx.buf_pool);
        CCtxPool.free(mtctx.cctx_pool);
        BufferPool.free(mtctx.seq_pool);
        mtctx.serial.free();
        if (mtctx.cdict_local) |cdict| compress.freeCDict(cdict);
        if (mtctx.round_buff.buffer) |buffer| mtctx.gpa.free(buffer[0..mtctx.round_buff.capacity]);
        mtctx.gpa.destroy(mtctx);
    }

    /// `ZSTDMT_sizeof_CCtx`: the memory the original's context of this
    /// shape takes; right only between compressions.
    pub fn sizeof(mtctx: ?*MtCCtx) usize {
        const m = mtctx orelse return 0;
        return @sizeOf(c_layout.MtCCtx) +
            ThreadPool.sizeof(m.factory) +
            m.buf_pool.?.sizeof() +
            (@as(usize, m.job_id_mask) + 1) * @sizeOf(c_layout.JobDescription) +
            m.cctx_pool.?.sizeof() +
            m.seq_pool.?.sizeof() +
            compress.sizeofCDict(m.cdict_local) +
            m.round_buff.capacity;
    }

    /// `ZSTDMT_releaseAllJobResources`: the jobs' buffers back to the pool
    /// and the jobs cleared, keeping their locks. The workers must be done.
    fn releaseAllJobResources(mtctx: *MtCCtx) void {
        for (mtctx.jobs) |*job| {
            const job_mutex = job.job_mutex;
            const job_cond = job.job_cond;
            if (mtctx.buf_pool) |buf_pool| buf_pool.releaseBuffer(job.dst_buff);
            job.* = .{ .job_mutex = job_mutex, .job_cond = job_cond };
        }
        mtctx.in_buff.buffer = null_buffer;
        mtctx.in_buff.filled = 0;
        mtctx.all_jobs_completed = true;
    }

    /// `ZSTDMT_waitForAllJobsCompleted`.
    fn waitForAllJobsCompleted(mtctx: *MtCCtx) void {
        const io = mtctx.io;
        while (mtctx.done_job_id < mtctx.next_job_id) {
            const job = &mtctx.jobs[mtctx.done_job_id & mtctx.job_id_mask];
            job.job_mutex.lockUncancelable(io);
            while (job.consumed < job.src.size) job.job_cond.waitUncancelable(io, &job.job_mutex);
            job.job_mutex.unlock(io);
            mtctx.done_job_id += 1;
        }
    }

    /// `ZSTDMT_expandJobsTable`.
    fn expandJobsTable(mtctx: *MtCCtx, nb_workers: u32) Error!void {
        var nb_jobs: u32 = nb_workers + 2;
        if (nb_jobs > mtctx.job_id_mask + 1) {
            freeJobsTable(mtctx.gpa, mtctx.jobs);
            mtctx.jobs = &.{};
            mtctx.job_id_mask = 0;
            mtctx.jobs = createJobsTable(mtctx.gpa, &nb_jobs) orelse return error.MemoryAllocation;
            assert(std.math.isPowerOfTwo(nb_jobs));
            mtctx.job_id_mask = nb_jobs - 1;
        }
    }

    /// `ZSTDMT_resize`: room for `nb_workers` workers. A caller's pool is
    /// resized too.
    fn resize(mtctx: *MtCCtx, nb_workers: u32) Error!void {
        mtctx.factory.?.resize(nb_workers) catch return error.MemoryAllocation;
        try mtctx.expandJobsTable(nb_workers);
        mtctx.buf_pool = BufferPool.expand(mtctx.buf_pool, bufPoolMaxNbBuffers(nb_workers)) orelse
            return error.MemoryAllocation;
        mtctx.cctx_pool = CCtxPool.expand(mtctx.cctx_pool, nb_workers) orelse
            return error.MemoryAllocation;
        mtctx.seq_pool = expandSeqPool(mtctx.seq_pool, nb_workers) orelse
            return error.MemoryAllocation;
        cctxParamSetNbWorkers(&mtctx.params, nb_workers);
    }

    /// `ZSTDMT_updateCParams_whileCompressing`: the level and the
    /// compression parameters of `cctx_params` for the next jobs, keeping
    /// the frame's window log.
    pub fn updateCParamsWhileCompressing(mtctx: *MtCCtx, cctx_params: *const CCtxParams) void {
        const saved_wlog = mtctx.params.cparams.window_log;
        mtctx.params.compression_level = cctx_params.compression_level;
        var cparams = compress.getCParamsFromCCtxParams(
            cctx_params,
            params.content_size_unknown,
            0,
            .no_attach_dict,
        );
        cparams.window_log = saved_wlog;
        mtctx.params.cparams = cparams;
    }

    /// `ZSTDMT_getFrameProgression`: the input read and the output made in
    /// the frame so far, the workers' progress included.
    pub fn getFrameProgression(mtctx: *MtCCtx) params.FrameProgression {
        const io = mtctx.io;
        var fps: params.FrameProgression = .{
            .ingested = mtctx.consumed + mtctx.in_buff.filled,
            .consumed = mtctx.consumed,
            .produced = mtctx.produced,
            .flushed = mtctx.produced,
            .current_job_id = mtctx.next_job_id,
            .nb_active_workers = 0,
        };
        const last_job_nb = mtctx.next_job_id + @intFromBool(mtctx.job_ready);
        var job_nb = mtctx.done_job_id;
        while (job_nb < last_job_nb) : (job_nb += 1) {
            const job = &mtctx.jobs[job_nb & mtctx.job_id_mask];
            job.job_mutex.lockUncancelable(io);
            const produced = if (job.failed()) 0 else job.c_size;
            const flushed = if (job.failed()) 0 else job.dst_flushed;
            assert(flushed <= produced);
            fps.ingested += job.src.size;
            fps.consumed += job.consumed;
            fps.produced += produced;
            fps.flushed += flushed;
            fps.nb_active_workers += @intFromBool(job.consumed < job.src.size);
            job.job_mutex.unlock(io);
        }
        return fps;
    }

    /// `ZSTDMT_toFlushNow`: the output of the oldest job not yet flushed
    /// that is ready to flush.
    pub fn toFlushNow(mtctx: *MtCCtx) usize {
        const job_id = mtctx.done_job_id;
        assert(job_id <= mtctx.next_job_id);
        // No job in progress, nothing to flush.
        if (job_id == mtctx.next_job_id) return 0;
        const job = &mtctx.jobs[job_id & mtctx.job_id_mask];
        job.job_mutex.lockUncancelable(mtctx.io);
        defer job.job_mutex.unlock(mtctx.io);
        const produced = if (job.failed()) 0 else job.c_size;
        const flushed = if (job.failed()) 0 else job.dst_flushed;
        assert(flushed <= produced);
        assert(job.consumed <= job.src.size);
        const to_flush = produced - flushed;
        // A job flushed in full and done would already be behind us.
        if (to_flush == 0) assert(job.consumed < job.src.size);
        return to_flush;
    }

    /// `ZSTDMT_initCStream_internal`: starts a frame of `pledged_src_size`
    /// bytes (`params.content_size_unknown` when unknown) with `cctx_params`,
    /// whose compression parameters must be set, and a dictionary: `dict`,
    /// raw content used as the first job's prefix or else made into a
    /// dictionary, or `cdict`, not both. `dict` and `cdict` are the caller's,
    /// valid until the frame ends.
    pub fn initCStreamInternal(
        mtctx: *MtCCtx,
        dict: ?[]const u8,
        dict_content_type: params.DictContentType,
        cdict: ?*const CDict,
        cctx_params_in: CCtxParams,
        pledged_src_size: u64,
    ) Error!void {
        var cctx_params = cctx_params_in;
        // The parameters are mostly checked by now.
        if (std.debug.runtime_safety) compress.checkCParams(cctx_params.cparams) catch unreachable;
        assert(dict == null or cdict == null);

        if (cctx_params.nb_workers != mtctx.params.nb_workers) {
            try mtctx.resize(@intCast(cctx_params.nb_workers));
        }

        if (cctx_params.job_size != 0 and cctx_params.job_size < jobsize_min) {
            cctx_params.job_size = jobsize_min;
        }
        if (cctx_params.job_size > jobsize_max) cctx_params.job_size = jobsize_max;

        if (!mtctx.all_jobs_completed) {
            // The previous frame was not ended.
            mtctx.waitForAllJobsCompleted();
            mtctx.releaseAllJobResources();
            mtctx.all_jobs_completed = true;
        }

        mtctx.params = cctx_params;
        mtctx.frame_content_size = pledged_src_size;
        if (mtctx.cdict_local) |local| compress.freeCDict(local);
        if (dict) |d| {
            mtctx.cdict_local = compress.createCDictAdvanced(
                mtctx.gpa,
                d,
                .by_copy,
                dict_content_type,
                cctx_params.cparams,
            );
            mtctx.cdict = mtctx.cdict_local;
            if (mtctx.cdict_local == null) return error.MemoryAllocation;
        } else {
            mtctx.cdict_local = null;
            mtctx.cdict = cdict;
        }

        mtctx.target_prefix_size = computeOverlapSize(&cctx_params);
        mtctx.target_section_size = cctx_params.job_size;
        if (mtctx.target_section_size == 0) {
            mtctx.target_section_size = @as(usize, 1) << @intCast(computeTargetJobLog(&cctx_params));
        }
        assert(mtctx.target_section_size <= jobsize_max);

        if (cctx_params.rsyncable != 0) {
            // The target section size as the jobs' average size.
            const job_size_kb: u32 = @intCast(mtctx.target_section_size >> 10);
            assert(job_size_kb >= 1);
            const rsync_bits = ci.highbit32(job_size_kb) + 10;
            // Jobs are at least a block, so aim at four times that.
            assert(rsync_bits >= rsync_min_block_log + 2);
            mtctx.rsync.hash = 0;
            mtctx.rsync.hit_mask = (@as(u64, 1) << @intCast(rsync_bits)) - 1;
            mtctx.rsync.prime_power = ci.rollingHashPrimePower(rsync_length);
        }
        // A job is at least the overlap.
        if (mtctx.target_section_size < mtctx.target_prefix_size) {
            mtctx.target_section_size = mtctx.target_prefix_size;
        }
        mtctx.buf_pool.?.setBufferSize(compress.compressBoundMacro(mtctx.target_section_size));
        {
            // Long distance matching keeps a window's worth of input.
            const window_size: usize = if (mtctx.params.ldm_params.enable_ldm == .enable)
                @as(usize, 1) << @intCast(mtctx.params.cparams.window_log)
            else
                0;
            // Two sections of slack, the least long distance matching works
            // with: a flush may waste up to a section, and the section being
            // filled must not overlap the window. One more for the overlap.
            const nb_slack_buffers = @as(usize, 2) + @intFromBool(mtctx.target_prefix_size > 0);
            const slack_size = mtctx.target_section_size * nb_slack_buffers;
            const nb_workers: usize = @intCast(@max(mtctx.params.nb_workers, 1));
            const sections_size = mtctx.target_section_size * nb_workers;
            const capacity = @max(window_size, sections_size) + slack_size;
            if (mtctx.round_buff.capacity < capacity) {
                if (mtctx.round_buff.buffer) |buffer| {
                    mtctx.gpa.free(buffer[0..mtctx.round_buff.capacity]);
                }
                mtctx.round_buff.buffer = null;
                const buffer = mtctx.gpa.alloc(u8, capacity) catch {
                    mtctx.round_buff.capacity = 0;
                    return error.MemoryAllocation;
                };
                mtctx.round_buff.buffer = buffer.ptr;
                mtctx.round_buff.capacity = capacity;
            }
        }
        mtctx.round_buff.pos = 0;
        mtctx.in_buff.buffer = null_buffer;
        mtctx.in_buff.filled = 0;
        mtctx.in_buff.prefix = null_range;
        mtctx.done_job_id = 0;
        mtctx.next_job_id = 0;
        mtctx.frame_ended = false;
        mtctx.all_jobs_completed = false;
        mtctx.consumed = 0;
        mtctx.produced = 0;

        // The dictionary, again: raw content becomes the first prefix, and
        // anything else a dictionary that references `dict`.
        if (mtctx.cdict_local) |local| compress.freeCDict(local);
        mtctx.cdict_local = null;
        mtctx.cdict = null;
        if (dict) |d| {
            if (dict_content_type == .raw_content) {
                mtctx.in_buff.prefix = .{ .start = d.ptr, .size = d.len };
            } else {
                mtctx.cdict_local = compress.createCDictAdvanced(
                    mtctx.gpa,
                    d,
                    .by_ref,
                    dict_content_type,
                    cctx_params.cparams,
                );
                mtctx.cdict = mtctx.cdict_local;
                if (mtctx.cdict_local == null) return error.MemoryAllocation;
            }
        } else {
            mtctx.cdict = cdict;
        }

        try mtctx.serial.reset(
            mtctx.seq_pool.?,
            cctx_params,
            mtctx.target_section_size,
            dict,
            dict_content_type,
        );
    }

    /// `ZSTDMT_writeLastEmptyBlock`: ends the frame with an empty last
    /// block, as a streaming job that is not the first.
    fn writeLastEmptyBlock(job: *JobDescription) void {
        assert(job.last_job);
        assert(job.src.size == 0);
        assert(!job.first_job);
        assert(job.dst_buff.start == null);
        job.dst_buff = job.buf_pool.?.getBuffer();
        const start = job.dst_buff.start orelse {
            job.c_error = error.MemoryAllocation;
            return;
        };
        assert(job.dst_buff.capacity >= zstd_internal.block_header_size);
        job.src = null_range;
        job.c_size = compress.writeLastEmptyBlock(start[0..job.dst_buff.capacity]) catch unreachable;
        assert(job.consumed == 0);
    }

    /// `ZSTDMT_createCompressionJob`: makes a job of the `src_size` bytes
    /// gathered, unless one is already prepared, and hands it to a worker if
    /// one is free. Nothing happens while the table of jobs is full.
    fn createCompressionJob(mtctx: *MtCCtx, src_size: usize, end_op: params.EndDirective) void {
        const job_id = mtctx.next_job_id & mtctx.job_id_mask;
        const end_frame = end_op == .end;

        if (mtctx.next_job_id > mtctx.done_job_id + mtctx.job_id_mask) {
            assert((mtctx.next_job_id & mtctx.job_id_mask) == (mtctx.done_job_id & mtctx.job_id_mask));
            return;
        }

        const job = &mtctx.jobs[job_id];
        if (!mtctx.job_ready) {
            const src = mtctx.in_buff.buffer.start;
            job.src = .{ .start = src, .size = src_size };
            assert(mtctx.in_buff.filled >= src_size);
            job.prefix = mtctx.in_buff.prefix;
            job.consumed = 0;
            job.c_size = 0;
            job.c_error = null;
            job.params = mtctx.params;
            job.cdict = if (mtctx.next_job_id == 0) mtctx.cdict else null;
            job.full_frame_size = mtctx.frame_content_size;
            job.dst_buff = null_buffer;
            job.cctx_pool = mtctx.cctx_pool;
            job.buf_pool = mtctx.buf_pool;
            job.seq_pool = mtctx.seq_pool;
            job.serial = &mtctx.serial;
            job.io = mtctx.io;
            job.job_id = mtctx.next_job_id;
            job.first_job = mtctx.next_job_id == 0;
            job.last_job = end_frame;
            job.frame_checksum_needed = mtctx.params.fparams.checksum_flag and end_frame and
                mtctx.next_job_id > 0;
            job.dst_flushed = 0;

            // The round buffer moves past the input; the next one starts
            // empty.
            mtctx.round_buff.pos += src_size;
            mtctx.in_buff.buffer = null_buffer;
            mtctx.in_buff.filled = 0;
            if (!end_frame) {
                // The next job's prefix.
                const new_prefix_size = @min(src_size, mtctx.target_prefix_size);
                mtctx.in_buff.prefix = .{
                    .start = src.? + src_size - new_prefix_size,
                    .size = new_prefix_size,
                };
            } else {
                mtctx.in_buff.prefix = null_range;
                mtctx.frame_ended = end_frame;
                // A single job computes the checksum itself.
                if (mtctx.next_job_id == 0) mtctx.params.fparams.checksum_flag = false;
            }

            if (src_size == 0 and mtctx.next_job_id > 0) {
                // Only the end of the frame is left: an empty last block.
                assert(end_op == .end);
                writeLastEmptyBlock(job);
                mtctx.next_job_id += 1;
                return;
            }
        }

        if (mtctx.factory.?.tryAdd(compressionJob, job)) {
            mtctx.next_job_id += 1;
            mtctx.job_ready = false;
        } else {
            // No worker free: try again on the next call.
            mtctx.job_ready = true;
        }
    }

    /// `ZSTDMT_flushProduced`: copies to `output` what the oldest job has
    /// made and not yet flushed, and moves to the next job when that one is
    /// flushed in full. With `block_to_flush`, waits for output when there
    /// is none yet. Returns the bytes left to flush: 0 when none, 1 when
    /// some are coming but their number is unknown. With `.end`, 0 means the
    /// frame is complete.
    fn flushProduced(
        mtctx: *MtCCtx,
        output: *params.OutBuffer,
        block_to_flush: bool,
        end: params.EndDirective,
    ) Error!usize {
        const io = mtctx.io;
        const job = &mtctx.jobs[mtctx.done_job_id & mtctx.job_id_mask];
        assert(output.dst.len >= output.pos);

        job.job_mutex.lockUncancelable(io);
        if (block_to_flush and mtctx.done_job_id < mtctx.next_job_id) {
            assert(job.dst_flushed <= job.c_size);
            // Nothing to flush yet, but more to come.
            while (job.dst_flushed == job.c_size) {
                // A job done has nothing more to come.
                if (job.consumed == job.src.size) break;
                job.job_cond.waitUncancelable(io, &job.job_mutex);
            }
        }

        {
            var c_size = job.c_size;
            const c_error = job.c_error;
            const src_consumed = job.consumed;
            const src_size = job.src.size;
            job.job_mutex.unlock(io);
            if (c_error) |err| {
                mtctx.waitForAllJobsCompleted();
                mtctx.releaseAllJobResources();
                return err;
            }
            assert(src_consumed <= src_size);
            // The frame checksum, once the last job is done, its worker gone.
            if (src_consumed == src_size and job.frame_checksum_needed) {
                const checksum: u32 = @truncate(mtctx.serial.xxh_state.final());
                std.mem.writeInt(u32, (job.dst_buff.start.? + job.c_size)[0..4], checksum, .little);
                c_size += 4;
                job.c_size += 4;
                job.frame_checksum_needed = false;
            }

            if (c_size > 0) {
                // The job has made output, or is done.
                const to_flush = @min(c_size - job.dst_flushed, output.dst.len - output.pos);
                assert(mtctx.done_job_id < mtctx.next_job_id);
                assert(c_size >= job.dst_flushed);
                assert(job.dst_buff.start != null);
                if (to_flush > 0) {
                    @memcpy(
                        output.dst[output.pos..][0..to_flush],
                        (job.dst_buff.start.? + job.dst_flushed)[0..to_flush],
                    );
                }
                output.pos += to_flush;
                job.dst_flushed += to_flush;

                if (src_consumed == src_size and job.dst_flushed == c_size) {
                    // Done and flushed: the job's slot is free.
                    mtctx.buf_pool.?.releaseBuffer(job.dst_buff);
                    job.dst_buff = null_buffer;
                    // Not started, for the next checks.
                    job.c_size = 0;
                    mtctx.consumed += src_size;
                    mtctx.produced += c_size;
                    mtctx.done_job_id += 1;
                }
            }

            if (c_size > job.dst_flushed) return c_size - job.dst_flushed;
            // The job is not done.
            if (src_size > src_consumed) return 1;
        }
        // More jobs in progress, a job waiting for a worker, or input not
        // yet made into a job.
        if (mtctx.done_job_id < mtctx.next_job_id) return 1;
        if (mtctx.job_ready) return 1;
        if (mtctx.in_buff.filled > 0) return 1;
        // Everything flushed: the frame is complete if its last job was.
        mtctx.all_jobs_completed = mtctx.frame_ended;
        // For `.end`, whether the frame is complete.
        if (end == .end) return @intFromBool(!mtctx.frame_ended);
        return 0;
    }

    /// `ZSTDMT_getInputDataInUse`: the input of the oldest job not done,
    /// its prefix included.
    fn getInputDataInUse(mtctx: *MtCCtx) Range {
        const io = mtctx.io;
        // Nothing is reused in the first round.
        const nb_jobs_1st_round_min = mtctx.round_buff.capacity / mtctx.target_section_size;
        if (mtctx.next_job_id < nb_jobs_1st_round_min) return null_range;

        var job_id = mtctx.done_job_id;
        while (job_id < mtctx.next_job_id) : (job_id += 1) {
            const job = &mtctx.jobs[job_id & mtctx.job_id_mask];
            job.job_mutex.lockUncancelable(io);
            const consumed = job.consumed;
            job.job_mutex.unlock(io);

            if (consumed < job.src.size) {
                var range = job.prefix;
                if (range.size == 0) range = job.src;
                // A job's input is in one piece.
                assert(@intFromPtr(range.start.?) <= @intFromPtr(job.src.start.?));
                return range;
            }
        }
        return null_range;
    }

    /// `ZSTDMT_waitForLdmComplete`: with long distance matching, waits
    /// until its window no longer covers `buffer`.
    fn waitForLdmComplete(mtctx: *MtCCtx, buffer: Buffer) void {
        if (mtctx.params.ldm_params.enable_ldm != .enable) return;
        const io = mtctx.io;
        const mutex = &mtctx.serial.ldm_window_mutex;
        mutex.lockUncancelable(io);
        while (doesOverlapWindow(buffer, mtctx.serial.ldm_window)) {
            mtctx.serial.ldm_window_cond.waitUncancelable(io, mutex);
        }
        mutex.unlock(io);
    }

    /// `ZSTDMT_tryGetInputRange`: makes the next section of the round
    /// buffer the input buffer, unless part of it is still in use. Says
    /// whether it did.
    fn tryGetInputRange(mtctx: *MtCCtx) bool {
        const in_use = mtctx.getInputDataInUse();
        const space_left = mtctx.round_buff.capacity - mtctx.round_buff.pos;
        const space_needed = mtctx.target_section_size;
        assert(mtctx.in_buff.buffer.start == null);
        assert(mtctx.round_buff.capacity >= space_needed);

        const round_start = mtctx.round_buff.buffer.?;
        if (space_left < space_needed) {
            // Back to the start, with the prefix copied there: repeat codes
            // cannot be invalidated with an external dictionary.
            const prefix_size = mtctx.in_buff.prefix.size;
            const prefix_buffer: Buffer = .{ .start = round_start, .capacity = prefix_size };
            if (isOverlapped(prefix_buffer, in_use)) return false;
            mtctx.waitForLdmComplete(prefix_buffer);
            if (prefix_size > 0) {
                std.mem.copyForwards(u8, round_start[0..prefix_size], mtctx.in_buff.prefix.slice());
            }
            mtctx.in_buff.prefix.start = round_start;
            mtctx.round_buff.pos = prefix_size;
        }
        const buffer: Buffer = .{
            .start = round_start + mtctx.round_buff.pos,
            .capacity = space_needed,
        };

        if (isOverlapped(buffer, in_use)) return false;
        assert(!isOverlapped(buffer, mtctx.in_buff.prefix));

        mtctx.waitForLdmComplete(buffer);

        mtctx.in_buff.buffer = buffer;
        mtctx.in_buff.filled = 0;
        assert(mtctx.round_buff.pos + buffer.capacity <= mtctx.round_buff.capacity);
        return true;
    }

    /// `findSynchronizationPoint`: how much of `input` to load, and with
    /// `rsyncable`, whether the job must end there: the rolling hash of the
    /// last `rsync_length` bytes hits its mask at a point that depends only
    /// on the content.
    fn findSynchronizationPoint(mtctx: *const MtCCtx, input: params.InBuffer) SyncPoint {
        const istart = input.src.ptr + input.pos;
        const prime_power = mtctx.rsync.prime_power;
        const hit_mask = mtctx.rsync.hit_mask;
        const filled = mtctx.in_buff.filled;

        var sync_point: SyncPoint = .{
            .to_load = @min(input.src.len - input.pos, mtctx.target_section_size - filled),
            .flush = false,
        };
        if (mtctx.params.rsyncable == 0) return sync_point;
        // No point that would make a job shorter than a block.
        if (filled + input.src.len - input.pos < rsync_min_block_size) return sync_point;
        // Too few bytes for a hash: a point here is missed, which happens
        // rarely, and depends only on the buffers, so that a synchronized
        // stream stays synchronized.
        if (filled + sync_point.to_load < rsync_length) return sync_point;

        var hash: u64 = undefined;
        var prev: [*]const u8 = undefined;
        var pos: usize = undefined;
        if (filled < rsync_min_block_size) {
            // The first positions cannot be points: start further in.
            pos = rsync_min_block_size - filled;
            if (pos >= rsync_length) {
                prev = istart + pos - rsync_length;
                hash = ci.rollingHashCompute(prev[0..rsync_length]);
            } else {
                assert(filled >= rsync_length);
                prev = mtctx.in_buff.buffer.start.? + filled - rsync_length;
                hash = ci.rollingHashCompute(prev[pos..rsync_length]);
                hash = ci.rollingHashAppend(hash, istart[0..pos]);
            }
        } else {
            // Enough bytes for the hash and a block: scan from the start of
            // the input.
            assert(filled >= rsync_min_block_size);
            comptime assert(rsync_min_block_size >= rsync_length);
            pos = 0;
            prev = mtctx.in_buff.buffer.start.? + filled - rsync_length;
            hash = ci.rollingHashCompute(prev[0..rsync_length]);
            if ((hash & hit_mask) == hit_mask) {
                // Already at a point, which a full table of jobs kept from
                // being flushed: load nothing until it is.
                sync_point.to_load = 0;
                sync_point.flush = true;
                return sync_point;
            }
        }
        // Roll the hash through the input. A job that reaches the target
        // size without a point ends anyway; a synchronized stream stays so.
        while (pos < sync_point.to_load) : (pos += 1) {
            const to_remove = if (pos < rsync_length) prev[pos] else istart[pos - rsync_length];
            hash = ci.rollingHashRotate(hash, to_remove, istart[pos], prime_power);
            assert(filled + pos >= rsync_min_block_size);
            if ((hash & hit_mask) == hit_mask) {
                sync_point.to_load = pos + 1;
                sync_point.flush = true;
                break;
            }
        }
        return sync_point;
    }

    /// `ZSTDMT_nextInputSizeHint`: the input that would fill the job being
    /// gathered.
    pub fn nextInputSizeHint(mtctx: *const MtCCtx) usize {
        var hint_in_size = mtctx.target_section_size - mtctx.in_buff.filled;
        if (hint_in_size == 0) hint_in_size = mtctx.target_section_size;
        return hint_in_size;
    }

    /// `ZSTDMT_compressStream_generic`: takes what input it can, starts the
    /// jobs it makes, and flushes what output is ready, waiting for some
    /// when no input was taken. `.flush` and `.end` make a job of the input
    /// gathered; `.end` ends the frame once all the input is taken. Returns
    /// at least the bytes left to flush, 0 when none (for `.end`: when the
    /// frame is complete). `input` and `output` are the caller's: the
    /// input taken is copied, so `input.src` need only be valid for the call.
    pub fn compressStreamGeneric(
        mtctx: *MtCCtx,
        output: *params.OutBuffer,
        input: *params.InBuffer,
        end_op_in: params.EndDirective,
    ) Error!usize {
        var end_op = end_op_in;
        var forward_input_progress = false;
        assert(output.pos <= output.dst.len);
        assert(input.pos <= input.src.len);

        // A frame being ended takes only flushes and its end.
        if (mtctx.frame_ended and end_op == .@"continue") return error.StageWrong;

        // Fill the input buffer.
        if (!mtctx.job_ready and input.src.len > input.pos) {
            if (mtctx.in_buff.buffer.start == null) {
                assert(mtctx.in_buff.filled == 0);
                // Fails only while jobs are in progress.
                if (!mtctx.tryGetInputRange()) assert(mtctx.done_job_id != mtctx.next_job_id);
            }
            if (mtctx.in_buff.buffer.start) |in_start| {
                const sync_point = mtctx.findSynchronizationPoint(input.*);
                if (sync_point.flush and end_op == .@"continue") end_op = .flush;
                assert(mtctx.in_buff.buffer.capacity >= mtctx.target_section_size);
                @memcpy(
                    in_start[mtctx.in_buff.filled..][0..sync_point.to_load],
                    input.src[input.pos..][0..sync_point.to_load],
                );
                input.pos += sync_point.to_load;
                mtctx.in_buff.filled += sync_point.to_load;
                forward_input_progress = sync_point.to_load > 0;
            }
        }
        if (input.pos < input.src.len and end_op == .end) {
            // The input is not all taken, so the frame cannot end yet: no
            // input buffer could be had, the buffer is full, or a
            // synchronization point was found. Flush this job instead.
            assert(mtctx.in_buff.filled == 0 or
                mtctx.in_buff.filled == mtctx.target_section_size or
                mtctx.params.rsyncable != 0);
            end_op = .flush;
        }

        if (mtctx.job_ready or
            mtctx.in_buff.filled >= mtctx.target_section_size or
            (end_op != .@"continue" and mtctx.in_buff.filled > 0) or
            (end_op == .end and !mtctx.frame_ended))
        {
            // A full buffer, something to flush, or a frame to end with an
            // empty block.
            const job_size = mtctx.in_buff.filled;
            assert(mtctx.in_buff.filled <= mtctx.target_section_size);
            mtctx.createCompressionJob(job_size, end_op);
        }

        // Flush what is ready, waiting for it if no input was taken.
        const remaining_to_flush = try mtctx.flushProduced(output, !forward_input_progress, end_op);
        // Input left: the flush is not over.
        if (input.pos < input.src.len) return @max(remaining_to_flush, 1);
        return remaining_to_flush;
    }
};

/// `SyncPoint`.
const SyncPoint = struct {
    /// The bytes of input to load.
    to_load: usize,
    /// Whether the job must end after them, at a synchronization point.
    flush: bool,
};

/// `ZSTDMT_CCtxParam_setNbWorkers`.
fn cctxParamSetNbWorkers(cctx_params: *CCtxParams, nb_workers: u32) void {
    // In bounds, as `nbworkers_max` is the bound.
    _ = compress.cctxParamsSetParameter(cctx_params, .nb_workers, @intCast(nb_workers)) catch unreachable;
}

/// `ZSTDMT_freeJobsTable`: the locks need no freeing.
fn freeJobsTable(gpa: Allocator, jobs: []JobDescription) void {
    gpa.free(jobs);
}

/// `ZSTDMT_createJobsTable`: a table of jobs, its size the power of 2
/// above `nb_jobs_ptr.*`, which it becomes.
fn createJobsTable(gpa: Allocator, nb_jobs_ptr: *u32) ?[]JobDescription {
    const nb_jobs_log2 = ci.highbit32(nb_jobs_ptr.*) + 1;
    const nb_jobs = @as(u32, 1) << @intCast(nb_jobs_log2);
    const jobs = gpa.alloc(JobDescription, nb_jobs) catch return null;
    @memset(jobs, .{});
    nb_jobs_ptr.* = nb_jobs;
    return jobs;
}

/// `ZSTDMT_computeTargetJobLog`.
fn computeTargetJobLog(cctx_params: *const CCtxParams) u32 {
    const job_log: u32 = if (cctx_params.ldm_params.enable_ldm == .enable)
        // With long distance matching, the window log is usually oversized:
        // the cycle log sizes the jobs better.
        @max(21, compress.cycleLog(cctx_params.cparams.chain_log, cctx_params.cparams.strategy) + 3)
    else
        @max(20, cctx_params.cparams.window_log + 2);
    return @min(job_log, joblog_max);
}

/// `ZSTDMT_overlapLog_default`.
fn overlapLogDefault(strategy: params.Strategy) i32 {
    return switch (strategy) {
        .btultra2 => 9,
        .btultra, .btopt => 8,
        .btlazy2, .lazy2 => 7,
        else => 6,
    };
}

/// `ZSTDMT_overlapLog`.
fn overlapLog(ovlog: i32, strategy: params.Strategy) i32 {
    assert(0 <= ovlog and ovlog <= 9);
    if (ovlog == 0) return overlapLogDefault(strategy);
    return ovlog;
}

/// `ZSTDMT_computeOverlapSize`: how much of the previous job's input each
/// job takes as its prefix, a fraction of the window set by the overlap log.
fn computeOverlapSize(cctx_params: *const CCtxParams) usize {
    const overlap_r_log = 9 - overlapLog(cctx_params.overlap_log, cctx_params.cparams.strategy);
    const window_log: i32 = @intCast(cctx_params.cparams.window_log);
    var ov_log: i32 = if (overlap_r_log >= 8) 0 else window_log - overlap_r_log;
    assert(0 <= overlap_r_log and overlap_r_log <= 8);
    if (cctx_params.ldm_params.enable_ldm == .enable) {
        // With long distance matching, the window log is usually oversized:
        // the overlap is a fraction of the job size instead.
        const job_log: i32 = @intCast(computeTargetJobLog(cctx_params));
        ov_log = @min(window_log, job_log - 2) - overlap_r_log;
    }
    assert(0 <= ov_log and ov_log <= params.window_log_max);
    return if (ov_log == 0) 0 else @as(usize, 1) << @intCast(ov_log);
}

/// `ZSTDMT_isOverlapped`: whether `buffer` and `range` share a byte.
fn isOverlapped(buffer: Buffer, range: Range) bool {
    const buffer_start = @intFromPtr(buffer.start orelse return false);
    const range_start = @intFromPtr(range.start orelse return false);
    const buffer_end = buffer_start + buffer.capacity;
    const range_end = range_start + range.size;
    // Empty ranges overlap nothing.
    if (buffer_start == buffer_end or range_start == range_end) return false;
    return buffer_start < range_end and range_start < buffer_end;
}

/// `ZSTDMT_doesOverlapWindow`: whether `buffer` holds part of `window`'s
/// external dictionary or prefix.
fn doesOverlapWindow(buffer: Buffer, window: Window) bool {
    const ext_dict: Range = .{
        .start = @ptrFromInt(@intFromPtr(window.dict_base) +% window.low_limit),
        .size = window.dict_limit - window.low_limit,
    };
    const prefix_start = @intFromPtr(window.base) +% window.dict_limit;
    const prefix: Range = .{
        .start = @ptrFromInt(prefix_start),
        .size = @intFromPtr(window.next_src) -% prefix_start,
    };
    return isOverlapped(buffer, ext_dict) or isOverlapped(buffer, prefix);
}

/// The original's structures as a C compiler lays them out for the target,
/// for the sizes `sizeof` reports.
const c_layout = struct {
    const Ptr = ?*anyopaque;
    const Mutex = pool.c_layout.Mutex;
    const Cond = pool.c_layout.Cond;
    const CustomMem = pool.c_layout.CustomMem;
    const CParams = compress.c_layout.CParams;

    const Buffer = extern struct { start: Ptr, capacity: usize };
    const Range = extern struct { start: Ptr, size: usize };

    const BufferPool = extern struct {
        pool_mutex: Mutex,
        buffer_size: usize,
        total_buffers: c_uint,
        nb_buffers: c_uint,
        c_mem: CustomMem,
        buffers: Ptr,
    };

    const CCtxPool = extern struct {
        pool_mutex: Mutex,
        total_cctx: c_int,
        avail_cctx: c_int,
        c_mem: CustomMem,
        cctxs: Ptr,
    };

    const SerialState = extern struct {
        mutex: Mutex,
        cond: Cond,
        params: CParams,
        ldm_state: compress.c_layout.CLdmState,
        xxh_state: compress.c_layout.CXxh64State,
        next_job_id: c_uint,
        ldm_window_mutex: Mutex,
        ldm_window_cond: Cond,
        ldm_window: compress.c_layout.CWindow,
    };

    const JobDescription = extern struct {
        consumed: usize,
        c_size: usize,
        job_mutex: Mutex,
        job_cond: Cond,
        cctx_pool: Ptr,
        buf_pool: Ptr,
        seq_pool: Ptr,
        serial: Ptr,
        dst_buff: c_layout.Buffer,
        prefix: c_layout.Range,
        src: c_layout.Range,
        job_id: c_uint,
        first_job: c_uint,
        last_job: c_uint,
        params: CParams,
        cdict: Ptr,
        full_frame_size: u64,
        dst_flushed: usize,
        frame_checksum_needed: c_uint,
    };

    const MtCCtx = extern struct {
        factory: Ptr,
        jobs: Ptr,
        buf_pool: Ptr,
        cctx_pool: Ptr,
        seq_pool: Ptr,
        params: CParams,
        target_section_size: usize,
        target_prefix_size: usize,
        job_ready: c_int,
        in_buff: extern struct { prefix: c_layout.Range, buffer: c_layout.Buffer, filled: usize },
        round_buff: extern struct { buffer: Ptr, capacity: usize, pos: usize },
        serial: c_layout.SerialState,
        rsync: extern struct { hash: u64, hit_mask: u64, prime_power: u64 },
        job_id_mask: c_uint,
        done_job_id: c_uint,
        next_job_id: c_uint,
        frame_ended: c_uint,
        all_jobs_completed: c_uint,
        frame_content_size: u64,
        consumed: u64,
        produced: u64,
        c_mem: CustomMem,
        cdict_local: Ptr,
        cdict: Ptr,
        /// The original's one-bit field, in an unsigned int.
        provided_factory: c_uint,
    };
};

// --------------------------------------------------------
// Tests
// --------------------------------------------------------

const testing = std.testing;

test "the overlap is a fraction of the window, or of the job with long distance matching" {
    var p: CCtxParams = .{};
    p.cparams.window_log = 20;
    p.cparams.chain_log = 16;
    p.cparams.strategy = .fast;
    p.overlap_log = 0;
    // The default for fast is 6: a window over 8.
    try testing.expectEqual(@as(usize, 1) << 17, computeOverlapSize(&p));
    p.overlap_log = 1;
    try testing.expectEqual(@as(usize, 0), computeOverlapSize(&p));
    p.overlap_log = 9;
    try testing.expectEqual(@as(usize, 1) << 20, computeOverlapSize(&p));
    p.cparams.strategy = .btultra2;
    p.overlap_log = 0;
    try testing.expectEqual(@as(usize, 1) << 20, computeOverlapSize(&p));
    try testing.expectEqual(@as(u32, 22), computeTargetJobLog(&p));

    p.ldm_params.enable_ldm = .enable;
    p.cparams.window_log = 27;
    // Cycle log 15 for a binary tree: job log 21, the overlap below it.
    try testing.expectEqual(@as(u32, 21), computeTargetJobLog(&p));
    try testing.expectEqual(@as(usize, 1) << 19, computeOverlapSize(&p));
}

test "ranges overlap when they share a byte" {
    var bytes: [64]u8 = undefined;
    const buffer: Buffer = .{ .start = &bytes, .capacity = 16 };
    try testing.expect(isOverlapped(buffer, .{ .start = &bytes, .size = 1 }));
    try testing.expect(isOverlapped(buffer, .{ .start = bytes[15..].ptr, .size = 4 }));
    try testing.expect(!isOverlapped(buffer, .{ .start = bytes[16..].ptr, .size = 4 }));
    try testing.expect(!isOverlapped(buffer, .{ .start = &bytes, .size = 0 }));
    try testing.expect(!isOverlapped(buffer, null_range));
    try testing.expect(!isOverlapped(null_buffer, .{ .start = &bytes, .size = 4 }));
}

test {
    if (build_options.multithread) testing.refAllDecls(MtCCtx);
}
