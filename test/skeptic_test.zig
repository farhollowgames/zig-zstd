//! The skeptic's probes: parameter sets with several values at or next to
//! their bounds at once, in one-shot, streaming, dictionary and worker
//! compression, each frame compared byte for byte with the original's.
//! Run with `-Dskeptic`. The combination probes at the top pass on the
//! current code; each `skeptic: ...` test after them shows one finding and
//! fails, or panics, until it is fixed.

const std = @import("std");
const zstd = @import("zstd");
const c = @import("upstream");
const common = @import("common.zig");
const frame = @import("frame_test.zig");

const params = zstd.params;
const CParameter = params.CParameter;
const gpa = common.gpa;
const Pair = frame.Pair;
const stream_test = @import("stream_test.zig");
const Stream = stream_test.Stream;
const Call = stream_test.Call;

const combo_params = [_]CParameter{
    .compression_level,
    .window_log,
    .hash_log,
    .chain_log,
    .search_log,
    .min_match,
    .target_length,
    .strategy,
    .target_cblock_size,
    .enable_long_distance_matching,
    .ldm_hash_log,
    .ldm_min_match,
    .ldm_bucket_size_log,
    .ldm_hash_rate_log,
    .content_size_flag,
    .checksum_flag,
    .dict_id_flag,
    .force_max_window,
    .literal_compression_mode,
    .src_size_hint,
    .enable_dedicated_dict_search,
    .split_after_sequences,
    .use_row_match_finder,
    .deterministic_ref_prefix,
    .max_block_size,
    .repcode_resolution,
    .block_splitter_level,
    .format,
    .force_attach_dict,
    .prefetch_cdict_tables,
};

/// A value at or next to a bound, with the largest tables capped to keep
/// memory in reach.
fn edgeValue(random: std.Random, param: CParameter) i32 {
    const b = zstd.cParamGetBounds(param);
    var hi: i32 = b.upper;
    switch (param) {
        .window_log => hi = @min(hi, 27),
        .hash_log, .chain_log => hi = @min(hi, 26),
        .ldm_hash_log => hi = @min(hi, 24),
        .ldm_hash_rate_log => hi = @min(hi, 9),
        .src_size_hint => hi = @min(hi, 1 << 30),
        else => {},
    }
    const lo: i64 = b.lower;
    const h: i64 = hi;
    const v: i64 = switch (random.uintLessThan(u32, 5)) {
        0 => lo,
        1 => @min(lo + 1, h),
        2 => @max(h - 1, lo),
        3 => h,
        else => @divTrunc(lo + h, 2),
    };
    return @intCast(v);
}

fn input(kind: u32, size: usize, seed: u32) ![]u8 {
    // The original's datagen writes a byte even for an empty buffer.
    if (size == 0) return gpa.alloc(u8, 0);
    return switch (kind) {
        0 => blk: {
            const buf = try gpa.alloc(u8, size);
            @memset(buf, 'a');
            break :blk buf;
        },
        1 => common.generated(size, 0.0, 0.0, seed),
        2 => common.generated(size, 0.95, 0.05, seed),
        else => common.generated(size, 0.5, 0.5, seed),
    };
}

test "skeptic: compress2 with several parameters at their bounds at once" {
    const seed = common.fuzzSeed(9001);
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();
    const sizes = [_]usize{ 0, 1, 2, 7, 1000, 4097, 70_000, 140_000 };
    for (0..@min(common.fuzz_cases, 400)) |case| {
        errdefer std.debug.print("seed {d}, case {d}\n", .{ seed, case });
        const pair = try Pair.init();
        defer pair.deinit();
        const nb = 2 + random.uintAtMost(usize, 8);
        for (0..nb) |_| {
            const param = combo_params[random.uintLessThan(usize, combo_params.len)];
            const value = edgeValue(random, param);
            errdefer std.debug.print("set {t} = {d}\n", .{ param, value });
            try pair.set(param, value);
        }
        const size = sizes[random.uintLessThan(usize, sizes.len)];
        const src = try input(random.uintLessThan(u32, 4), size, @truncate(case));
        defer gpa.free(src);
        errdefer std.debug.print("{d} bytes\n", .{size});
        _ = try pair.compress2(src, c.ZSTD_compressBound(size));
        try std.testing.expectEqual(c.ZSTD_sizeof_CCtx(pair.upstream), pair.port.sizeof());
        // A second frame on the same context, so the reused state is compared.
        _ = try pair.compress2(src, c.ZSTD_compressBound(size));
        try std.testing.expectEqual(c.ZSTD_sizeof_CCtx(pair.upstream), pair.port.sizeof());
    }
}

