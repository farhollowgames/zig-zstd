//! Oracle tests of compression from the caller's sequences:
//! `compressSequences`, with and without block delimiters, validation on
//! and off, each way of resolving repeat offsets, and
//! `compressSequencesAndLiterals`. The sequences come from both sides'
//! `generateSequences` and from a generator that builds an input to fit
//! random sequences, long lengths included; invalid ones must fail with the
//! original's errors. Every frame must be the same, byte for byte, and
//! decode back to its input.

const std = @import("std");
const zstd = @import("zstd");
const c = @import("upstream");
const common = @import("common.zig");
const frame = @import("frame_test.zig");

const params = zstd.params;
const Sequence = params.Sequence;
const gpa = common.gpa;
const testing = std.testing;
const Pair = frame.Pair;
const expectSameResult = frame.expectSameResult;
const kib = 1 << 10;

/// The settings of a sequence compression.
const Setup = struct {
    level: i32 = 3,
    delimiters: params.SequenceFormat = .explicit_block_delimiters,
    validate: bool = false,
    /// The `repcode_resolution` parameter: 0 auto, 1 on, 2 off.
    repcodes: i32 = 0,
    checksum: bool = false,
    window_log: i32 = 0,
    min_match: i32 = 0,
};

/// Resets both contexts and applies `setup`.
fn apply(pair: Pair, setup: Setup) !void {
    try expectSameResult(
        c.ZSTD_CCtx_reset(pair.upstream, 3),
        pair.port.reset(.session_and_parameters),
    );
    try pair.set(.compression_level, setup.level);
    try pair.set(.block_delimiters, @intCast(@backingInt(setup.delimiters)));
    try pair.set(.validate_sequences, @intFromBool(setup.validate));
    try pair.set(.repcode_resolution, setup.repcodes);
    try pair.set(.checksum_flag, @intFromBool(setup.checksum));
    try pair.set(.window_log, setup.window_log);
    try pair.set(.min_match, setup.min_match);
}

fn asC(seqs: []const Sequence) [*]const c.ZSTD_Sequence {
    return @ptrCast(seqs.ptr);
}

/// `compressSequences` on both, the original with `upstream_seqs`, the
/// port with `port_seqs`, into `capacity` bytes. Checks the results and the
/// frames, and that a frame decodes back, with `dict` when given.
fn expectCompressSequences(
    pair: Pair,
    upstream_seqs: []const Sequence,
    port_seqs: []const Sequence,
    src: []const u8,
    capacity: usize,
    dict: ?[]const u8,
) !bool {
    const expected = try gpa.alloc(u8, capacity);
    defer gpa.free(expected);
    const dst = try gpa.alloc(u8, capacity);
    defer gpa.free(dst);
    const code = c.ZSTD_compressSequences(
        pair.upstream,
        expected.ptr,
        expected.len,
        asC(upstream_seqs),
        upstream_seqs.len,
        src.ptr,
        src.len,
    );
    const result = pair.port.compressSequences(dst, port_seqs, src);
    try expectSameResult(code, result);
    const n = result catch return false;
    try common.expectSameFrame(expected[0..code], dst[0..n]);
    if (dict) |d| {
        try common.expectUpstreamDecodes(dst[0..n], src, d);
    } else {
        try common.expectRoundTrip(dst[0..n], src);
    }
    return true;
}

/// Both sides' sequences of `src` at `level`, with block delimiters,
/// which must be the same. The caller frees them. Null when both refuse,
/// as for a block too small or too noisy to compress.
fn generate(pair: Pair, src: []const u8, level: i32) !?struct { []Sequence, []Sequence } {
    try expectSameResult(
        c.ZSTD_CCtx_reset(pair.upstream, 3),
        pair.port.reset(.session_and_parameters),
    );
    try pair.set(.compression_level, level);
    const bound = c.ZSTD_sequenceBound(src.len);
    const upstream_seqs = try gpa.alloc(Sequence, bound);
    errdefer gpa.free(upstream_seqs);
    const port_seqs = try gpa.alloc(Sequence, bound);
    errdefer gpa.free(port_seqs);
    const code = c.ZSTD_generateSequences(
        pair.upstream,
        @ptrCast(upstream_seqs.ptr),
        bound,
        src.ptr,
        src.len,
    );
    const result = pair.port.generateSequences(gpa, port_seqs, src);
    try expectSameResult(code, result);
    const n = result catch {
        gpa.free(upstream_seqs);
        gpa.free(port_seqs);
        return null;
    };
    try testing.expectEqualSlices(Sequence, upstream_seqs[0..code], port_seqs[0..n]);
    return .{ upstream_seqs[0..code], port_seqs[0..n] };
}

