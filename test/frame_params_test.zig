//! Oracle tests of the advanced parameters: their bounds, setting and
//! reading them on a context and on parameters held apart, frames made with
//! each and with fuzzed sets of them, contexts reused across frames and
//! reset, and static contexts with the sizes their estimates give.

const std = @import("std");
const zstd = @import("zstd");
const c = @import("upstream");
const common = @import("common.zig");
const frame = @import("frame_test.zig");

const params = zstd.params;
const CParameter = params.CParameter;
const gpa = common.gpa;
const testing = std.testing;
const Pair = frame.Pair;
const expectSameResult = frame.expectSameResult;

const all_params = std.enums.values(CParameter);

/// `result` without its value.
fn voidOf(result: anytype) zstd.Error!void {
    _ = try result;
}

/// The original's bounds, which must be the port's.
fn upstreamBounds(param: CParameter) params.Bounds {
    const b = c.ZSTD_cParam_getBounds(@backingInt(param));
    std.debug.assert(c.ZSTD_isError(b.@"error") == 0);
    return .{ .lower = b.lower_bound, .upper = b.upper_bound };
}

/// Checks every parameter reads back the same from both contexts.
fn expectSameParameters(pair: Pair) !void {
    for (all_params) |param| {
        var value: c_int = undefined;
        const code = c.ZSTD_CCtx_getParameter(pair.upstream, @backingInt(param), &value);
        const result = pair.port.getParameter(param);
        expectSameResult(code, voidOf(result)) catch |err| {
            std.debug.print("getParameter {t}\n", .{param});
            return err;
        };
        const actual = result catch continue;
        testing.expectEqual(value, actual) catch |err| {
            std.debug.print("getParameter {t}\n", .{param});
            return err;
        };
    }
}

/// Values in and around `param`'s bounds.
fn testValues(param: CParameter) [9]i32 {
    const b = upstreamBounds(param);
    const lo: i64 = b.lower;
    const hi: i64 = b.upper;
    const values = [9]i64{ lo - 1, lo, lo + 1, @divTrunc(lo + hi, 2), hi - 1, hi, hi + 1, 0, -1 };
    var out: [9]i32 = undefined;
    for (values, &out) |v, *o| o.* = @intCast(
        std.math.clamp(v, std.math.minInt(i32), std.math.maxInt(i32)),
    );
    return out;
}

/// Whether frames with `param` set can be decoded by std and the original
/// without telling them.
fn decodable(param: CParameter, value: i32) bool {
    return !(param == .format and value == 1);
}

test "cParamGetBounds: every parameter" {
    for (all_params) |param| {
        const b = zstd.cParamGetBounds(param);
        try testing.expectEqual(upstreamBounds(param), b);
    }
}

test "setParameter, getParameter: every parameter over its bounds, and a frame with each" {
    const src = try common.generated(150_000, 0.5, 0.3, 51);
    defer gpa.free(src);
    for (all_params) |param| {
        for (testValues(param)) |value| {
            const pair = try Pair.init();
            defer pair.deinit();
            try expectSameParameters(pair);
            try pair.set(param, value);
            try expectSameParameters(pair);
            for ([_]usize{ 0, 1, 1000, src.len }) |size| {
                const out = pair.compress2Frame(
                    src[0..size],
                    c.ZSTD_compressBound(size),
                ) catch |err| {
                    std.debug.print("{t} = {d}, {d} bytes\n", .{ param, value, size });
                    return err;
                } orelse continue;
                defer gpa.free(out);
                if (decodable(param, value)) try common.expectRoundTrip(out, src[0..size]);
            }
        }
    }
}

