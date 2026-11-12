//! The skeptic's probes: parameter sets with several values at or next to
//! their bounds at once, in one-shot, streaming, dictionary and worker
//! compression, each frame compared byte for byte with the original's.
//! Run with `-Dskeptic`. Every probe here passes on the current code.

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
