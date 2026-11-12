//! Oracle tests of multithreaded compression: the port's context against
//! the original's zstdmt_compress.c, both driven through their
//! `initCStream_internal` and `compressStream_generic` as
//! `ZSTD_compressStream2` drives them, with the same parameters, input and
//! calls. The parameters are resolved on the original's side, as
//! `ZSTD_CCtx_init_compressStream2` resolves them, and copied to the port's
//! one by one. Every frame must be the same as the original's on every run,
//! whatever the threads' timing, and so must every value that does not
//! depend on the timing: the sizes after the start of a frame, the frame
//! progression whenever no job is in progress, and the errors.

const std = @import("std");
const zstd = @import("zstd");
const c = @import("upstream");
const test_options = @import("test_options");
const common = @import("common.zig");

const params = zstd.params;
const zstdmt = zstd.internal.zstdmt;
const compress = zstd.internal.compress;
const pool = zstd.internal.pool;
const CCtxParams = zstd.internal.compress_internal.CCtxParams;
const EndDirective = params.EndDirective;
const Param = common.Param;
const Result = common.Result;
const gpa = common.gpa;
const io = std.testing.io;
const kib = 1 << 10;
const mib = 1 << 20;

/// Runs of each case on each side; every one must give the same frame.
const port_runs = 3;
const upstream_runs = 2;

// The original's parameter numbers.
const p_level = 100;
const p_window_log = 101;
const p_hash_log = 102;
const p_chain_log = 103;
const p_strategy = 107;
const p_ldm = 160;
const p_checksum = 201;
const p_nb_workers = 400;
const p_job_size = 401;
const p_overlap_log = 402;
const p_rsyncable = 500;

/// How the caller feeds a frame, the same for both sides.
const Script = struct {
    /// The input of each `.continue` call.
    chunk: usize = 1 * mib,
    /// A `.flush` after every this many bytes fed; 0 for none.
    flush_every: usize = 0,
    /// The last chunk goes with `.end`, rather than an `.end` without input.
    end_with_data: bool = false,
    /// The output space each call gets.
    out_window: usize = 1 << 40,
    /// After this many bytes fed, the level changes, as `ZSTD_compressStream2`
    /// passes a changed level on.
    update_at: ?usize = null,
    update_level: i32 = 0,
};

const Dict = struct {
    bytes: []const u8,
    content_type: params.DictContentType = .raw_content,
    /// Each side makes a dictionary of this level from `bytes`, which the
    /// frame refers to as `ZSTD_CCtx_refCDict` would, in place of a prefix.
    cdict_level: ?i32 = null,
};

const Case = struct {
    nb_workers: u32,
    /// The workers the context is made for, when it is resized to
    /// `nb_workers` at the start of the frame.
    created_workers: ?u32 = null,
    /// A thread pool of this many threads for the context, shared.
    shared_pool: ?usize = null,
    params: []const Param = &.{},
    input: []const u8,
    /// Whether the frame's size is pledged.
    pledged: bool = false,
    dict: ?Dict = null,
    script: Script = .{},
    /// Frames compressed one after the other with the context.
    frames: u32 = 1,
    /// A first frame abandoned after this many bytes, before the frames.
    abandon_after: ?usize = null,
};

/// What a frame's run gives besides the frame: the values that do not
/// depend on the threads' timing.
const Observed = struct {
    /// The size of the context and the input size hint, right after the
    /// first frame started.
    sizeof_after_init: usize = 0,
    hint_after_init: usize = 0,
    /// The frame progression after each flush and at the end of a frame.
    progressions: [64]params.FrameProgression = undefined,
    nb_progressions: usize = 0,
    /// The error the run stopped at, if any.
    failure: ?Result = null,

    fn record(o: *Observed, fp: params.FrameProgression) void {
        if (o.nb_progressions == o.progressions.len) return;
        o.progressions[o.nb_progressions] = fp;
        o.nb_progressions += 1;
    }

    fn expectEqual(expected: *const Observed, actual: *const Observed) !void {
        try std.testing.expectEqual(expected.sizeof_after_init, actual.sizeof_after_init);
        try std.testing.expectEqual(expected.hint_after_init, actual.hint_after_init);
        try std.testing.expectEqual(expected.failure, actual.failure);
        try std.testing.expectEqualSlices(
            params.FrameProgression,
            expected.progressions[0..expected.nb_progressions],
            actual.progressions[0..actual.nb_progressions],
        );
    }
};

fn pledgedSize(case: *const Case) u64 {
    return if (case.pledged) case.input.len else params.content_size_unknown;
}

fn dictPrefix(case: *const Case) ?[]const u8 {
    const d = case.dict orelse return null;
    return if (d.cdict_level == null) d.bytes else null;
}