test "setParameter: values that interact" {
    const src = try common.generated(300_000, 0.6, 0.2, 52);
    defer gpa.free(src);
    const Case = []const common.Param;
    const cases = [_]Case{
        &.{ .{ .param = 160, .value = 1 }, .{ .param = 101, .value = 20 } },
        &.{
            .{ .param = 160, .value = 1 },
            .{ .param = 100, .value = 19 },
            .{ .param = 161, .value = 16 },
        },
        &.{
            .{ .param = 160, .value = 1 },
            .{ .param = 162, .value = 32 },
            .{ .param = 164, .value = 4 },
        },
        &.{ .{ .param = 100, .value = 7 }, .{ .param = 1011, .value = 1 } },
        &.{ .{ .param = 100, .value = 7 }, .{ .param = 1011, .value = 2 } },
        &.{ .{ .param = 100, .value = 5 }, .{ .param = 1005, .value = 1 } },
        &.{ .{ .param = 130, .value = 2000 }, .{ .param = 100, .value = 3 } },
        &.{ .{ .param = 130, .value = 1340 }, .{ .param = 100, .value = 19 } },
        &.{ .{ .param = 1015, .value = 4096 }, .{ .param = 100, .value = 9 } },
        &.{ .{ .param = 1017, .value = 6 }, .{ .param = 100, .value = 17 } },
        &.{ .{ .param = 1017, .value = 1 }, .{ .param = 100, .value = 1 } },
        &.{ .{ .param = 1010, .value = 2 }, .{ .param = 100, .value = 19 } },
        &.{ .{ .param = 1002, .value = 2 }, .{ .param = 100, .value = 1 } },
        &.{ .{ .param = 1002, .value = 1 }, .{ .param = 100, .value = -3 } },
        &.{ .{ .param = 1000, .value = 1 }, .{ .param = 101, .value = 15 } },
        &.{ .{ .param = 1004, .value = 1000 }, .{ .param = 100, .value = 12 } },
        &.{ .{ .param = 1016, .value = 2 }, .{ .param = 100, .value = 12 } },
        &.{
            .{ .param = 107, .value = 9 },
            .{ .param = 101, .value = 18 },
            .{ .param = 105, .value = 3 },
        },
        &.{
            .{ .param = 107, .value = 6 },
            .{ .param = 104, .value = 9 },
            .{ .param = 106, .value = 999 },
        },
        &.{
            .{ .param = 200, .value = 0 },
            .{ .param = 201, .value = 1 },
            .{ .param = 202, .value = 0 },
        },
        &.{ .{ .param = 400, .value = 2 }, .{ .param = 100, .value = 3 } },
    };
    for (cases, 0..) |case, i| {
        const pair = try Pair.init();
        defer pair.deinit();
        for (case) |p| try pair.set(@fromBackingInt(p.param), p.value);
        try expectSameParameters(pair);
        for ([_]usize{ 1, 10_000, src.len }) |size| {
            _ = pair.compress2(src[0..size], c.ZSTD_compressBound(size)) catch |err| {
                std.debug.print("case {d}, {d} bytes\n", .{ i, size });
                return err;
            };
        }
    }
}

/// A value for `param`, mostly inside its bounds; the logs that size tables
/// stay small enough for the test's memory.
fn randomValue(random: std.Random, param: CParameter) i32 {
    const b = upstreamBounds(param);
    var hi = b.upper;
    switch (param) {
        .window_log => hi = @min(hi, 25),
        .hash_log, .chain_log => hi = @min(hi, 24),
        .ldm_hash_log => hi = @min(hi, 22),
        // A rate over the window log gives the largest hash table, of 8 GiB.
        .ldm_hash_rate_log => hi = @min(hi, 9),
        .search_log => hi = @min(hi, 12),
        .nb_workers => hi = @min(hi, 2),
        else => {},
    }
    return switch (random.uintLessThan(u32, 16)) {
        0 => b.lower -| 1,
        1 => hi +| 1,
        2 => 0,
        else => random.intRangeAtMost(i32, b.lower, hi),
    };
}

/// Parameters that compress2 uses, for the fuzzed sets.
const fuzzed_params = [_]CParameter{
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
    .nb_workers,
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
    .stable_in_buffer,
    .stable_out_buffer,
};