test "skeptic: compressStream2 with several parameters at their bounds at once" {
    const seed = common.fuzzSeed(9002);
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();
    const sizes = [_]usize{ 0, 1, 2, 7, 1000, 4097, 70_000, 300_000 };
    for (0..@min(common.fuzz_cases, 300)) |case| {
        errdefer std.debug.print("seed {d}, case {d}\n", .{ seed, case });
        const pair = try Pair.init();
        defer pair.deinit();
        const nb = 2 + random.uintAtMost(usize, 8);
        for (0..nb) |_| {
            const param = combo_params[random.uintLessThan(usize, combo_params.len)];
            const value = edgeValue(random, param);
            errdefer std.debug.print("set {t} = {d}\n", .{ param, value });
            try pair.set(param, value);
        }
        const size = sizes[random.uintLessThan(usize, sizes.len)];
        const src = try input(random.uintLessThan(u32, 4), size, @truncate(case));
        defer gpa.free(src);
        errdefer std.debug.print("{d} bytes\n", .{size});
        const stable_in = random.boolean();
        const stable_out = random.boolean();
        try pair.set(.stable_in_buffer, @intFromBool(stable_in));
        try pair.set(.stable_out_buffer, @intFromBool(stable_out));
        errdefer std.debug.print("stable in {}, out {}\n", .{ stable_in, stable_out });
        const capacity = c.ZSTD_compressBound(size) + 64;
        var stream = try Stream.init(pair, src, capacity, stable_in, stable_out);
        defer stream.deinit();
        var calls: u32 = 0;
        var failed = false;
        while (calls < 20 and stream.in_pos < src.len) : (calls += 1) {
            const kind: Call.Kind = switch (random.uintLessThan(u32, 4)) {
                0, 1 => .stream2_continue,
                2 => .stream2_flush,
                else => .flush,
            };
            const in = switch (random.uintLessThan(u32, 3)) {
                0 => random.uintAtMost(usize, 3),
                1 => random.uintAtMost(usize, 5000),
                else => random.uintAtMost(usize, 200_000),
            };
            const result = try stream.step(.{ .kind = kind, .in = in });
            if (result == .error_code) {
                failed = true;
                break;
            }
        }
        if (!failed) _ = try stream.finish(null, 1 << 40);
        try std.testing.expectEqualSlices(
            u8,
            stream.upstream_out[0..stream.out_pos],
            stream.port_out[0..stream.out_pos],
        );
    }
}

