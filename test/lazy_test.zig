//! Oracle tests for the lazy match finders: greedy, lazy and lazy2 over the
//! hash chain and the row-based match finder, and btlazy2 over the binary
//! tree, each run on one block after the setup of a fresh compression,
//! against the original's on the same block with the same setup: without a
//! dictionary, with one loaded into the context (an external dictionary),
//! with one attached (a dict match state, or the dedicated dictionary
//! search), and after an earlier block of the same context, contiguous or
//! not. Every stored sequence, literal, repeat offset and table entry, and
//! the match state's position, hash cache and salt entropy are compared.

const std = @import("std");
const zstd = @import("zstd");
const c = @import("upstream");
const common = @import("common.zig");
const core_test = @import("core_test.zig");

const ci = zstd.internal.compress_internal;
const lazy = zstd.internal.lazy;
const params = zstd.params;
const CompressionParameters = params.CompressionParameters;
const gpa = common.gpa;
const testing = std.testing;
const toC = core_test.toC;
const windowLogFor = core_test.windowLogFor;

const DictKind = enum(c_int) { none = 0, loaded = 1, attached = 2, earlier_block = 3 };

const LazyCase = struct {
    cparams: CompressionParameters,
    use_row: bool = false,
    hash_salt: u64 = 0,
    src: []const u8,
    dict_kind: DictKind = .none,
    dict: []const u8 = &.{},
    /// For an attached dictionary; `cparams` when null.
    dict_cparams: ?CompressionParameters = null,
    dict_use_row: bool = false,
    dict_dedicated_search: bool = false,
};

/// The block compressor `ZSTD_selectBlockCompressor` picks.
fn selectCompressor(
    strategy: params.Strategy,
    use_row: bool,
    mode: ci.DictMode,
) ci.BlockCompressor {
    if (use_row) {
        return switch (strategy) {
            .greedy => switch (mode) {
                .no_dict => lazy.compressBlockGreedyRow,
                .ext_dict => lazy.compressBlockGreedyExtDictRow,
                .dict_match_state => lazy.compressBlockGreedyDictMatchStateRow,
                .dedicated_dict_search => lazy.compressBlockGreedyDedicatedDictSearchRow,
            },
            .lazy => switch (mode) {
                .no_dict => lazy.compressBlockLazyRow,
                .ext_dict => lazy.compressBlockLazyExtDictRow,
                .dict_match_state => lazy.compressBlockLazyDictMatchStateRow,
                .dedicated_dict_search => lazy.compressBlockLazyDedicatedDictSearchRow,
            },
            .lazy2 => switch (mode) {
                .no_dict => lazy.compressBlockLazy2Row,
                .ext_dict => lazy.compressBlockLazy2ExtDictRow,
                .dict_match_state => lazy.compressBlockLazy2DictMatchStateRow,
                .dedicated_dict_search => lazy.compressBlockLazy2DedicatedDictSearchRow,
            },
            else => unreachable,
        };
    }
    return switch (strategy) {
        .greedy => switch (mode) {
            .no_dict => lazy.compressBlockGreedy,
            .ext_dict => lazy.compressBlockGreedyExtDict,
            .dict_match_state => lazy.compressBlockGreedyDictMatchState,
            .dedicated_dict_search => lazy.compressBlockGreedyDedicatedDictSearch,
        },
        .lazy => switch (mode) {
            .no_dict => lazy.compressBlockLazy,
            .ext_dict => lazy.compressBlockLazyExtDict,
            .dict_match_state => lazy.compressBlockLazyDictMatchState,
            .dedicated_dict_search => lazy.compressBlockLazyDedicatedDictSearch,
        },
        .lazy2 => switch (mode) {
            .no_dict => lazy.compressBlockLazy2,
            .ext_dict => lazy.compressBlockLazy2ExtDict,
            .dict_match_state => lazy.compressBlockLazy2DictMatchState,
            .dedicated_dict_search => lazy.compressBlockLazy2DedicatedDictSearch,
        },
        .btlazy2 => switch (mode) {
            .no_dict => lazy.compressBlockBtlazy2,
            .ext_dict => lazy.compressBlockBtlazy2ExtDict,
            .dict_match_state => lazy.compressBlockBtlazy2DictMatchState,
            .dedicated_dict_search => unreachable,
        },
        else => unreachable,
    };
}