test "compress2: fuzzed parameter sets, fresh and reused contexts" {
    const seed = common.fuzzSeed(53);
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();
    const input = try common.generated(400_000, 0.5, 0.3, 53);
    defer gpa.free(input);
    const reused = try Pair.init();
    defer reused.deinit();
    for (0..common.fuzz_cases) |case| {
        errdefer std.debug.print("seed {d}, case {d}\n", .{ seed, case });
        const fresh = try Pair.init();
        defer fresh.deinit();
        if (random.uintLessThan(u32, 4) == 0) {
            const directive: params.ResetDirective = @fromBackingInt(
                random.intRangeAtMost(u32, 1, 3),
            );
            try expectSameResult(
                c.ZSTD_CCtx_reset(reused.upstream, @backingInt(directive)),
                reused.port.reset(directive),
            );
        }
        const nb_params = random.uintAtMost(usize, 8);
        for (0..nb_params) |_| {
            const param = fuzzed_params[random.uintLessThan(usize, fuzzed_params.len)];
            const value = randomValue(random, param);
            try fresh.set(param, value);
            try reused.set(param, value);
        }
        const size = if (random.uintLessThan(u32, 8) == 0)
            random.uintAtMost(usize, input.len)
        else
            random.uintAtMost(usize, 40_000);
        const start = random.uintAtMost(usize, input.len - size);
        const src = input[start..][0..size];
        const capacity = if (random.uintLessThan(u32, 16) == 0)
            random.uintAtMost(usize, c.ZSTD_compressBound(size))
        else
            c.ZSTD_compressBound(size);
        _ = try fresh.compress2(src, capacity);
        _ = try reused.compress2(src, capacity);
        try expectSameParameters(reused);
    }
}

test "compressCCtx, compressAdvanced and compress2 on one context" {
    const src = try common.generated(200_000, 0.5, 0.3, 54);
    defer gpa.free(src);
    const pair = try Pair.init();
    defer pair.deinit();
    const expected = try frame.boundBuffer(src.len);
    defer gpa.free(expected);
    const dst = try frame.boundBuffer(src.len);
    defer gpa.free(dst);
    var prng = std.Random.DefaultPrng.init(common.fuzzSeed(54));
    const random = prng.random();
    for (0..200) |round| {
        errdefer std.debug.print("round {d}\n", .{round});
        const level = frame.levels[random.uintLessThan(usize, frame.levels.len)];
        const size = random.uintAtMost(usize, src.len);
        switch (random.uintLessThan(u32, 4)) {
            0 => {
                const code = c.ZSTD_compressCCtx(
                    pair.upstream,
                    expected.ptr,
                    expected.len,
                    src.ptr,
                    size,
                    level,
                );
                const n = try pair.port.compressCCtx(dst, src[0..size], level);
                try common.expectSameFrame(expected[0..code], dst[0..n]);
            },
            1 => {
                var p = zstd.getParams(level, size, 0);
                p.fparams.checksum_flag = random.boolean();
                p.fparams.content_size_flag = random.boolean();
                const code = c.ZSTD_compress_advanced(
                    pair.upstream,
                    expected.ptr,
                    expected.len,
                    src.ptr,
                    size,
                    null,
                    0,
                    frame.parametersToC(p),
                );
                const n = try pair.port.compressAdvanced(dst, src[0..size], null, p);
                try common.expectSameFrame(expected[0..code], dst[0..n]);
            },
            2 => try pair.set(.compression_level, level),
            else => _ = try pair.compress2(src[0..size], expected.len),
        }
    }
}

