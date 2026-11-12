//! Oracle tests of streaming compression: `compressStream2` and the
//! functions around it (`compressStream`, `flushStream`, `endStream`, the
//! `initCStream*` variants, `resetCStream`), driven call by call on the
//! port and the original with the same input chunks, output windows and
//! directives, in the buffered and the stable buffer modes. After every
//! call the results, the input and output positions and the frame
//! progression must be the same, and every frame the same byte for byte,
//! decoding back to its input. Multithreaded streams compare their frames,
//! which do not depend on the threads' timing.

const std = @import("std");
const zstd = @import("zstd");
const c = @import("upstream");
const common = @import("common.zig");
const frame = @import("frame_test.zig");
const test_options = @import("test_options");

const params = zstd.params;
const EndDirective = params.EndDirective;
const gpa = common.gpa;
const testing = std.testing;
const Pair = frame.Pair;
const Result = common.Result;
const expectSameResult = frame.expectSameResult;
const kib = 1 << 10;
const mib = 1 << 20;

/// One call of a stream: how much more input it offers, the output window
/// it gives, and which entry point it goes through.
pub const Call = struct {
    kind: Kind,
    /// More input bytes offered, from where the last call left off.
    in: usize = 0,
    /// The output window; a stable output always gets the whole buffer.
    out: usize = 1 << 40,

    pub const Kind = enum { stream2_continue, stream2_flush, stream2_end, stream, flush, end };

    fn directive(call: Call) EndDirective {
        return switch (call.kind) {
            .stream2_continue, .stream => .@"continue",
            .stream2_flush, .flush => .flush,
            .stream2_end, .end => .end,
        };
    }
};

/// A stream on both sides, with the same buffers' layout: each side writes
/// into its own output buffer at the same positions.
pub const Stream = struct {
    pair: Pair,
    src: []const u8,
    stable_in: bool,
    stable_out: bool,
    /// Whether the frame progression is compared after each call, as it
    /// is for a single thread.
    single_thread: bool = true,
    upstream_out: []u8,
    port_out: []u8,
    in_pos: usize = 0,
    /// The input a stable input buffer offers so far.
    avail: usize = 0,
    out_pos: usize = 0,
    /// The result of the last call; null before the first.
    last: ?Result = null,
    /// Whether a stable input has so far only been offered, less than a
    /// block with no flush, so the frame has not started.
    waiting: bool = true,

    /// A stream over `src` with output buffers of `out_capacity` bytes.
    pub fn init(
        pair: Pair,
        src: []const u8,
        out_capacity: usize,
        stable_in: bool,
        stable_out: bool,
    ) !Stream {
        const upstream_out = try gpa.alloc(u8, out_capacity);
        errdefer gpa.free(upstream_out);
        const port_out = try gpa.alloc(u8, out_capacity);
        return .{
            .pair = pair,
            .src = src,
            .stable_in = stable_in,
            .stable_out = stable_out,
            .upstream_out = upstream_out,
            .port_out = port_out,
        };
    }

    pub fn deinit(s: *Stream) void {
        gpa.free(s.upstream_out);
        gpa.free(s.port_out);
    }

    pub fn frameDone(s: *const Stream) bool {
        const last = s.last orelse return false;
        return last == .size and last.size == 0 and s.in_pos == s.src.len;
    }

    /// Runs `call` on both sides and checks they agree; returns the result.
    pub fn step(s: *Stream, given: Call) !Result {
        var call = given;
        if (s.stable_in and s.waiting) {
            // The original's flushStream and endStream offer a null input
            // when the context's last frame buffered its input, and then
            // step back past it to the input it has not taken.
            call.kind = switch (call.kind) {
                .flush => .stream2_flush,
                .end => .stream2_end,
                else => call.kind,
            };
        }
        var upstream_in: c.ZSTD_inBuffer = undefined;
        var port_in: zstd.InBuffer = undefined;
        if (s.stable_in) {
            s.avail = @min(s.src.len, s.avail +| call.in);
            if (call.directive() != .@"continue" or s.avail >= 128 * kib) s.waiting = false;
            upstream_in = .{ .src = s.src.ptr, .size = s.avail, .pos = s.in_pos };
            port_in = .{ .src = s.src[0..s.avail], .pos = s.in_pos };
        } else {
            const end = @min(s.src.len, s.in_pos +| call.in);
            upstream_in = .{ .src = s.src.ptr + s.in_pos, .size = end - s.in_pos, .pos = 0 };
            port_in = .{ .src = s.src[s.in_pos..end] };
        }
        var upstream_output: c.ZSTD_outBuffer = undefined;
        var port_output: zstd.OutBuffer = undefined;
        if (s.stable_out) {
            upstream_output = .{
                .dst = s.upstream_out.ptr,
                .size = s.upstream_out.len,
                .pos = s.out_pos,
            };
            port_output = .{ .dst = s.port_out, .pos = s.out_pos };
        } else {
            const end = @min(s.upstream_out.len, s.out_pos +| call.out);
            upstream_output = .{
                .dst = s.upstream_out.ptr + s.out_pos,
                .size = end - s.out_pos,
                .pos = 0,
            };
            port_output = .{ .dst = s.port_out[s.out_pos..end] };
        }

        const port = s.pair.port;
        const up = s.pair.upstream;
        const op = call.directive();
        var code: usize = undefined;
        var result: zstd.Error!usize = undefined;
        var takes_input = true;
        switch (call.kind) {
            .stream2_continue, .stream2_flush, .stream2_end => {
                code = c.ZSTD_compressStream2(up, &upstream_output, &upstream_in, @backingInt(op));
                result = port.compressStream2(&port_output, &port_in, op);
            },
            .stream => {
                code = c.ZSTD_compressStream(up, &upstream_output, &upstream_in);
                result = port.compressStream(&port_output, &port_in);
            },
            .flush => {
                takes_input = false;
                code = c.ZSTD_flushStream(up, &upstream_output);
                result = port.flushStream(&port_output);
            },
            .end => {
                takes_input = false;
                code = c.ZSTD_endStream(up, &upstream_output);
                result = port.endStream(&port_output);
            },
        }
        errdefer std.debug.print(
            "call {t} in {d} out {d}, at input {d} output {d}\n",
            .{ call.kind, call.in, call.out, s.in_pos, s.out_pos },
        );
        try expectSameResult(code, result);
        if (takes_input) {
            const upstream_in_pos = if (s.stable_in)
                upstream_in.pos
            else
                s.in_pos + upstream_in.pos;
            const port_in_pos = if (s.stable_in) port_in.pos else s.in_pos + port_in.pos;
            try testing.expectEqual(upstream_in_pos, port_in_pos);
            s.in_pos = port_in_pos;
        }
        const upstream_out_pos = if (s.stable_out)
            upstream_output.pos
        else
            s.out_pos + upstream_output.pos;
        const port_out_pos = if (s.stable_out) port_output.pos else s.out_pos + port_output.pos;
        try testing.expectEqual(upstream_out_pos, port_out_pos);
        s.out_pos = port_out_pos;
        if (s.single_thread) try expectSameProgression(s.pair);
        s.last = Result.of(code);
        return s.last.?;
    }

    /// Ends the frame: the rest of the input with `.end`, then `endStream`
    /// or `.end` calls with `out` windows until it is complete, fails or
    /// fills the output.
    /// Returns whether a frame was made.
    pub fn finish(s: *Stream, random: ?std.Random, out: usize) !bool {
        var calls: usize = 0;
        while (true) : (calls += 1) {
            if (calls > 10_000_000) return error.StreamDoesNotEnd;
            const window = if (random) |r| randomWindow(r, out) else out;
            const rest = s.src.len - s.in_pos;
            const use_end_stream = rest == 0 and if (random) |r| r.boolean() else false;
            const result = try s.step(.{
                .kind = if (use_end_stream) .end else .stream2_end,
                .in = rest,
                .out = window,
            });
            switch (result) {
                .error_code => return false,
                .size => |n| {
                    if (n == 0 and s.in_pos == s.src.len) return true;
                    // A full output that still has bytes to take never ends.
                    if (s.out_pos == s.port_out.len) return false;
                },
            }
        }
    }

    /// Checks the frames are the same and decode back, with `dict` when given.
    pub fn expectFrame(s: *const Stream, dict: ?[]const u8) !void {
        const upstream_frame = s.upstream_out[0..s.out_pos];
        const port_frame = s.port_out[0..s.out_pos];
        try common.expectSameFrame(upstream_frame, port_frame);
        if (dict) |d| {
            try common.expectUpstreamDecodes(port_frame, s.src, d);
        } else {
            try common.expectRoundTrip(port_frame, s.src);
        }
    }
};