/// Tables of one match state, aligned as the workspace aligns them.
const Tables = struct {
    hash_table: []align(64) u32,
    chain_table: []align(64) u32,
    tag_table: []align(64) u8,

    fn init(cparams: CompressionParameters) !Tables {
        const hash_size = @as(usize, 1) << @intCast(cparams.hash_log);
        const chain_size = @as(usize, 1) << @intCast(cparams.chain_log);
        const hash_table = try gpa.alignedAlloc(u32, .@"64", hash_size);
        errdefer gpa.free(hash_table);
        const chain_table = try gpa.alignedAlloc(u32, .@"64", chain_size);
        errdefer gpa.free(chain_table);
        const tag_table = try gpa.alignedAlloc(u8, .@"64", hash_size);
        @memset(hash_table, 0);
        @memset(chain_table, 0);
        @memset(tag_table, 0);
        return .{ .hash_table = hash_table, .chain_table = chain_table, .tag_table = tag_table };
    }

    fn deinit(self: *Tables) void {
        gpa.free(self.hash_table);
        gpa.free(self.chain_table);
        gpa.free(self.tag_table);
        self.* = undefined;
    }

    fn expectEqual(expected: *const Tables, actual: *const Tables) !void {
        try testing.expectEqualSlices(u32, expected.hash_table, actual.hash_table);
        try testing.expectEqualSlices(u32, expected.chain_table, actual.chain_table);
        try testing.expectEqualSlices(u8, expected.tag_table, actual.tag_table);
    }
};

/// The port's side of `reference_lazyBlockTest`, step for step.
const PortBlock = struct {
    ms: ci.MatchState = .{},
    dms: ci.MatchState = .{},
    seq_store: ci.SeqStore = .{},
    rep: [3]u32 = .{ 1, 4, 8 },
    /// The buffers `seq_store` writes to.
    sequences: []ci.SeqDef = &.{},
    literals: []u8 = &.{},

    /// The sequences stored.
    pub fn storedSequences(self: *const PortBlock) []const ci.SeqDef {
        const n = (@intFromPtr(self.seq_store.sequences) - @intFromPtr(self.sequences.ptr)) /
            @sizeOf(ci.SeqDef);
        return self.sequences[0..n];
    }

    /// The literals stored, the last ones included.
    pub fn storedLiterals(self: *const PortBlock) []const u8 {
        return self.literals[0 .. @intFromPtr(self.seq_store.lit) - @intFromPtr(self.literals.ptr)];
    }

    fn resetMs(
        ms: *ci.MatchState,
        cparams: CompressionParameters,
        use_row: bool,
        salt: u64,
        t: *Tables,
    ) void {
        ms.* = .{};
        ms.window.init();
        ms.window.clear();
        ms.next_to_update = ms.window.dict_limit;
        ms.hash_table = t.hash_table.ptr;
        ms.chain_table = t.chain_table.ptr;
        ms.cparams = cparams;
        if (use_row) {
            const row_log = std.math.clamp(cparams.search_log, 4, 6);
            ms.tag_table = t.tag_table.ptr;
            ms.row_hash_log = cparams.hash_log - row_log;
            ms.hash_salt = salt;
        }
    }

    fn indexOf(ms: *const ci.MatchState, p: [*]const u8) u32 {
        return @truncate(@intFromPtr(p) -% @intFromPtr(ms.window.base));
    }

    /// `ZSTD_loadDictionaryContent`'s steps for the lazy strategies.
    fn loadDictContent(ms: *ci.MatchState, use_row: bool, dict: []const u8) void {
        var ip = dict.ptr;
        const iend = dict.ptr + dict.len;
        _ = ms.window.update(dict, false);
        var size = dict.len;
        const max_log = @min(@max(ms.cparams.hash_log + 3, ms.cparams.chain_log + 1), 31);
        const max_dict_size = @as(usize, 1) << @intCast(max_log);
        if (size > max_dict_size) {
            ip = iend - max_dict_size;
            size = max_dict_size;
        }
        ms.next_to_update = indexOf(ms, ip);
        ms.loaded_dict_end = indexOf(ms, iend);
        if (size <= ci.hash_read_size) return;
        switch (ms.cparams.strategy) {
            .greedy, .lazy, .lazy2 => {
                if (ms.dedicated_dict_search) {
                    lazy.dedicatedDictSearchLazyLoadDictionary(ms, iend - ci.hash_read_size);
                } else if (use_row) {
                    const tag_size = @as(usize, 1) << @intCast(ms.cparams.hash_log);
                    @memset(ms.tag_table[0..tag_size], 0);
                    lazy.rowUpdate(ms, iend - ci.hash_read_size);
                } else {
                    _ = lazy.insertAndFindFirstIndex(ms, iend - ci.hash_read_size);
                }
            },
            // btlazy2's dictionaries load through the optimal parser's
            // `updateTree`, not ported yet.
            else => unreachable,
        }
        ms.next_to_update = indexOf(ms, iend);
    }

    fn block(self: *PortBlock, use_row: bool, src: []const u8) usize {
        const ms = &self.ms;
        const max_dist = @as(u32, 1) << @intCast(ms.cparams.window_log);
        if (!ms.window.update(src, ms.force_non_contiguous)) {
            ms.force_non_contiguous = false;
            ms.next_to_update = ms.window.dict_limit;
        }
        const block_end = src.ptr + src.len;
        ms.window.checkDictValidity(block_end, max_dist, &ms.loaded_dict_end, &ms.dict_match_state);
        ms.window.enforceMaxDist(src.ptr, max_dist, &ms.loaded_dict_end, &ms.dict_match_state);
        if (ms.next_to_update < ms.window.low_limit) ms.next_to_update = ms.window.low_limit;
        const curr = indexOf(ms, src.ptr);
        if (curr > ms.next_to_update + 384) {
            ms.next_to_update = curr - @min(192, curr - ms.next_to_update - 384);
        }
        const mode = ci.matchStateDictMode(ms);
        const compressor = selectCompressor(ms.cparams.strategy, use_row, mode);
        const last_ll_size = compressor(ms, &self.seq_store, &self.rep, src);
        const last_literals = src[src.len - last_ll_size ..];
        @memcpy(self.seq_store.lit[0..last_literals.len], last_literals);
        self.seq_store.lit += last_literals.len;
        return last_ll_size;
    }
};

