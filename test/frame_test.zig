//! Oracle tests of whole frames: the port's one-shot and buffer-less
//! compression against the original's on the same inputs, levels and
//! parameters, and the functions that pick and check parameters. Every
//! frame must be the same, byte for byte, and decode back to the input
//! through std's decoder and the original's. The helpers here are shared by
//! the other frame test files.

const std = @import("std");
const zstd = @import("zstd");
const c = @import("upstream");
const common = @import("common.zig");
const test_options = @import("test_options");

const params = zstd.params;
const gpa = common.gpa;
const testing = std.testing;
const Result = common.Result;

/// The levels every frame test covers: the fastest, the negative ones, and
/// every positive level.
pub const levels = [_]i32{ -131072, -1000, -50, -5, -1 } ++ positive: {
    var l: [22]i32 = undefined;
    for (&l, 1..) |*level, i| level.* = @intCast(i);
    break :positive l;
};

/// A level of each strategy, and the negative levels' fast variant.
pub const strategy_levels = [_]i32{ -5, 1, 3, 5, 6, 8, 13, 16, 18, 19, 22 };

/// The port's result as the original's: a size, or the error code. A
/// result of no value counts as size 0.
pub fn portResult(result: anytype) Result {
    const value = switch (@typeInfo(@TypeOf(result))) {
        .error_union => result catch |err| {
            return .{ .error_code = @backingInt(zstd.errorCode(err)) };
        },
        else => result,
    };
    return .{ .size = if (@TypeOf(value) == void) 0 else value };
}

/// Checks the port's result against the original's return code; a port
/// function with no value only has to succeed when the original does.
pub fn expectSameResult(code: usize, result: anytype) !void {
    const T = @TypeOf(result);
    const no_value =
        T == void or (@typeInfo(T) == .error_union and @typeInfo(T).error_union.payload == void);
    const expected = Result.of(code);
    const actual = portResult(result);
    const same = switch (expected) {
        .size => |size| actual == .size and (no_value or actual.size == size),
        // A size the original computes with wrap-around can land in its
        // error range, as an input size hint can; the port gives the same.
        .error_code => |e| (actual == .error_code and actual.error_code == e) or
            (actual == .size and actual.size == code),
    };
    if (!same) {
        std.debug.print("original {any}, port {any}\n", .{ expected, actual });
        return error.ResultsDiffer;
    }
}

const Error = zstd.Error;

pub fn toC(p: params.CompressionParameters) c.ZSTD_compressionParameters {
    return .{
        .window_log = p.window_log,
        .chain_log = p.chain_log,
        .hash_log = p.hash_log,
        .search_log = p.search_log,
        .min_match = p.min_match,
        .target_length = p.target_length,
        .strategy = @backingInt(p.strategy),
    };
}

pub fn fromC(p: c.ZSTD_compressionParameters) params.CompressionParameters {
    return .{
        .window_log = p.window_log,
        .chain_log = p.chain_log,
        .hash_log = p.hash_log,
        .search_log = p.search_log,
        .min_match = p.min_match,
        .target_length = p.target_length,
        .strategy = @fromBackingInt(p.strategy),
    };
}

pub fn fparamsToC(p: params.FrameParameters) c.ZSTD_frameParameters {
    return .{
        .content_size_flag = @intFromBool(p.content_size_flag),
        .checksum_flag = @intFromBool(p.checksum_flag),
        .no_dict_id_flag = @intFromBool(p.no_dict_id_flag),
    };
}

pub fn parametersToC(p: params.Parameters) c.ZSTD_parameters {
    return .{ .cparams = toC(p.cparams), .fparams = fparamsToC(p.fparams) };
}

pub fn expectSameCParams(
    expected: c.ZSTD_compressionParameters,
    actual: params.CompressionParameters,
) !void {
    try testing.expectEqual(expected, toC(actual));
}

/// A buffer of `compressBound(size)` bytes, the caller frees it.
pub fn boundBuffer(size: usize) ![]u8 {
    return gpa.alloc(u8, c.ZSTD_compressBound(size));
}

