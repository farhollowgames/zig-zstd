//! Oracle tests of the sequence functions: the sequences a compression
//! finds (`generateSequences`), their block delimiters merged away
//! (`mergeBlockDelimiters`), and frames made from an external sequence
//! producer's sequences, with and without the fallback to the built-in
//! match finders. The producers are test/reference.c's, called by both
//! sides.

const std = @import("std");
const zstd = @import("zstd");
const c = @import("upstream");
const common = @import("common.zig");
const frame = @import("frame_test.zig");

const params = zstd.params;
const gpa = common.gpa;
const testing = std.testing;
const Pair = frame.Pair;
const expectSameResult = frame.expectSameResult;

test "sequenceBound" {
    for (0..300_000) |size| {
        try testing.expectEqual(c.ZSTD_sequenceBound(size), zstd.sequenceBound(size));
    }
    for ([_]usize{ 1 << 30, 1 << 40, std.math.maxInt(u32) }) |size| {
        try testing.expectEqual(c.ZSTD_sequenceBound(size), zstd.sequenceBound(size));
    }
}

/// Checks two sequence lists are the same.
fn expectSameSequences(expected: []const c.ZSTD_Sequence, actual: []const params.Sequence) !void {
    try testing.expectEqual(expected.len, actual.len);
    for (expected, actual, 0..) |e, a, i| {
        const same = e.offset == a.offset and e.lit_length == a.lit_length and
            e.match_length == a.match_length and e.rep == a.rep;
        if (!same) {
            std.debug.print(
                "sequence {d} of {d}: original {any}, port {any}\n",
                .{ i, expected.len, e, a },
            );
            return error.SequencesDiffer;
        }
    }
}

test "generateSequences, mergeBlockDelimiters: a level of each strategy" {
    const src = try common.generated(500_000, 0.6, 0.3, 81);
    defer gpa.free(src);
    const pair = try Pair.init();
    defer pair.deinit();
    for (frame.levels) |level| {
        for ([_]usize{ 0, 1, 100, 5000, 128 << 10, (128 << 10) + 1, src.len }) |size| {
            errdefer std.debug.print("level {d}, {d} bytes\n", .{ level, size });
            try pair.set(.compression_level, level);
            const bound = c.ZSTD_sequenceBound(size);
            for ([_]usize{ bound, bound - 1 }) |capacity| {
                const expected = try gpa.alloc(c.ZSTD_Sequence, capacity);
                defer gpa.free(expected);
                @memset(expected, std.mem.zeroes(c.ZSTD_Sequence));
                const actual = try gpa.alloc(params.Sequence, capacity);
                defer gpa.free(actual);
                @memset(actual, std.mem.zeroes(params.Sequence));
                const code = c.ZSTD_generateSequences(
                    pair.upstream,
                    expected.ptr,
                    capacity,
                    src.ptr,
                    size,
                );
                const result = pair.port.generateSequences(gpa, actual, src[0..size]);
                try expectSameResult(code, result);
                const n = result catch continue;
                try expectSameSequences(expected[0..code], actual[0..n]);
                const merged_code = c.ZSTD_mergeBlockDelimiters(expected.ptr, code);
                const merged = zstd.mergeBlockDelimiters(actual[0..n]);
                try expectSameSequences(expected[0..merged_code], actual[0..merged]);
            }
        }
    }
}