test "setCParams, setFParams, setParams, setPledgedSrcSize" {
    const src = try common.generated(100_000, 0.5, 0.3, 55);
    defer gpa.free(src);
    const seed = common.fuzzSeed(55);
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();
    for (0..common.fuzz_cases / 4) |case| {
        errdefer std.debug.print("seed {d}, case {d}\n", .{ seed, case });
        const pair = try Pair.init();
        defer pair.deinit();
        var p = zstd.getParams(
            random.intRangeAtMost(i32, -5, 22),
            random.uintAtMost(u64, 1 << 20),
            0,
        );
        if (random.uintLessThan(u32, 4) == 0) p.cparams.window_log = random.uintAtMost(u32, 40);
        if (random.uintLessThan(u32, 4) == 0) p.cparams.hash_log = random.uintAtMost(u32, 24);
        if (random.uintLessThan(u32, 8) == 0) p.cparams.strategy = @fromBackingInt(
            random.uintAtMost(u32, 10),
        );
        p.fparams = .{
            .content_size_flag = random.boolean(),
            .checksum_flag = random.boolean(),
            .no_dict_id_flag = random.boolean(),
        };
        switch (random.uintLessThan(u32, 3)) {
            0 => try expectSameResult(
                c.ZSTD_CCtx_setCParams(pair.upstream, frame.toC(p.cparams)),
                pair.port.setCParams(p.cparams),
            ),
            1 => try expectSameResult(
                c.ZSTD_CCtx_setFParams(pair.upstream, frame.fparamsToC(p.fparams)),
                pair.port.setFParams(p.fparams),
            ),
            else => try expectSameResult(
                c.ZSTD_CCtx_setParams(pair.upstream, frame.parametersToC(p)),
                pair.port.setParams(p),
            ),
        }
        try expectSameParameters(pair);
        const size = random.uintAtMost(usize, src.len);
        if (random.boolean()) {
            const pledged = if (random.boolean()) size else random.uintAtMost(u64, src.len);
            try expectSameResult(
                c.ZSTD_CCtx_setPledgedSrcSize(pair.upstream, pledged),
                pair.port.setPledgedSrcSize(pledged),
            );
        }
        _ = try pair.compress2(src[0..size], c.ZSTD_compressBound(size));
    }
}

test "reset: each directive, between frames" {
    const src = try common.generated(100_000, 0.5, 0.3, 56);
    defer gpa.free(src);
    const pair = try Pair.init();
    defer pair.deinit();
    for (std.enums.values(params.ResetDirective)) |directive| {
        try pair.set(.compression_level, 19);
        try pair.set(.checksum_flag, 1);
        try pair.set(.window_log, 17);
        try expectSameResult(
            c.ZSTD_CCtx_setPledgedSrcSize(pair.upstream, 5),
            pair.port.setPledgedSrcSize(5),
        );
        try expectSameResult(
            c.ZSTD_CCtx_reset(pair.upstream, @backingInt(directive)),
            pair.port.reset(directive),
        );
        try expectSameParameters(pair);
        _ = try pair.compress2(src, c.ZSTD_compressBound(src.len));
    }
}

/// Parameters held apart from a context, one of each side.
const ParamsPair = struct {
    port: *zstd.CCtxParams,
    upstream: *c.ZSTD_CCtx_params,

    fn init() !ParamsPair {
        const port = try zstd.CCtxParams.create(gpa);
        const upstream = c.ZSTD_createCCtxParams() orelse return error.OutOfMemory;
        return .{ .port = port, .upstream = upstream };
    }

    fn deinit(pair: ParamsPair) void {
        pair.port.destroy();
        _ = c.ZSTD_freeCCtxParams(pair.upstream);
    }

    fn set(pair: ParamsPair, param: CParameter, value: i32) !void {
        const code = c.ZSTD_CCtxParams_setParameter(pair.upstream, @backingInt(param), value);
        try expectSameResult(code, pair.port.setParameter(param, value));
    }

    fn expectSame(pair: ParamsPair) !void {
        for (all_params) |param| {
            var value: c_int = undefined;
            const code = c.ZSTD_CCtxParams_getParameter(pair.upstream, @backingInt(param), &value);
            const result = pair.port.getParameter(param);
            try expectSameResult(code, voidOf(result));
            const actual = result catch continue;
            testing.expectEqual(value, actual) catch |err| {
                std.debug.print("{t}\n", .{param});
                return err;
            };
        }
    }
};