/// The original's parameters for `case`, resolved for its frame: the
/// caller frees them with `c.ZSTD_freeCCtxParams`.
fn upstreamParams(case: *const Case, cdict: ?*c.ZSTD_CDict, level_override: ?i32) !*c.ZSTD_CCtx_params {
    const p = c.ZSTD_createCCtxParams() orelse return error.OutOfMemory;
    errdefer _ = c.ZSTD_freeCCtxParams(p);
    try upstreamSet(p, p_nb_workers, @intCast(case.nb_workers));
    for (case.params) |param| try upstreamSet(p, param.param, param.value);
    if (level_override) |level| {
        // The requested parameters, unresolved, as a level change passes them.
        try upstreamSet(p, p_level, level);
        return p;
    }
    // A digested dictionary's level wins, as in `ZSTD_compressStream2`.
    if (case.dict) |d| if (d.cdict_level) |level| try upstreamSet(p, p_level, level);
    const dict_size = if (case.dict) |d| d.bytes.len else 0;
    c.reference_mt_resolveParams(p, pledgedSize(case), dict_size, cdict);
    return p;
}

fn upstreamSet(p: *c.ZSTD_CCtx_params, param: u32, value: i32) !void {
    if (c.ZSTD_isError(c.ZSTD_CCtxParams_setParameter(p, param, value)) != 0) {
        return error.UpstreamParameterRefused;
    }
}

/// The port's parameters, set to the original's `p` parameter by parameter.
fn portParamsFrom(p: *const c.ZSTD_CCtx_params) !CCtxParams {
    var port = compress.cctxParamsInit(3);
    for (std.enums.values(params.CParameter)) |param| {
        var value: c_int = 0;
        if (c.ZSTD_isError(c.ZSTD_CCtxParams_getParameter(p, @backingInt(param), &value)) != 0) {
            return error.UpstreamParameterRefused;
        }
        _ = try compress.cctxParamsSetParameter(&port, param, value);
    }
    return port;
}

/// The port's parameters for `case` as requested, unresolved, with the
/// level `level`.
fn portRequestedParams(case: *const Case, level: i32) !CCtxParams {
    var port = compress.cctxParamsInit(3);
    _ = try compress.cctxParamsSetParameter(&port, .nb_workers, @intCast(case.nb_workers));
    for (case.params) |param| {
        _ = try compress.cctxParamsSetParameter(&port, @fromBackingInt(param.param), param.value);
    }
    _ = try compress.cctxParamsSetParameter(&port, .compression_level, level);
    return port;
}

const Upstream = struct {
    case: *const Case,
    mt: *c.ZSTDMT_CCtx,
    thread_pool: ?*c.ZSTD_threadPool,
    cdict: ?*c.ZSTD_CDict,

    fn create(case: *const Case) !Upstream {
        const thread_pool = if (case.shared_pool) |n| c.ZSTD_createThreadPool(n) else null;
        errdefer c.ZSTD_freeThreadPool(thread_pool);
        const mt = c.reference_mt_create(case.created_workers orelse case.nb_workers, thread_pool) orelse
            return error.OutOfMemory;
        errdefer _ = c.ZSTDMT_freeCCtx(mt);
        var cdict: ?*c.ZSTD_CDict = null;
        if (case.dict) |d| if (d.cdict_level) |level| {
            cdict = c.ZSTD_createCDict(d.bytes.ptr, d.bytes.len, level) orelse return error.OutOfMemory;
        };
        return .{ .case = case, .mt = mt, .thread_pool = thread_pool, .cdict = cdict };
    }

    fn destroy(u: *Upstream) void {
        _ = c.ZSTDMT_freeCCtx(u.mt);
        _ = c.ZSTD_freeCDict(u.cdict);
        c.ZSTD_freeThreadPool(u.thread_pool);
    }

    fn initFrame(u: *Upstream) Result {
        const p = upstreamParams(u.case, u.cdict, null) catch unreachable;
        defer _ = c.ZSTD_freeCCtxParams(p);
        const prefix = dictPrefix(u.case);
        const content_type: c_int = if (u.case.dict) |d| @intCast(@backingInt(d.content_type)) else 0;
        return .of(c.reference_mt_initCStream(
            u.mt,
            if (prefix) |d| d.ptr else null,
            if (prefix) |d| d.len else 0,
            content_type,
            u.cdict,
            p,
            pledgedSize(u.case),
        ));
    }

    fn stream(
        u: *Upstream,
        out: []u8,
        out_pos: *usize,
        in: []const u8,
        in_pos: *usize,
        end_op: EndDirective,
    ) Result {
        var output: c.ZSTD_outBuffer = .{ .dst = out.ptr, .size = out.len, .pos = out_pos.* };
        var input: c.ZSTD_inBuffer = .{ .src = in.ptr, .size = in.len, .pos = in_pos.* };
        const code = c.ZSTDMT_compressStream_generic(u.mt, &output, &input, @backingInt(end_op));
        out_pos.* = output.pos;
        in_pos.* = input.pos;
        return .of(code);
    }

    fn update(u: *Upstream, level: i32) void {
        const p = upstreamParams(u.case, null, level) catch unreachable;
        defer _ = c.ZSTD_freeCCtxParams(p);
        c.ZSTDMT_updateCParams_whileCompressing(u.mt, p);
    }

    fn progression(u: *Upstream) params.FrameProgression {
        const fp = c.ZSTDMT_getFrameProgression(u.mt);
        return .{
            .ingested = fp.ingested,
            .consumed = fp.consumed,
            .produced = fp.produced,
            .flushed = fp.flushed,
            .current_job_id = fp.current_job_id,
            .nb_active_workers = fp.nb_active_workers,
        };
    }

    fn toFlushNow(u: *Upstream) usize {
        return c.ZSTDMT_toFlushNow(u.mt);
    }

    fn sizeof(u: *Upstream) usize {
        return c.ZSTDMT_sizeof_CCtx(u.mt);
    }

    fn nextInputSizeHint(u: *Upstream) usize {
        return c.ZSTDMT_nextInputSizeHint(u.mt);
    }
};