fn randomWindow(random: std.Random, max: usize) usize {
    return switch (random.uintLessThan(u32, 8)) {
        0 => 1,
        1 => 1 + random.uintLessThan(usize, 64),
        2, 3 => 1 + random.uintLessThan(usize, 8 * kib),
        4, 5 => 1 + random.uintLessThan(usize, 200 * kib),
        else => max,
    };
}

fn randomInput(random: std.Random, src_len: usize) usize {
    return switch (random.uintLessThan(u32, 8)) {
        0 => 0,
        1 => 1 + random.uintLessThan(usize, 100),
        2, 3 => 1 + random.uintLessThan(usize, 20 * kib),
        4, 5 => 1 + random.uintLessThan(usize, 200 * kib),
        else => src_len,
    };
}

/// Checks both sides' frame progression and bytes to flush agree.
pub fn expectSameProgression(pair: Pair) !void {
    const expected = c.ZSTD_getFrameProgression(pair.upstream);
    const actual = pair.port.getFrameProgression();
    try testing.expectEqual(expected.ingested, actual.ingested);
    try testing.expectEqual(expected.consumed, actual.consumed);
    try testing.expectEqual(expected.produced, actual.produced);
    try testing.expectEqual(expected.flushed, actual.flushed);
    try testing.expectEqual(expected.current_job_id, actual.current_job_id);
    try testing.expectEqual(expected.nb_active_workers, actual.nb_active_workers);
    try testing.expectEqual(c.ZSTD_toFlushNow(pair.upstream), pair.port.toFlushNow());
}

/// Sets the stable buffer modes on both sides.
fn setModes(pair: Pair, stable_in: bool, stable_out: bool) !void {
    try pair.set(.stable_in_buffer, @intFromBool(stable_in));
    try pair.set(.stable_out_buffer, @intFromBool(stable_out));
}

/// Streams `src` on both sides: `chunk` bytes per `.continue` call, a
/// `.flush` every `flush_every` bytes (0 for none), output windows of
/// `out`, then the end. Checks the frames.
fn streamSimple(
    pair: Pair,
    src: []const u8,
    chunk: usize,
    flush_every: usize,
    out: usize,
    dict: ?[]const u8,
) !void {
    var s = try Stream.init(pair, src, c.ZSTD_compressBound(src.len) + 64, false, false);
    defer s.deinit();
    var since_flush: usize = 0;
    while (s.in_pos < src.len) {
        const before = s.in_pos;
        _ = try s.step(.{ .kind = .stream2_continue, .in = chunk, .out = out });
        since_flush += s.in_pos - before;
        if (flush_every != 0 and since_flush >= flush_every) {
            since_flush = 0;
            while (true) {
                const r = try s.step(.{ .kind = .stream2_flush, .out = out });
                if (r != .size or r.size == 0) break;
            }
        }
    }
    try testing.expect(try s.finish(null, out));
    try s.expectFrame(dict);
}