test "CCtxParams: set, get, init, reset, and applied to a context" {
    const src = try common.generated(150_000, 0.5, 0.3, 57);
    defer gpa.free(src);
    const seed = common.fuzzSeed(57);
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();
    const held = try ParamsPair.init();
    defer held.deinit();
    try held.expectSame();
    for (0..common.fuzz_cases / 4) |case| {
        errdefer std.debug.print("seed {d}, case {d}\n", .{ seed, case });
        switch (random.uintLessThan(u32, 8)) {
            0 => {
                const level = random.intRangeAtMost(i32, -10, 25);
                try expectSameResult(c.ZSTD_CCtxParams_init(held.upstream, level), {});
                held.port.* = zstd.CCtxParams.init(level);
                held.port.custom_mem = gpa;
            },
            1 => {
                var p = zstd.getParams(random.intRangeAtMost(i32, 1, 22), 0, 0);
                if (random.uintLessThan(u32, 4) == 0) p.cparams.window_log = 5;
                const code = c.ZSTD_CCtxParams_init_advanced(held.upstream, frame.parametersToC(p));
                const result = zstd.CCtxParams.initAdvanced(p);
                try expectSameResult(code, voidOf(result));
                if (result) |value| {
                    held.port.* = value;
                    held.port.custom_mem = gpa;
                } else |_| {}
            },
            2 => {
                try expectSameResult(c.ZSTD_CCtxParams_reset(held.upstream), {});
                held.port.reset();
            },
            else => for (0..random.uintAtMost(usize, 4)) |_| {
                const param = fuzzed_params[random.uintLessThan(usize, fuzzed_params.len)];
                try held.set(param, randomValue(random, param));
            },
        }
        try held.expectSame();
        const pair = try Pair.init();
        defer pair.deinit();
        try expectSameResult(
            c.ZSTD_CCtx_setParametersUsingCCtxParams(pair.upstream, held.upstream),
            pair.port.setParametersUsingCCtxParams(held.port),
        );
        try expectSameParameters(pair);
        const size = random.uintAtMost(usize, src.len);
        _ = try pair.compress2(src[0..size], c.ZSTD_compressBound(size));
        // With long distance matching on and its minimum match unset, the
        // estimates divide by zero, the original's as the port's.
        const ldm_on = try held.port.getParameter(.enable_long_distance_matching) == 1;
        if (ldm_on and try held.port.getParameter(.ldm_min_match) == 0) continue;
        try expectSameResult(
            c.ZSTD_estimateCCtxSize_usingCCtxParams(held.upstream),
            zstd.estimateCCtxSizeUsingCCtxParams(held.port),
        );
        try expectSameResult(
            c.ZSTD_estimateCStreamSize_usingCCtxParams(held.upstream),
            zstd.estimateCStreamSizeUsingCCtxParams(held.port),
        );
    }
}