const Port = struct {
    case: *const Case,
    mt: *zstdmt.ZstdmtCCtx,
    thread_pool: ?*pool.ThreadPool,
    cdict: ?*compress.CDict,

    fn create(case: *const Case) !Port {
        const thread_pool = if (case.shared_pool) |n|
            pool.createThreadPool(gpa, io, n) orelse return error.OutOfMemory
        else
            null;
        errdefer pool.freeThreadPool(thread_pool);
        const workers = case.created_workers orelse case.nb_workers;
        const mt = zstdmt.createCCtxAdvanced(workers, gpa, io, thread_pool) orelse
            return error.OutOfMemory;
        errdefer mt.free();
        var cdict: ?*compress.CDict = null;
        if (case.dict) |d| if (d.cdict_level) |level| {
            cdict = try compress.createCDict(gpa, d.bytes, level);
        };
        return .{ .case = case, .mt = mt, .thread_pool = thread_pool, .cdict = cdict };
    }

    fn destroy(p: *Port) void {
        p.mt.free();
        if (p.cdict) |cdict| compress.freeCDict(cdict);
        pool.freeThreadPool(p.thread_pool);
    }

    fn initFrame(p: *Port) Result {
        // The original's resolved parameters, copied.
        const upstream_cdict = if (p.cdict != null) blk: {
            const d = p.case.dict.?;
            break :blk c.ZSTD_createCDict(d.bytes.ptr, d.bytes.len, d.cdict_level.?);
        } else null;
        defer _ = c.ZSTD_freeCDict(upstream_cdict);
        const up = upstreamParams(p.case, upstream_cdict, null) catch unreachable;
        defer _ = c.ZSTD_freeCCtxParams(up);
        const cctx_params = portParamsFrom(up) catch unreachable;
        const content_type: params.DictContentType = if (p.case.dict) |d| d.content_type else .auto;
        p.mt.initCStreamInternal(
            dictPrefix(p.case),
            content_type,
            p.cdict,
            cctx_params,
            pledgedSize(p.case),
        ) catch |err| return .{ .error_code = @backingInt(zstd.errorCode(err)) };
        return .{ .size = 0 };
    }

    fn stream(
        p: *Port,
        out: []u8,
        out_pos: *usize,
        in: []const u8,
        in_pos: *usize,
        end_op: EndDirective,
    ) Result {
        var output: params.OutBuffer = .{ .dst = out, .pos = out_pos.* };
        var input: params.InBuffer = .{ .src = in, .pos = in_pos.* };
        defer {
            out_pos.* = output.pos;
            in_pos.* = input.pos;
        }
        const remaining = p.mt.compressStreamGeneric(&output, &input, end_op) catch |err|
            return .{ .error_code = @backingInt(zstd.errorCode(err)) };
        return .{ .size = remaining };
    }

    fn update(p: *Port, level: i32) void {
        const requested = portRequestedParams(p.case, level) catch unreachable;
        p.mt.updateCParamsWhileCompressing(&requested);
    }

    fn progression(p: *Port) params.FrameProgression {
        return p.mt.getFrameProgression();
    }

    fn toFlushNow(p: *Port) usize {
        return p.mt.toFlushNow();
    }

    fn sizeof(p: *Port) usize {
        return zstdmt.ZstdmtCCtx.sizeof(p.mt);
    }

    fn nextInputSizeHint(p: *Port) usize {
        return p.mt.nextInputSizeHint();
    }
};

/// A frame being written: the output so far, in windows of the script's
/// size.
const Output = struct {
    buffer: []u8,
    len: usize = 0,
};