test "compressSequences: generated sequences, both formats, validation, repeat offsets" {
    const corpus = try common.generated(600_000, 0.6, 0.3, 601);
    defer gpa.free(corpus);
    const pair = try Pair.init();
    defer pair.deinit();
    for (frame.strategy_levels) |level| {
        for ([_]usize{ 0, 1, 100, 5000, 128 * kib + 1, 500_000 }) |size| {
            const src = corpus[0..size];
            const upstream_seqs, const port_seqs = try generate(pair, src, level) orelse continue;
            defer gpa.free(upstream_seqs.ptr[0..c.ZSTD_sequenceBound(size)]);
            defer gpa.free(port_seqs.ptr[0..c.ZSTD_sequenceBound(size)]);
            const merged_upstream = try gpa.dupe(Sequence, upstream_seqs);
            defer gpa.free(merged_upstream);
            const merged_port = try gpa.dupe(Sequence, port_seqs);
            defer gpa.free(merged_port);
            const nb_merged_upstream = c.ZSTD_mergeBlockDelimiters(
                @ptrCast(merged_upstream.ptr),
                merged_upstream.len,
            );
            const nb_merged_port = zstd.mergeBlockDelimiters(merged_port);

            for (std.enums.values(params.SequenceFormat)) |delimiters| {
                for ([_]bool{ false, true }) |validate| {
                    for ([_]i32{ 0, 1, 2 }) |repcodes| {
                        errdefer std.debug.print(
                            "level {d}, {d} bytes, {t}, validate {}, repcodes {d}\n",
                            .{ level, size, delimiters, validate, repcodes },
                        );
                        try apply(pair, .{
                            .level = level,
                            .delimiters = delimiters,
                            .validate = validate,
                            .repcodes = repcodes,
                            .checksum = repcodes == 1,
                        });
                        const explicit = delimiters == .explicit_block_delimiters;
                        try testing.expect(try expectCompressSequences(
                            pair,
                            if (explicit) upstream_seqs else merged_upstream[0..nb_merged_upstream],
                            if (explicit) port_seqs else merged_port[0..nb_merged_port],
                            src,
                            c.ZSTD_compressBound(size) + 16,
                            null,
                        ));
                    }
                }
            }
        }
    }
}

/// An input built to fit random sequences, and the sequences, with block
/// delimiters when `explicit`, and their literals one after the other.
const Synthetic = struct {
    src: []u8,
    seqs: []Sequence,
    literals: []u8,

    fn deinit(s: Synthetic) void {
        gpa.free(s.src);
        gpa.free(s.seqs);
        gpa.free(s.literals);
    }
};

const SynthOptions = struct {
    size: usize,
    explicit: bool,
    /// Literal and match lengths over 0xFFFF now and then.
    long: bool = false,
    /// Raw content the offsets may reach into, before the input.
    dict: []const u8 = &.{},
    max_offset: usize = 1 << 17,
    min_match: u32 = 3,
    /// The block sizes are at most this.
    block_size_max: usize = 128 * kib,
};