test "estimate: every level, fuzzed compression parameters" {
    var level: i32 = -10;
    while (level <= 23) : (level += 1) {
        try testing.expectEqual(c.ZSTD_estimateCCtxSize(level), zstd.estimateCCtxSize(level));
        try testing.expectEqual(c.ZSTD_estimateCStreamSize(level), zstd.estimateCStreamSize(level));
        for ([_]usize{ 0, 1000, 100_000 }) |dict_size| {
            try testing.expectEqual(
                c.ZSTD_estimateCDictSize(dict_size, level),
                zstd.estimateCDictSize(dict_size, level),
            );
        }
    }
    var prng = std.Random.DefaultPrng.init(common.fuzzSeed(58));
    const random = prng.random();
    for (0..common.fuzz_cases) |_| {
        var cp = zstd.getCParams(
            random.intRangeAtMost(i32, -5, 22),
            random.uintAtMost(u64, 1 << 22),
            0,
        );
        cp.window_log = random.intRangeAtMost(u32, params.window_log_min, 27);
        const ccp = frame.toC(cp);
        try testing.expectEqual(
            c.ZSTD_estimateCCtxSize_usingCParams(ccp),
            zstd.estimateCCtxSizeUsingCParams(cp),
        );
        try testing.expectEqual(
            c.ZSTD_estimateCStreamSize_usingCParams(ccp),
            zstd.estimateCStreamSizeUsingCParams(cp),
        );
        const dict_size = random.uintAtMost(usize, 200_000);
        const method: params.DictLoadMethod = @fromBackingInt(random.uintAtMost(u32, 1));
        try testing.expectEqual(
            c.ZSTD_estimateCDictSize_advanced(dict_size, ccp, @backingInt(method)),
            zstd.estimateCDictSizeAdvanced(dict_size, cp, method),
        );
    }
}

test "sizeof: a context after frames at every level" {
    const src = try common.generated(300_000, 0.5, 0.3, 59);
    defer gpa.free(src);
    const pair = try Pair.init();
    defer pair.deinit();
    try testing.expectEqual(c.ZSTD_sizeof_CCtx(pair.upstream), pair.port.sizeof());
    for (frame.levels) |level| {
        for ([_]usize{ 100, src.len }) |size| {
            try pair.set(.compression_level, level);
            _ = try pair.compress2(src[0..size], c.ZSTD_compressBound(size));
            try testing.expectEqual(c.ZSTD_sizeof_CCtx(pair.upstream), pair.port.sizeof());
        }
    }
}

/// A static context of each side, over workspaces of `size` bytes.
const StaticPair = struct {
    port_workspace: []align(64) u8,
    upstream_workspace: []align(64) u8,
    port: ?*zstd.CCtx,
    upstream: ?*c.ZSTD_CCtx,

    fn init(size: usize, offset: usize) !StaticPair {
        const port_workspace = try gpa.alignedAlloc(u8, .@"64", size + offset);
        errdefer gpa.free(port_workspace);
        const upstream_workspace = try gpa.alignedAlloc(u8, .@"64", size + offset);
        return .{
            .port_workspace = port_workspace,
            .upstream_workspace = upstream_workspace,
            .port = zstd.CCtx.initStatic(port_workspace[offset..]),
            .upstream = c.ZSTD_initStaticCCtx(upstream_workspace[offset..].ptr, size),
        };
    }

    fn deinit(pair: StaticPair) void {
        gpa.free(pair.port_workspace);
        gpa.free(pair.upstream_workspace);
    }
};