/// Runs the port's and the original's block compressor on `case` and
/// compares everything they leave.
fn expectSameBlock(case: LazyCase) !void {
    const dict_cparams = case.dict_cparams orelse case.cparams;
    const earlier_size = if (case.dict_kind == .earlier_block) case.dict.len else 0;
    const block_size = @max(case.src.len, earlier_size);

    var port_tables = try Tables.init(case.cparams);
    defer port_tables.deinit();
    var port_dict_tables = try Tables.init(dict_cparams);
    defer port_dict_tables.deinit();
    var upstream_tables = try Tables.init(case.cparams);
    defer upstream_tables.deinit();
    var upstream_dict_tables = try Tables.init(dict_cparams);
    defer upstream_dict_tables.deinit();

    const seq_capacity = block_size / 3 + 1;
    const lit_capacity = block_size + 32;
    const port_seqs = try gpa.alloc(ci.SeqDef, seq_capacity);
    defer gpa.free(port_seqs);
    const port_lits = try gpa.alloc(u8, lit_capacity);
    defer gpa.free(port_lits);
    const upstream_seqs = try gpa.alloc(c.SeqDef, seq_capacity);
    defer gpa.free(upstream_seqs);
    const upstream_lits = try gpa.alloc(u8, lit_capacity);
    defer gpa.free(upstream_lits);

    // The port.
    var port: PortBlock = .{ .sequences = port_seqs, .literals = port_lits };
    const seq_store_start: ci.SeqStore = .{
        .sequences_start = port_seqs.ptr,
        .sequences = port_seqs.ptr,
        .lit_start = port_lits.ptr,
        .lit = port_lits.ptr,
        .max_nb_seq = seq_capacity,
        .max_nb_lit = block_size,
    };
    port.seq_store = seq_store_start;
    PortBlock.resetMs(&port.ms, case.cparams, case.use_row, case.hash_salt, &port_tables);
    switch (case.dict_kind) {
        .none => {},
        .loaded => PortBlock.loadDictContent(&port.ms, case.use_row, case.dict),
        .attached => {
            const dms = &port.dms;
            PortBlock.resetMs(dms, dict_cparams, case.dict_use_row, 0, &port_dict_tables);
            dms.dedicated_dict_search = case.dict_dedicated_search;
            PortBlock.loadDictContent(dms, case.dict_use_row, case.dict);
            const cdict_end = PortBlock.indexOf(dms, dms.window.next_src);
            if (cdict_end - dms.window.dict_limit != 0) {
                const ms = &port.ms;
                ms.dict_match_state = dms;
                if (ms.window.dict_limit < cdict_end) {
                    ms.window.next_src = ms.window.base + cdict_end;
                    ms.window.clear();
                }
                ms.loaded_dict_end = ms.window.dict_limit;
            }
        },
        .earlier_block => {
            _ = port.block(case.use_row, case.dict);
            port.seq_store = seq_store_start;
        },
    }
    const port_last = port.block(case.use_row, case.src);

    // The original.
    const setup: c.reference_LazySetup = .{
        .cparams = toC(case.cparams),
        .use_row = @intFromBool(case.use_row),
        .hash_salt = case.hash_salt,
        .hash_table = upstream_tables.hash_table.ptr,
        .chain_table = upstream_tables.chain_table.ptr,
        .tag_table = upstream_tables.tag_table.ptr,
        .dict_kind = @backingInt(case.dict_kind),
        .dict = case.dict.ptr,
        .dict_size = case.dict.len,
        .dict_cparams = toC(dict_cparams),
        .dict_use_row = @intFromBool(case.dict_use_row),
        .dict_dedicated_search = @intFromBool(case.dict_dedicated_search),
        .dict_hash_table = upstream_dict_tables.hash_table.ptr,
        .dict_chain_table = upstream_dict_tables.chain_table.ptr,
        .dict_tag_table = upstream_dict_tables.tag_table.ptr,
    };
    var result: c.reference_LazyResult = .{
        .seqs = upstream_seqs.ptr,
        .seq_capacity = seq_capacity,
        .lits = upstream_lits.ptr,
        .lit_capacity = block_size,
        .rep = undefined,
        .nb_seq = 0,
        .nb_lit = 0,
        .long_length_type = 0,
        .long_length_pos = 0,
        .next_to_update = 0,
        .hash_salt_entropy = 0,
        .lazy_skipping = 0,
        .hash_cache = undefined,
    };
    const upstream_last = c.reference_lazyBlockTest(&setup, case.src.ptr, case.src.len, &result);

    try testing.expectEqual(upstream_last, port_last);
    const nb_seq = port.storedSequences().len;
    try testing.expectEqual(result.nb_seq, nb_seq);
    for (upstream_seqs[0..nb_seq], port_seqs[0..nb_seq], 0..) |expected, actual, i| {
        if (expected.off_base != actual.off_base or expected.lit_length != actual.lit_length or
            expected.ml_base != actual.ml_base)
        {
            std.debug.print("sequence {d} of {d}: original {any}, port {any}\n", .{
                i, nb_seq, expected, actual,
            });
            return error.SequencesDiffer;
        }
    }
    try testing.expectEqualSlices(u8, upstream_lits[0..result.nb_lit], port.storedLiterals());
    try testing.expectEqual(result.rep, port.rep);
    try testing.expectEqual(result.long_length_type, @backingInt(port.seq_store.long_length_type));
    if (result.long_length_type != 0) {
        try testing.expectEqual(result.long_length_pos, port.seq_store.long_length_pos);
    }
    try testing.expectEqual(result.next_to_update, port.ms.next_to_update);
    try testing.expectEqual(result.hash_salt_entropy, port.ms.hash_salt_entropy);
    try testing.expectEqual(result.lazy_skipping != 0, port.ms.lazy_skipping);
    try testing.expectEqual(result.hash_cache, port.ms.hash_cache);
    try Tables.expectEqual(&upstream_tables, &port_tables);
    try Tables.expectEqual(&upstream_dict_tables, &port_dict_tables);
}