test "skeptic: compress2 with a dictionary and several parameters at their bounds" {
    const seed = common.fuzzSeed(9003);
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();
    const corpus = try common.generated(600_000, 0.6, 0.3, 9003);
    defer gpa.free(corpus);
    const dict_sizes = [_]usize{ 1, 7, 8, 9, 100, 5000, 40_000 };
    const sizes = [_]usize{ 0, 1, 2, 7, 1000, 4097, 70_000, 140_000 };
    for (0..@min(common.fuzz_cases, 400)) |case| {
        errdefer std.debug.print("seed {d}, case {d}\n", .{ seed, case });
        const pair = try Pair.init();
        defer pair.deinit();
        const nb = 1 + random.uintAtMost(usize, 7);
        for (0..nb) |_| {
            const param = combo_params[random.uintLessThan(usize, combo_params.len)];
            const value = edgeValue(random, param);
            errdefer std.debug.print("set {t} = {d}\n", .{ param, value });
            try pair.set(param, value);
        }
        const dict = corpus[0..dict_sizes[random.uintLessThan(usize, dict_sizes.len)]];
        const level: i32 = random.intRangeAtMost(i32, -5, 22);
        const how = random.uintLessThan(u32, 3);
        errdefer std.debug.print("dict {d} bytes, way {d}, level {d}\n", .{
            dict.len, how, level,
        });
        var port_cdict: ?*zstd.CDict = null;
        defer if (port_cdict) |d| d.destroy();
        var upstream_cdict: ?*c.ZSTD_CDict = null;
        defer if (upstream_cdict) |d| {
            _ = c.ZSTD_freeCDict(d);
        };
        switch (how) {
            0 => {
                port_cdict = try zstd.CDict.create(gpa, dict, level);
                upstream_cdict = c.ZSTD_createCDict(dict.ptr, dict.len, level).?;
                try frame.expectSameResult(
                    c.ZSTD_CCtx_refCDict(pair.upstream, upstream_cdict),
                    pair.port.refCDict(port_cdict),
                );
            },
            1 => try frame.expectSameResult(
                c.ZSTD_CCtx_loadDictionary(pair.upstream, dict.ptr, dict.len),
                pair.port.loadDictionary(dict),
            ),
            else => try frame.expectSameResult(
                c.ZSTD_CCtx_refPrefix(pair.upstream, dict.ptr, dict.len),
                pair.port.refPrefix(dict),
            ),
        }
        const size = sizes[random.uintLessThan(usize, sizes.len)];
        const src = corpus[corpus.len - size ..];
        errdefer std.debug.print("{d} bytes\n", .{size});
        _ = try pair.compress2(src, c.ZSTD_compressBound(size));
        try std.testing.expectEqual(c.ZSTD_sizeof_CCtx(pair.upstream), pair.port.sizeof());
    }
}

const mt_params = combo_params ++ [_]CParameter{ .job_size, .overlap_log, .rsyncable };

test "skeptic: compress2 with workers and several parameters at their bounds" {
    if (@typeInfo(zstd.internal.zstdmt.ZstdmtCCtx) == .@"opaque") return error.SkipZigTest;
    const seed = common.fuzzSeed(9004);
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();
    const corpus = try common.generated(3 << 20, 0.6, 0.3, 9004);
    defer gpa.free(corpus);
    const sizes = [_]usize{ 0, 1, 1000, 600_000, 1_500_000, 3 << 20 };
    for (0..@min(common.fuzz_cases, 120)) |case| {
        errdefer std.debug.print("seed {d}, case {d}\n", .{ seed, case });
        const pair = try Pair.init();
        defer pair.deinit();
        pair.port.setIo(std.testing.io);
        const workers: i32 = 1 + @as(i32, random.uintLessThan(u8, 2));
        try pair.set(.nb_workers, workers);
        errdefer std.debug.print("workers {d}\n", .{workers});
        const nb = 1 + random.uintAtMost(usize, 7);
        var set: [8]struct { CParameter, i32 } = undefined;
        for (set[0..nb]) |*entry| {
            const param = mt_params[random.uintLessThan(usize, mt_params.len)];
            entry.* = .{ param, edgeValue(random, param) };
            try pair.set(entry[0], entry[1]);
        }
        errdefer for (set[0..nb]) |entry| std.debug.print("set {t} = {d}\n", entry);
        const size = sizes[random.uintLessThan(usize, sizes.len)];
        const src = corpus[corpus.len - size ..];
        errdefer std.debug.print("{d} bytes\n", .{size});
        _ = try pair.compress2(src, c.ZSTD_compressBound(size));
        // The original's context size with workers depends on its threads'
        // timing (the buffers its pool holds), so it is not compared.
    }
}

/// Parameters whose tables shrink to a known input size, so their full
/// bounds stay cheap in one-shot compression.
const shrinking_params = [_]CParameter{
    .compression_level,
    .window_log,
    .hash_log,
    .chain_log,
    .search_log,
    .min_match,
    .target_length,
    .strategy,
    .target_cblock_size,
    .literal_compression_mode,
    .use_row_match_finder,
    .max_block_size,
    .repcode_resolution,
    .block_splitter_level,
    .split_after_sequences,
    .checksum_flag,
};