fn synthesize(random: std.Random, o: SynthOptions) !Synthetic {
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(gpa);
    var seqs: std.ArrayList(Sequence) = .empty;
    defer seqs.deinit(gpa);
    var literals: std.ArrayList(u8) = .empty;
    defer literals.deinit(gpa);
    // The dictionary and the input, as the offsets see them.
    var history: std.ArrayList(u8) = .empty;
    defer history.deinit(gpa);
    try history.appendSlice(gpa, o.dict);

    var block_left = o.block_size_max;
    while (src.items.len < o.size) {
        var ll: u32 = switch (random.uintLessThan(u32, 10)) {
            0, 1, 2 => 0,
            3, 4, 5 => random.uintLessThan(u32, 20),
            6, 7, 8 => random.uintLessThan(u32, 400),
            else => if (o.long) 65530 + random.uintLessThan(u32, 20) else random.uintLessThan(
                u32,
                3000,
            ),
        };
        const ml: u32 = switch (random.uintLessThan(u32, 10)) {
            0, 1, 2, 3 => o.min_match + random.uintLessThan(u32, 8),
            4, 5, 6, 7 => o.min_match + random.uintLessThan(u32, 300),
            8 => o.min_match + random.uintLessThan(u32, 5000),
            else => if (o.long) 65530 + random.uintLessThan(u32, 20) else 3000,
        };
        if (history.items.len + ll == 0) ll = 1;
        if (o.explicit and ll + ml > block_left) {
            // End the block with a delimiter and its literals.
            const last_ll = random.uintLessThan(usize, block_left + 1);
            try appendLiterals(random, &src, &literals, &history, last_ll);
            try seqs.append(
                gpa,
                .{ .offset = 0, .lit_length = @intCast(last_ll), .match_length = 0, .rep = 0 },
            );
            block_left = if (random.uintLessThan(u32, 4) == 0)
                o.block_size_max
            else
                1 + random.uintLessThan(usize, o.block_size_max);
            continue;
        }
        try appendLiterals(random, &src, &literals, &history, ll);
        const offset: u32 = @intCast(
            1 + random.uintLessThan(usize, @min(history.items.len, o.max_offset)),
        );
        // Repeats of the last offsets, now and then.
        const repeat = random.uintLessThan(u32, 4) == 0 and seqs.items.len > 0 and
            seqs.items[seqs.items.len - 1].offset != 0 and
            seqs.items[seqs.items.len - 1].offset <= history.items.len;
        const off = if (repeat) seqs.items[seqs.items.len - 1].offset else offset;
        for (0..ml) |_| {
            const byte = history.items[history.items.len - off];
            try history.append(gpa, byte);
            try src.append(gpa, byte);
        }
        try seqs.append(gpa, .{ .offset = off, .lit_length = ll, .match_length = ml, .rep = 0 });
        if (o.explicit) block_left -= ll + ml;
    }
    // The last literals, in a last delimiter.
    const last_ll = if (o.explicit) random.uintLessThan(usize, @min(block_left, 100) + 1) else 0;
    try appendLiterals(random, &src, &literals, &history, last_ll);
    if (o.explicit) {
        try seqs.append(
            gpa,
            .{ .offset = 0, .lit_length = @intCast(last_ll), .match_length = 0, .rep = 0 },
        );
    } else {
        // Literals no sequence covers.
        try appendLiterals(random, &src, &literals, &history, random.uintLessThan(usize, 100));
    }
    return .{
        .src = try src.toOwnedSlice(gpa),
        .seqs = try seqs.toOwnedSlice(gpa),
        .literals = try literals.toOwnedSlice(gpa),
    };
}

fn appendLiterals(
    random: std.Random,
    src: *std.ArrayList(u8),
    literals: *std.ArrayList(u8),
    history: *std.ArrayList(u8),
    n: usize,
) !void {
    for (0..n) |_| {
        // A small alphabet, so the literals compress.
        const byte = 'a' + random.uintLessThan(u8, 20);
        try src.append(gpa, byte);
        try literals.append(gpa, byte);
        try history.append(gpa, byte);
    }
}

test "compressSequences: synthetic sequences, long lengths, a dictionary, small blocks" {
    const pair = try Pair.init();
    defer pair.deinit();
    const dict = try common.generated(30_000, 0.5, 0.3, 602);
    defer gpa.free(dict);
    for (0..@max(1, common.fuzz_cases / 4)) |case| {
        const seed = common.fuzzSeed(603) +% case;
        var prng: std.Random.DefaultPrng = .init(seed);
        const random = prng.random();
        errdefer std.debug.print("fuzz seed {d}, case {d}\n", .{ seed, case });
        const explicit = random.boolean();
        const use_dict = random.uintLessThan(u32, 4) == 0;
        const min_match: u32 = if (random.boolean()) 3 else 4;
        const synth = try synthesize(random, .{
            .size = random.uintLessThan(usize, 400_000),
            .explicit = explicit,
            .long = random.uintLessThan(u32, 3) == 0,
            .dict = if (use_dict) dict else &.{},
            .min_match = min_match,
            .block_size_max = if (random.uintLessThan(u32, 4) == 0)
                1 + random.uintLessThan(usize, 300)
            else
                128 * kib,
        });
        defer synth.deinit();
        try apply(pair, .{
            .level = frame.strategy_levels[random.uintLessThan(usize, frame.strategy_levels.len)],
            .delimiters = if (explicit) .explicit_block_delimiters else .no_block_delimiters,
            .validate = random.boolean(),
            .repcodes = @as(i32, @intCast(random.uintLessThan(u32, 3))),
            .checksum = random.boolean(),
            .min_match = if (min_match == 3) 3 else 0,
        });
        if (use_dict) {
            try expectSameResult(
                c.ZSTD_CCtx_loadDictionary(pair.upstream, dict.ptr, dict.len),
                pair.port.loadDictionary(dict),
            );
        }
        _ = try expectCompressSequences(
            pair,
            synth.seqs,
            synth.seqs,
            synth.src,
            c.ZSTD_compressBound(synth.src.len) + 16,
            if (use_dict) dict else null,
        );
    }
}