fn lazyParams(
    strategy: params.Strategy,
    window_log: u32,
    hash_log: u32,
    chain_log: u32,
    search_log: u32,
    min_match: u32,
) CompressionParameters {
    return .{
        .window_log = window_log,
        .chain_log = chain_log,
        .hash_log = hash_log,
        .search_log = search_log,
        .min_match = min_match,
        .target_length = 0,
        .strategy = strategy,
    };
}

const Finder = struct { strategy: params.Strategy, use_row: bool };

const finders = [_]Finder{
    .{ .strategy = .greedy, .use_row = false },
    .{ .strategy = .lazy, .use_row = false },
    .{ .strategy = .lazy2, .use_row = false },
    .{ .strategy = .btlazy2, .use_row = false },
    .{ .strategy = .greedy, .use_row = true },
    .{ .strategy = .lazy, .use_row = true },
    .{ .strategy = .lazy2, .use_row = true },
};

/// Hash, chain and search logs and the minimum match, over the code paths:
/// every row log and minimum match length, searches capped by the row or
/// not, small tables that collide.
const table_sets = [_][4]u32{
    .{ 6, 6, 1, 3 },
    .{ 12, 10, 4, 4 },
    .{ 16, 16, 5, 5 },
    .{ 17, 16, 6, 6 },
    .{ 18, 17, 8, 7 },
    .{ 20, 19, 3, 4 },
    .{ 14, 14, 7, 5 },
};