test "initStatic: workspaces of the estimated size, and one byte less" {
    const src = try common.generated(1 << 20, 0.5, 0.3, 60);
    defer gpa.free(src);
    const expected = try frame.boundBuffer(src.len);
    defer gpa.free(expected);
    const dst = try frame.boundBuffer(src.len);
    defer gpa.free(dst);
    for (frame.strategy_levels ++ [_]i32{ -131072, 2, 22 }) |level| {
        const estimate = zstd.estimateCCtxSize(level);
        for ([_]usize{ estimate, estimate - 1 }) |size| {
            const pair = try StaticPair.init(size, 0);
            defer pair.deinit();
            try testing.expect(pair.port != null);
            try testing.expect(pair.upstream != null);
            const port = pair.port.?;
            const upstream = pair.upstream.?;
            for ([_]usize{ 0, 1000, 20_000, 200_000, src.len }) |n| {
                const code = c.ZSTD_compressCCtx(
                    upstream,
                    expected.ptr,
                    expected.len,
                    src.ptr,
                    n,
                    level,
                );
                const result = port.compressCCtx(dst, src[0..n], level);
                expectSameResult(code, result) catch |err| {
                    std.debug.print("level {d}, workspace {d}, {d} bytes\n", .{ level, size, n });
                    return err;
                };
                const out = result catch continue;
                try common.expectSameFrame(expected[0..code], dst[0..out]);
                try common.expectRoundTrip(dst[0..out], src[0..n]);
                try testing.expectEqual(c.ZSTD_sizeof_CCtx(upstream), port.sizeof());
            }
            // compress2 on a static context: its zeroed parameters write no
            // content size.
            const code = c.ZSTD_compress2(upstream, expected.ptr, expected.len, src.ptr, 5000);
            const result = port.compress2(dst, src[0..5000]);
            try expectSameResult(code, result);
            if (result) |out| try common.expectSameFrame(expected[0..code], dst[0..out]) else |_| {}
            // A static context cannot be freed, nor load a dictionary by copy.
            try expectSameResult(c.ZSTD_freeCCtx(upstream), port.destroy());
        }
    }
    // Too small for the context itself, or misaligned.
    for ([_]struct { size: usize, offset: usize }{
        .{ .size = 100, .offset = 0 },
        .{ .size = zstd.internal.compress.cctx_object_size, .offset = 0 },
        .{ .size = 1 << 20, .offset = 4 },
    }) |case| {
        const pair = try StaticPair.init(case.size, case.offset);
        defer pair.deinit();
        try testing.expectEqual(pair.upstream == null, pair.port == null);
    }
    // A few bytes over the context: the original returns a context without
    // its block states, the port none.
    const pair = try StaticPair.init(zstd.internal.compress.cctx_object_size + 1, 0);
    defer pair.deinit();
    try testing.expect(pair.upstream != null);
    try testing.expect(pair.port == null);
}

test "initStatic: estimates from compression and context parameters" {
    const src = try common.generated(600_000, 0.5, 0.3, 61);
    defer gpa.free(src);
    const expected = try frame.boundBuffer(src.len);
    defer gpa.free(expected);
    const dst = try frame.boundBuffer(src.len);
    defer gpa.free(dst);
    const held = try ParamsPair.init();
    defer held.deinit();
    const sets = [_][]const common.Param{
        &.{.{ .param = 100, .value = 5 }},
        &.{ .{ .param = 100, .value = 7 }, .{ .param = 1011, .value = 2 } },
        &.{ .{ .param = 100, .value = 7 }, .{ .param = 1011, .value = 1 } },
        &.{
            .{ .param = 100, .value = 3 },  .{ .param = 160, .value = 1 },
            .{ .param = 101, .value = 20 }, .{ .param = 162, .value = 64 },
        },
        &.{ .{ .param = 100, .value = 19 }, .{ .param = 1015, .value = 8192 } },
        &.{
            .{ .param = 100, .value = 12 },
            .{ .param = 101, .value = 18 },
            .{ .param = 201, .value = 1 },
        },
    };
    for (sets) |set| {
        try expectSameResult(c.ZSTD_CCtxParams_reset(held.upstream), {});
        held.port.reset();
        for (set) |p| try held.set(@fromBackingInt(p.param), p.value);
        const estimate = try zstd.estimateCCtxSizeUsingCCtxParams(held.port);
        try testing.expectEqual(c.ZSTD_estimateCCtxSize_usingCCtxParams(held.upstream), estimate);
        for ([_]usize{ estimate, estimate - 1 }) |size| {
            const pair = try StaticPair.init(size, 0);
            defer pair.deinit();
            try expectSameResult(
                c.ZSTD_CCtx_setParametersUsingCCtxParams(pair.upstream.?, held.upstream),
                pair.port.?.setParametersUsingCCtxParams(held.port),
            );
            const code = c.ZSTD_compress2(
                pair.upstream.?,
                expected.ptr,
                expected.len,
                src.ptr,
                src.len,
            );
            const result = pair.port.?.compress2(dst, src);
            try expectSameResult(code, result);
            if (result) |out| try common.expectSameFrame(expected[0..code], dst[0..out]) else |_| {}
        }
    }
}