test "skeptic: compress2 with the full window, hash and chain bounds at once" {
    const seed = common.fuzzSeed(9005);
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();
    const sizes = [_]usize{ 0, 1, 2, 7, 1000, 4097, 70_000, 140_000 };
    for (0..@min(common.fuzz_cases, 400)) |case| {
        errdefer std.debug.print("seed {d}, case {d}\n", .{ seed, case });
        const pair = try Pair.init();
        defer pair.deinit();
        const nb = 2 + random.uintAtMost(usize, 8);
        for (0..nb) |_| {
            const param = shrinking_params[random.uintLessThan(usize, shrinking_params.len)];
            const b = zstd.cParamGetBounds(param);
            const value = switch (random.uintLessThan(u32, 4)) {
                0 => b.lower,
                1 => b.upper,
                2 => @max(b.upper - 1, b.lower),
                else => edgeValue(random, param),
            };
            errdefer std.debug.print("set {t} = {d}\n", .{ param, value });
            try pair.set(param, value);
        }
        const size = sizes[random.uintLessThan(usize, sizes.len)];
        const src = try input(random.uintLessThan(u32, 4), size, @truncate(case));
        defer gpa.free(src);
        errdefer std.debug.print("{d} bytes\n", .{size});
        _ = try pair.compress2(src, c.ZSTD_compressBound(size));
        try std.testing.expectEqual(c.ZSTD_sizeof_CCtx(pair.upstream), pair.port.sizeof());
    }
}

// The findings: each test below fails, or panics, until its finding is fixed.

/// Streams `src` on both sides with `.flush` and then `.end`, so the size
/// stays unknown, and compares every result and the frames.
fn expectSameFlushedStream(pair: Pair, src: []const u8) !void {
    const capacity = c.ZSTD_compressBound(src.len) + 64;
    const expected = try gpa.alloc(u8, capacity);
    defer gpa.free(expected);
    const actual = try gpa.alloc(u8, capacity);
    defer gpa.free(actual);
    var upstream_out: c.ZSTD_outBuffer = .{ .dst = expected.ptr, .size = capacity, .pos = 0 };
    var upstream_in: c.ZSTD_inBuffer = .{ .src = src.ptr, .size = src.len, .pos = 0 };
    var port_out: zstd.OutBuffer = .{ .dst = actual };
    var port_in: zstd.InBuffer = .{ .src = src };
    for ([_]zstd.EndDirective{ .flush, .end }) |op| {
        const code = c.ZSTD_compressStream2(
            pair.upstream,
            &upstream_out,
            &upstream_in,
            @backingInt(op),
        );
        try frame.expectSameResult(code, pair.port.compressStream2(&port_out, &port_in, op));
        try std.testing.expectEqual(upstream_in.pos, port_in.pos);
        try std.testing.expectEqual(upstream_out.pos, port_out.pos);
    }
    try common.expectSameFrame(expected[0..upstream_out.pos], actual[0..port_out.pos]);
}

// `Window.checkDictValidity` and `Window.enforceMaxDist` add the window size
// to the dictionary's end index in u32 with `+`, where the original's U32 sum
// wraps. A prefix of 2 GiB puts the end index at 2^31 + 2, and a window log
// of 31 makes the window 2^31: the port panics with an integer overflow in a
// safe build, while the original's sum wraps to 2 and it drops the prefix.
test "skeptic: a 2 GiB prefix with window log 31 overflows the dictionary's validity check" {
    const prefix = try gpa.alloc(u8, 1 << 31);
    defer gpa.free(prefix);
    @memset(prefix, 'z');
    const src = try common.generated(200_000, 0.5, 0.3, 31);
    defer gpa.free(src);
    const pair = try Pair.init();
    defer pair.deinit();
    try pair.set(.window_log, 31);
    try pair.set(.strategy, 1);
    try pair.set(.hash_log, 16);
    try pair.set(.chain_log, 16);
    // A stable input, so neither side buffers a 2 GiB window.
    try pair.set(.stable_in_buffer, 1);
    try frame.expectSameResult(
        c.ZSTD_CCtx_refPrefix(pair.upstream, prefix.ptr, prefix.len),
        pair.port.refPrefix(prefix),
    );
    try expectSameFlushedStream(pair, src);
}