test "lazy blocks without a dictionary match the original's" {
    var inputs = try core_test.Inputs.standard();
    defer inputs.deinit();
    var cases: usize = 0;
    for (inputs.list.items) |src| {
        const w = windowLogFor(src.len);
        for (finders) |finder| {
            for (table_sets, 0..) |set, set_index| {
                const window_log = if (set_index % 2 == 0) w else @max(w, 22);
                const cparams = lazyParams(
                    finder.strategy,
                    window_log,
                    set[0],
                    set[1],
                    set[2],
                    set[3],
                );
                const salt: u64 = if (set_index % 3 == 0) 0 else 0x9E3779B97F4A7C15 *% set_index;
                expectSameBlock(.{
                    .cparams = cparams,
                    .use_row = finder.use_row,
                    .hash_salt = salt,
                    .src = src,
                }) catch |err| {
                    std.debug.print("row {}, {d} bytes, {any}\n", .{
                        finder.use_row,
                        src.len,
                        cparams,
                    });
                    return err;
                };
                cases += 1;
            }
        }
    }
    try testing.expect(cases > 500);
}

test "lazy blocks with dictionaries and earlier blocks match the original's" {
    var inputs = try core_test.Inputs.standard();
    defer inputs.deinit();
    const related = try common.generated(64 * 1024, 0.5, 0.0, 1);
    defer gpa.free(related);
    const dicts = [_][]const u8{ related[0..16], related[0..1000], related, inputs.list.items[0] };
    var cases: usize = 0;
    for (inputs.list.items, 0..) |src, src_index| {
        for (dicts) |dict| {
            const w = @max(windowLogFor(src.len + dict.len), 17);
            for (finders) |finder| {
                for (table_sets[1..], 0..) |set, set_index| {
                    // A sample of the sets per input keeps the test short.
                    if ((set_index + src_index) % 2 != 0) continue;
                    const cparams = lazyParams(finder.strategy, w, set[0], set[1], set[2], set[3]);
                    for ([_]DictKind{ .loaded, .attached, .earlier_block }) |kind| {
                        // btlazy2's dictionaries load through the optimal
                        // parser, not ported yet.
                        if (finder.strategy == .btlazy2 and kind != .earlier_block) continue;
                        var case: LazyCase = .{
                            .cparams = cparams,
                            .use_row = finder.use_row,
                            .hash_salt = 0x1234_5678_9ABC_DEF0,
                            .src = src,
                            .dict_kind = kind,
                            .dict = dict,
                            .dict_use_row = finder.use_row,
                        };
                        try expectSameBlockLogged(case);
                        cases += 1;
                        if (kind == .attached and finder.strategy != .btlazy2) {
                            // The dedicated dictionary search: the
                            // dictionary's hash table holds buckets of 4.
                            var dds_cparams = cparams;
                            dds_cparams.hash_log = @max(set[0], set[1] + 1) +
                                lazy.lazy_ddss_bucket_log;
                            dds_cparams.chain_log = @min(set[1], 24);
                            case.dict_cparams = dds_cparams;
                            case.dict_use_row = false;
                            case.dict_dedicated_search = true;
                            try expectSameBlockLogged(case);
                            cases += 1;
                        }
                        if (kind == .attached and !finder.use_row) {
                            // A dictionary with tables of other sizes.
                            var other = cparams;
                            other.hash_log = set[0] + 1;
                            other.chain_log = set[1] - 1;
                            case.dict_cparams = other;
                            case.dict_use_row = false;
                            case.dict_dedicated_search = false;
                            try expectSameBlockLogged(case);
                            cases += 1;
                        }
                    }
                }
            }
        }
    }
    try testing.expect(cases > 1000);
}