test "compressStream2: every level, chunks, flushes and small windows" {
    const pair = try Pair.init();
    defer pair.deinit();
    const src = try common.generated(400_000, 0.6, 0.3, 501);
    defer gpa.free(src);
    for (frame.levels) |level| {
        errdefer std.debug.print("level {d}\n", .{level});
        try pair.set(.compression_level, level);
        try streamSimple(pair, src, 64 * kib, 0, 1 << 40, null);
        try streamSimple(pair, src[0..100_000], 7_777, 30_000, 5_000, null);
        try streamSimple(pair, src[0..3000], 1, 0, 1 << 40, null);
        try streamSimple(pair, src[0..0], 1, 0, 1 << 40, null);
    }
}

test "compressStream2: one-byte output windows" {
    const pair = try Pair.init();
    defer pair.deinit();
    const src = try common.generated(150_000, 0.5, 0.2, 502);
    defer gpa.free(src);
    for ([_]i32{ 1, 3, 19 }) |level| {
        try pair.set(.compression_level, level);
        try pair.set(.checksum_flag, 1);
        try streamSimple(pair, src, 50_000, 40_000, 1, null);
    }
}

/// One parameter, by the port's name, with the original's number.
fn p(param: params.CParameter, value: i32) common.Param {
    return .{ .param = @backingInt(param), .value = value };
}

/// Parameter sets the streaming tests run with.
const param_sets = [_][]const common.Param{
    &.{},
    &.{ p(.checksum_flag, 1), p(.content_size_flag, 0) },
    &.{ p(.window_log, 10), p(.compression_level, 4) },
    &.{ p(.window_log, 17), p(.enable_long_distance_matching, 1) },
    &.{ p(.target_cblock_size, 1000), p(.compression_level, 7) },
    &.{ p(.block_splitter_level, 2), p(.compression_level, 15) },
    &.{ p(.split_after_sequences, 1), p(.compression_level, 19) },
    &.{ p(.use_row_match_finder, 1), p(.compression_level, 12) },
    &.{ p(.max_block_size, 4096), p(.compression_level, 2) },
    &.{ p(.max_block_size, 20_000), p(.compression_level, 9) },
    &.{ p(.literal_compression_mode, 2), p(.compression_level, 1) },
    &.{ p(.src_size_hint, 50_000), p(.compression_level, 6) },
    &.{ p(.dict_id_flag, 0), p(.compression_level, -3) },
    &.{ p(.force_max_window, 1), p(.compression_level, 22) },
    &.{ p(.format, 1), p(.compression_level, 5) },
    &.{
        p(.deterministic_ref_prefix, 1),
        p(.enable_dedicated_dict_search, 1),
        p(.compression_level, 6),
    },
};

/// The original's parameter number as the port's parameter.
fn portParam(number: u32) params.CParameter {
    return @fromBackingInt(number);
}

fn setParams(pair: Pair, set: []const common.Param) !void {
    for (set) |param| try pair.set(portParam(param.param), param.value);
}

/// Whether frames with `set` decode without telling the decoder.
fn plainFormat(set: []const common.Param) bool {
    for (set) |param| if (param.param == 10 and param.value == 1) return false;
    return true;
}

test "compressStream2: fuzzed calls, both buffer modes, parameters, dictionaries, frames" {
    const corpus = try common.generated(1 << 20, 0.6, 0.3, 503);
    defer gpa.free(corpus);
    const raw_dict = corpus[0..40_000];
    const random_bytes = try gpa.alloc(u8, 300_000);
    defer gpa.free(random_bytes);
    var prng: std.Random.DefaultPrng = .init(common.fuzzSeed(504));
    prng.random().bytes(random_bytes);
    const port_cdict = try zstd.CDict.create(gpa, raw_dict, 5);
    defer port_cdict.destroy();
    const upstream_cdict = c.ZSTD_createCDict(raw_dict.ptr, raw_dict.len, 5).?;
    defer _ = c.ZSTD_freeCDict(upstream_cdict);

    for (0..common.fuzz_cases) |case| {
        const seed = common.fuzzSeed(505) +% case;
        var case_prng: std.Random.DefaultPrng = .init(seed);
        const random = case_prng.random();
        errdefer std.debug.print("fuzz seed {d}, case {d}\n", .{ seed, case });

        const pair = try Pair.init();
        defer pair.deinit();
        const set = param_sets[random.uintLessThan(usize, param_sets.len)];
        try setParams(pair, set);
        if (random.uintLessThan(u32, 3) == 0) {
            try pair.set(.compression_level, frame.strategy_levels[
                random.uintLessThan(usize, frame.strategy_levels.len)
            ]);
        }
        const stable_in = random.boolean();
        const stable_out = random.boolean();
        try setModes(pair, stable_in, stable_out);

        const nb_frames = 1 + random.uintLessThan(u32, 3);
        for (0..nb_frames) |_| {
            const size = switch (random.uintLessThan(u32, 4)) {
                0 => random.uintLessThan(usize, 300),
                1 => random.uintLessThan(usize, 20_000),
                else => random.uintLessThan(usize, 400_000),
            };
            const src = if (random.uintLessThan(u32, 6) == 0)
                random_bytes[0..@min(size, random_bytes.len)]
            else
                corpus[corpus.len - size ..];

            // The dictionary of this frame.
            var dict: ?[]const u8 = null;
            switch (random.uintLessThan(u32, 6)) {
                0 => {
                    try expectSameResult(
                        c.ZSTD_CCtx_refPrefix(pair.upstream, raw_dict.ptr, raw_dict.len),
                        pair.port.refPrefix(raw_dict),
                    );
                    dict = raw_dict;
                },
                1 => {
                    try expectSameResult(
                        c.ZSTD_CCtx_loadDictionary(pair.upstream, raw_dict.ptr, raw_dict.len),
                        pair.port.loadDictionary(raw_dict),
                    );
                    dict = raw_dict;
                },
                2 => {
                    try expectSameResult(
                        c.ZSTD_CCtx_refCDict(pair.upstream, upstream_cdict),
                        pair.port.refCDict(port_cdict),
                    );
                    dict = raw_dict;
                },
                else => {
                    try expectSameResult(
                        c.ZSTD_CCtx_refCDict(pair.upstream, null),
                        pair.port.refCDict(null),
                    );
                },
            }
            // The pledged size: none, right, or wrong.
            switch (random.uintLessThan(u32, 6)) {
                0 => try expectSameResult(
                    c.ZSTD_CCtx_setPledgedSrcSize(pair.upstream, src.len),
                    pair.port.setPledgedSrcSize(src.len),
                ),
                1 => {
                    const wrong: u64 = if (random.boolean()) src.len + 1 else src.len -| 1;
                    try expectSameResult(
                        c.ZSTD_CCtx_setPledgedSrcSize(pair.upstream, wrong),
                        pair.port.setPledgedSrcSize(wrong),
                    );
                },
                else => {},
            }

            // A stable output buffer, now and then too small.
            const capacity = if (stable_out and random.uintLessThan(u32, 8) == 0)
                1 + random.uintLessThan(usize, 1000)
            else
                c.ZSTD_compressBound(src.len) + 64;
            var stream = try Stream.init(pair, src, capacity, stable_in, stable_out);
            defer stream.deinit();
            var failed = false;
            var calls: u32 = 0;
            const nb_calls = random.uintLessThan(u32, 30);
            while (calls < nb_calls and stream.in_pos < src.len) : (calls += 1) {
                const kind: Call.Kind = switch (random.uintLessThan(u32, 10)) {
                    0...5 => .stream2_continue,
                    6 => .stream2_flush,
                    7 => .stream,
                    else => .flush,
                };
                const result = try stream.step(.{
                    .kind = kind,
                    .in = randomInput(random, src.len),
                    .out = randomWindow(random, 1 << 40),
                });
                if (result == .error_code) {
                    failed = true;
                    break;
                }
            }
            if (!failed) failed = !try stream.finish(random, 1 << 40);
            if (!failed and plainFormat(set)) {
                try stream.expectFrame(dict);
            } else if (!failed) {
                try common.expectSameFrame(
                    stream.upstream_out[0..stream.out_pos],
                    stream.port_out[0..stream.out_pos],
                );
            }
            try testing.expectEqual(c.ZSTD_sizeof_CStream(pair.upstream), pair.port.sizeof());
            if (failed) {
                try expectSameResult(
                    c.ZSTD_CCtx_reset(pair.upstream, 1),
                    pair.port.reset(.session_only),
                );
            }
        }
    }
}