/// One `ZSTD_compressStream2` call: its loop over the multithreaded
/// context, until some progress for `.continue`, or until the flush is done
/// or the output window full.
fn compressStream2(
    side: anytype,
    out: *Output,
    window: usize,
    in: []const u8,
    in_pos: *usize,
    end_op: EndDirective,
) Result {
    const window_end = @min(out.buffer.len, out.len +| window);
    const dst = out.buffer[0..window_end];
    var result: Result = undefined;
    while (true) {
        const ipos = in_pos.*;
        const opos = out.len;
        result = side.stream(dst, &out.len, in, in_pos, end_op);
        const remaining = switch (result) {
            .size => |s| s,
            .error_code => return result,
        };
        if (end_op == .@"continue") {
            if (in_pos.* != ipos or out.len != opos or in_pos.* == in.len or out.len == window_end) break;
        } else {
            if (remaining == 0 or out.len == window_end) break;
        }
    }
    return result;
}

/// Calls with `end_op` until `in` is taken, and for `.flush` and `.end`
/// until the flush is done; then, with no job in progress, records the
/// progression.
fn feed(
    side: anytype,
    out: *Output,
    script: Script,
    in: []const u8,
    end_op: EndDirective,
    observed: *Observed,
) !void {
    var in_pos: usize = 0;
    while (true) {
        const result = compressStream2(side, out, script.out_window, in, &in_pos, end_op);
        const remaining = switch (result) {
            .size => |s| s,
            .error_code => {
                observed.failure = result;
                return error.Failed;
            },
        };
        if (end_op == .@"continue") {
            if (in_pos == in.len) return;
        } else if (remaining == 0) {
            break;
        }
    }
    try std.testing.expectEqual(@as(usize, 0), side.toFlushNow());
    observed.record(side.progression());
}

/// One frame of `case`, its input fed as the script says, into `out`.
fn compressFrame(side: anytype, case: *const Case, out: *Output, observed: *Observed, first: bool) !void {
    out.len = 0;
    switch (side.initFrame()) {
        .size => {},
        .error_code => |code| {
            observed.failure = .{ .error_code = code };
            return error.Failed;
        },
    }
    if (first) {
        observed.sizeof_after_init = side.sizeof();
        observed.hint_after_init = side.nextInputSizeHint();
    }
    const s = case.script;
    const input = case.input;
    var fed: usize = 0;
    var updated = false;
    while (fed < input.len) {
        var n = @min(s.chunk, input.len - fed);
        if (s.flush_every != 0) n = @min(n, s.flush_every - fed % s.flush_every);
        const last = fed + n == input.len;
        const end_op: EndDirective = if (last and s.end_with_data) .end else .@"continue";
        try feed(side, out, s, input[fed..][0..n], end_op, observed);
        fed += n;
        if (last and s.end_with_data) return;
        if (s.flush_every != 0 and fed % s.flush_every == 0) {
            try feed(side, out, s, &.{}, .flush, observed);
        }
        if (s.update_at) |at| {
            if (!updated and fed >= at) {
                side.update(s.update_level);
                updated = true;
            }
        }
    }
    try feed(side, out, s, &.{}, .end, observed);
}

/// Every frame of `case` on one side, into `frames`, one buffer per frame.
fn runSide(side: anytype, case: *const Case, frames: [][]u8, observed: *Observed) !void {
    if (case.abandon_after) |after| {
        var scratch: Output = .{ .buffer = frames[0] };
        _ = side.initFrame();
        var in_pos: usize = 0;
        const part = case.input[0..after];
        while (in_pos < part.len) {
            if (scratch.len == scratch.buffer.len) scratch.len = 0;
            _ = compressStream2(side, &scratch, 1 << 40, part, &in_pos, .@"continue");
        }
    }
    for (frames, 0..) |frame, i| {
        var out: Output = .{ .buffer = frame };
        compressFrame(side, case, &out, observed, i == 0) catch |err| switch (err) {
            error.Failed => return,
            else => return err,
        };
        frames[i] = frame[0..out.len];
    }
}