/// Compresses `src` with the port's `compressCCtx` and the original's, and
/// checks the frames are equal and decode back.
fn expectCompressCCtx(cctx: *zstd.CCtx, ucctx: *c.ZSTD_CCtx, src: []const u8, level: i32) !void {
    const expected = try boundBuffer(src.len);
    defer gpa.free(expected);
    const code = c.ZSTD_compressCCtx(ucctx, expected.ptr, expected.len, src.ptr, src.len, level);
    const dst = try boundBuffer(src.len);
    defer gpa.free(dst);
    const result = cctx.compressCCtx(dst, src, level);
    expectSameResult(code, result) catch |err| {
        std.debug.print("level {d}, {d} bytes\n", .{ level, src.len });
        return err;
    };
    const size = result catch return;
    common.expectSameFrame(expected[0..code], dst[0..size]) catch |err| {
        std.debug.print("level {d}, {d} bytes\n", .{ level, src.len });
        return err;
    };
    try common.expectRoundTrip(dst[0..size], src);
}

/// A context of each side, freed by `deinit`.
pub const Pair = struct {
    port: *zstd.CCtx,
    upstream: *c.ZSTD_CCtx,

    pub fn init() !Pair {
        const port = try zstd.CCtx.create(gpa);
        errdefer port.destroy() catch unreachable;
        const upstream = c.ZSTD_createCCtx() orelse return error.OutOfMemory;
        return .{ .port = port, .upstream = upstream };
    }

    pub fn deinit(pair: Pair) void {
        pair.port.destroy() catch unreachable;
        _ = c.ZSTD_freeCCtx(pair.upstream);
    }

    /// Sets `param` on both, checking they agree.
    pub fn set(pair: Pair, param: params.CParameter, value: i32) !void {
        const code = c.ZSTD_CCtx_setParameter(pair.upstream, @backingInt(param), value);
        const result = pair.port.setParameter(param, value);
        expectSameResult(code, result) catch |err| {
            std.debug.print("{t} = {d}\n", .{ param, value });
            return err;
        };
    }

    /// Compresses `src` with `compress2` on both and checks the frames, or
    /// the error codes, are the same; returns whether a frame was made.
    pub fn compress2(pair: Pair, src: []const u8, capacity: usize) !bool {
        const out = try pair.compress2Frame(src, capacity) orelse return false;
        gpa.free(out);
        return true;
    }

    /// `compress2`, returning the port's frame when one was made. The
    /// caller frees it.
    pub fn compress2Frame(pair: Pair, src: []const u8, capacity: usize) !?[]u8 {
        const expected = try gpa.alloc(u8, capacity);
        defer gpa.free(expected);
        const code = c.ZSTD_compress2(pair.upstream, expected.ptr, expected.len, src.ptr, src.len);
        const dst = try gpa.alloc(u8, capacity);
        errdefer gpa.free(dst);
        const result = pair.port.compress2(dst, src);
        try expectSameResult(code, result);
        const size = result catch {
            gpa.free(dst);
            return null;
        };
        try common.expectSameFrame(expected[0..code], dst[0..size]);
        return try gpa.realloc(dst, size);
    }
};

/// Inputs of several compressibilities, generated by the original's datagen.
pub const generated_inputs = [_]struct { size: usize, match: f64, lit: f64, seed: u32 }{
    .{ .size = 100_000, .match = 0.5, .lit = 0.0, .seed = 1 },
    .{ .size = 300_000, .match = 0.2, .lit = 0.5, .seed = 2 },
    .{ .size = 200_000, .match = 0.9, .lit = 0.1, .seed = 3 },
    .{ .size = 150_000, .match = 0.05, .lit = 0.9, .seed = 4 },
};

test "compressCCtx: generated data at every level" {
    const pair = try Pair.init();
    defer pair.deinit();
    for (generated_inputs) |input| {
        const src = try common.generated(input.size, input.match, input.lit, input.seed);
        defer gpa.free(src);
        for (levels) |level| try expectCompressCCtx(pair.port, pair.upstream, src, level);
    }
}