test "compressStream2: a pledged size, right and wrong" {
    const pair = try Pair.init();
    defer pair.deinit();
    const src = try common.generated(300_000, 0.5, 0.3, 506);
    defer gpa.free(src);
    for ([_]i32{ 1, 6, 19 }) |level| {
        try pair.set(.compression_level, level);
        for ([_]i64{ 0, -1, 1, -1000, 1000 }) |delta| {
            for ([_]usize{ 0, 1, 1000, 128 * kib, 128 * kib + 1, src.len }) |size| {
                errdefer std.debug.print(
                    "level {d}, size {d}, delta {d}\n",
                    .{ level, size, delta },
                );
                const pledged: u64 = @intCast(@max(0, @as(i64, @intCast(size)) + delta));
                try expectSameResult(
                    c.ZSTD_CCtx_setPledgedSrcSize(pair.upstream, pledged),
                    pair.port.setPledgedSrcSize(pledged),
                );
                var s = try Stream.init(
                    pair,
                    src[0..size],
                    c.ZSTD_compressBound(size) + 64,
                    false,
                    false,
                );
                defer s.deinit();
                var failed = false;
                while (s.in_pos < size) {
                    const r = try s.step(.{ .kind = .stream2_continue, .in = 50_000 });
                    if (r == .error_code) {
                        failed = true;
                        break;
                    }
                }
                if (!failed) failed = !try s.finish(null, 1 << 40);
                if (!failed) {
                    // A frame ended by its first call takes that call's
                    // input as its size.
                    if (size > 0) try testing.expectEqual(@as(u64, size), pledged);
                    try s.expectFrame(null);
                }
                try expectSameResult(
                    c.ZSTD_CCtx_reset(pair.upstream, 1),
                    pair.port.reset(.session_only),
                );
            }
        }
    }
}