test "compressSequences: invalid sequences and small buffers" {
    const pair = try Pair.init();
    defer pair.deinit();
    var prng: std.Random.DefaultPrng = .init(common.fuzzSeed(604));
    const random = prng.random();
    const explicit = try synthesize(random, .{ .size = 300_000, .explicit = true });
    defer explicit.deinit();
    const no_delimiters = try synthesize(random, .{ .size = 300_000, .explicit = false });
    defer no_delimiters.deinit();
    const formats = [_]struct { params.SequenceFormat, Synthetic }{
        .{ .explicit_block_delimiters, explicit },
        .{ .no_block_delimiters, no_delimiters },
    };

    for (formats) |format| {
        const delimiters, const synth = format;
        errdefer std.debug.print("{t}\n", .{delimiters});
        const src = synth.src;
        const bound = c.ZSTD_compressBound(src.len) + 16;
        const work = try gpa.dupe(Sequence, synth.seqs);
        defer gpa.free(work);
        // Offsets past a small window.
        try apply(pair, .{ .window_log = 10, .validate = true, .delimiters = delimiters });
        _ = try expectCompressSequences(pair, work, work, src, bound, null);
        // A match shorter than any minimum, its bytes given to the literals.
        for (work) |*seq| if (seq.match_length >= 5) {
            seq.lit_length += seq.match_length - 2;
            seq.match_length = 2;
            break;
        };
        for ([_]i32{ 3, 0 }) |min_match| {
            try apply(
                pair,
                .{ .validate = true, .min_match = min_match, .delimiters = delimiters },
            );
            _ = try expectCompressSequences(pair, work, work, src, bound, null);
        }
        // Outputs too small, down to the largest frame header.
        try apply(pair, .{ .checksum = true, .delimiters = delimiters });
        const ok_size = blk: {
            const dst = try gpa.alloc(u8, bound);
            defer gpa.free(dst);
            break :blk try pair.port.compressSequences(dst, synth.seqs, src);
        };
        for ([_]usize{ ok_size, ok_size - 1, ok_size - 4, ok_size / 2, 20, 18 }) |capacity| {
            errdefer std.debug.print("capacity {d}\n", .{capacity});
            _ = try expectCompressSequences(pair, synth.seqs, synth.seqs, src, capacity, null);
        }
        // An input shorter than the sequences, and longer.
        try apply(pair, .{ .delimiters = delimiters });
        _ = try expectCompressSequences(
            pair,
            synth.seqs,
            synth.seqs,
            src[0 .. src.len - 1],
            bound,
            null,
        );
        const longer = try gpa.alloc(u8, src.len + 1);
        defer gpa.free(longer);
        @memcpy(longer[0..src.len], src);
        longer[src.len] = 'x';
        _ = try expectCompressSequences(pair, synth.seqs, synth.seqs, longer, bound, null);
        // An empty frame.
        const empty = [_]Sequence{.{ .offset = 0, .lit_length = 0, .match_length = 0, .rep = 0 }};
        for ([_]usize{ 100, 18 }) |capacity| {
            _ = try expectCompressSequences(pair, &empty, &empty, &.{}, capacity, null);
            _ = try expectCompressSequences(pair, empty[0..0], empty[0..0], &.{}, capacity, null);
        }
    }

    const src = explicit.src;
    const seqs = explicit.seqs;
    const bound = c.ZSTD_compressBound(src.len) + 16;
    const work = try gpa.dupe(Sequence, seqs);
    defer gpa.free(work);
    try apply(pair, .{});
    // No delimiter at the end.
    _ = try expectCompressSequences(
        pair,
        seqs[0 .. seqs.len - 1],
        seqs[0 .. seqs.len - 1],
        src,
        bound,
        null,
    );
    // A delimiter with a match.
    work[work.len - 1].match_length = 4;
    _ = try expectCompressSequences(pair, work, work, src, bound, null);
    // Two blocks joined, over the block size when they are large.
    @memcpy(work, seqs);
    var joined = false;
    for (work[0 .. work.len - 1], 0..) |*seq, i| {
        if (seq.offset == 0 and seq.match_length == 0) {
            // The delimiter's literals go to the next sequence.
            work[i + 1].lit_length += seq.lit_length;
            std.mem.copyForwards(Sequence, work[i .. work.len - 1], work[i + 1 ..]);
            joined = true;
            break;
        }
    }
    try testing.expect(joined);
    _ = try expectCompressSequences(
        pair,
        work[0 .. work.len - 1],
        work[0 .. work.len - 1],
        src,
        bound,
        null,
    );
    // More sequences in a block than the store takes: 3-byte matches with
    // a minimum match over 3.
    {
        const n = 40_000;
        const many = try gpa.alloc(Sequence, n + 1);
        defer gpa.free(many);
        const flat = try gpa.alloc(u8, 3 * n + 1);
        defer gpa.free(flat);
        @memset(flat, 'q');
        many[0] = .{ .offset = 1, .lit_length = 1, .match_length = 3, .rep = 0 };
        for (many[1..n]) |*seq| seq.* = .{
            .offset = 1,
            .lit_length = 0,
            .match_length = 3,
            .rep = 0,
        };
        many[n] = .{ .offset = 0, .lit_length = 0, .match_length = 0, .rep = 0 };
        try apply(pair, .{ .level = 1 });
        _ = try expectCompressSequences(
            pair,
            many,
            many,
            flat,
            c.ZSTD_compressBound(flat.len),
            null,
        );
    }
}