test "compressCCtx: edge cases" {
    const pair = try Pair.init();
    defer pair.deinit();
    const big = try common.generated(1 << 20 | 12345, 0.6, 0.3, 9);
    defer gpa.free(big);
    var prng = std.Random.DefaultPrng.init(4);
    const random = try gpa.alloc(u8, 200_000);
    defer gpa.free(random);
    prng.random().bytes(random);
    const same: [70_000]u8 = @splat('z');
    const kib128 = 128 * 1024;
    const sizes = [_]usize{ 0, 1, 2, 3, 7, 100, kib128 - 1, kib128, kib128 + 1, 2 * kib128 + 5 };
    for (levels) |level| {
        for (sizes) |size| try expectCompressCCtx(pair.port, pair.upstream, big[0..size], level);
        try expectCompressCCtx(pair.port, pair.upstream, big, level);
        try expectCompressCCtx(pair.port, pair.upstream, random, level);
        try expectCompressCCtx(pair.port, pair.upstream, &same, level);
        try expectCompressCCtx(pair.port, pair.upstream, same[0..1], level);
    }
}

test "compressCCtx: an input that straddles the window" {
    const pair = try Pair.init();
    defer pair.deinit();
    // Level 1's window for an input over 256 KiB is 512 KiB; matches repeat
    // across it.
    const src = try gpa.alloc(u8, 3 << 20);
    defer gpa.free(src);
    const part = try common.generated(600 << 10, 0.7, 0.2, 11);
    defer gpa.free(part);
    var pos: usize = 0;
    while (pos < src.len) : (pos += part.len) {
        const n = @min(part.len, src.len - pos);
        @memcpy(src[pos..][0..n], part[0..n]);
    }
    for ([_]i32{ -5, 1, 2, 4, 7, 12, 17, 19 }) |level| {
        try expectCompressCCtx(pair.port, pair.upstream, src, level);
    }
}

test "compressCCtx: golden compression inputs and test data" {
    const pair = try Pair.init();
    defer pair.deinit();
    const golden = "tests/golden-compression/";
    const files = [_]struct { dir: []const u8, name: []const u8 }{
        .{ .dir = test_options.reference, .name = golden ++ "http" },
        .{ .dir = test_options.reference, .name = golden ++ "huffman-compressed-larger" },
        .{ .dir = test_options.reference, .name = golden ++ "large-literal-and-match-lengths" },
        .{
            .dir = test_options.reference,
            .name = golden ++ "PR-3517-block-splitter-corruption-test",
        },
        .{ .dir = test_options.data, .name = "bc7.bin" },
        .{ .dir = test_options.data, .name = "mesh.bin" },
        .{ .dir = test_options.data, .name = "snapshot.bin" },
    };
    for (files) |file| {
        const src = try common.readFile(file.dir, file.name);
        defer gpa.free(src);
        for (levels) |level| {
            expectCompressCCtx(pair.port, pair.upstream, src, level) catch |err| {
                std.debug.print("{s}\n", .{file.name});
                return err;
            };
        }
    }
}

test "compress: the one-shot function, and a destination too small" {
    const src = try common.generated(50_000, 0.5, 0.3, 21);
    defer gpa.free(src);
    for ([_]i32{ -3, 0, 1, 3, 9, 19 }) |level| {
        const expected = try boundBuffer(src.len);
        defer gpa.free(expected);
        const dst = try boundBuffer(src.len);
        defer gpa.free(dst);
        const code = c.ZSTD_compress(expected.ptr, expected.len, src.ptr, src.len, level);
        const size = try zstd.compress(gpa, dst, src, level);
        try common.expectSameFrame(expected[0..code], dst[0..size]);
        try common.expectRoundTrip(dst[0..size], src);
        // Every capacity below the frame's size fails the same way.
        for ([_]usize{ 0, 1, 5, 6, 100, code / 2, code - 1 }) |capacity| {
            const small = c.ZSTD_compress(expected.ptr, capacity, src.ptr, src.len, level);
            try expectSameResult(small, zstd.compress(gpa, dst[0..capacity], src, level));
        }
    }
}