test "lazy blocks after an earlier block of the same buffer match the original's" {
    // The two blocks are contiguous: the first is the prefix of the second.
    const buffer = try common.generated(256 * 1024, 0.7, 0.1, 9);
    defer gpa.free(buffer);
    for (finders) |finder| {
        for (table_sets) |set| {
            for ([_]u32{ 17, 18, 20 }) |window_log| {
                for ([_]usize{ 1000, 64 * 1024, 128 * 1024 }) |first| {
                    const cparams = lazyParams(
                        finder.strategy,
                        window_log,
                        set[0],
                        set[1],
                        set[2],
                        set[3],
                    );
                    try expectSameBlockLogged(.{
                        .cparams = cparams,
                        .use_row = finder.use_row,
                        .hash_salt = 77,
                        .src = buffer[first..@min(buffer.len, first + 128 * 1024)],
                        .dict_kind = .earlier_block,
                        .dict = buffer[0..first],
                    });
                }
            }
        }
    }
}

fn expectSameBlockLogged(case: LazyCase) !void {
    expectSameBlock(case) catch |err| {
        std.debug.print("{t}, row {}, dds {}: {d} bytes, dict {d} bytes, {any}, dict {any}\n", .{
            case.dict_kind,
            case.use_row,
            case.dict_dedicated_search,
            case.src.len,
            case.dict.len,
            case.cparams,
            case.dict_cparams,
        });
        return err;
    };
}

test "fuzz: lazy blocks match the original's" {
    const seed = common.fuzzSeed(0x6c617a79);
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
        const dict_size = random.intRangeAtMost(usize, 16, 64 * 1024);
        const dict = try common.generated(dict_size, random.float(f64), 0.0, random.int(u32));
        defer gpa.free(dict);
        // Half the dictionaries share the input's start, so they match.
        if (random.boolean()) {
            const shared = @min(dict.len, src.len);
            @memcpy(dict[0..shared], src[0..shared]);
        }
        const finder = finders[random.uintLessThan(usize, finders.len)];
        var kind = random.enumValue(DictKind);
        if (finder.strategy == .btlazy2 and (kind == .loaded or kind == .attached)) {
            kind = .earlier_block;
        }
        const min_window = windowLogFor(src.len + if (kind == .none) 0 else dict.len);
        const window_log = random.intRangeAtMost(u32, min_window, @max(min_window, 23));
        const search_log = random.intRangeAtMost(u32, 1, 9);
        const cparams = lazyParams(
            finder.strategy,
            window_log,
            random.intRangeAtMost(u32, 6, 20),
            random.intRangeAtMost(u32, 6, 20),
            search_log,
            random.intRangeAtMost(u32, 3, 7),
        );
        var case: LazyCase = .{
            .cparams = cparams,
            .use_row = finder.use_row,
            .hash_salt = random.int(u64),
            .src = src,
            .dict_kind = kind,
            .dict = dict,
            .dict_use_row = finder.use_row,
        };
        if (kind == .attached and finder.strategy != .btlazy2 and random.boolean()) {
            var dds_cparams = cparams;
            dds_cparams.chain_log = @min(cparams.chain_log, 24);
            dds_cparams.hash_log = @max(cparams.hash_log, dds_cparams.chain_log + 1) +
                lazy.lazy_ddss_bucket_log;
            case.dict_cparams = dds_cparams;
            case.dict_use_row = false;
            case.dict_dedicated_search = true;
        } else if (kind == .attached and !finder.use_row) {
            var other = cparams;
            other.hash_log = random.intRangeAtMost(u32, 6, 20);
            other.chain_log = random.intRangeAtMost(u32, 6, 20);
            case.dict_cparams = other;
        }
        expectSameBlock(case) catch |err| {
            std.debug.print("fuzz seed {d}, case {d}\n", .{ seed, case_index });
            try expectSameBlockLogged(case);
            return err;
        };
    }
}