test "compressStream2: stable buffers, and their promises broken" {
    const src = try common.generated(500_000, 0.5, 0.3, 507);
    defer gpa.free(src);
    for ([_]bool{ false, true }) |stable_in| {
        for ([_]bool{ false, true }) |stable_out| {
            const pair = try Pair.init();
            defer pair.deinit();
            try setModes(pair, stable_in, stable_out);
            errdefer std.debug.print("stable in {}, out {}\n", .{ stable_in, stable_out });

            // Whole frames, fed in chunks.
            for ([_]usize{ 1000, 60_000, 128 * kib, 200_000 }) |chunk| {
                var s = try Stream.init(
                    pair,
                    src,
                    c.ZSTD_compressBound(src.len),
                    stable_in,
                    stable_out,
                );
                defer s.deinit();
                while (s.in_pos < src.len) {
                    _ = try s.step(.{ .kind = .stream2_continue, .in = chunk, .out = 100_000 });
                }
                try testing.expect(try s.finish(null, 100_000));
                try s.expectFrame(null);
            }

            // A stable output too small for the frame.
            {
                var s = try Stream.init(pair, src, 1000, stable_in, stable_out);
                defer s.deinit();
                _ = try s.finish(null, 1000);
                try expectSameResult(
                    c.ZSTD_CCtx_reset(pair.upstream, 1),
                    pair.port.reset(.session_only),
                );
            }

            // The input moved, its position changed, the output's space
            // changed, before and after the frame starts.
            const moved = try gpa.dupe(u8, src);
            defer gpa.free(moved);
            for (0..3) |broken| {
                if (broken < 2 and !stable_in) continue;
                if (broken == 2 and !stable_out) continue;
                for ([_]usize{ 1000, 200_000 }) |first| {
                    // A fresh context each: the original's reset keeps the
                    // count of input it has not taken after a broken promise.
                    const own = try Pair.init();
                    defer own.deinit();
                    try setModes(own, stable_in, stable_out);
                    var s = try Stream.init(
                        own,
                        src,
                        c.ZSTD_compressBound(src.len),
                        stable_in,
                        stable_out,
                    );
                    defer s.deinit();
                    _ = try s.step(.{ .kind = .stream2_continue, .in = first, .out = 50_000 });
                    const in_base = if (broken == 0) moved else src;
                    const in_pos = if (broken != 1)
                        s.in_pos
                    else if (s.in_pos > 0)
                        s.in_pos - 1
                    else
                        s.in_pos + 1;
                    // Before the frame starts the original checks the input
                    // only on a call that stays under a block with no flush;
                    // any other call takes it as the frame's, past the start.
                    const before_start = stable_in and s.waiting and broken < 2;
                    const in_end = if (before_start) @min(src.len, s.avail + 1000) else src.len;
                    const op: EndDirective = if (before_start) .@"continue" else .end;
                    var upstream_in: c.ZSTD_inBuffer = if (stable_in)
                        .{ .src = in_base.ptr, .size = in_end, .pos = in_pos }
                    else
                        .{ .src = src.ptr + s.in_pos, .size = src.len - s.in_pos, .pos = 0 };
                    var port_in: zstd.InBuffer = if (stable_in)
                        .{ .src = in_base[0..in_end], .pos = in_pos }
                    else
                        .{ .src = src[s.in_pos..] };
                    const out_end = s.port_out.len - @intFromBool(broken == 2);
                    var upstream_output: c.ZSTD_outBuffer = if (stable_out)
                        .{ .dst = s.upstream_out.ptr, .size = out_end, .pos = s.out_pos }
                    else
                        .{
                            .dst = s.upstream_out.ptr + s.out_pos,
                            .size = out_end - s.out_pos,
                            .pos = 0,
                        };
                    var port_output: zstd.OutBuffer = if (stable_out)
                        .{ .dst = s.port_out[0..out_end], .pos = s.out_pos }
                    else
                        .{ .dst = s.port_out[s.out_pos..out_end] };
                    errdefer std.debug.print("broken {d}, first {d}\n", .{ broken, first });
                    const code = c.ZSTD_compressStream2(
                        own.upstream,
                        &upstream_output,
                        &upstream_in,
                        @backingInt(op),
                    );
                    const result = own.port.compressStream2(&port_output, &port_in, op);
                    try expectSameResult(code, result);
                    try testing.expectEqual(upstream_in.pos, port_in.pos);
                    try testing.expectEqual(upstream_output.pos, port_output.pos);
                }
            }
        }
    }
}

test "compressStream2: dictionaries, prefixes and CDicts, frames after frames" {
    const corpus = try common.generated(1 << 20, 0.6, 0.3, 508);
    defer gpa.free(corpus);
    const dict = corpus[0..60_000];
    const src = corpus[corpus.len - 300_000 ..];
    for (frame.strategy_levels) |level| {
        errdefer std.debug.print("level {d}\n", .{level});
        const pair = try Pair.init();
        defer pair.deinit();
        try pair.set(.compression_level, level);
        // A prefix serves one frame only.
        try expectSameResult(
            c.ZSTD_CCtx_refPrefix(pair.upstream, dict.ptr, dict.len),
            pair.port.refPrefix(dict),
        );
        try streamSimple(pair, src, 40_000, 100_000, 1 << 40, dict);
        try streamSimple(pair, src, 40_000, 0, 1 << 40, null);
        // A loaded dictionary serves every frame.
        try expectSameResult(
            c.ZSTD_CCtx_loadDictionary(pair.upstream, dict.ptr, dict.len),
            pair.port.loadDictionary(dict),
        );
        try streamSimple(pair, src, 128 * kib, 0, 1 << 40, dict);
        try streamSimple(pair, src[0..5000], 100, 0, 1000, dict);
        // A CDict, whose level wins.
        const port_cdict = try zstd.CDict.create(gpa, dict, level);
        defer port_cdict.destroy();
        const upstream_cdict = c.ZSTD_createCDict(dict.ptr, dict.len, level).?;
        defer _ = c.ZSTD_freeCDict(upstream_cdict);
        try expectSameResult(
            c.ZSTD_CCtx_refCDict(pair.upstream, upstream_cdict),
            pair.port.refCDict(port_cdict),
        );
        try streamSimple(pair, src, 64 * kib, 0, 1 << 40, dict);
        try streamSimple(pair, src[0..20_000], 64 * kib, 0, 1 << 40, dict);
    }
}