test "compressBegin, compressContinue, compressEnd: odd chunks, known and unknown size" {
    const src = try common.generated(700_000, 0.6, 0.2, 31);
    defer gpa.free(src);
    const pair = try Pair.init();
    defer pair.deinit();
    var prng = std.Random.DefaultPrng.init(common.fuzzSeed(31));
    const random = prng.random();
    const expected = try boundBuffer(src.len);
    defer gpa.free(expected);
    const dst = try boundBuffer(src.len);
    defer gpa.free(dst);
    for (strategy_levels) |level| {
        if (!common.levelFits(level)) continue;
        for (0..3) |mode| {
            // 0: compressBegin, the size unknown; 1: compressBegin_advanced
            // with the size pledged; 2: with a checksum, the size unknown.
            const size = src.len - random.uintLessThan(usize, 1000);
            switch (mode) {
                0 => try expectSameResult(
                    c.ZSTD_compressBegin(pair.upstream, level),
                    pair.port.compressBegin(level),
                ),
                else => {
                    var p = zstd.getParams(level, size, 0);
                    p.fparams.checksum_flag = mode == 2;
                    const pledged = if (mode == 1) size else params.content_size_unknown;
                    try expectSameResult(
                        c.ZSTD_compressBegin_advanced(
                            pair.upstream,
                            null,
                            0,
                            parametersToC(p),
                            pledged,
                        ),
                        pair.port.compressBeginAdvanced(null, p, pledged),
                    );
                },
            }
            var pos: usize = 0;
            var out: usize = 0;
            while (true) {
                const chunk = @min(size - pos, random.uintAtMost(usize, 300_000));
                const last = pos + chunk == size or random.uintLessThan(u32, 8) == 0;
                const piece = if (last) src[pos..size] else src[pos..][0..chunk];
                const code = if (last)
                    c.ZSTD_compressEnd(
                        pair.upstream,
                        expected[out..].ptr,
                        expected.len - out,
                        piece.ptr,
                        piece.len,
                    )
                else
                    c.ZSTD_compressContinue(
                        pair.upstream,
                        expected[out..].ptr,
                        expected.len - out,
                        piece.ptr,
                        piece.len,
                    );
                const result = if (last)
                    pair.port.compressEnd(dst[out..], piece)
                else
                    pair.port.compressContinue(dst[out..], piece);
                expectSameResult(code, result) catch |err| {
                    std.debug.print("level {d}, mode {d}, at {d}\n", .{ level, mode, pos });
                    return err;
                };
                const n = try result;
                try common.expectSameFrame(expected[out..][0..code], dst[out..][0..n]);
                out += n;
                pos += piece.len;
                if (last) break;
            }
            try common.expectRoundTrip(dst[0..out], src[0..size]);
        }
    }
}

test "compressEnd: a pledged size that is wrong" {
    const src = try common.generated(50_000, 0.5, 0.3, 32);
    defer gpa.free(src);
    const pair = try Pair.init();
    defer pair.deinit();
    const expected = try boundBuffer(src.len);
    defer gpa.free(expected);
    const dst = try boundBuffer(src.len);
    defer gpa.free(dst);
    for ([_]u64{ 0, 1, 40_000, 49_999, 50_001 }) |pledged| {
        const p = zstd.getParams(3, pledged, 0);
        try expectSameResult(
            c.ZSTD_compressBegin_advanced(pair.upstream, null, 0, parametersToC(p), pledged),
            pair.port.compressBeginAdvanced(null, p, pledged),
        );
        const half = src.len / 2;
        const code1 = c.ZSTD_compressContinue(
            pair.upstream,
            expected.ptr,
            expected.len,
            src.ptr,
            half,
        );
        const result1 = pair.port.compressContinue(dst, src[0..half]);
        try expectSameResult(code1, result1);
        const n1 = result1 catch continue;
        const code2 = c.ZSTD_compressEnd(
            pair.upstream,
            expected[n1..].ptr,
            expected.len - n1,
            src[half..].ptr,
            src.len - half,
        );
        try expectSameResult(code2, pair.port.compressEnd(dst[n1..], src[half..]));
    }
}

