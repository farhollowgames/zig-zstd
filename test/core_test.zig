//! Oracle tests for the parts below the frame: the default parameter table,
//! and the fast and double-fast block compressors, each run on one block
//! after the setup of a fresh compression, against the original's on the
//! same block with the same setup. Every stored sequence, literal, repeat
//! offset and table entry is compared. A cross-check against
//! `ZSTD_generateSequences` shows that setup gives the sequences a real
//! compression gives.

const std = @import("std");
const zstd = @import("zstd");
const c = @import("upstream");
const common = @import("common.zig");
const test_options = @import("test_options");

const ci = zstd.internal.compress_internal;
const fast = zstd.internal.fast;
const double_fast = zstd.internal.double_fast;
const clevels = zstd.internal.clevels;
const params = zstd.params;
const CompressionParameters = params.CompressionParameters;
const gpa = common.gpa;
const testing = std.testing;

fn toC(p: CompressionParameters) c.ZSTD_compressionParameters {
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

fn fromC(p: c.ZSTD_compressionParameters) CompressionParameters {
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

test "default parameters: the table rows against ZSTD_getCParams" {
    // ZSTD_getCParams picks the row by the size class of its size hint (0 is
    // unknown) and adjusts it to the size; at each class's largest size, and
    // with no size, the adjustment leaves every row as it is.
    const classes = [_]struct { table: usize, src_size: u64 }{
        .{ .table = 0, .src_size = 0 },
        .{ .table = 0, .src_size = 1 << 30 },
        .{ .table = 1, .src_size = 256 * 1024 },
        .{ .table = 2, .src_size = 128 * 1024 },
        .{ .table = 3, .src_size = 16 * 1024 },
    };
    for (classes) |class| {
        for (1..clevels.max_clevel + 1) |level| {
            const expected = c.ZSTD_getCParams(@intCast(level), class.src_size, 0);
            try testing.expectEqual(expected, toC(clevels.default_cparameters[class.table][level]));
        }
        // Level 0 is the default level; negative levels are row 0 with the
        // target length the level's magnitude.
        const default_level = c.ZSTD_getCParams(0, class.src_size, 0);
        try testing.expectEqual(
            default_level,
            toC(clevels.default_cparameters[class.table][params.clevel_default]),
        );
        for ([_]i32{ -1, -5, -100, -131072 }) |level| {
            var row = clevels.default_cparameters[class.table][0];
            row.target_length = @intCast(-level);
            try testing.expectEqual(c.ZSTD_getCParams(level, class.src_size, 0), toC(row));
        }
    }
}

const DictKind = enum(c_int) { none = 0, ext = 1, attached = 2 };

fn selectCompressor(strategy: params.Strategy, mode: ci.DictMode) ci.BlockCompressor {
    return switch (strategy) {
        .fast => switch (mode) {
            .no_dict => fast.compressBlockFast,
            .ext_dict => fast.compressBlockFastExtDict,
            .dict_match_state => fast.compressBlockFastDictMatchState,
            .dedicated_dict_search => unreachable,
        },
        .dfast => switch (mode) {
            .no_dict => double_fast.compressBlockDoubleFast,
            .ext_dict => double_fast.compressBlockDoubleFastExtDict,
            .dict_match_state => double_fast.compressBlockDoubleFastDictMatchState,
            .dedicated_dict_search => unreachable,
        },
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

const BlockCase = struct {
    cparams: CompressionParameters,
    src: []const u8,
    dict_kind: DictKind = .none,
    dict: []const u8 = &.{},
    /// For an attached dictionary; `cparams` when null.
    dict_cparams: ?CompressionParameters = null,
};

/// Runs the port's and the original's block compressor on `case` and
/// compares everything they leave.
fn expectSameBlock(case: BlockCase) !void {
    const dict_cparams = case.dict_cparams orelse case.cparams;
    const dict: ci.BlockTest.Dict = switch (case.dict_kind) {
        .none => .none,
        .ext => .{ .ext = case.dict },
        .attached => .{ .attached = .{ .content = case.dict, .cparams = dict_cparams } },
    };
    const port = try ci.BlockTest.create(gpa, case.cparams, case.src, dict, fillFor(case.cparams.strategy));
    defer port.destroy();
    const compressor = selectCompressor(case.cparams.strategy, ci.matchStateDictMode(&port.ms));
    const port_last = port.run(compressor, case.src);

    // The original's run, on tables and buffers of the same sizes.
    const hash_table = try zeroed(case.cparams.hash_log);
    defer gpa.free(hash_table);
    const chain_table = try zeroed(case.cparams.chain_log);
    defer gpa.free(chain_table);
    const dict_hash_table = try zeroed(dict_cparams.hash_log);
    defer gpa.free(dict_hash_table);
    const dict_chain_table = try zeroed(dict_cparams.chain_log);
    defer gpa.free(dict_chain_table);
    const seqs = try gpa.alloc(c.SeqDef, port.sequences.len);
    defer gpa.free(seqs);
    const lits = try gpa.alloc(u8, port.literals.len);
    defer gpa.free(lits);
    var rep: [3]u32 = undefined;
    var nb_seq: usize = 0;
    var nb_lit: usize = 0;
    var long_length_type: u32 = 0;
    var long_length_pos: u32 = 0;
    const cparams_c = toC(case.cparams);
    const dict_cparams_c = toC(dict_cparams);
    const upstream_last = c.reference_blockTest(
        &cparams_c,
        @backingInt(case.dict_kind),
        case.dict.ptr,
        case.dict.len,
        &dict_cparams_c,
        case.src.ptr,
        case.src.len,
        hash_table.ptr,
        chain_table.ptr,
        dict_hash_table.ptr,
        dict_chain_table.ptr,
        seqs.ptr,
        seqs.len,
        lits.ptr,
        case.src.len,
        &rep,
        &nb_seq,
        &nb_lit,
        &long_length_type,
        &long_length_pos,
    );

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
    if (long_length_type != 0) try testing.expectEqual(long_length_pos, port.seq_store.long_length_pos);
    try testing.expectEqualSlices(u32, hash_table, port.hash_table);
    try testing.expectEqualSlices(u32, chain_table, port.chain_table);
    if (case.dict_kind == .attached) {
        try testing.expectEqualSlices(u32, dict_hash_table, port.dict_hash_table);
        try testing.expectEqualSlices(u32, dict_chain_table, port.dict_chain_table);
    }
}

fn zeroed(log: u32) ![]u32 {
    const table = try gpa.alloc(u32, @as(usize, 1) << @intCast(log));
    @memset(table, 0);
    return table;
}

/// Inputs for the block tests: the original's golden inputs (their first
/// 128 KiB), generated data of several kinds, and hand-made edge cases.
const Inputs = struct {
    list: std.ArrayList([]u8) = .empty,

    fn deinit(self: *Inputs) void {
        for (self.list.items) |input| gpa.free(input);
        self.list.deinit(gpa);
    }

    fn add(self: *Inputs, input: []u8) !void {
        errdefer gpa.free(input);
        try self.list.append(gpa, input);
    }

    fn standard() !Inputs {
        var self: Inputs = .{};
        errdefer self.deinit();
        for ([_][]const u8{
            "http",
            "huffman-compressed-larger",
            "large-literal-and-match-lengths",
            "PR-3517-block-splitter-corruption-test",
        }) |name| {
            const path = try std.fmt.allocPrint(gpa, "tests/golden-compression/{s}", .{name});
            defer gpa.free(path);
            const bytes = try common.readFile(test_options.reference, path);
            defer gpa.free(bytes);
            try self.add(try gpa.dupe(u8, bytes[0..@min(bytes.len, params.block_size_max)]));
        }
        const generated = [_]struct { size: usize, match: f64, lit: f64, seed: u32 }{
            .{ .size = 128 * 1024, .match = 0.5, .lit = 0.0, .seed = 1 },
            .{ .size = 128 * 1024, .match = 0.9, .lit = 0.2, .seed = 2 },
            .{ .size = 100_000, .match = 0.2, .lit = 0.5, .seed = 3 },
            .{ .size = 4096, .match = 0.7, .lit = 0.0, .seed = 4 },
            .{ .size = 1000, .match = 0.3, .lit = 0.9, .seed = 5 },
            .{ .size = 64 * 1024, .match = 0.98, .lit = 0.0, .seed = 6 },
        };
        for (generated) |g| try self.add(try common.generated(g.size, g.match, g.lit, g.seed));
        // All the same byte, long repeats from the start.
        const same = try gpa.alloc(u8, 128 * 1024);
        @memset(same, 'z');
        try self.add(same);
        // Incompressible bytes.
        const random = try gpa.alloc(u8, 128 * 1024);
        var prng = std.Random.DefaultPrng.init(42);
        prng.random().bytes(random);
        try self.add(random);
        // The smallest blocks the block path compresses, and a little more.
        for ([_]usize{ 7, 8, 9, 15, 16, 17, 31, 33, 64 }) |size| {
            const small = try gpa.alloc(u8, size);
            for (small, 0..) |*byte, i| byte.* = @truncate((i % 5) * 3);
            try self.add(small);
        }
        return self;
    }
};

fn fastParams(window_log: u32, hash_log: u32, min_match: u32, target_length: u32) CompressionParameters {
    return .{
        .window_log = window_log,
        .chain_log = 6,
        .hash_log = hash_log,
        .search_log = 1,
        .min_match = min_match,
        .target_length = target_length,
        .strategy = .fast,
    };
}

fn dfastParams(window_log: u32, hash_log: u32, chain_log: u32, min_match: u32) CompressionParameters {
    return .{
        .window_log = window_log,
        .chain_log = chain_log,
        .hash_log = hash_log,
        .search_log = 1,
        .min_match = min_match,
        .target_length = 0,
        .strategy = .dfast,
    };
}

/// The smallest window log that holds `size` bytes, at least the minimum.
fn windowLogFor(size: usize) u32 {
    var log: u32 = params.window_log_min;
    while ((@as(usize, 1) << @intCast(log)) < size) log += 1;
    return log;
}

/// The parameter sets the block tests run on `size` bytes.
fn blockParams(size: usize) ![]CompressionParameters {
    var list: std.ArrayList(CompressionParameters) = .empty;
    errdefer list.deinit(gpa);
    const w = windowLogFor(size);
    for ([_]u32{ 3, 4, 5, 6, 7 }) |mls| {
        for ([_]u32{ 0, 1, 2, 7, 100 }) |target_length| {
            // Below window log 19 the finder takes the conditional-move path.
            for ([_]u32{ w, @max(w, 19) }) |window_log| {
                for ([_]u32{ 6, 12, 17 }) |hash_log| {
                    try list.append(gpa, fastParams(window_log, hash_log, mls, target_length));
                }
            }
        }
        for ([_][2]u32{ .{ 6, 6 }, .{ 12, 10 }, .{ 17, 16 }, .{ 20, 18 } }) |logs| {
            try list.append(gpa, dfastParams(@max(w, 17), logs[0], logs[1], mls));
        }
    }
    return list.toOwnedSlice(gpa);
}

test "fast and dfast blocks without a dictionary match the original's" {
    var inputs = try Inputs.standard();
    defer inputs.deinit();
    var cases: usize = 0;
    for (inputs.list.items) |src| {
        const sets = try blockParams(src.len);
        defer gpa.free(sets);
        for (sets) |cparams| {
            expectSameBlock(.{ .cparams = cparams, .src = src }) catch |err| {
                std.debug.print("{d} bytes, {any}\n", .{ src.len, cparams });
                return err;
            };
            cases += 1;
        }
    }
    try testing.expect(cases > 1000);
}

test "fast and dfast blocks with external and attached dictionaries match the original's" {
    var inputs = try Inputs.standard();
    defer inputs.deinit();
    // Dictionaries that share content with the inputs: the start of a
    // related generated buffer, and a golden input.
    const related = try common.generated(64 * 1024, 0.5, 0.0, 1);
    defer gpa.free(related);
    const dicts = [_][]const u8{ related[0..16], related[0..1000], related, inputs.list.items[0] };
    for (inputs.list.items) |src| {
        for (dicts) |dict| {
            const w = @max(windowLogFor(src.len + dict.len), 17);
            const sets = [_]CompressionParameters{
                fastParams(w, 14, 4, 0),
                fastParams(w, 17, 6, 1),
                fastParams(w, 12, 5, 7),
                fastParams(w, 16, 7, 0),
                dfastParams(w, 16, 14, 4),
                dfastParams(w, 17, 16, 5),
                dfastParams(w, 12, 10, 6),
                dfastParams(w, 18, 17, 7),
            };
            for (sets) |cparams| {
                for ([_]DictKind{ .ext, .attached }) |kind| {
                    var dict_cparams = cparams;
                    dict_cparams.hash_log += 1;
                    for ([_]CompressionParameters{ cparams, dict_cparams }) |dcp| {
                        expectSameBlock(.{
                            .cparams = cparams,
                            .src = src,
                            .dict_kind = kind,
                            .dict = dict,
                            .dict_cparams = dcp,
                        }) catch |err| {
                            std.debug.print("{t}: {d} bytes, dict {d} bytes, {any}\n", .{
                                kind, src.len, dict.len, cparams,
                            });
                            return err;
                        };
                    }
                }
            }
        }
    }
}

test "fuzz: fast and dfast blocks match the original's" {
    const seed = common.fuzzSeed(0x6661_7374);
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();
    for (0..common.fuzz_cases) |case_index| {
        const size = random.intRangeAtMost(usize, 7, params.block_size_max);
        const src = try common.generated(
            size,
            random.float(f64),
            random.float(f64) * 0.5,
            random.int(u32),
        );
        defer gpa.free(src);
        const dict_size = random.intRangeAtMost(usize, 16, 32 * 1024);
        const dict = try common.generated(dict_size, random.float(f64), 0.0, random.int(u32));
        defer gpa.free(dict);
        // Half the dictionaries share the input's start, so they match.
        if (random.boolean()) @memcpy(dict[0..@min(dict.len, src.len)], src[0..@min(dict.len, src.len)]);
        const strategy: params.Strategy = if (random.boolean()) .fast else .dfast;
        const kind = random.enumValue(DictKind);
        const min_window = windowLogFor(src.len + if (kind == .none) 0 else dict.len);
        const window_log = random.intRangeAtMost(u32, min_window, @max(min_window, 23));
        const cparams: CompressionParameters = .{
            .window_log = window_log,
            .chain_log = random.intRangeAtMost(u32, 6, 20),
            .hash_log = random.intRangeAtMost(u32, 6, 20),
            .search_log = 1,
            .min_match = random.intRangeAtMost(u32, 3, 7),
            .target_length = if (random.boolean()) 0 else random.intRangeAtMost(u32, 1, 300),
            .strategy = strategy,
        };
        var dict_cparams = cparams;
        dict_cparams.hash_log = random.intRangeAtMost(u32, 6, 20);
        dict_cparams.chain_log = random.intRangeAtMost(u32, 6, 20);
        expectSameBlock(.{
            .cparams = cparams,
            .src = src,
            .dict_kind = kind,
            .dict = dict,
            .dict_cparams = dict_cparams,
        }) catch |err| {
            std.debug.print("fuzz seed {d}, case {d}: {t}, {d} bytes, {any}\n", .{
                seed, case_index, kind, size, cparams,
            });
            return err;
        };
    }
}

/// The port's sequences of one block in `ZSTD_generateSequences`' form, as
/// `ZSTD_copyBlockSequences` makes them: offsets resolved from repeat codes,
/// then a delimiter with the last literals.
fn generatedSequences(block: *const ci.BlockTest) ![]c.ZSTD_Sequence {
    const in_seqs = block.storedSequences();
    const out = try gpa.alloc(c.ZSTD_Sequence, in_seqs.len + 1);
    var repcodes: ci.Repcodes = .{ .rep = .{ 1, 4, 8 } };
    var nb_out_literals: usize = 0;
    for (in_seqs, 0..) |seq, i| {
        var lit_length: u32 = seq.lit_length;
        var match_length: u32 = @as(u32, seq.ml_base) + 3;
        if (i == block.seq_store.long_length_pos) {
            switch (block.seq_store.long_length_type) {
                .literal_length => lit_length += 0x10000,
                .match_length => match_length += 0x10000,
                .none => {},
            }
        }
        var rep_id: u32 = 0;
        const raw_offset = if (ci.offbaseIsRepcode(seq.off_base)) blk: {
            const repcode = ci.offbaseToRepcode(seq.off_base);
            rep_id = repcode;
            if (lit_length != 0) break :blk repcodes.rep[repcode - 1];
            if (repcode == 3) break :blk repcodes.rep[0] - 1;
            break :blk repcodes.rep[repcode];
        } else ci.offbaseToOffset(seq.off_base);
        out[i] = .{
            .offset = raw_offset,
            .lit_length = lit_length,
            .match_length = match_length,
            .rep = rep_id,
        };
        ci.updateRep(&repcodes.rep, seq.off_base, @intFromBool(seq.lit_length == 0));
        nb_out_literals += lit_length;
    }
    out[in_seqs.len] = .{
        .offset = 0,
        .lit_length = @intCast(block.storedLiterals().len - nb_out_literals),
        .match_length = 0,
        .rep = 0,
    };
    return out;
}

test "the block setup gives ZSTD_generateSequences' sequences" {
    var inputs = try Inputs.standard();
    defer inputs.deinit();
    var cases: usize = 0;
    for (inputs.list.items) |src| {
        const sets = try blockParams(src.len);
        defer gpa.free(sets);
        for (sets, 0..) |requested, set_index| {
            // A sample of the sets keeps the test short.
            if (set_index % 7 != 0) continue;
            const cctx = try common.upstreamCCtx(&.{
                .{ .param = 101, .value = @intCast(requested.window_log) },
                .{ .param = 102, .value = @intCast(requested.hash_log) },
                .{ .param = 103, .value = @intCast(requested.chain_log) },
                .{ .param = 104, .value = @intCast(requested.search_log) },
                .{ .param = 105, .value = @intCast(requested.min_match) },
                .{ .param = 106, .value = @intCast(requested.target_length) },
                .{ .param = 107, .value = @intCast(@backingInt(requested.strategy)) },
            });
            defer _ = c.ZSTD_freeCCtx(cctx);
            const capacity = c.ZSTD_sequenceBound(src.len);
            const expected = try gpa.alloc(c.ZSTD_Sequence, capacity);
            defer gpa.free(expected);
            const n = c.ZSTD_generateSequences(cctx, expected.ptr, capacity, src.ptr, src.len);
            try testing.expect(c.ZSTD_isError(n) == 0);
            // The original adjusts the parameters to the source size.
            var applied: c.ZSTD_compressionParameters = undefined;
            c.reference_appliedCParams(cctx, &applied);
            const cparams = fromC(applied);
            try testing.expectEqual(requested.strategy, cparams.strategy);

            const block = try ci.BlockTest.create(gpa, cparams, src, .none, null);
            defer block.destroy();
            _ = block.run(selectCompressor(cparams.strategy, .no_dict), src);
            const actual = try generatedSequences(block);
            defer gpa.free(actual);
            // ZSTD_copyBlockSequences leaves the delimiter's `rep` unwritten:
            // compare it on the port's side only.
            try testing.expectEqual(n, actual.len);
            try testing.expectEqual(@as(c_uint, 0), actual[n - 1].rep);
            expected[n - 1].rep = 0;
            try testing.expectEqualSlices(c.ZSTD_Sequence, expected[0..n], actual);
            cases += 1;
        }
    }
    try testing.expect(cases > 100);
}
