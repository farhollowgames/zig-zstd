//! Oracle tests for long distance matching: the gear hash, the parameter
//! defaults, the sequence store bookkeeping, and the sequence generator,
//! run on the port's matcher state and the original's side by side over the
//! same inputs. After every step the raw sequences, the return value, the
//! whole hash table, the bucket offsets and the window are compared. A block
//! test runs the fast and double fast compressors through `blockCompress`
//! and compares every stored sequence and literal.

const std = @import("std");
const zstd = @import("zstd");
const c = @import("upstream");
const common = @import("common.zig");
const test_options = @import("test_options");

const ldm = zstd.internal.ldm;
const ci = zstd.internal.compress_internal;
const fast = zstd.internal.fast;
const double_fast = zstd.internal.double_fast;
const params = zstd.params;
const LdmParams = ci.LdmParams;
const gpa = common.gpa;
const testing = std.testing;

fn toC(p: LdmParams) [6]c_uint {
    return .{
        @backingInt(p.enable_ldm),
        p.hash_log,
        p.bucket_size_log,
        p.min_match_length,
        p.hash_rate_log,
        p.window_log,
    };
}

fn cparamsToC(p: params.CompressionParameters) c.ZSTD_compressionParameters {
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

/// Long distance matching parameters as the caller sets them: every
/// combination the tests run goes through `adjustParameters` first.
fn ldmParams(
    hash_log: u32,
    bucket_size_log: u32,
    min_match_length: u32,
    hash_rate_log: u32,
    window_log: u32,
) LdmParams {
    return .{
        .enable_ldm = .enable,
        .hash_log = hash_log,
        .bucket_size_log = bucket_size_log,
        .min_match_length = min_match_length,
        .hash_rate_log = hash_rate_log,
        .window_log = window_log,
    };
}

test "adjustParameters, getTableSize, getMaxNbSeq match the original's" {
    const strategies = [_]params.Strategy{
        .fast, .dfast, .greedy, .lazy, .lazy2, .btlazy2, .btopt, .btultra, .btultra2,
    };
    const hash_logs = [_]u32{ 0, 6, 10, 20, 27, 30 };
    const bucket_size_logs = [_]u32{ 0, 1, 4, 8 };
    const min_matches = [_]u32{ 0, 4, 64, 4096 };
    const hash_rate_logs = [_]u32{ 0, 1, 7, 25 };
    const window_logs = [_]u32{ 10, 17, 27, 31 };
    var cases: usize = 0;
    for (strategies) |strategy| for (hash_logs) |hash_log| for (bucket_size_logs) |bsl| {
        for (min_matches) |min_match| for (hash_rate_logs) |rate| for (window_logs) |window_log| {
            const cparams: params.CompressionParameters = .{
                .window_log = window_log,
                .chain_log = 16,
                .hash_log = 17,
                .search_log = 3,
                .min_match = 4,
                .target_length = 0,
                .strategy = strategy,
            };
            var port = ldmParams(hash_log, bsl, min_match, rate, 0);
            ldm.adjustParameters(&port, &cparams);
            var expected = toC(ldmParams(hash_log, bsl, min_match, rate, 0));
            const cparams_c = cparamsToC(cparams);
            c.reference_ldm_adjustParameters(&expected, &cparams_c);
            try testing.expectEqual(expected, toC(port));
            // A table of 4 GiB or more (8-byte entries), or a window over 1 GiB,
            // is past a 32-bit target's limits; the original's sizes wrap there.
            const too_large = port.hash_log >= 29 or window_log > 30;
            if (@sizeOf(usize) == 4 and too_large) {
                cases += 1;
                continue;
            }

            const table_size = c.reference_ldm_getTableSize(&expected);
            try testing.expectEqual(table_size, ldm.getTableSize(port));
            for ([_]usize{ 0, 1000, 1 << 17, 1 << 20 }) |chunk| {
                try testing.expectEqual(
                    c.reference_ldm_getMaxNbSeq(&expected, chunk),
                    ldm.getMaxNbSeq(port, chunk),
                );
            }
            var off = port;
            off.enable_ldm = .disable;
            const off_c = toC(off);
            try testing.expectEqual(c.reference_ldm_getTableSize(&off_c), ldm.getTableSize(off));
            try testing.expectEqual(
                c.reference_ldm_getMaxNbSeq(&off_c, 1 << 17),
                ldm.getMaxNbSeq(off, 1 << 17),
            );
            cases += 1;
        };
    };
    try testing.expectEqual(@as(usize, 9 * 6 * 4 * 4 * 4 * 4), cases);
}

test "the gear hash splits where the original's does" {
    const data = try common.generated(1 << 20, 0.5, 0.0, 11);
    defer gpa.free(data);
    var prng: std.Random.DefaultPrng = .init(common.fuzzSeed(0x6ea2));
    const random = prng.random();
    const min_matches = [_]u32{ 4, 5, 16, 31, 64, 65, 300, 4096 };
    for (0..26) |hash_rate_log| for (min_matches) |min_match| {
        var port: ldm.RollingHashState = undefined;
        ldm.gearInit(&port, &.{
            .min_match_length = min_match,
            .hash_rate_log = @intCast(hash_rate_log),
        });
        var expected: [2]u64 = undefined;
        c.reference_ldm_gearInit(&expected, min_match, @intCast(hash_rate_log));
        try testing.expectEqual(expected, [2]u64{ port.rolling, port.stop_mask });

        // Feeds of uneven sizes, a reset now and then, splits compared in
        // their batches.
        var pos: usize = 0;
        while (pos + min_match < data.len) {
            if (random.uintLessThan(u32, 8) == 0) {
                ldm.gearReset(&port, data[pos..].ptr, min_match);
                c.reference_ldm_gearReset(&expected, data[pos..].ptr, min_match);
                try testing.expectEqual(expected[0], port.rolling);
                pos += min_match;
            }
            const size = @min(data.len - pos, random.uintAtMost(usize, 5000));
            var port_splits: [ci.ldm_batch_size]usize = undefined;
            var expected_splits: [ci.ldm_batch_size]usize = undefined;
            const already = random.uintLessThan(u32, 4);
            var port_num: u32 = already;
            var expected_num: c_uint = already;
            const port_hashed = ldm.gearFeed(&port, data[pos..].ptr, size, &port_splits, &port_num);
            const expected_hashed = c.reference_ldm_gearFeed(
                &expected,
                data[pos..].ptr,
                size,
                &expected_splits,
                &expected_num,
            );
            try testing.expectEqual(expected_hashed, port_hashed);
            try testing.expectEqual(expected_num, port_num);
            try testing.expectEqualSlices(
                usize,
                expected_splits[already..expected_num],
                port_splits[already..port_num],
            );
            try testing.expectEqual(expected[0], port.rolling);
            pos += port_hashed;
        }
    };
}

fn toPort(seqs: []const c.RawSeq, out: []ci.RawSeq) void {
    for (seqs, out) |seq, *o| {
        o.* = .{
            .offset = seq.offset,
            .lit_length = seq.lit_length,
            .match_length = seq.match_length,
        };
    }
}

fn expectSameSeqs(expected: []const c.RawSeq, actual: []const ci.RawSeq) !void {
    try testing.expectEqual(expected.len, actual.len);
    for (expected, actual, 0..) |e, a, i| {
        if (e.offset != a.offset or e.lit_length != a.lit_length or
            e.match_length != a.match_length)
        {
            std.debug.print("raw sequence {d} of {d}: original {any}, port {any}\n", .{
                i,
                expected.len,
                e,
                a,
            });
            return error.SequencesDiffer;
        }
    }
}

fn randomSeqs(random: std.Random, out: []c.RawSeq) void {
    for (out) |*seq| {
        // Short and long lengths, zero literals and short matches included.
        const lit_length = switch (random.uintLessThan(u32, 4)) {
            0 => 0,
            1 => random.uintAtMost(u32, 8),
            2 => random.uintAtMost(u32, 300),
            else => random.uintAtMost(u32, 200_000),
        };
        const match_length = switch (random.uintLessThan(u32, 3)) {
            0 => random.intRangeAtMost(u32, 1, 10),
            1 => random.intRangeAtMost(u32, 3, 1000),
            else => random.intRangeAtMost(u32, 3, 300_000),
        };
        seq.* = .{
            .offset = random.intRangeAtMost(u32, 1, 1 << 27),
            .lit_length = lit_length,
            .match_length = match_length,
        };
    }
}

test "fuzz: skipSequences, maybeSplitSequence, skipRawSeqStoreBytes match the original's" {
    var prng: std.Random.DefaultPrng = .init(common.fuzzSeed(0x5e95));
    const random = prng.random();
    var c_seqs: [24]c.RawSeq = undefined;
    var port_seqs: [24]ci.RawSeq = undefined;
    for (0..common.fuzz_cases) |case| {
        errdefer std.debug.print("case {d}, seed {d}\n", .{ case, common.fuzzSeed(0x5e95) });
        const n = random.intRangeAtMost(usize, 1, c_seqs.len);
        randomSeqs(random, c_seqs[0..n]);
        toPort(c_seqs[0..n], port_seqs[0..n]);
        var c_pos: usize = 0;
        var c_pos_in_sequence: usize = 0;
        var store: ci.RawSeqStore = .{ .seq = &port_seqs, .size = n, .capacity = n };
        const min_match = random.intRangeAtMost(u32, 3, 7);
        const raw = random.boolean();
        // Blocks of random sizes through the whole store, as the block loop
        // would take them.
        while (c_pos < n) {
            const block = switch (random.uintLessThan(u32, 3)) {
                0 => random.uintAtMost(usize, 16),
                1 => random.uintAtMost(usize, 2000),
                else => random.uintAtMost(usize, 1 << 17),
            };
            if (raw) {
                c.reference_ldm_skipRawSeqStoreBytes(&c_seqs, n, &c_pos, &c_pos_in_sequence, block);
                ldm.skipRawSeqStoreBytes(&store, block);
                try testing.expectEqual(c_pos_in_sequence, store.pos_in_sequence);
            } else if (random.boolean()) {
                c.reference_ldm_skipSequences(&c_seqs, n, &c_pos, block, min_match);
                ldm.skipSequences(&store, block, min_match);
            } else {
                var expected: c.RawSeq = undefined;
                const remaining: u32 = @intCast(@max(block, 1));
                c.reference_ldm_maybeSplitSequence(
                    &c_seqs,
                    n,
                    &c_pos,
                    remaining,
                    min_match,
                    &expected,
                );
                const actual = ldm.maybeSplitSequence(&store, remaining, min_match);
                try expectSameSeqs(&.{expected}, &.{actual});
            }
            try testing.expectEqual(c_pos, store.pos);
            try expectSameSeqs(c_seqs[0..n], port_seqs[0..n]);
        }
    }
}

/// The port's long distance matcher state and the original's, set up as a
/// fresh context sets them up, given the same steps.
const Pair = struct {
    ldm_params: LdmParams,
    port: ci.LdmState,
    hash_table: []ci.LdmEntry,
    bucket_offsets: []u8,
    seqs: []ci.RawSeq,
    upstream: *c.ReferenceLdm,
    /// Whether the windows have taken any input: before, each side's base
    /// points at its own empty buffer.
    fed: bool,
    /// The long matches found and the generator's failures so far.
    found: usize,
    failures: usize,

    fn create(ldm_params: LdmParams) !*Pair {
        const self = try gpa.create(Pair);
        errdefer gpa.destroy(self);
        const p = toC(ldm_params);
        const upstream = c.reference_ldm_create(&p) orelse return error.OutOfMemory;
        errdefer c.reference_ldm_free(upstream);
        const nb_entries = @as(usize, 1) << @intCast(ldm_params.hash_log);
        const hash_table = try gpa.alloc(ci.LdmEntry, nb_entries);
        errdefer gpa.free(hash_table);
        @memset(hash_table, .{ .offset = 0, .checksum = 0 });
        const bucket_log = ldm_params.hash_log - ldm_params.bucket_size_log;
        const nb_buckets = @as(usize, 1) << @intCast(bucket_log);
        const bucket_offsets = try gpa.alloc(u8, nb_buckets);
        @memset(bucket_offsets, 0);
        self.* = .{
            .ldm_params = ldm_params,
            .port = .{ .hash_table = hash_table.ptr, .bucket_offsets = bucket_offsets.ptr },
            .hash_table = hash_table,
            .bucket_offsets = bucket_offsets,
            .seqs = &.{},
            .upstream = upstream,
            .fed = false,
            .found = 0,
            .failures = 0,
        };
        self.port.window.init();
        self.port.loaded_dict_end = 0;
        return self;
    }

    fn destroy(self: *Pair) void {
        gpa.free(self.hash_table);
        gpa.free(self.bucket_offsets);
        gpa.free(self.seqs);
        c.reference_ldm_free(self.upstream);
        gpa.destroy(self);
    }

    fn update(self: *Pair, src: []const u8) !void {
        const expected = c.reference_ldm_update(self.upstream, src.ptr, src.len);
        const actual = self.port.window.update(src, false);
        try testing.expectEqual(expected != 0, actual);
        if (src.len != 0) self.fed = true;
    }

    /// Moves both windows' indexes up by `shift`, as if that much input had
    /// come before.
    fn shiftIndexes(self: *Pair, shift: u32) void {
        c.reference_ldm_shiftIndexes(self.upstream, shift);
        const w = &self.port.window;
        w.base = @ptrFromInt(@intFromPtr(w.base) -% shift);
        w.dict_base = @ptrFromInt(@intFromPtr(w.dict_base) -% shift);
        w.dict_limit += shift;
        w.low_limit += shift;
    }

    /// `ZSTD_loadDictionaryContent`'s steps for the long distance matcher.
    fn loadDictionary(self: *Pair, dict: []const u8, force_window: bool) !void {
        const force: c_int = @intFromBool(force_window);
        c.reference_ldm_loadDictionary(self.upstream, dict.ptr, dict.len, force);
        _ = self.port.window.update(dict, false);
        if (dict.len != 0) self.fed = true;
        self.port.loaded_dict_end = if (force_window)
            0
        else
            @intCast(@intFromPtr(dict.ptr + dict.len) - @intFromPtr(self.port.window.base));
        ldm.fillHashTable(&self.port, dict, &self.ldm_params);
        try self.expectSameState();
    }

    /// Updates the windows with `src`, generates its sequences into a fresh
    /// store of `capacity`, and compares the results and the states.
    /// Compression never generates for an empty input, for which the
    /// window's precondition (`src` ends inside it) does not hold.
    fn generate(self: *Pair, src: []const u8, capacity: usize, shift: u32) !void {
        if (src.len == 0) return;
        try self.update(src);
        if (shift != 0) self.shiftIndexes(shift);

        var expected_seqs: [*]const c.RawSeq = undefined;
        var expected_size: usize = 0;
        const code = c.reference_ldm_generateSequences(
            self.upstream,
            src.ptr,
            src.len,
            capacity,
            &expected_seqs,
            &expected_size,
        );

        self.seqs = try gpa.realloc(self.seqs, capacity);
        var store: ci.RawSeqStore = .{ .seq = self.seqs.ptr, .capacity = capacity };
        const result = ldm.generateSequences(&self.port, &store, &self.ldm_params, src);
        if (c.ZSTD_isError(code) != 0) {
            const err = if (result) |_| return error.ExpectedError else |err| err;
            try testing.expectEqual(c.ZSTD_getErrorCode(code), @backingInt(zstd.errorCode(err)));
            self.failures += 1;
        } else {
            try result;
            try testing.expectEqual(@as(usize, 0), code);
        }
        try expectSameSeqs(expected_seqs[0..expected_size], self.seqs[0..store.size]);
        self.found += store.size;
        try self.expectSameState();
    }

    fn expectSameState(self: *Pair) !void {
        var w: [7]usize = undefined;
        c.reference_ldm_window(self.upstream, &w);
        const window = self.port.window;
        const next_src_index = @intFromPtr(window.next_src) -% @intFromPtr(window.base);
        try testing.expectEqual(w[2] -% w[0], next_src_index);
        if (self.fed) try testing.expectEqual(w[0], @intFromPtr(window.base));
        try testing.expectEqual(w[3], window.dict_limit);
        try testing.expectEqual(w[4], window.low_limit);
        // The dictionary base is only read under an external dictionary;
        // before one, it is each side's own empty buffer.
        if (window.hasExtDict()) try testing.expectEqual(w[1], @intFromPtr(window.dict_base));
        try testing.expectEqual(w[5], window.nb_overflow_corrections);
        try testing.expectEqual(w[6], self.port.loaded_dict_end);

        const table = c.reference_ldm_hashTable(self.upstream)[0..self.hash_table.len];
        for (table, self.hash_table, 0..) |expected, actual, i| {
            if (expected.offset != actual.offset or expected.checksum != actual.checksum) {
                std.debug.print("hash table entry {d}: original {any}, port {any}\n", .{
                    i,
                    expected,
                    actual,
                });
                return error.HashTablesDiffer;
            }
        }
        const offsets = c.reference_ldm_bucketOffsets(self.upstream)[0..self.bucket_offsets.len];
        try testing.expectEqualSlices(u8, offsets, self.bucket_offsets);
    }
};

/// How the input reaches the generator.
const Feed = enum {
    /// All at once, as a multithreaded job: the generator cuts it in 1 MiB
    /// chunks.
    whole,
    /// In 128 KiB blocks, as one thread compresses.
    blocks,
    /// In two buffers that are not contiguous: the first becomes the
    /// external dictionary.
    split,
    /// The first part loaded as a dictionary from its own buffer, then the
    /// rest in blocks.
    dictionary,
    /// As `dictionary`, with `forceWindow`.
    dictionary_force_window,
};

fn capacityFor(ldm_params: LdmParams, size: usize) usize {
    return size / ldm_params.min_match_length + 1;
}

/// Runs `input` through both matchers, fed as `feed` says, and compares
/// every step. Returns the number of long matches found.
fn expectSameGeneration(ldm_params: LdmParams, input: []const u8, feed: Feed) !usize {
    const pair = try Pair.create(ldm_params);
    defer pair.destroy();
    const block_size = params.block_size_max;
    switch (feed) {
        .whole => try pair.generate(input, capacityFor(ldm_params, input.len), 0),
        .blocks => {
            var pos: usize = 0;
            while (pos < input.len) : (pos += block_size) {
                const block = input[pos..@min(input.len, pos + block_size)];
                try pair.generate(block, block_size / ldm_params.min_match_length, 0);
            }
        },
        .split, .dictionary, .dictionary_force_window => {
            // Separate buffers, so the second never follows the first.
            const cut = input.len / 3;
            const first = try gpa.dupe(u8, input[0..cut]);
            defer gpa.free(first);
            const second = try gpa.dupe(u8, input[cut..]);
            defer gpa.free(second);
            if (feed == .split) {
                try pair.generate(first, capacityFor(ldm_params, first.len), 0);
                try pair.generate(second, capacityFor(ldm_params, second.len), 0);
            } else {
                try pair.loadDictionary(first, feed == .dictionary_force_window);
                var pos: usize = 0;
                while (pos < second.len) : (pos += block_size) {
                    const block = second[pos..@min(second.len, pos + block_size)];
                    try pair.generate(block, block_size / ldm_params.min_match_length, 0);
                }
            }
        },
    }
    return pair.found;
}

/// `copies` of a `piece_size` piece, `distance` bytes apart, with
/// incompressible filler between them; each copy has a few bytes changed.
fn farRepeats(piece_size: usize, distance: usize, copies: usize, seed: u32) ![]u8 {
    std.debug.assert(distance >= piece_size);
    const piece = try common.generated(piece_size, 0.3, 0.0, seed);
    defer gpa.free(piece);
    const total = distance * (copies - 1) + piece_size;
    const buffer = try gpa.alloc(u8, total);
    errdefer gpa.free(buffer);
    var prng: std.Random.DefaultPrng = .init(seed);
    const random = prng.random();
    random.bytes(buffer);
    for (0..copies) |copy| {
        const dst = buffer[copy * distance ..][0..piece_size];
        @memcpy(dst, piece);
        for (0..copy * 3) |_| dst[random.uintLessThan(usize, piece_size)] +%= 1;
    }
    return buffer;
}

const parameter_sets = [_]LdmParams{
    // The defaults for dfast at window log 27, and for btultra2.
    ldmParams(20, 4, 64, 7, 27),
    ldmParams(23, 8, 32, 4, 27),
    // Small tables and buckets, short and long matches.
    ldmParams(16, 3, 32, 4, 24),
    ldmParams(12, 8, 16, 2, 20),
    ldmParams(22, 1, 512, 9, 27),
    ldmParams(18, 5, 4096, 25, 26),
    // A split at every byte, and a window smaller than the input.
    ldmParams(10, 4, 4, 0, 12),
    ldmParams(14, 2, 8, 3, 17),
};

test "generateSequences matches the original's on repeats far apart" {
    const distances = [_]usize{ 1 << 20, 3 << 20, 16 << 20, 64 << 20 };
    for (distances, 0..) |distance, d| {
        const input = try farRepeats(300 * 1024, distance, 2, @intCast(d + 1));
        defer gpa.free(input);
        for ([_]usize{ 0, 1, 4 }) |set| {
            for ([_]Feed{ .whole, .blocks, .split }) |feed| {
                errdefer std.debug.print("distance {d}, set {d}, {t}\n", .{ distance, set, feed });
                const found = try expectSameGeneration(parameter_sets[set], input, feed);
                // The window reaches the repeat.
                if (set == 0) try testing.expect(found > 0);
            }
        }
    }
    // Several copies close together, in one buffer and through a dictionary.
    const input = try farRepeats(200 * 1024, 1 << 20, 5, 9);
    defer gpa.free(input);
    for (parameter_sets, 0..) |ldm_params, set| {
        for (std.meta.tags(Feed)) |feed| {
            if (ldm_params.hash_rate_log == 0 and feed != .whole) continue;
            errdefer std.debug.print("set {d}, {t}\n", .{ set, feed });
            _ = try expectSameGeneration(ldm_params, input, feed);
        }
    }
}

test "generateSequences matches the original's on test files and their concatenations" {
    const files = [_]struct { dir: []const u8, name: []const u8 }{
        .{ .dir = test_options.reference, .name = "tests/golden-compression/http" },
        .{
            .dir = test_options.reference,
            .name = "tests/golden-compression/huffman-compressed-larger",
        },
        .{
            .dir = test_options.reference,
            .name = "tests/golden-compression/large-literal-and-match-lengths",
        },
        .{
            .dir = test_options.reference,
            .name = "tests/golden-compression/PR-3517-block-splitter-corruption-test",
        },
        .{ .dir = test_options.data, .name = "bc7.bin" },
        .{ .dir = test_options.data, .name = "mesh.bin" },
        .{ .dir = test_options.data, .name = "snapshot.bin" },
    };
    for (files) |file| {
        const content = try common.readFile(file.dir, file.name);
        defer gpa.free(content);
        // The file, then the file twice and four times in a row.
        const doubled = try std.mem.concat(gpa, u8, &.{ content, content, content, content });
        defer gpa.free(doubled);
        for ([_][]const u8{ content, doubled[0 .. 2 * content.len], doubled }) |input| {
            for ([_]usize{ 0, 2, 3, 7 }) |set| {
                for (std.meta.tags(Feed)) |feed| {
                    if (parameter_sets[set].hash_rate_log == 0 and feed != .whole) continue;
                    errdefer std.debug.print("{s} ({d} bytes), set {d}, {t}\n", .{
                        file.name,
                        input.len,
                        set,
                        feed,
                    });
                    _ = try expectSameGeneration(parameter_sets[set], input, feed);
                }
            }
        }
    }
}

test "generateSequences matches the original's on edge cases" {
    const zeros: [600_000]u8 = @splat(0);
    var random_bytes: [300_000]u8 = undefined;
    var prng: std.Random.DefaultPrng = .init(5);
    prng.random().bytes(&random_bytes);
    const inputs = [_][]const u8{
        &.{},
        zeros[0..1],
        zeros[0..63],
        zeros[0..64],
        zeros[0..72],
        &zeros,
        &random_bytes,
    };
    for (inputs) |input| {
        for (parameter_sets, 0..) |ldm_params, set| {
            for ([_]Feed{ .whole, .blocks, .split }) |feed| {
                errdefer std.debug.print("{d} bytes, set {d}, {t}\n", .{ input.len, set, feed });
                _ = try expectSameGeneration(ldm_params, input, feed);
            }
        }
    }
}

test "generateSequences fills its store as the original's does" {
    // Stores too small for every match: the generator stops at a chunk
    // boundary when full, and fails inside a chunk.
    const input = try farRepeats(100 * 1024, 1 << 20, 6, 3);
    defer gpa.free(input);
    var failures: usize = 0;
    var stopped: usize = 0;
    for ([_]usize{ 0, 1, 2, 3, 5, 8, 13, 40, 41, 200 }) |capacity| {
        errdefer std.debug.print("capacity {d}\n", .{capacity});
        const pair = try Pair.create(ldmParams(16, 3, 32, 4, 24));
        defer pair.destroy();
        try pair.generate(input, capacity, 0);
        failures += pair.failures;
        if (pair.failures == 0 and pair.found == capacity) stopped += 1;
    }
    try testing.expect(failures > 0);
    try testing.expect(stopped > 0);
}

test "generateSequences corrects its indexes as the original's does" {
    // The indexes start near the limit, so a chunk past it corrects them
    // and reduces the hash table.
    const input = try farRepeats(300 * 1024, 1 << 20, 6, 4);
    defer gpa.free(input);
    for ([_]usize{ 0, 2 }) |set| {
        const ldm_params = parameter_sets[set];
        const pair = try Pair.create(ldm_params);
        defer pair.destroy();
        const shift: u32 = ci.current_max - (2 << 20);
        try pair.generate(input[0 .. input.len / 2], capacityFor(ldm_params, input.len), shift);
        try pair.generate(input[input.len / 2 ..], capacityFor(ldm_params, input.len), 0);
        try testing.expect(pair.port.window.nb_overflow_corrections > 0);
    }
}

test "fuzz: generateSequences matches the original's" {
    var prng: std.Random.DefaultPrng = .init(common.fuzzSeed(0x1d57));
    const random = prng.random();
    for (0..common.fuzz_cases) |case| {
        const hash_log = random.intRangeAtMost(u32, 6, 18);
        const ldm_params = ldmParams(
            hash_log,
            random.intRangeAtMost(u32, 1, @min(8, hash_log)),
            switch (random.uintLessThan(u32, 3)) {
                0 => random.intRangeAtMost(u32, 4, 16),
                1 => random.intRangeAtMost(u32, 4, 128),
                else => random.intRangeAtMost(u32, 4, 4096),
            },
            random.intRangeAtMost(u32, 1, 12),
            random.intRangeAtMost(u32, 10, 27),
        );
        const size = random.uintAtMost(usize, 600 * 1024);
        const seed = random.int(u32);
        const input = if (random.boolean())
            try common.generated(size, random.float(f64), random.float(f64) * 0.5, seed)
        else
            try farRepeats(@max(size / 4, 1), @max(size / 3, 1), 3, seed);
        defer gpa.free(input);
        const feed = random.enumValue(Feed);
        errdefer std.debug.print("case {d}, seed {d}: {any}, {d} bytes, {t}\n", .{
            case,
            common.fuzzSeed(0x1d57),
            ldm_params,
            input.len,
            feed,
        });
        _ = try expectSameGeneration(ldm_params, input, feed);
    }
}

fn cparamsOf(
    window_log: u32,
    chain_log: u32,
    hash_log: u32,
    search_log: u32,
    min_match: u32,
    target_length: u32,
    strategy: params.Strategy,
) params.CompressionParameters {
    return .{
        .window_log = window_log,
        .chain_log = chain_log,
        .hash_log = hash_log,
        .search_log = search_log,
        .min_match = min_match,
        .target_length = target_length,
        .strategy = strategy,
    };
}

fn compressorFor(strategy: params.Strategy) ci.BlockCompressor {
    return switch (strategy) {
        .fast => fast.compressBlockFast,
        .dfast => double_fast.compressBlockDoubleFast,
        else => unreachable,
    };
}

fn fillFor(strategy: params.Strategy) ci.BlockTest.FillTables {
    return switch (strategy) {
        .fast => fast.fillHashTable,
        .dfast => double_fast.fillDoubleHashTable,
        else => unreachable,
    };
}

/// One block through `generateSequences` and `blockCompress` with the
/// strategy's compressor, against the original's `ZSTD_ldm_blockCompress`
/// after the same setup.
fn expectSameLdmBlock(
    cparams: params.CompressionParameters,
    ldm_params: LdmParams,
    src: []const u8,
) !void {
    const pair = try Pair.create(ldm_params);
    defer pair.destroy();
    const raw_capacity = ldm.getMaxNbSeq(ldm_params, params.block_size_max);

    const port = try ci.BlockTest.create(gpa, cparams, src, .none, fillFor(cparams.strategy));
    defer port.destroy();
    _ = pair.port.window.update(src, false);
    pair.fed = src.len != 0;
    pair.seqs = try gpa.realloc(pair.seqs, raw_capacity);
    var raw_store: ci.RawSeqStore = .{ .seq = pair.seqs.ptr, .capacity = raw_capacity };
    try ldm.generateSequences(&pair.port, &raw_store, &ldm_params, src);
    const port_last = ldm.blockCompress(
        &raw_store,
        &port.ms,
        &port.seq_store,
        &port.rep,
        compressorFor(cparams.strategy),
        src,
    );
    try testing.expectEqual(raw_store.size, raw_store.pos);
    const last_literals = src[src.len - port_last ..];
    @memcpy(port.seq_store.lit[0..last_literals.len], last_literals);
    port.seq_store.lit += last_literals.len;

    const hash_table = try gpa.alloc(u32, port.hash_table.len);
    defer gpa.free(hash_table);
    @memset(hash_table, 0);
    const chain_table = try gpa.alloc(u32, port.chain_table.len);
    defer gpa.free(chain_table);
    @memset(chain_table, 0);
    const seqs = try gpa.alloc(c.SeqDef, port.sequences.len);
    defer gpa.free(seqs);
    const lits = try gpa.alloc(u8, port.literals.len);
    defer gpa.free(lits);
    var rep: [3]u32 = undefined;
    var nb_seq: usize = 0;
    var nb_lit: usize = 0;
    var long_length_type: u32 = 0;
    var long_length_pos: u32 = 0;
    var nb_raw: usize = 0;
    const cparams_c = cparamsToC(cparams);
    const upstream_last = c.reference_ldmBlockTest(
        &cparams_c,
        pair.upstream,
        src.ptr,
        src.len,
        raw_capacity,
        hash_table.ptr,
        chain_table.ptr,
        seqs.ptr,
        seqs.len,
        lits.ptr,
        src.len,
        &rep,
        &nb_seq,
        &nb_lit,
        &long_length_type,
        &long_length_pos,
        &nb_raw,
    );
    try testing.expect(c.ZSTD_isError(upstream_last) == 0);

    try testing.expectEqual(nb_raw, raw_store.size);
    try testing.expectEqual(upstream_last, port_last);
    const port_seqs = port.storedSequences();
    try testing.expectEqual(nb_seq, port_seqs.len);
    for (seqs[0..nb_seq], port_seqs, 0..) |expected, actual, i| {
        if (expected.off_base != actual.off_base or expected.lit_length != actual.lit_length or
            expected.ml_base != actual.ml_base)
        {
            std.debug.print("sequence {d}: original {any}, port {any}\n", .{ i, expected, actual });
            return error.SequencesDiffer;
        }
    }
    try testing.expectEqualSlices(u8, lits[0..nb_lit], port.storedLiterals());
    try testing.expectEqual(rep, port.rep);
    try testing.expectEqual(long_length_type, @backingInt(port.seq_store.long_length_type));
    if (long_length_type != 0) {
        try testing.expectEqual(long_length_pos, port.seq_store.long_length_pos);
    }
    try testing.expectEqualSlices(u32, hash_table, port.hash_table);
    try testing.expectEqualSlices(u32, chain_table, port.chain_table);
    try pair.expectSameState();
}

test "blockCompress with fast and dfast matches the original's" {
    // Repeats inside one block, long enough for the matcher.
    const inputs = [_]struct { piece: usize, distance: usize, copies: usize }{
        .{ .piece = 4000, .distance = 30_000, .copies = 4 },
        .{ .piece = 20_000, .distance = 60_000, .copies = 2 },
        .{ .piece = 500, .distance = 2_000, .copies = 60 },
    };
    const strategies = [_]params.CompressionParameters{
        cparamsOf(17, 12, 13, 1, 6, 0, .fast),
        cparamsOf(17, 12, 12, 1, 5, 1, .fast),
        cparamsOf(17, 15, 16, 2, 5, 0, .dfast),
        cparamsOf(16, 17, 17, 2, 4, 0, .dfast),
    };
    for (inputs, 0..) |input_spec, i| {
        const input = try farRepeats(
            input_spec.piece,
            input_spec.distance,
            input_spec.copies,
            @intCast(i),
        );
        defer gpa.free(input);
        const block = input[0..@min(input.len, params.block_size_max)];
        for (strategies) |cparams| {
            for ([_]LdmParams{
                ldmParams(20, 4, 64, 7, 27),
                ldmParams(12, 3, 16, 3, 17),
                ldmParams(16, 8, 300, 5, 17),
            }) |ldm_params| {
                errdefer std.debug.print("input {d}, {any}, {any}\n", .{ i, cparams, ldm_params });
                try expectSameLdmBlock(cparams, ldm_params, block);
            }
        }
    }
    // Generated data and the golden files.
    const golden = try common.readFile(test_options.reference, "tests/golden-compression/http");
    defer gpa.free(golden);
    const generated = try common.generated(params.block_size_max, 0.7, 0.0, 21);
    defer gpa.free(generated);
    for ([_][]const u8{ golden[0..@min(golden.len, params.block_size_max)], generated }) |block| {
        for (strategies) |cparams| {
            try expectSameLdmBlock(cparams, ldmParams(10, 2, 8, 2, 17), block);
        }
    }
}

test "fuzz: blockCompress with fast and dfast matches the original's" {
    var prng: std.Random.DefaultPrng = .init(common.fuzzSeed(0xb10c));
    const random = prng.random();
    for (0..common.fuzz_cases / 4) |case| {
        const strategy: params.Strategy = if (random.boolean()) .fast else .dfast;
        const hash_log = random.intRangeAtMost(u32, 8, 17);
        const cparams: params.CompressionParameters = .{
            .window_log = random.intRangeAtMost(u32, 10, 17),
            .chain_log = random.intRangeAtMost(u32, 8, 17),
            .hash_log = hash_log,
            .search_log = 1,
            .min_match = random.intRangeAtMost(u32, 4, 7),
            .target_length = random.uintAtMost(u32, 8),
            .strategy = strategy,
        };
        const ldm_hash_log = random.intRangeAtMost(u32, 6, 18);
        const ldm_params = ldmParams(
            ldm_hash_log,
            random.intRangeAtMost(u32, 1, @min(8, ldm_hash_log)),
            random.intRangeAtMost(u32, 4, 256),
            random.intRangeAtMost(u32, 0, 9),
            cparams.window_log,
        );
        const size = random.intRangeAtMost(usize, 1, params.block_size_max);
        const seed = random.int(u32);
        const input = if (random.boolean())
            try common.generated(size, random.float(f64), random.float(f64) * 0.5, seed)
        else
            try farRepeats(@max(size / 5, 1), @max(size / 4, 1), 4, seed);
        defer gpa.free(input);
        errdefer std.debug.print("case {d}, seed {d}: {any}, {any}, {d} bytes\n", .{
            case,
            common.fuzzSeed(0xb10c),
            cparams,
            ldm_params,
            input.len,
        });
        try expectSameLdmBlock(cparams, ldm_params, input);
    }
}