test "compressBlock: blocks of a frame body, and copyCCtx" {
    const src = try common.generated(400_000, 0.5, 0.3, 33);
    defer gpa.free(src);
    const pair = try Pair.init();
    defer pair.deinit();
    const copy = try Pair.init();
    defer copy.deinit();
    const expected = try boundBuffer(src.len);
    defer gpa.free(expected);
    const dst = try boundBuffer(src.len);
    defer gpa.free(dst);
    for (strategy_levels) |level| {
        if (!common.levelFits(level)) continue;
        try expectSameResult(
            c.ZSTD_compressBegin(pair.upstream, level),
            pair.port.compressBegin(level),
        );
        try testing.expectEqual(c.ZSTD_getBlockSize(pair.upstream), pair.port.getBlockSize());
        try expectSameResult(
            c.ZSTD_copyCCtx(copy.upstream, pair.upstream, src.len),
            copy.port.copy(pair.port, src.len),
        );
        const block_size = pair.port.getBlockSize();
        var pos: usize = 0;
        var step: usize = 1;
        while (pos < src.len) : (step = step * 7 % 1000 + 1) {
            const n = @min(src.len - pos, block_size, step * 211);
            const code = c.ZSTD_compressBlock(
                pair.upstream,
                expected.ptr,
                expected.len,
                src[pos..].ptr,
                n,
            );
            const result = pair.port.compressBlock(dst, src[pos..][0..n]);
            try expectSameResult(code, result);
            const size = try result;
            try common.expectSameFrame(expected[0..code], dst[0..size]);
            pos += n;
        }
        // A block over the block size is refused.
        try expectSameResult(
            c.ZSTD_compressBlock(
                pair.upstream,
                expected.ptr,
                expected.len,
                src.ptr,
                block_size + 1,
            ),
            pair.port.compressBlock(dst, src[0 .. block_size + 1]),
        );
        // The copy compresses the whole input as one frame with its size.
        const code = c.ZSTD_compressEnd(
            copy.upstream,
            expected.ptr,
            expected.len,
            src.ptr,
            src.len,
        );
        const size = try copy.port.compressEnd(dst, src);
        try common.expectSameFrame(expected[0..code], dst[0..size]);
        try common.expectRoundTrip(dst[0..size], src);
    }
}

test "writeSkippableFrame" {
    const src = "a skippable frame's content";
    var expected: [64]u8 = undefined;
    var dst: [64]u8 = undefined;
    for (0..18) |variant| {
        for ([_]usize{ 0, 7, 8, 8 + src.len - 1, 8 + src.len, dst.len }) |capacity| {
            const code = c.ZSTD_writeSkippableFrame(
                &expected,
                capacity,
                src,
                src.len,
                @intCast(variant),
            );
            const result = zstd.writeSkippableFrame(dst[0..capacity], src, @intCast(variant));
            try expectSameResult(code, result);
            const size = result catch continue;
            try testing.expectEqualSlices(u8, expected[0..code], dst[0..size]);
        }
    }
}

test "compressBound: every size class and the largest input" {
    const max_input: usize = if (@sizeOf(usize) == 8) 0xFF00FF00FF00FF00 else 0xFF00FF00;
    const sizes = [_]usize{
        0,         1,               2,                      100,     (128 << 10) - 1,
        128 << 10, (128 << 10) + 1, 1 << 20,                1 << 30, max_input - 1,
        max_input, max_input + 1,   std.math.maxInt(usize),
    };
    for (sizes) |size| {
        // Just under the largest input, the original's bound is a number in
        // its error range, and the port's the same number.
        const code = c.ZSTD_compressBound(size);
        const raw = zstd.compressBound(size) catch |err| 0 -% @as(
            usize,
            @backingInt(zstd.errorCode(err)),
        );
        try testing.expectEqual(code, raw);
    }
    for (0..300_000) |size| {
        try testing.expectEqual(c.ZSTD_compressBound(size), try zstd.compressBound(size));
    }
}