// `CCtx.refThreadPool` says the pool "must stay valid until it is replaced"
// (and zstd.zig's `CCtx` doc says the same of the pool and the `Io`), but the
// multithreaded context made at the first frame with workers keeps the pool
// it was made with: after `refThreadPool(other)`, the workers still run on
// the first pool, so freeing it as documented is a use after free. The
// original behaves the same; the documentation is what is wrong.
test "skeptic: a thread pool replaced by refThreadPool still runs the context's workers" {
    if (@typeInfo(zstd.internal.zstdmt.ZstdmtCCtx) == .@"opaque") return error.SkipZigTest;
    const io = std.testing.io;
    const first = zstd.createThreadPool(gpa, io, 2) orelse return error.OutOfMemory;
    defer zstd.freeThreadPool(first);
    const second = zstd.createThreadPool(gpa, io, 2) orelse return error.OutOfMemory;
    defer zstd.freeThreadPool(second);
    const cctx = try zstd.CCtx.create(gpa);
    defer cctx.destroy() catch unreachable;
    try cctx.refThreadPool(first);
    _ = try cctx.setParameter(.nb_workers, 2);
    const src = try common.generated(3 << 20, 0.6, 0.3, 77);
    defer gpa.free(src);
    const dst = try gpa.alloc(u8, zstd.compressBound(src.len));
    defer gpa.free(dst);
    _ = try cctx.compress2(dst, src);
    try cctx.refThreadPool(second);
    _ = try cctx.compress2(dst, src);
    try std.testing.expect(cctx.mtctx.?.factory.? == second);
}

// Probes run while looking for findings; kept only while they find one.

/// Sets `dict` on both sides one `way`: 0 none, 1 loaded, 2 a CDict at
/// `level`, 3 a prefix. The CDicts are returned for the caller to free.
fn setDict(pair: Pair, way: u32, dict: []const u8, level: i32) !struct {
    ?*zstd.CDict,
    ?*c.ZSTD_CDict,
} {
    switch (way) {
        1 => try frame.expectSameResult(
            c.ZSTD_CCtx_loadDictionary(pair.upstream, dict.ptr, dict.len),
            pair.port.loadDictionary(dict),
        ),
        2 => {
            const port_cdict = try zstd.CDict.create(gpa, dict, level);
            const upstream_cdict = c.ZSTD_createCDict(dict.ptr, dict.len, level).?;
            try frame.expectSameResult(
                c.ZSTD_CCtx_refCDict(pair.upstream, upstream_cdict),
                pair.port.refCDict(port_cdict),
            );
            return .{ port_cdict, upstream_cdict };
        },
        3 => try frame.expectSameResult(
            c.ZSTD_CCtx_refPrefix(pair.upstream, dict.ptr, dict.len),
            pair.port.refPrefix(dict),
        ),
        else => {},
    }
    return .{ null, null };
}

test "skeptic probe: pledged sizes near 2^64 with dictionaries and workers" {
    const corpus = try common.generated(400_000, 0.6, 0.3, 64);
    defer gpa.free(corpus);
    const dict = corpus[0..20_000];
    const src = corpus[corpus.len - 150_000 ..];
    const max = std.math.maxInt(u64);
    const pledged_sizes = [_]u64{
        max - 1,       max - 2, max - src.len, 1 << 63, (1 << 32) + 5, 1 << 32,
        (1 << 32) - 1, 1 << 31, src.len + 1,
    };
    const levels = [_]i32{ -5, 1, 3, 9, 19 };
    for (pledged_sizes) |pledged| for (0..4) |way| for (levels) |level| for ([_]i32{ 0, 2 }) |nb| {
        errdefer std.debug.print("pledged {d}, dict way {d}, level {d}, workers {d}\n", .{
            pledged, way, level, nb,
        });
        const pair = try Pair.init();
        defer pair.deinit();
        pair.port.setIo(std.testing.io);
        try pair.set(.compression_level, level);
        try pair.set(.nb_workers, nb);
        const cdicts = try setDict(pair, @intCast(way), dict, level);
        defer if (cdicts[0]) |d| d.destroy();
        defer if (cdicts[1]) |d| {
            _ = c.ZSTD_freeCDict(d);
        };
        try frame.expectSameResult(
            c.ZSTD_CCtx_setPledgedSrcSize(pair.upstream, pledged),
            pair.port.setPledgedSrcSize(pledged),
        );
        try expectSameFlushedStream(pair, src);
    };
}

fn pick(random: std.Random, values: []const i32) i32 {
    return values[random.uintLessThan(usize, values.len)];
}