/// Runs `case` on both sides, several times each, and compares every frame
/// and observed value with the original's first run.
fn expectSameAsUpstream(case: Case) !void {
    const bound = c.ZSTD_compressBound(case.input.len) + case.input.len / 8 + 64 * kib;
    const frames = try gpa.alloc([]u8, case.frames);
    defer gpa.free(frames);
    const buffers = try gpa.alloc(u8, bound * case.frames * 2);
    defer gpa.free(buffers);

    const expected_frames = try gpa.alloc([]u8, case.frames);
    defer gpa.free(expected_frames);
    for (expected_frames, 0..) |*f, i| f.* = buffers[i * bound ..][0..bound];
    const actual = buffers[case.frames * bound ..];

    var expected_observed: Observed = .{};
    {
        var u = try Upstream.create(&case);
        defer u.destroy();
        try runSide(&u, &case, expected_frames, &expected_observed);
    }
    var run: usize = 1;
    while (run < upstream_runs) : (run += 1) {
        for (frames, 0..) |*f, i| f.* = actual[i * bound ..][0..bound];
        var observed: Observed = .{};
        var u = try Upstream.create(&case);
        defer u.destroy();
        try runSide(&u, &case, frames, &observed);
        // The original itself gives the same frames on every run.
        try expected_observed.expectEqual(&observed);
        if (observed.failure != null) continue;
        for (expected_frames, frames) |e, a| try common.expectSameFrame(e, a);
    }
    run = 0;
    while (run < port_runs) : (run += 1) {
        for (frames, 0..) |*f, i| f.* = actual[i * bound ..][0..bound];
        var observed: Observed = .{};
        var p = try Port.create(&case);
        defer p.destroy();
        try runSide(&p, &case, frames, &observed);
        expected_observed.expectEqual(&observed) catch |err| {
            std.debug.print("run {d}: the observed values differ\n", .{run});
            return err;
        };
        if (observed.failure != null) continue;
        for (expected_frames, frames) |e, a| {
            common.expectSameFrame(e, a) catch |err| {
                std.debug.print("run {d}: {d} workers, {d} bytes\n", .{ run, case.nb_workers, case.input.len });
                return err;
            };
        }
    }
    if (expected_observed.failure != null) return;
    for (expected_frames) |frame| {
        if (case.dict) |d| {
            try common.expectUpstreamDecodes(frame, case.input, d.bytes);
        } else {
            try common.expectRoundTrip(frame, case.input);
        }
    }
}

// ---------------------------------------------------------------------------
// Inputs
// ---------------------------------------------------------------------------

const Inputs = struct {
    /// Compressible, several jobs.
    text: []u8,
    /// Less compressible, with literals.
    mixed: []u8,
    /// Incompressible.
    random: []u8,
    /// A long repeat beyond the jobs, for long distance matching: a block
    /// of data, other data, then the block again.
    far: []u8,

    fn make() !Inputs {
        const text = try common.generated(6 * mib, 0.5, 0.0, 1);
        errdefer gpa.free(text);
        const mixed = try common.generated(3 * mib, 0.25, 0.5, 2);
        errdefer gpa.free(mixed);
        const random = try gpa.alloc(u8, 2 * mib);
        errdefer gpa.free(random);
        var prng: std.Random.DefaultPrng = .init(3);
        prng.random().bytes(random);
        const far = try gpa.alloc(u8, 5 * mib);
        errdefer gpa.free(far);
        c.reference_genBuffer(far.ptr, 2 * mib, 0.3, 0.2, 4);
        c.reference_genBuffer(far[2 * mib ..].ptr, mib, 0.3, 0.2, 5);
        @memcpy(far[3 * mib ..], far[0 .. 2 * mib]);
        return .{ .text = text, .mixed = mixed, .random = random, .far = far };
    }

    fn free(inputs: *Inputs) void {
        gpa.free(inputs.text);
        gpa.free(inputs.mixed);
        gpa.free(inputs.random);
        gpa.free(inputs.far);
    }
};

const worker_counts = [_]u32{ 1, 2, 3, 4, 8 };

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "zstdmt: levels across every strategy, every worker count" {
    var inputs = try Inputs.make();
    defer inputs.free();
    const levels = [_]i32{ -5, 1, 2, 4, 5, 6, 8, 13, 16, 17, 19, 22 };
    for (levels, 0..) |level, i| {
        const optimal = level >= 16;
        const input = if (optimal) inputs.mixed[0 .. 3 * mib / 2] else inputs.text[0 .. 4 * mib];
        // The optimal parsers' tables are large: fewer workers, and a
        // pledged size that shrinks them.
        const nb_workers = if (optimal) worker_counts[i % 3] else worker_counts[i % worker_counts.len];
        expectSameAsUpstream(.{
            .nb_workers = nb_workers,
            .params = &.{
                .{ .param = p_level, .value = level },
                .{ .param = p_job_size, .value = 512 * kib },
            },
            .input = input,
            .pledged = optimal,
        }) catch |err| {
            std.debug.print("level {d}, {d} workers\n", .{ level, nb_workers });
            return err;
        };
    }
}