test "minCLevel, maxCLevel, defaultCLevel" {
    try testing.expectEqual(c.ZSTD_minCLevel(), zstd.minCLevel());
    try testing.expectEqual(c.ZSTD_maxCLevel(), zstd.maxCLevel());
    try testing.expectEqual(c.ZSTD_defaultCLevel(), zstd.defaultCLevel());
}

const size_hints = [_]u64{
    0,
    1,
    1000,
    16 << 10,
    (16 << 10) + 1,
    128 << 10,
    (128 << 10) + 1,
    256 << 10,
    (256 << 10) + 1,
    1 << 30,
    params.content_size_unknown,
    params.content_size_unknown - 1,
};
const dict_sizes = [_]usize{ 0, 1, 1000, 16 << 10, 100_000, 1 << 20 };

test "getCParams, getParams: every level and size class" {
    var level: i32 = -131080;
    while (level <= 30) : (level += if (level < -200) 1009 else 1) {
        for (size_hints) |hint| {
            for (dict_sizes) |dict_size| {
                try expectSameCParams(
                    c.ZSTD_getCParams(level, hint, dict_size),
                    zstd.getCParams(level, hint, dict_size),
                );
                const expected = c.ZSTD_getParams(level, hint, dict_size);
                const actual = zstd.getParams(level, hint, dict_size);
                try expectSameCParams(expected.cparams, actual.cparams);
                try testing.expectEqual(expected.fparams, fparamsToC(actual.fparams));
            }
        }
    }
    for ([_]i32{ std.math.minInt(i32), std.math.maxInt(i32) }) |l| {
        try expectSameCParams(c.ZSTD_getCParams(l, 0, 0), zstd.getCParams(l, 0, 0));
    }
}

/// Compression parameters drawn around and past their bounds.
fn randomCParams(random: std.Random) params.CompressionParameters {
    const pick = struct {
        fn f(r: std.Random, lo: u32, hi: u32) u32 {
            return switch (r.uintLessThan(u32, 8)) {
                0 => r.int(u32),
                1 => lo -| 1,
                2 => hi + 1,
                else => r.intRangeAtMost(u32, lo, hi),
            };
        }
    }.f;
    return .{
        .window_log = pick(random, params.window_log_min, params.window_log_max),
        .chain_log = pick(random, params.chain_log_min, params.chain_log_max),
        .hash_log = pick(random, params.hash_log_min, params.hash_log_max),
        .search_log = pick(random, params.search_log_min, params.search_log_max),
        .min_match = pick(random, params.min_match_min, params.min_match_max),
        .target_length = pick(random, params.target_length_min, params.target_length_max),
        .strategy = @fromBackingInt(pick(random, 1, 9)),
    };
}

test "checkCParams, adjustCParams: fuzzed parameters and sizes" {
    const seed = common.fuzzSeed(41);
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();
    for (0..common.fuzz_cases * 10) |case| {
        errdefer std.debug.print("seed {d}, case {d}\n", .{ seed, case });
        const cp = randomCParams(random);
        try expectSameResult(c.ZSTD_checkCParams(toC(cp)), zstd.checkCParams(cp));
        const hint = size_hints[
            random.uintLessThan(
                usize,
                size_hints.len,
            )
        ] +% random.uintAtMost(u64, 3);
        const dict_size = dict_sizes[random.uintLessThan(usize, dict_sizes.len)];
        // The original asserts its input is valid after clamping, which a
        // strategy out of range is not.
        if (@backingInt(cp.strategy) < 1 or @backingInt(cp.strategy) > 9) continue;
        try expectSameCParams(
            c.ZSTD_adjustCParams(toC(cp), hint, dict_size),
            zstd.adjustCParams(cp, hint, dict_size),
        );
    }
}

// ---------------------------------------------------------------------------
// The other frame test files
// ---------------------------------------------------------------------------

test {
    _ = @import("frame_params_test.zig");
    _ = @import("frame_dict_test.zig");
    _ = @import("frame_sequences_test.zig");
}