/// `compressSequencesAndLiterals` on both into `capacity` bytes; checks the
/// results and frames, and that a frame decodes back to `src` when given.
fn expectCompressSequencesAndLiterals(
    pair: Pair,
    seqs: []const Sequence,
    literals: []const u8,
    lit_capacity: usize,
    decompressed_size: usize,
    capacity: usize,
    src: ?[]const u8,
) !void {
    const expected = try gpa.alloc(u8, capacity);
    defer gpa.free(expected);
    const dst = try gpa.alloc(u8, capacity);
    defer gpa.free(dst);
    const code = c.ZSTD_compressSequencesAndLiterals(
        pair.upstream,
        expected.ptr,
        expected.len,
        asC(seqs),
        seqs.len,
        literals.ptr,
        literals.len,
        lit_capacity,
        decompressed_size,
    );
    const result = pair.port.compressSequencesAndLiterals(
        dst,
        seqs,
        literals,
        lit_capacity,
        decompressed_size,
    );
    try expectSameResult(code, result);
    const n = result catch return;
    try common.expectSameFrame(expected[0..code], dst[0..n]);
    if (src) |s| try common.expectRoundTrip(dst[0..n], s);
}

/// The literals of `seqs` over `src`, one after the other. The caller
/// frees them.
fn literalsOf(seqs: []const Sequence, src: []const u8) ![]u8 {
    var literals: std.ArrayList(u8) = .empty;
    errdefer literals.deinit(gpa);
    var pos: usize = 0;
    for (seqs) |s| {
        try literals.appendSlice(gpa, src[pos..][0..s.lit_length]);
        pos += s.lit_length + s.match_length;
    }
    return literals.toOwnedSlice(gpa);
}

test "compressSequencesAndLiterals: generated and synthetic sequences, repeat offsets" {
    const corpus = try common.generated(600_000, 0.6, 0.3, 605);
    defer gpa.free(corpus);
    const pair = try Pair.init();
    defer pair.deinit();
    for (frame.strategy_levels) |level| {
        for ([_]usize{ 1, 100, 5000, 128 * kib + 1, 500_000 }) |size| {
            const src = corpus[0..size];
            const upstream_seqs, const port_seqs = try generate(pair, src, level) orelse continue;
            defer gpa.free(upstream_seqs.ptr[0..c.ZSTD_sequenceBound(size)]);
            defer gpa.free(port_seqs.ptr[0..c.ZSTD_sequenceBound(size)]);
            const literals = try literalsOf(port_seqs, src);
            defer gpa.free(literals);
            for ([_]i32{ 0, 1, 2 }) |repcodes| {
                errdefer std.debug.print(
                    "level {d}, {d} bytes, repcodes {d}\n",
                    .{ level, size, repcodes },
                );
                try apply(pair, .{ .level = level, .repcodes = repcodes });
                try expectCompressSequencesAndLiterals(
                    pair,
                    port_seqs,
                    literals,
                    literals.len + 8,
                    size,
                    c.ZSTD_compressBound(size) + 16,
                    src,
                );
            }
        }
    }
    for (0..@max(1, common.fuzz_cases / 4)) |case| {
        const seed = common.fuzzSeed(606) +% case;
        var prng: std.Random.DefaultPrng = .init(seed);
        const random = prng.random();
        errdefer std.debug.print("fuzz seed {d}, case {d}\n", .{ seed, case });
        const synth = try synthesize(random, .{
            .size = random.uintLessThan(usize, 400_000),
            .explicit = true,
            .long = random.uintLessThan(u32, 3) == 0,
            .block_size_max = if (random.uintLessThan(u32, 4) == 0)
                1 + random.uintLessThan(usize, 300)
            else
                128 * kib,
        });
        defer synth.deinit();
        try apply(pair, .{
            .level = frame.strategy_levels[random.uintLessThan(usize, frame.strategy_levels.len)],
            .repcodes = @as(i32, @intCast(random.uintLessThan(u32, 3))),
        });
        try expectCompressSequencesAndLiterals(
            pair,
            synth.seqs,
            synth.literals,
            synth.literals.len,
            synth.src.len,
            c.ZSTD_compressBound(synth.src.len) + 16,
            synth.src,
        );
    }
}