test "initCStream variants, resetCStream, compressStream2SimpleArgs" {
    const corpus = try common.generated(1 << 20, 0.6, 0.3, 509);
    defer gpa.free(corpus);
    const dict = corpus[0..50_000];
    const src = corpus[corpus.len - 250_000 ..];
    const port_cdict = try zstd.CDict.create(gpa, dict, 7);
    defer port_cdict.destroy();
    const upstream_cdict = c.ZSTD_createCDict(dict.ptr, dict.len, 7).?;
    defer _ = c.ZSTD_freeCDict(upstream_cdict);
    const pair = try Pair.init();
    defer pair.deinit();

    for ([_]i32{ -5, 1, 3, 9, 19 }) |level| {
        for ([_]u64{ 0, src.len, params.content_size_unknown }) |pss| {
            errdefer std.debug.print("level {d}, pledged {d}\n", .{ level, pss });
            const port = pair.port;
            const up = pair.upstream;
            try expectSameResult(c.ZSTD_initCStream(up, level), port.initCStream(level));
            try streamSimple(pair, src, 30_000, 0, 1 << 40, null);
            try expectSameResult(
                c.ZSTD_initCStream_srcSize(up, level, pss),
                port.initCStreamSrcSize(level, pss),
            );
            try streamSimple(pair, src, 30_000, 0, 1 << 40, null);
            try expectSameResult(
                c.ZSTD_initCStream_usingDict(up, dict.ptr, dict.len, level),
                port.initCStreamUsingDict(dict, level),
            );
            try streamSimple(pair, src, 30_000, 0, 1 << 40, dict);
            try expectSameResult(
                c.ZSTD_initCStream_usingDict(up, null, 0, level),
                port.initCStreamUsingDict(&.{}, level),
            );
            try streamSimple(pair, src, 30_000, 0, 1 << 40, null);
            const level_params = zstd.getParams(level, src.len, dict.len);
            for ([_]bool{ false, true }) |content_size| {
                var pa = level_params;
                pa.fparams.content_size_flag = content_size;
                pa.fparams.checksum_flag = true;
                try expectSameResult(
                    c.ZSTD_initCStream_advanced(
                        up,
                        dict.ptr,
                        dict.len,
                        frame.parametersToC(pa),
                        pss,
                    ),
                    port.initCStreamAdvanced(dict, pa, pss),
                );
                // A pledged size the input does not have fails on both.
                if (pss == 0 or pss == src.len or pss == params.content_size_unknown) {
                    var s = try Stream.init(
                        pair,
                        src,
                        c.ZSTD_compressBound(src.len) + 64,
                        false,
                        false,
                    );
                    defer s.deinit();
                    while (s.in_pos < src.len) {
                        const r = try s.step(.{ .kind = .stream, .in = 30_000 });
                        if (r == .error_code) break;
                    }
                    if (s.last.? != .error_code and try s.finish(null, 1 << 40)) try s.expectFrame(
                        dict,
                    );
                }
                try expectSameResult(c.ZSTD_CCtx_reset(up, 1), port.reset(.session_only));
            }
            // Parameters out of bounds.
            var bad = level_params;
            bad.cparams.window_log = 5;
            try expectSameResult(
                c.ZSTD_initCStream_advanced(up, null, 0, frame.parametersToC(bad), pss),
                port.initCStreamAdvanced(&.{}, bad, pss),
            );
            try expectSameResult(
                c.ZSTD_initCStream_usingCDict(up, upstream_cdict),
                port.initCStreamUsingCDict(port_cdict),
            );
            try streamSimple(pair, src, 30_000, 0, 1 << 40, dict);
            const fparams: params.FrameParameters = .{
                .content_size_flag = pss != 0,
                .checksum_flag = true,
                .no_dict_id_flag = true,
            };
            try expectSameResult(
                c.ZSTD_initCStream_usingCDict_advanced(
                    up,
                    upstream_cdict,
                    frame.fparamsToC(fparams),
                    pss,
                ),
                port.initCStreamUsingCDictAdvanced(port_cdict, fparams, pss),
            );
            if (pss != src.len and pss != params.content_size_unknown) {
                try expectSameResult(c.ZSTD_CCtx_reset(up, 1), port.reset(.session_only));
            } else {
                try streamSimple(pair, src, 30_000, 0, 1 << 40, dict);
            }
            try expectSameResult(c.ZSTD_resetCStream(up, pss), port.resetCStream(pss));
            try streamSimple(pair, src, 30_000, 0, 1 << 40, dict);
            try expectSameResult(c.ZSTD_initCStream(up, level), port.initCStream(level));
        }
    }

    // compressStream2SimpleArgs, from positions within the buffers.
    const expected = try gpa.alloc(u8, c.ZSTD_compressBound(src.len) + 10);
    defer gpa.free(expected);
    const actual = try gpa.alloc(u8, expected.len);
    defer gpa.free(actual);
    for ([_]usize{ 0, 3, 10 }) |start| {
        var upstream_dst_pos = start;
        var upstream_src_pos = start;
        var port_dst_pos = start;
        var port_src_pos = start;
        const code = c.ZSTD_compressStream2_simpleArgs(
            pair.upstream,
            expected.ptr,
            expected.len,
            &upstream_dst_pos,
            src.ptr,
            src.len,
            &upstream_src_pos,
            2,
        );
        const result = pair.port.compressStream2SimpleArgs(
            actual,
            &port_dst_pos,
            src,
            &port_src_pos,
            .end,
        );
        try expectSameResult(code, result);
        try testing.expectEqual(upstream_dst_pos, port_dst_pos);
        try testing.expectEqual(upstream_src_pos, port_src_pos);
        try common.expectSameFrame(expected[start..upstream_dst_pos], actual[start..port_dst_pos]);
    }
    // Positions past the buffers.
    var dst_pos: usize = expected.len + 1;
    var src_pos: usize = 0;
    try expectSameResult(
        c.ZSTD_compressStream2_simpleArgs(
            pair.upstream,
            expected.ptr,
            expected.len,
            &dst_pos,
            src.ptr,
            src.len,
            &src_pos,
            0,
        ),
        pair.port.compressStream2SimpleArgs(actual, &dst_pos, src, &src_pos, .@"continue"),
    );
    dst_pos = 0;
    src_pos = src.len + 1;
    try expectSameResult(
        c.ZSTD_compressStream2_simpleArgs(
            pair.upstream,
            expected.ptr,
            expected.len,
            &dst_pos,
            src.ptr,
            src.len,
            &src_pos,
            0,
        ),
        pair.port.compressStream2SimpleArgs(actual, &dst_pos, src, &src_pos, .@"continue"),
    );
}