test "zstdmt: job sizes from the smallest up, and the default" {
    var inputs = try Inputs.make();
    defer inputs.free();
    const job_sizes = [_]i32{ 1, 512 * kib, 700 * kib + 3, mib, 3 * mib / 2 + 1, 4 * mib, 0 };
    for (job_sizes, 0..) |job_size, i| {
        for ([_]bool{ false, true }) |pledged| {
            expectSameAsUpstream(.{
                .nb_workers = worker_counts[(i + @intFromBool(pledged)) % worker_counts.len],
                .params = &.{
                    .{ .param = p_level, .value = 3 },
                    .{ .param = p_job_size, .value = job_size },
                },
                .input = inputs.text,
                .pledged = pledged,
            }) catch |err| {
                std.debug.print("job size {d}, pledged {}\n", .{ job_size, pledged });
                return err;
            };
        }
    }
}

test "zstdmt: overlap logs 0 to 9" {
    var inputs = try Inputs.make();
    defer inputs.free();
    for (0..10) |overlap_log| {
        for ([_]i32{ 6, 18 }) |level| {
            const input = if (level > 10) inputs.mixed[0..mib] else inputs.mixed;
            expectSameAsUpstream(.{
                .nb_workers = 2 + @as(u32, @intCast(overlap_log % 3)),
                .params = &.{
                    .{ .param = p_level, .value = level },
                    .{ .param = p_job_size, .value = 512 * kib },
                    .{ .param = p_overlap_log, .value = @intCast(overlap_log) },
                },
                .input = input,
                .pledged = level > 10,
            }) catch |err| {
                std.debug.print("overlap log {d}, level {d}\n", .{ overlap_log, level });
                return err;
            };
        }
    }
}

test "zstdmt: long distance matching on and off" {
    var inputs = try Inputs.make();
    defer inputs.free();
    const configs = [_]struct { level: i32, window_log: i32, workers: u32 }{
        .{ .level = 1, .window_log = 23, .workers = 4 },
        .{ .level = 4, .window_log = 22, .workers = 8 },
        .{ .level = 7, .window_log = 23, .workers = 3 },
        .{ .level = 16, .window_log = 23, .workers = 2 },
    };
    for (configs) |config| {
        for ([_]i32{ 1, 2 }) |ldm| {
            for ([_]i32{ 0, 512 * kib }) |job_size| {
                expectSameAsUpstream(.{
                    .nb_workers = config.workers,
                    .params = &.{
                        .{ .param = p_level, .value = config.level },
                        .{ .param = p_window_log, .value = config.window_log },
                        .{ .param = p_ldm, .value = ldm },
                        .{ .param = p_job_size, .value = job_size },
                        .{ .param = p_checksum, .value = 1 },
                    },
                    .input = inputs.far,
                    .script = .{ .chunk = 300 * kib + 1 },
                }) catch |err| {
                    std.debug.print("level {d}, ldm {d}, job size {d}\n", .{ config.level, ldm, job_size });
                    return err;
                };
            }
        }
    }
}

test "zstdmt: rsyncable cuts jobs where the content says" {
    var inputs = try Inputs.make();
    defer inputs.free();
    const scripts = [_]Script{
        .{},
        .{ .chunk = 77_777 },
        .{ .chunk = 31 },
        .{ .chunk = 200_001, .flush_every = 1_000_003, .out_window = 4093 },
        .{ .chunk = 3 * mib, .end_with_data = true },
    };
    for (scripts, 0..) |script, i| {
        const input = if (script.chunk < 100) inputs.text[0 .. mib + 7] else inputs.text;
        for ([_]i32{ 512 * kib, mib }) |job_size| {
            expectSameAsUpstream(.{
                .nb_workers = worker_counts[i % worker_counts.len],
                .params = &.{
                    .{ .param = p_level, .value = 3 },
                    .{ .param = p_job_size, .value = job_size },
                    .{ .param = p_rsyncable, .value = 1 },
                    .{ .param = p_checksum, .value = @intFromBool(i % 2 == 0) },
                },
                .input = input,
                .script = script,
            }) catch |err| {
                std.debug.print("script {d}, job size {d}\n", .{ i, job_size });
                return err;
            };
        }
    }
}

test "zstdmt: checksums, single and several jobs" {
    var inputs = try Inputs.make();
    defer inputs.free();
    for ([_]usize{ 1, 100 * kib, 512 * kib, 2 * mib + 5, 6 * mib }) |size| {
        for ([_]u32{ 1, 3 }) |nb_workers| {
            try expectSameAsUpstream(.{
                .nb_workers = nb_workers,
                .params = &.{
                    .{ .param = p_level, .value = 5 },
                    .{ .param = p_job_size, .value = 512 * kib },
                    .{ .param = p_checksum, .value = 1 },
                },
                .input = inputs.text[0..size],
            });
        }
    }
}