test "compressSequencesAndLiterals: what it refuses" {
    const pair = try Pair.init();
    defer pair.deinit();
    var prng: std.Random.DefaultPrng = .init(common.fuzzSeed(607));
    const random = prng.random();
    const synth = try synthesize(random, .{ .size = 300_000, .explicit = true });
    defer synth.deinit();
    const seqs = synth.seqs;
    const lits = synth.literals;
    const size = synth.src.len;
    const bound = c.ZSTD_compressBound(size) + 16;

    // The modes it does not take.
    try apply(pair, .{ .delimiters = .no_block_delimiters });
    try expectCompressSequencesAndLiterals(pair, seqs, lits, lits.len, size, bound, null);
    try apply(pair, .{ .validate = true });
    try expectCompressSequencesAndLiterals(pair, seqs, lits, lits.len, size, bound, null);
    try apply(pair, .{ .checksum = true });
    try expectCompressSequencesAndLiterals(pair, seqs, lits, lits.len, size, bound, null);

    try apply(pair, .{});
    // A literals buffer smaller than the literals.
    try expectCompressSequencesAndLiterals(pair, seqs, lits, lits.len - 1, size, bound, null);
    // Literals left over, or missing.
    const more = try gpa.alloc(u8, lits.len + 1);
    defer gpa.free(more);
    @memcpy(more[0..lits.len], lits);
    more[lits.len] = 'z';
    try expectCompressSequencesAndLiterals(pair, seqs, more, more.len, size, bound, null);
    try expectCompressSequencesAndLiterals(
        pair,
        seqs,
        lits[0 .. lits.len - 1],
        lits.len,
        size,
        bound,
        null,
    );
    // A size the sequences do not cover.
    try expectCompressSequencesAndLiterals(pair, seqs, lits, lits.len, size + 1, bound, null);
    try expectCompressSequencesAndLiterals(pair, seqs, lits, lits.len, size - 1, bound, null);
    // No sequences, no delimiter at the end, an empty frame.
    try expectCompressSequencesAndLiterals(pair, seqs[0..0], lits, lits.len, size, bound, null);
    try expectCompressSequencesAndLiterals(
        pair,
        seqs[0 .. seqs.len - 1],
        lits,
        lits.len,
        size,
        bound,
        null,
    );
    const empty = [_]Sequence{.{ .offset = 0, .lit_length = 0, .match_length = 0, .rep = 0 }};
    for ([_]usize{ 100, 18 }) |capacity| {
        try expectCompressSequencesAndLiterals(pair, &empty, &.{}, 0, 0, capacity, &.{});
    }
    // Outputs too small, down to the largest frame header.
    for ([_]usize{ 1000, 20, 18 }) |capacity| {
        try expectCompressSequencesAndLiterals(pair, seqs, lits, lits.len, size, capacity, null);
    }
    // Literals that do not compress: the block cannot be stored raw.
    const noise = try gpa.alloc(u8, 128 * kib);
    defer gpa.free(noise);
    random.bytes(noise);
    const only_literals = [_]Sequence{.{
        .offset = 0,
        .lit_length = 128 * kib,
        .match_length = 0,
        .rep = 0,
    }};
    try expectCompressSequencesAndLiterals(
        pair,
        &only_literals,
        noise,
        noise.len,
        noise.len,
        c.ZSTD_compressBound(noise.len),
        null,
    );
}