test "CStreamInSize, CStreamOutSize, initStaticCStream" {
    try testing.expectEqual(c.ZSTD_CStreamInSize(), zstd.cStreamInSize());
    try testing.expectEqual(c.ZSTD_CStreamOutSize(), zstd.cStreamOutSize());
    const src = try common.generated(300_000, 0.5, 0.3, 510);
    defer gpa.free(src);
    for ([_]i32{ 1, 3, 7, 16, 19 }) |level| {
        errdefer std.debug.print("level {d}\n", .{level});
        const size = c.ZSTD_estimateCStreamSize(level);
        try testing.expectEqual(size, zstd.estimateCStreamSize(level));
        const upstream_ws = try gpa.alignedAlloc(u8, .@"8", size);
        defer gpa.free(upstream_ws);
        const port_ws = try gpa.alignedAlloc(u8, .@"8", size);
        defer gpa.free(port_ws);
        const up = c.ZSTD_initStaticCStream(upstream_ws.ptr, upstream_ws.len).?;
        const port = zstd.CCtx.initStatic(port_ws).?;
        const pair: Pair = .{ .port = port, .upstream = up };
        try expectSameResult(c.ZSTD_initCStream(up, level), port.initCStream(level));
        try streamSimple(pair, src, 50_000, 120_000, 1 << 40, null);
        try streamSimple(pair, src[0..1000], 50_000, 0, 1 << 40, null);
        try testing.expectEqual(c.ZSTD_sizeof_CStream(up), port.sizeof());
    }
}

// ---------------------------------------------------------------------------
// Multithreading
// ---------------------------------------------------------------------------

const io = std.testing.io;

/// An input of several jobs; the caller frees it.
fn mtInput() ![]u8 {
    return common.generated(5 * mib + 12345, 0.6, 0.3, 520);
}

/// A pair set up for `nb_workers` with `extra` parameters; the port's
/// context runs on the test's `Io`.
fn mtPair(nb_workers: i32, extra: []const common.Param) !Pair {
    const pair = try Pair.init();
    errdefer pair.deinit();
    pair.port.setIo(io);
    try pair.set(.nb_workers, nb_workers);
    try setParams(pair, extra);
    return pair;
}

/// Compresses `src` with `compress2` on both, `runs` times on the port,
/// checking every frame is the original's.
fn expectMtCompress2(pair: Pair, src: []const u8, runs: usize) !void {
    const expected = try frame.boundBuffer(src.len);
    defer gpa.free(expected);
    const code = c.ZSTD_compress2(pair.upstream, expected.ptr, expected.len, src.ptr, src.len);
    const dst = try frame.boundBuffer(src.len);
    defer gpa.free(dst);
    for (0..runs) |_| {
        const result = pair.port.compress2(dst, src);
        try expectSameResult(code, result);
        const n = result catch return;
        try common.expectSameFrame(expected[0..code], dst[0..n]);
    }
    try common.expectRoundTrip(dst[0..code], src);
}

/// A multithreaded stream on both sides. The threads' timing decides how
/// much input a call takes and how much output it gives, so each side
/// keeps its own positions, and is fed until it has taken the same input
/// before a flush or the end.
const MtStream = struct {
    pair: Pair,
    src: []const u8,
    upstream_out: []u8,
    port_out: []u8,
    upstream: Position = .{},
    port: Position = .{},

    const Position = struct {
        in: usize = 0,
        out: usize = 0,
    };

    fn init(pair: Pair, src: []const u8) !MtStream {
        const upstream_out = try frame.boundBuffer(src.len);
        errdefer gpa.free(upstream_out);
        return .{
            .pair = pair,
            .src = src,
            .upstream_out = upstream_out,
            .port_out = try frame.boundBuffer(src.len),
        };
    }

    fn deinit(m: *MtStream) void {
        gpa.free(m.upstream_out);
        gpa.free(m.port_out);
    }

    /// `.continue` calls with output windows of `out` until each side has
    /// taken the input up to `target`.
    fn feed(m: *MtStream, target: usize, out: usize) !void {
        while (m.upstream.in < target) {
            var input: c.ZSTD_inBuffer = .{
                .src = m.src.ptr,
                .size = target,
                .pos = m.upstream.in,
            };
            var output = upstreamWindow(m, out);
            const code = c.ZSTD_compressStream2(m.pair.upstream, &output, &input, 0);
            if (c.ZSTD_isError(code) != 0) return error.UpstreamFailed;
            m.upstream = .{ .in = input.pos, .out = output.pos };
        }
        while (m.port.in < target) {
            var input: zstd.InBuffer = .{ .src = m.src[0..target], .pos = m.port.in };
            var output = portWindow(m, out);
            _ = try m.pair.port.compressStream2(&output, &input, .@"continue");
            m.port = .{ .in = input.pos, .out = output.pos };
        }
    }

    /// `.flush` or `.end` calls with no more input until each side is done;
    /// both must then have written the same.
    fn drain(m: *MtStream, op: EndDirective, out: usize) !void {
        while (true) {
            var input: c.ZSTD_inBuffer = .{
                .src = m.src.ptr,
                .size = m.upstream.in,
                .pos = m.upstream.in,
            };
            var output = upstreamWindow(m, out);
            const code = c.ZSTD_compressStream2(m.pair.upstream, &output, &input, @backingInt(op));
            if (c.ZSTD_isError(code) != 0) return error.UpstreamFailed;
            m.upstream = .{ .in = input.pos, .out = output.pos };
            if (code == 0) break;
        }
        while (true) {
            var input: zstd.InBuffer = .{ .src = m.src[0..m.port.in], .pos = m.port.in };
            var output = portWindow(m, out);
            const remaining = try m.pair.port.compressStream2(&output, &input, op);
            m.port = .{ .in = input.pos, .out = output.pos };
            if (remaining == 0) break;
        }
        try testing.expectEqual(m.upstream, m.port);
        try common.expectSameFrame(m.upstream_out[0..m.upstream.out], m.port_out[0..m.port.out]);
        // No job is in progress, so the progression does not depend on
        // the timing.
        try expectSameProgression(m.pair);
    }

    fn upstreamWindow(m: *MtStream, out: usize) c.ZSTD_outBuffer {
        return .{
            .dst = m.upstream_out.ptr,
            .size = @min(m.upstream_out.len, m.upstream.out +| out),
            .pos = m.upstream.out,
        };
    }

    fn portWindow(m: *MtStream, out: usize) zstd.OutBuffer {
        return .{
            .dst = m.port_out[0..@min(m.port_out.len, m.port.out +| out)],
            .pos = m.port.out,
        };
    }
};