test "zstdmt: edge sizes around a job" {
    var inputs = try Inputs.make();
    defer inputs.free();
    const job = 512 * kib;
    const sizes = [_]usize{ 0, 1, 7, 100 * kib, job - 1, job, job + 1, 2 * job, 2 * job + 1 };
    for (sizes) |size| {
        for ([_]bool{ false, true }) |end_with_data| {
            for ([_]bool{ false, true }) |pledged| {
                expectSameAsUpstream(.{
                    .nb_workers = 2,
                    .params = &.{
                        .{ .param = p_level, .value = 3 },
                        .{ .param = p_job_size, .value = job },
                        .{ .param = p_checksum, .value = 1 },
                    },
                    .input = inputs.text[0..size],
                    .pledged = pledged,
                    .script = .{ .end_with_data = end_with_data },
                }) catch |err| {
                    std.debug.print("size {d}, end with data {}, pledged {}\n", .{ size, end_with_data, pledged });
                    return err;
                };
            }
        }
        // Incompressible.
        try expectSameAsUpstream(.{
            .nb_workers = 3,
            .params = &.{
                .{ .param = p_level, .value = 1 },
                .{ .param = p_job_size, .value = job },
            },
            .input = inputs.random[0..@min(size, inputs.random.len)],
        });
    }
}

test "zstdmt: streaming with flushes and ends at odd points, small output windows" {
    var inputs = try Inputs.make();
    defer inputs.free();
    const scripts = [_]Script{
        .{ .chunk = 100_003, .flush_every = 700_001 },
        .{ .chunk = 1, .flush_every = 3 },
        .{ .chunk = 65_536, .flush_every = 512 * kib, .out_window = 1 },
        .{ .chunk = 333_333, .out_window = 4093, .end_with_data = true },
        .{ .chunk = 6 * mib, .flush_every = 1_234_567, .out_window = 100_000 },
        .{ .chunk = 999, .flush_every = 2 * mib + 11, .end_with_data = true },
    };
    for (scripts, 0..) |script, i| {
        const input = if (script.chunk == 1)
            inputs.text[0..3000]
        else if (script.out_window == 1)
            inputs.text[0 .. mib + 3]
        else
            inputs.text;
        expectSameAsUpstream(.{
            .nb_workers = worker_counts[i % worker_counts.len],
            .params = &.{
                .{ .param = p_level, .value = 4 },
                .{ .param = p_job_size, .value = 512 * kib },
                .{ .param = p_checksum, .value = 1 },
            },
            .input = input,
            .script = script,
        }) catch |err| {
            std.debug.print("script {d}\n", .{i});
            return err;
        };
    }
}

test "zstdmt: the level changes while compressing" {
    var inputs = try Inputs.make();
    defer inputs.free();
    const changes = [_][2]i32{ .{ 3, 9 }, .{ 9, 1 }, .{ 1, 16 }, .{ -3, 5 } };
    for (changes, 0..) |change, i| {
        expectSameAsUpstream(.{
            .nb_workers = worker_counts[(i + 1) % worker_counts.len],
            .params = &.{
                .{ .param = p_level, .value = change[0] },
                .{ .param = p_job_size, .value = 512 * kib },
            },
            .input = inputs.mixed,
            .script = .{ .chunk = 256 * kib, .update_at = mib, .update_level = change[1] },
        }) catch |err| {
            std.debug.print("level {d} to {d}\n", .{ change[0], change[1] });
            return err;
        };
    }
}

test "zstdmt: dictionaries: a raw prefix, a full dictionary, a digested one" {
    var inputs = try Inputs.make();
    defer inputs.free();
    // A dictionary trained on pieces of the input.
    var sizes: [600]usize = undefined;
    @memset(&sizes, 4 * kib);
    var dict_buffer: [32 * kib]u8 = undefined;
    const dict_size = c.ZDICT_trainFromBuffer(&dict_buffer, dict_buffer.len, inputs.mixed.ptr, &sizes, sizes.len);
    try std.testing.expect(c.ZDICT_isError(dict_size) == 0);
    const trained = dict_buffer[0..dict_size];
    const raw = inputs.mixed[2 * mib ..][0 .. 200 * kib];

    const dicts = [_]Dict{
        .{ .bytes = raw, .content_type = .raw_content },
        .{ .bytes = trained, .content_type = .auto },
        .{ .bytes = trained, .content_type = .full_dict },
        .{ .bytes = raw, .content_type = .auto },
        .{ .bytes = trained, .cdict_level = 3 },
        .{ .bytes = trained, .cdict_level = 7 },
    };
    for (dicts, 0..) |dict, i| {
        for ([_]bool{ false, true }) |ldm| {
            expectSameAsUpstream(.{
                .nb_workers = worker_counts[i % worker_counts.len],
                .params = &.{
                    .{ .param = p_level, .value = 7 },
                    .{ .param = p_window_log, .value = 21 },
                    .{ .param = p_job_size, .value = 512 * kib },
                    .{ .param = p_ldm, .value = if (ldm) 1 else 2 },
                },
                .input = inputs.mixed,
                .dict = dict,
                .pledged = i % 2 == 1,
            }) catch |err| {
                std.debug.print("dictionary {d}, ldm {}\n", .{ i, ldm });
                return err;
            };
        }
    }
}