/// `ZSTD_bitmix`, from zstd_compress.c: the salt of a fresh context's rows is
/// `bitmix(0, 8) ^ bitmix(0, 4)`.
fn bitmix(start: u64, len: u64) u64 {
    var val = start;
    val ^= std.math.rotr(u64, val, 49) ^ std.math.rotr(u64, val, 24);
    val *%= 0x9FB21C651E98DF25;
    val ^= (val >> 35) + len;
    val *%= 0x9FB21C651E98DF25;
    return val ^ (val >> 28);
}

test "the lazy block setup gives ZSTD_generateSequences' sequences" {
    var inputs = try core_test.Inputs.standard();
    defer inputs.deinit();
    const fresh_salt = bitmix(0, 8) ^ bitmix(0, 4);
    var cases: usize = 0;
    for (inputs.list.items) |src| {
        // Levels 5 to 15: greedy to btlazy2, with the row matcher on and off.
        for (5..16) |level| {
            for ([_]bool{ false, true }) |use_row| {
                const cctx = try common.upstreamCCtx(&.{
                    .{ .param = 100, .value = @intCast(level) },
                    // ZSTD_c_useRowMatchFinder: 1 enables, 2 disables.
                    .{ .param = 1011, .value = if (use_row) 1 else 2 },
                });
                defer _ = c.ZSTD_freeCCtx(cctx);
                const capacity = c.ZSTD_sequenceBound(src.len);
                const expected = try gpa.alloc(c.ZSTD_Sequence, capacity);
                defer gpa.free(expected);
                const n = c.ZSTD_generateSequences(cctx, expected.ptr, capacity, src.ptr, src.len);
                try testing.expect(c.ZSTD_isError(n) == 0);
                var applied: c.ZSTD_compressionParameters = undefined;
                c.reference_appliedCParams(cctx, &applied);
                const cparams = core_test.fromC(applied);
                // Small inputs take the rows of faster strategies.
                switch (cparams.strategy) {
                    .greedy, .lazy, .lazy2, .btlazy2 => {},
                    else => continue,
                }
                const row = use_row and cparams.strategy != .btlazy2;

                var tables = try Tables.init(cparams);
                defer tables.deinit();
                const seqs = try gpa.alloc(ci.SeqDef, src.len / 3 + 1);
                defer gpa.free(seqs);
                const lits = try gpa.alloc(u8, src.len + 32);
                defer gpa.free(lits);
                var port: PortBlock = .{ .sequences = seqs, .literals = lits };
                port.seq_store = .{
                    .sequences_start = seqs.ptr,
                    .sequences = seqs.ptr,
                    .lit_start = lits.ptr,
                    .lit = lits.ptr,
                    .max_nb_seq = seqs.len,
                    .max_nb_lit = src.len,
                };
                PortBlock.resetMs(&port.ms, cparams, row, fresh_salt, &tables);
                _ = port.block(row, src);
                const actual = try core_test.generatedSequences(&port);
                defer gpa.free(actual);
                // ZSTD_copyBlockSequences leaves the delimiter's `rep` unwritten.
                try testing.expectEqual(n, actual.len);
                expected[n - 1].rep = 0;
                testing.expectEqualSlices(c.ZSTD_Sequence, expected[0..n], actual) catch |err| {
                    std.debug.print("level {d}, row {}, {d} bytes, {any}\n", .{
                        level, row, src.len, cparams,
                    });
                    return err;
                };
                cases += 1;
            }
        }
    }
    try testing.expect(cases > 250);
}