/// Streams `src` with workers on both: `chunk` bytes at a time, a `.flush`
/// every `flush_every` bytes (0 for none), output windows of `out`.
/// Checks the frames.
fn expectMtStream(pair: Pair, src: []const u8, chunk: usize, flush_every: usize, out: usize) !void {
    var m = try MtStream.init(pair, src);
    defer m.deinit();
    var since_flush: usize = 0;
    var fed: usize = 0;
    while (fed < src.len) {
        const target = @min(src.len, fed + chunk);
        try m.feed(target, out);
        since_flush += target - fed;
        fed = target;
        if (flush_every != 0 and since_flush >= flush_every) {
            since_flush = 0;
            try m.drain(.flush, out);
        }
    }
    try m.drain(.end, out);
    try common.expectRoundTrip(m.port_out[0..m.port.out], src);
}

test "multithreading: compress2 with 1, 2 and 4 workers, job sizes, overlaps, rsyncable" {
    if (@typeInfo(zstd.internal.zstdmt.ZstdmtCCtx) == .@"opaque") return error.SkipZigTest;
    const big = try mtInput();
    defer gpa.free(big);
    const sets = [_][]const common.Param{
        &.{},
        &.{p(.compression_level, 1)},
        &.{p(.compression_level, 19)},
        &.{ p(.job_size, 512 * kib), p(.compression_level, 5) },
        &.{ p(.job_size, 1 * mib), p(.overlap_log, 0) },
        &.{ p(.job_size, 700 * kib), p(.overlap_log, 9) },
        &.{ p(.rsyncable, 1), p(.compression_level, 3) },
        &.{ p(.enable_long_distance_matching, 1), p(.compression_level, 12) },
        &.{ p(.checksum_flag, 1), p(.job_size, 600 * kib) },
    };
    for ([_]i32{ 1, 2, 4 }) |nb_workers| {
        for (sets) |set| {
            errdefer std.debug.print("{d} workers, {any}\n", .{ nb_workers, set });
            const pair = try mtPair(nb_workers, set);
            defer pair.deinit();
            try expectMtCompress2(pair, big, 3);
            try expectMtCompress2(pair, big[0 .. 512 * kib + 1], 2);
            try expectMtCompress2(pair, big[0 .. 512 * kib], 1);
            try expectMtCompress2(pair, big[0..1000], 1);
        }
    }
}

test "multithreading: compressStream2 with flushes, small windows, a shared pool" {
    if (@typeInfo(zstd.internal.zstdmt.ZstdmtCCtx) == .@"opaque") return error.SkipZigTest;
    const big = try mtInput();
    defer gpa.free(big);
    for ([_]i32{ 1, 2, 4 }) |nb_workers| {
        errdefer std.debug.print("{d} workers\n", .{nb_workers});
        {
            const pair = try mtPair(nb_workers, &.{p(.compression_level, 3)});
            defer pair.deinit();
            try expectMtStream(pair, big, 1 * mib, 0, 1 << 40);
            try expectMtStream(pair, big, 300 * kib, 1 * mib, 100 * kib);
            try expectMtStream(pair, big[0 .. 2 * mib], 100 * kib, 700 * kib, 1000);
        }
        {
            // A thread pool of 2 threads, shared by both contexts of a side.
            const port_pool = zstd.createThreadPool(gpa, io, 2) orelse return error.OutOfMemory;
            defer zstd.freeThreadPool(port_pool);
            const upstream_pool = c.ZSTD_createThreadPool(2) orelse return error.OutOfMemory;
            defer c.ZSTD_freeThreadPool(upstream_pool);
            const set = [_]common.Param{
                p(.compression_level, 6),
                p(.job_size, 512 * kib),
            };
            const a = try Pair.init();
            defer a.deinit();
            const b = try Pair.init();
            defer b.deinit();
            for ([_]Pair{ a, b }) |pair| {
                try expectSameResult(
                    c.ZSTD_CCtx_refThreadPool(pair.upstream, upstream_pool),
                    pair.port.refThreadPool(port_pool),
                );
                try pair.set(.nb_workers, nb_workers);
                try setParams(pair, &set);
            }
            try expectMtCompress2(a, big, 2);
            try expectMtCompress2(b, big[0 .. 3 * mib], 2);
            try expectMtStream(a, big, 1 * mib, 2 * mib, 1 << 40);
            try expectMtStream(b, big, 1 * mib, 0, 1 << 40);
        }
    }
}

test "multithreading: a level change while compressing, a context without an Io" {
    if (@typeInfo(zstd.internal.zstdmt.ZstdmtCCtx) == .@"opaque") return error.SkipZigTest;
    const big = try mtInput();
    defer gpa.free(big);
    {
        // The level changes after the first megabytes.
        const pair = try mtPair(2, &.{p(.compression_level, 3)});
        defer pair.deinit();
        var m = try MtStream.init(pair, big);
        defer m.deinit();
        try m.feed(2 * mib, 1 << 40);
        try pair.set(.compression_level, 9);
        try m.feed(big.len, 1 << 40);
        try m.drain(.end, 1 << 40);
        try common.expectRoundTrip(m.port_out[0..m.port.out], big);
    }
    {
        // The port needs an `Io` for workers; the original needs none.
        const port = try zstd.CCtx.create(gpa);
        defer port.destroy() catch unreachable;
        _ = try port.setParameter(.nb_workers, 2);
        const dst = try frame.boundBuffer(big.len);
        defer gpa.free(dst);
        try testing.expectError(error.ParameterCombinationUnsupported, port.compress2(dst, big));
        // A source too small for workers needs none.
        _ = try port.compress2(dst, big[0 .. 512 * kib]);
    }
}