test "skeptic probe: long distance matching at its largest tables and rates" {
    // Two copies of the same 1 MiB far apart, with other data between.
    const corpus = try common.generated(5 << 20, 0.5, 0.4, 65);
    defer gpa.free(corpus);
    @memcpy(corpus[4 << 20 ..], corpus[0 .. 1 << 20]);
    const seed = common.fuzzSeed(9101);
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();
    for (0..@min(common.fuzz_cases, 40)) |case| {
        errdefer std.debug.print("seed {d}, case {d}\n", .{ seed, case });
        const pair = try Pair.init();
        defer pair.deinit();
        const hash_log = pick(random, &.{ 25, 26, 27, 25, 26, 20 });
        const bucket = pick(random, &.{ 1, 4, 8, 8, 0 });
        const min_match = pick(random, &.{ 4, 5, 64, 65, 4096, 0 });
        const rate = pick(random, &.{ 0, 1, 7, 24, 25 });
        const window_log = pick(random, &.{ 0, 27, 28, 31 });
        const level = pick(random, &.{ 1, 3, 5, 7, 16, 19, 22 });
        const streamed = random.boolean();
        errdefer std.debug.print(
            "ldm hash log {d}, bucket {d}, min match {d}, rate {d}, window {d}, " ++
                "level {d}, streamed {}\n",
            .{ hash_log, bucket, min_match, rate, window_log, level, streamed },
        );
        try pair.set(.enable_long_distance_matching, 1);
        try pair.set(.ldm_hash_log, hash_log);
        try pair.set(.ldm_bucket_size_log, bucket);
        try pair.set(.ldm_min_match, min_match);
        try pair.set(.ldm_hash_rate_log, rate);
        try pair.set(.window_log, window_log);
        try pair.set(.compression_level, level);
        if (streamed) {
            // An unknown size keeps the whole window; a stable input keeps
            // it out of the context's buffers.
            try pair.set(.stable_in_buffer, 1);
            try expectSameFlushedStream(pair, corpus);
        } else {
            _ = try pair.compress2(corpus, c.ZSTD_compressBound(corpus.len));
        }
    }
}

test "skeptic probe: size hints near 2^31 with dictionaries, streamed" {
    const corpus = try common.generated(400_000, 0.6, 0.3, 66);
    defer gpa.free(corpus);
    const dict = corpus[0..30_000];
    const src = corpus[corpus.len - 150_000 ..];
    const int_max = std.math.maxInt(i32);
    const hints = [_]i32{ int_max, int_max - 1, int_max - 30_000, (1 << 30) + 1, 1 << 30 };
    for (hints) |hint| for (0..4) |way| for ([_]i32{ 1, 3, 9, 19, 22 }) |level| {
        errdefer std.debug.print("hint {d}, dict way {d}, level {d}\n", .{ hint, way, level });
        const pair = try Pair.init();
        defer pair.deinit();
        try pair.set(.compression_level, level);
        try pair.set(.src_size_hint, hint);
        const cdicts = try setDict(pair, @intCast(way), dict, level);
        defer if (cdicts[0]) |d| d.destroy();
        defer if (cdicts[1]) |d| {
            _ = c.ZSTD_freeCDict(d);
        };
        try expectSameFlushedStream(pair, src);
    };
}

test "skeptic probe: the smallest blocks with superblocks at every level" {
    const src = try common.generated(300_000, 0.6, 0.3, 67);
    defer gpa.free(src);
    for ([_]i32{ -5, 1, 2, 3, 5, 7, 13, 16, 19, 22 }) |level| for ([_]i32{
        1340, 1341, 2000, 1 << 17,
    }) |target| for ([_]i32{ 1024, 1025, 1500, 1 << 17 }) |max_block| {
        errdefer std.debug.print("level {d}, target {d}, max block {d}\n", .{
            level, target, max_block,
        });
        const pair = try Pair.init();
        defer pair.deinit();
        try pair.set(.compression_level, level);
        try pair.set(.target_cblock_size, target);
        try pair.set(.max_block_size, max_block);
        _ = try pair.compress2(src, c.ZSTD_compressBound(src.len));
        try expectSameFlushedStream(pair, src);
    };
}