test "zstdmt: a context reused, resized, abandoned mid-frame, on a shared pool" {
    var inputs = try Inputs.make();
    defer inputs.free();
    const p: []const Param = &.{
        .{ .param = p_level, .value = 3 },
        .{ .param = p_job_size, .value = 512 * kib },
        .{ .param = p_checksum, .value = 1 },
    };
    try expectSameAsUpstream(.{ .nb_workers = 3, .params = p, .input = inputs.text, .frames = 3 });
    try expectSameAsUpstream(.{ .nb_workers = 8, .created_workers = 2, .params = p, .input = inputs.text });
    try expectSameAsUpstream(.{ .nb_workers = 2, .created_workers = 8, .params = p, .input = inputs.text });
    try expectSameAsUpstream(.{
        .nb_workers = 4,
        .params = p,
        .input = inputs.text,
        .abandon_after = 3 * mib + 5,
        .frames = 2,
    });
    try expectSameAsUpstream(.{ .nb_workers = 4, .shared_pool = 2, .params = p, .input = inputs.text });
    try expectSameAsUpstream(.{ .nb_workers = 2, .shared_pool = 6, .params = p, .input = inputs.text, .frames = 2 });
}

test "zstdmt: test data and golden files" {
    const data_files = [_][]const u8{ "bc7.bin", "mesh.bin", "snapshot.bin" };
    for (data_files, 0..) |name, i| {
        const bytes = try common.readFile(test_options.data, name);
        defer gpa.free(bytes);
        for ([_]i32{ 3, 12 }) |level| {
            expectSameAsUpstream(.{
                .nb_workers = worker_counts[(i + 2) % worker_counts.len],
                .params = &.{
                    .{ .param = p_level, .value = level },
                    .{ .param = p_job_size, .value = 1 },
                    .{ .param = p_rsyncable, .value = @intFromBool(level == 3) },
                },
                .input = bytes,
                .script = .{ .chunk = 64 * kib },
            }) catch |err| {
                std.debug.print("{s}, level {d}\n", .{ name, level });
                return err;
            };
        }
    }
    const golden = [_][]const u8{
        "http",
        "huffman-compressed-larger",
        "large-literal-and-match-lengths",
        "PR-3517-block-splitter-corruption-test",
    };
    for (golden) |name| {
        const path = try std.fs.path.join(gpa, &.{ "tests/golden-compression", name });
        defer gpa.free(path);
        const bytes = try common.readFile(test_options.reference, path);
        defer gpa.free(bytes);
        try expectSameAsUpstream(.{
            .nb_workers = 2,
            .params = &.{.{ .param = p_level, .value = 19 }},
            .input = bytes,
            .pledged = true,
        });
    }
}

test "zstdmt: continuing a frame being ended is refused" {
    var inputs = try Inputs.make();
    defer inputs.free();
    const case: Case = .{
        .nb_workers = 2,
        .params = &.{
            .{ .param = p_level, .value = 3 },
            .{ .param = p_job_size, .value = 512 * kib },
        },
        .input = inputs.text[0 .. 2 * mib],
    };
    const buffer = try gpa.alloc(u8, c.ZSTD_compressBound(case.input.len));
    defer gpa.free(buffer);
    var results: [2][2]Result = undefined;
    inline for (.{ Upstream, Port }, 0..) |Side, side_index| {
        var side = try Side.create(&case);
        defer side.destroy();
        _ = side.initFrame();
        var observed: Observed = .{};
        var out: Output = .{ .buffer = buffer };
        try feed(&side, &out, .{}, case.input, .@"continue", &observed);
        try feed(&side, &out, .{}, &.{}, .flush, &observed);
        // The end with one byte of room: the frame is ended, not flushed.
        var in_pos: usize = 0;
        results[side_index][0] = compressStream2(&side, &out, 1, &.{}, &in_pos, .end);
        results[side_index][1] = compressStream2(&side, &out, 1 << 40, &.{}, &in_pos, .@"continue");
    }
    try std.testing.expect(results[0][0] == .size and results[0][0].size > 0);
    try std.testing.expect(results[1][0] == .size and results[1][0].size > 0);
    try std.testing.expectEqual(results[0][1], results[1][1]);
    try std.testing.expectEqual(
        Result{ .error_code = @backingInt(zstd.ErrorCode.stage_wrong) },
        results[1][1],
    );
}

test "zstdmt: a context needs a worker" {
    try std.testing.expect(c.reference_mt_create(0, null) == null);
    try std.testing.expect(zstdmt.createCCtxAdvanced(0, gpa, io, null) == null);
}