test "generateSequences: parameters it refuses, and ones it keeps" {
    const src = try common.generated(300_000, 0.6, 0.3, 82);
    defer gpa.free(src);
    const cases = [_][]const common.Param{
        &.{.{ .param = 130, .value = 2000 }},
        &.{.{ .param = 400, .value = 2 }},
        &.{ .{ .param = 160, .value = 1 }, .{ .param = 101, .value = 20 } },
        &.{ .{ .param = 1017, .value = 6 }, .{ .param = 100, .value = 17 } },
        &.{ .{ .param = 1015, .value = 8192 }, .{ .param = 100, .value = 4 } },
        &.{
            .{ .param = 201, .value = 1 },
            .{ .param = 1011, .value = 1 },
            .{ .param = 100, .value = 6 },
        },
    };
    const bound = c.ZSTD_sequenceBound(src.len);
    const expected = try gpa.alloc(c.ZSTD_Sequence, bound);
    defer gpa.free(expected);
    const actual = try gpa.alloc(params.Sequence, bound);
    defer gpa.free(actual);
    for (cases) |case| {
        const pair = try Pair.init();
        defer pair.deinit();
        for (case) |p| try pair.set(@fromBackingInt(p.param), p.value);
        @memset(expected, std.mem.zeroes(c.ZSTD_Sequence));
        @memset(actual, std.mem.zeroes(params.Sequence));
        const code = c.ZSTD_generateSequences(pair.upstream, expected.ptr, bound, src.ptr, src.len);
        const result = pair.port.generateSequences(gpa, actual, src);
        try expectSameResult(code, result);
        const n = result catch continue;
        try expectSameSequences(expected[0..code], actual[0..n]);
    }
}

/// The port's side of test/reference.c's producers.
fn portProducer(
    context: ?*anyopaque,
    out_seqs: []params.Sequence,
    src: []const u8,
    dict: []const u8,
    compression_level: i32,
    window_size: usize,
) usize {
    return c.reference_sequenceProducer(
        context,
        @ptrCast(out_seqs.ptr),
        out_seqs.len,
        src.ptr,
        src.len,
        dict.ptr,
        dict.len,
        compression_level,
        window_size,
    );
}

/// A pair of contexts with a producer of `mode` registered on each, its
/// states in `states`.
fn register(pair: Pair, states: *[2]c.ProducerState, mode: c_int) void {
    states.* = .{ .{ .mode = mode }, .{ .mode = mode } };
    c.ZSTD_registerSequenceProducer(pair.upstream, &states[0], c.reference_sequenceProducer);
    pair.port.registerSequenceProducer(.{ .context = &states[1], .produce_fn = portProducer });
}

test "registerSequenceProducer: each producer, fallback on and off" {
    const input = try common.generated(700_000, 0.6, 0.3, 83);
    defer gpa.free(input);
    for (0..4) |mode| {
        for ([_]i32{ 0, 1 }) |fallback| {
            for ([_]i32{ -5, 1, 3, 7, 16, 19 }) |level| {
                const pair = try Pair.init();
                defer pair.deinit();
                var states: [2]c.ProducerState = undefined;
                register(pair, &states, @intCast(mode));
                try pair.set(.enable_seq_producer_fallback, fallback);
                try pair.set(.compression_level, level);
                for ([_]usize{ 0, 1, 10, 1000, 128 << 10, 300_000, input.len }) |size| {
                    errdefer std.debug.print(
                        "mode {d}, fallback {d}, level {d}, {d} bytes\n",
                        .{ mode, fallback, level, size },
                    );
                    const out = try pair.compress2Frame(input[0..size], c.ZSTD_compressBound(size));
                    try testing.expectEqual(states[0].calls, states[1].calls);
                    if (out) |frame_bytes| {
                        defer gpa.free(frame_bytes);
                        try common.expectRoundTrip(frame_bytes, input[0..size]);
                    }
                }
                // compressCCtx ignores the producer.
                const expected = try frame.boundBuffer(5000);
                defer gpa.free(expected);
                const dst = try frame.boundBuffer(5000);
                defer gpa.free(dst);
                const code = c.ZSTD_compressCCtx(
                    pair.upstream,
                    expected.ptr,
                    expected.len,
                    input.ptr,
                    5000,
                    level,
                );
                const result = pair.port.compressCCtx(dst, input[0..5000], level);
                try expectSameResult(code, result);
                if (result) |n| try common.expectSameFrame(expected[0..code], dst[0..n]) else |_| {}
                try testing.expectEqual(states[0].calls, states[1].calls);
            }
        }
    }
}

test "registerSequenceProducer: with other parameters, and cleared" {
    const input = try common.generated(300_000, 0.6, 0.3, 84);
    defer gpa.free(input);
    const cases = [_][]const common.Param{
        &.{ .{ .param = 160, .value = 1 }, .{ .param = 101, .value = 20 } },
        &.{.{ .param = 400, .value = 2 }},
        &.{.{ .param = 1015, .value = 4096 }},
        &.{.{ .param = 130, .value = 1500 }},
        &.{ .{ .param = 1017, .value = 6 }, .{ .param = 100, .value = 17 } },
        &.{.{ .param = 1016, .value = 2 }},
        &.{.{ .param = 1016, .value = 1 }},
        &.{ .{ .param = 201, .value = 1 }, .{ .param = 101, .value = 14 } },
    };
    for (cases) |case| {
        for ([_]i32{ 0, 1 }) |fallback| {
            const pair = try Pair.init();
            defer pair.deinit();
            var states: [2]c.ProducerState = undefined;
            register(pair, &states, 0);
            try pair.set(.enable_seq_producer_fallback, fallback);
            for (case) |p| try pair.set(@fromBackingInt(p.param), p.value);
            for ([_]usize{ 100, input.len }) |size| {
                _ = try pair.compress2(input[0..size], c.ZSTD_compressBound(size));
                try testing.expectEqual(states[0].calls, states[1].calls);
            }
            // With a dictionary the producer is handed it.
            const dict = input[0..20_000];
            try expectSameResult(
                c.ZSTD_CCtx_loadDictionary(pair.upstream, dict.ptr, dict.len),
                pair.port.loadDictionary(dict),
            );
            _ = try pair.compress2(input[20_000..], c.ZSTD_compressBound(input.len));
            try testing.expectEqual(states[0].calls, states[1].calls);
            // Cleared, the built-in match finder is back.
            c.ZSTD_registerSequenceProducer(pair.upstream, null, null);
            pair.port.registerSequenceProducer(null);
            _ = try pair.compress2(input, c.ZSTD_compressBound(input.len));
            try testing.expectEqual(states[0].calls, states[1].calls);
        }
    }
}

test "CCtxParams.registerSequenceProducer: estimates and static contexts" {
    const input = try common.generated(200_000, 0.6, 0.3, 85);
    defer gpa.free(input);
    for ([_]i32{ 1, 3, 7, 19 }) |level| {
        var states: [2]c.ProducerState = .{ .{ .mode = 0 }, .{ .mode = 0 } };
        const uheld = c.ZSTD_createCCtxParams().?;
        defer _ = c.ZSTD_freeCCtxParams(uheld);
        const held = try zstd.CCtxParams.create(gpa);
        defer held.destroy();
        _ = c.ZSTD_CCtxParams_init(uheld, level);
        held.* = zstd.CCtxParams.init(level);
        held.custom_mem = gpa;
        c.ZSTD_CCtxParams_registerSequenceProducer(uheld, &states[0], c.reference_sequenceProducer);
        held.registerSequenceProducer(.{ .context = &states[1], .produce_fn = portProducer });
        const estimate = try zstd.estimateCCtxSizeUsingCCtxParams(held);
        try testing.expectEqual(c.ZSTD_estimateCCtxSize_usingCCtxParams(uheld), estimate);
        for ([_]usize{ estimate, estimate - 1 }) |size| {
            const port_workspace = try gpa.alignedAlloc(u8, .@"64", size);
            defer gpa.free(port_workspace);
            const upstream_workspace = try gpa.alignedAlloc(u8, .@"64", size);
            defer gpa.free(upstream_workspace);
            const port = zstd.CCtx.initStatic(port_workspace).?;
            const upstream = c.ZSTD_initStaticCCtx(upstream_workspace.ptr, size).?;
            try expectSameResult(
                c.ZSTD_CCtx_setParametersUsingCCtxParams(upstream, uheld),
                port.setParametersUsingCCtxParams(held),
            );
            const expected = try frame.boundBuffer(input.len);
            defer gpa.free(expected);
            const dst = try frame.boundBuffer(input.len);
            defer gpa.free(dst);
            const code = c.ZSTD_compress2(
                upstream,
                expected.ptr,
                expected.len,
                input.ptr,
                input.len,
            );
            const result = port.compress2(dst, input);
            try expectSameResult(code, result);
            if (result) |n| try common.expectSameFrame(expected[0..code], dst[0..n]) else |_| {}
            try testing.expectEqual(states[0].calls, states[1].calls);
        }
    }
}
