//! Oracle tests for the optimal parser (btopt, btultra, btultra2), run over
//! one or more blocks after the setup of a fresh compression, against the
//! original's on the same blocks with the same setup (test/reference.c,
//! `reference_optTest*`). After every block, each stored sequence, literal
//! and repeat offset is compared, and so is the state the next block starts
//! from: the parser's statistics and base prices, the window, the hash, tree
//! and 3-byte tables, and the long distance candidates' position.

const std = @import("std");
const zstd = @import("zstd");
const c = @import("upstream");
const common = @import("common.zig");
const test_options = @import("test_options");

const ci = zstd.internal.compress_internal;
const opt = zstd.internal.opt;
const params = zstd.params;
const CompressionParameters = params.CompressionParameters;
const gpa = common.gpa;
const testing = std.testing;

const max_lit = 255;
const max_ll = 35;
const max_ml = 52;
const max_off = 31;
const block_size_max = params.block_size_max;

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

const DictKind = enum(c_int) { none = 0, ext = 1, attached = 2 };

fn selectCompressor(strategy: params.Strategy, mode: ci.DictMode) ci.BlockCompressor {
    return switch (strategy) {
        .btopt => switch (mode) {
            .no_dict => opt.compressBlockBtopt,
            .ext_dict => opt.compressBlockBtoptExtDict,
            .dict_match_state => opt.compressBlockBtoptDictMatchState,
            .dedicated_dict_search => unreachable,
        },
        .btultra => switch (mode) {
            .no_dict => opt.compressBlockBtultra,
            .ext_dict => opt.compressBlockBtultraExtDict,
            .dict_match_state => opt.compressBlockBtultraDictMatchState,
            .dedicated_dict_search => unreachable,
        },
        // btultra2 has no dictionary variants: btultra's take its place.
        .btultra2 => switch (mode) {
            .no_dict => opt.compressBlockBtultra2,
            .ext_dict => opt.compressBlockBtultraExtDict,
            .dict_match_state => opt.compressBlockBtultraDictMatchState,
            .dedicated_dict_search => unreachable,
        },
        else => unreachable,
    };
}

/// `ZSTD_loadDictionaryContent`'s table fill for the binary tree strategies.
fn fillBinaryTree(
    ms: *ci.MatchState,
    end: [*]const u8,
    dtlm: ci.DictTableLoadMethod,
    tfp: ci.TableFillPurpose,
) void {
    _ = dtlm;
    _ = tfp;
    opt.updateTree(ms, end - ci.hash_read_size, end);
}

const OptCase = struct {
    cparams: CompressionParameters,
    src: []const u8,
    /// The input is cut into blocks of this size, the last one shorter.
    block_size: usize = block_size_max,
    dict_kind: DictKind = .none,
    /// An external dictionary that ends where `src` starts is a prefix.
    dict: []const u8 = &.{},
    /// For an attached dictionary; `cparams` when null.
    dict_cparams: ?CompressionParameters = null,
    literal_mode: params.ParamSwitch = .auto,
    /// Dictionary entropy tables, made from this seed and the dictionary (or
    /// the input when there is none); null for a fresh context's.
    entropy_seed: ?u32 = null,
    /// Long distance match candidates over the whole input.
    ldm: []const c.RawSeq = &.{},
};

/// `ZSTD_ldm_skipRawSeqStoreBytes`, which the long distance matcher's port
/// will hold.
fn skipRawSeqStoreBytes(raw_seq_store: *ci.RawSeqStore, nb_bytes: usize) void {
    var curr_pos: u32 = @truncate(raw_seq_store.pos_in_sequence + nb_bytes);
    while (curr_pos != 0 and raw_seq_store.pos < raw_seq_store.size) {
        const curr_seq = raw_seq_store.seq.?[raw_seq_store.pos];
        if (curr_pos >= curr_seq.lit_length + curr_seq.match_length) {
            curr_pos -= curr_seq.lit_length + curr_seq.match_length;
            raw_seq_store.pos += 1;
        } else {
            raw_seq_store.pos_in_sequence = curr_pos;
            break;
        }
    }
    if (curr_pos == 0 or raw_seq_store.pos == raw_seq_store.size) {
        raw_seq_store.pos_in_sequence = 0;
    }
}

/// The optimal parser's tables, zeroed, as the workspace's first use leaves
/// them.
const OptTables = struct {
    lit_freq: [max_lit + 1]u32 = @splat(0),
    lit_length_freq: [max_ll + 1]u32 = @splat(0),
    match_length_freq: [max_ml + 1]u32 = @splat(0),
    off_code_freq: [max_off + 1]u32 = @splat(0),
    match_table: [ci.opt_size]ci.Match = @splat(.{ .off = 0, .len = 0 }),
    price_table: [ci.opt_size]ci.Optimal = @splat(std.mem.zeroes(ci.Optimal)),
};

/// Runs the port's and the original's parser on `case`, block by block, and
/// compares everything each block leaves.
fn expectSameOpt(case: OptCase) !void {
    const dict_cparams = case.dict_cparams orelse case.cparams;
    const first_block = case.src[0..@min(case.block_size, case.src.len)];

    var entropy: ci.EntropyCTables = undefined;
    entropy.huf.repeat_mode = .none;
    entropy.fse.offcode_repeat_mode = .none;
    entropy.fse.matchlength_repeat_mode = .none;
    entropy.fse.litlength_repeat_mode = .none;
    if (case.entropy_seed) |seed| {
        const sample = if (case.dict.len != 0) case.dict else case.src;
        const code = c.reference_optEntropy(
            sample.ptr,
            sample.len,
            seed,
            &entropy.huf.ctable,
            &entropy.fse.offcode_ctable,
            &entropy.fse.matchlength_ctable,
            &entropy.fse.litlength_ctable,
        );
        try testing.expectEqual(@as(c_int, 0), code);
        entropy.huf.repeat_mode = .valid;
    }

    const cparams_c = toC(case.cparams);
    const dict_cparams_c = toC(dict_cparams);
    const has_entropy = case.entropy_seed != null;
    const upstream = c.reference_optTestCreate(
        &cparams_c,
        @backingInt(case.dict_kind),
        case.dict.ptr,
        case.dict.len,
        &dict_cparams_c,
        first_block.len,
        @backingInt(case.literal_mode),
        if (has_entropy) &entropy.huf.ctable else null,
        @backingInt(entropy.huf.repeat_mode),
        if (has_entropy) &entropy.fse.offcode_ctable else null,
        if (has_entropy) &entropy.fse.matchlength_ctable else null,
        if (has_entropy) &entropy.fse.litlength_ctable else null,
        case.ldm.ptr,
        case.ldm.len,
    ) orelse return error.OutOfMemory;
    defer c.reference_optTestFree(upstream);

    const dict: ci.BlockTest.Dict = switch (case.dict_kind) {
        .none => .none,
        .ext => .{ .ext = case.dict },
        .attached => .{ .attached = .{ .content = case.dict, .cparams = dict_cparams } },
    };
    const port = try ci.BlockTest.create(gpa, case.cparams, first_block, dict, fillBinaryTree);
    defer port.destroy();
    const ms = &port.ms;

    // The parser's state, which the original's driver sets up before it
    // loads the dictionary; loading it does not touch this state.
    const tables = try gpa.create(OptTables);
    defer gpa.destroy(tables);
    tables.* = .{};
    ms.opt.lit_freq = &tables.lit_freq;
    ms.opt.lit_length_freq = &tables.lit_length_freq;
    ms.opt.match_length_freq = &tables.match_length_freq;
    ms.opt.off_code_freq = &tables.off_code_freq;
    ms.opt.match_table = &tables.match_table;
    ms.opt.price_table = &tables.price_table;
    ms.hash_log3 = if (case.cparams.min_match == 3) @min(17, case.cparams.window_log) else 0;
    const hash3_size = if (ms.hash_log3 != 0) @as(usize, 1) << @intCast(ms.hash_log3) else 0;
    const hash_table3 = try gpa.alloc(u32, hash3_size);
    defer gpa.free(hash_table3);
    @memset(hash_table3, 0);
    ms.hash_table3 = hash_table3.ptr;

    const ldm_seqs = try gpa.alloc(ci.RawSeq, case.ldm.len);
    defer gpa.free(ldm_seqs);
    for (case.ldm, ldm_seqs) |from, *to| to.* = .{
        .offset = from.offset,
        .lit_length = from.lit_length,
        .match_length = from.match_length,
    };
    var ldm_store: ci.RawSeqStore = .{
        .seq = ldm_seqs.ptr,
        .size = ldm_seqs.len,
        .capacity = ldm_seqs.len,
    };

    var start: usize = 0;
    var block_nb: usize = 0;
    while (start < case.src.len or block_nb == 0) : (block_nb += 1) {
        const block = case.src[start..@min(start + case.block_size, case.src.len)];
        start += block.len;

        // BlockTest.create took the first block's steps; later blocks take
        // them here.
        if (block_nb > 0) blockSteps(ms, block);
        ci.resetSeqStore(&port.seq_store);
        ms.opt.symbol_costs = &entropy;
        ms.opt.literal_compression_mode = case.literal_mode;
        const compressor = selectCompressor(case.cparams.strategy, ci.matchStateDictMode(ms));
        if (ldm_seqs.len != 0) ms.ldm_seq_store = &ldm_store;
        const port_last = port.run(compressor, block);
        ms.ldm_seq_store = null;
        if (ldm_seqs.len != 0) skipRawSeqStoreBytes(&ldm_store, block.len);

        const upstream_last = c.reference_optTestBlock(upstream, block.ptr, block.len);
        var result: c.OptResult = undefined;
        c.reference_optTestResult(upstream, &result);
        expectSameBlock(&result, upstream_last, port, port_last, &ldm_store, case) catch |err| {
            std.debug.print("block {d}, at {d} of {d} bytes\n", .{
                block_nb,
                start - block.len,
                case.src.len,
            });
            return err;
        };
    }
}

/// The steps of `ZSTD_compressContinue_internal`, `ZSTD_compress_frameChunk`
/// and `ZSTD_buildSeqStore` before a block, as BlockTest.create takes them.
fn blockSteps(ms: *ci.MatchState, block: []const u8) void {
    if (!ms.window.update(block, ms.force_non_contiguous)) {
        ms.force_non_contiguous = false;
        ms.next_to_update = ms.window.dict_limit;
    }
    const max_dist = @as(u32, 1) << @intCast(ms.cparams.window_log);
    const block_end = block.ptr + block.len;
    ms.window.checkDictValidity(block_end, max_dist, &ms.loaded_dict_end, &ms.dict_match_state);
    ms.window.enforceMaxDist(block.ptr, max_dist, &ms.loaded_dict_end, &ms.dict_match_state);
    if (ms.next_to_update < ms.window.low_limit) ms.next_to_update = ms.window.low_limit;
    const curr: u32 = @intCast(@intFromPtr(block.ptr) - @intFromPtr(ms.window.base));
    if (curr > ms.next_to_update + 384) {
        ms.next_to_update = curr - @min(192, curr - ms.next_to_update - 384);
    }
}

fn expectSameBlock(
    r: *const c.OptResult,
    upstream_last: usize,
    port: *const ci.BlockTest,
    port_last: usize,
    ldm_store: *const ci.RawSeqStore,
    case: OptCase,
) !void {
    const ms = &port.ms;
    try testing.expectEqual(upstream_last, port_last);
    const port_seqs = port.storedSequences();
    const nb_common = @min(r.nb_seq, port_seqs.len);
    for (r.seqs[0..nb_common], port_seqs[0..nb_common], 0..) |expected, actual, i| {
        if (expected.off_base != actual.off_base or expected.lit_length != actual.lit_length or
            expected.ml_base != actual.ml_base)
        {
            std.debug.print("sequence {d}: original {any}, port {any}\n", .{ i, expected, actual });
            return error.SequencesDiffer;
        }
    }
    try testing.expectEqual(r.nb_seq, port_seqs.len);
    try testing.expectEqualSlices(u8, r.lits[0..r.nb_lit], port.storedLiterals());
    try testing.expectEqual(r.rep, port.rep);
    try testing.expectEqual(r.long_length_type, @backingInt(port.seq_store.long_length_type));
    if (r.long_length_type != 0) {
        try testing.expectEqual(r.long_length_pos, port.seq_store.long_length_pos);
    }

    try testing.expectEqual(r.next_to_update, ms.next_to_update);
    try testing.expectEqual(r.dict_limit, ms.window.dict_limit);
    try testing.expectEqual(r.low_limit, ms.window.low_limit);
    try testing.expectEqual(r.loaded_dict_end, ms.loaded_dict_end);
    try testing.expectEqual(@intFromPtr(r.base), @intFromPtr(ms.window.base));

    const o = &ms.opt;
    try testing.expectEqual(r.price_type, @backingInt(o.price_type));
    try testing.expectEqual(r.lit_sum, o.lit_sum);
    try testing.expectEqual(r.lit_length_sum, o.lit_length_sum);
    try testing.expectEqual(r.match_length_sum, o.match_length_sum);
    try testing.expectEqual(r.off_code_sum, o.off_code_sum);
    try testing.expectEqual(r.lit_sum_base_price, o.lit_sum_base_price);
    try testing.expectEqual(r.lit_length_sum_base_price, o.lit_length_sum_base_price);
    try testing.expectEqual(r.match_length_sum_base_price, o.match_length_sum_base_price);
    try testing.expectEqual(r.off_code_sum_base_price, o.off_code_sum_base_price);
    try expectSameTable(r.lit_freq, o.lit_freq[0 .. max_lit + 1]);
    try expectSameTable(r.lit_length_freq, o.lit_length_freq[0 .. max_ll + 1]);
    try expectSameTable(r.match_length_freq, o.match_length_freq[0 .. max_ml + 1]);
    try expectSameTable(r.off_code_freq, o.off_code_freq[0 .. max_off + 1]);

    try testing.expectEqual(r.hash_log3, ms.hash_log3);
    try expectSameTable(r.hash_table, port.hash_table);
    try expectSameTable(r.chain_table, port.chain_table);
    if (ms.hash_log3 != 0) {
        const size = @as(usize, 1) << @intCast(ms.hash_log3);
        try expectSameTable(r.hash_table3, ms.hash_table3[0..size]);
    }
    if (case.dict_kind == .attached) {
        try expectSameTable(r.dict_hash_table.?, port.dict_hash_table);
        try expectSameTable(r.dict_chain_table.?, port.dict_chain_table);
    }
    try testing.expectEqual(r.ldm_pos, ldm_store.pos);
    try testing.expectEqual(r.ldm_pos_in_sequence, ldm_store.pos_in_sequence);
}

fn expectSameTable(expected: [*]const u32, actual: []const u32) !void {
    try testing.expectEqualSlices(u32, expected[0..actual.len], actual);
}

// ---------------------------------------------------------------------------
// Inputs
// ---------------------------------------------------------------------------

/// The level 19 to 22 parameters for a 128 KiB block and larger, and for
/// small blocks, with every minimum match length.
fn levelParams(strategy: params.Strategy, min_match_len: u32) CompressionParameters {
    return .{
        .window_log = 23,
        .chain_log = 24,
        .hash_log = 22,
        .search_log = 6,
        .min_match = min_match_len,
        .target_length = if (strategy == .btopt) 64 else 256,
        .strategy = strategy,
    };
}

const strategies = [_]params.Strategy{ .btopt, .btultra, .btultra2 };

/// `size` bytes in which copies of earlier runs are planted, each recorded
/// as a long distance candidate in `ldm`. The caller frees both.
fn plantedCopies(size: usize, seed: u64, ldm: *std.ArrayList(c.RawSeq)) ![]u8 {
    const src = try common.generated(size, 0.3, 0.0, @truncate(seed));
    var prng: std.Random.DefaultPrng = .init(seed);
    const random = prng.random();
    var pos: usize = 1024 + random.uintLessThan(usize, 4096);
    var last_end: usize = 0;
    while (pos + 4096 < size) {
        const length = 16 + random.uintLessThan(usize, 3000);
        const offset = 1 + random.uintLessThan(usize, pos - 1);
        for (0..length) |i| src[pos + i] = src[pos - offset + i];
        try ldm.append(gpa, .{
            .offset = @intCast(offset),
            .lit_length = @intCast(pos - last_end),
            .match_length = @intCast(length),
        });
        last_end = pos + length;
        pos = last_end + random.uintLessThan(usize, 20_000);
    }
    return src;
}

test "opt: every strategy and minimum match length on generated data" {
    for ([_]f64{ 0.1, 0.5, 0.9 }, 0..) |match_proba, i| {
        const src = try common.generated(block_size_max, match_proba, 0.0, @intCast(i + 1));
        defer gpa.free(src);
        for (strategies) |strategy| {
            for (3..8) |min_match_len| {
                try expectSameOpt(.{
                    .cparams = levelParams(strategy, @intCast(min_match_len)),
                    .src = src,
                });
            }
        }
    }
}

test "opt: golden files and the compressor's sample inputs, several blocks" {
    const golden = [_][]const u8{
        "tests/golden-compression/http",
        "tests/golden-compression/huffman-compressed-larger",
        "tests/golden-compression/large-literal-and-match-lengths",
        "tests/golden-compression/PR-3517-block-splitter-corruption-test",
    };
    for (golden) |name| {
        const src = try common.readFile(test_options.reference, name);
        defer gpa.free(src);
        for (strategies) |strategy| {
            try expectSameOpt(.{ .cparams = levelParams(strategy, 3), .src = src });
            try expectSameOpt(.{
                .cparams = levelParams(strategy, 4),
                .src = src,
                .block_size = 16 * 1024,
            });
        }
    }
    for ([_][]const u8{ "bc7.bin", "mesh.bin", "snapshot.bin" }) |name| {
        const data = try common.readFile(test_options.data, name);
        defer gpa.free(data);
        const src = data[0..@min(data.len, 3 * block_size_max + 1000)];
        for (strategies) |strategy| {
            try expectSameOpt(.{ .cparams = levelParams(strategy, 3), .src = src });
            try expectSameOpt(.{ .cparams = levelParams(strategy, 5), .src = src });
        }
    }
}

test "opt: edge inputs" {
    const zeros = try gpa.alloc(u8, block_size_max);
    defer gpa.free(zeros);
    @memset(zeros, 0);
    const random_bytes = try gpa.alloc(u8, block_size_max);
    defer gpa.free(random_bytes);
    var prng: std.Random.DefaultPrng = .init(77);
    prng.random().bytes(random_bytes);
    var text: [12 * 400]u8 = undefined;
    for (0..400) |i| text[i * 12 ..][0..12].* = "abcabcabcabd".*;
    for (strategies) |strategy| {
        for ([_]u32{ 3, 4, 6 }) |min_match_len| {
            const cparams = levelParams(strategy, min_match_len);
            // All the same bytes, with the longest matches.
            try expectSameOpt(.{ .cparams = cparams, .src = zeros });
            try expectSameOpt(.{ .cparams = cparams, .src = zeros, .block_size = 1000 });
            try expectSameOpt(.{ .cparams = cparams, .src = random_bytes });
            try expectSameOpt(.{ .cparams = cparams, .src = &text });
            // Tiny blocks: fixed prices at the first one, and blocks too
            // short for any match.
            for (1..20) |size| {
                try expectSameOpt(.{ .cparams = cparams, .src = text[0..size] });
                try expectSameOpt(.{
                    .cparams = cparams,
                    .src = text[0 .. size * 7],
                    .block_size = size,
                });
            }
        }
    }
}

test "opt: small windows, trees and hash tables over several blocks" {
    const src = try common.generated(4 * block_size_max, 0.6, 0.0, 5);
    defer gpa.free(src);
    for (strategies) |strategy| {
        for ([_]u32{ 10, 12, 17 }) |window_log| {
            try expectSameOpt(.{
                .cparams = .{
                    .window_log = window_log,
                    .chain_log = window_log - 2,
                    .hash_log = 8,
                    .search_log = 4,
                    .min_match = 3,
                    .target_length = 32,
                    .strategy = strategy,
                },
                .src = src,
                .block_size = 50_000,
            });
        }
    }
}

test "opt: literal compression off and on" {
    const src = try common.generated(2 * block_size_max, 0.4, 0.0, 6);
    defer gpa.free(src);
    for (strategies) |strategy| {
        for ([_]params.ParamSwitch{ .disable, .enable }) |mode| {
            try expectSameOpt(.{
                .cparams = levelParams(strategy, 3),
                .src = src,
                .literal_mode = mode,
            });
        }
    }
}

test "opt: dictionaries: prefix, external, attached, with their entropy tables" {
    const buffer = try common.generated(3 * block_size_max, 0.5, 0.0, 8);
    defer gpa.free(buffer);
    const dict = buffer[0 .. 64 * 1024];
    const src = buffer[64 * 1024 ..];
    // The same dictionary in another buffer, so the input does not follow it.
    const dict_copy = try gpa.dupe(u8, dict);
    defer gpa.free(dict_copy);
    for (strategies) |strategy| {
        for ([_]u32{ 3, 4, 5 }) |min_match_len| {
            const cparams = levelParams(strategy, min_match_len);
            for ([_]?u32{ null, 99 }) |entropy_seed| {
                // A prefix: the dictionary right before the input.
                try expectSameOpt(.{
                    .cparams = cparams,
                    .src = src,
                    .dict_kind = .ext,
                    .dict = dict,
                    .entropy_seed = entropy_seed,
                });
                try expectSameOpt(.{
                    .cparams = cparams,
                    .src = src,
                    .dict_kind = .ext,
                    .dict = dict_copy,
                    .entropy_seed = entropy_seed,
                });
                try expectSameOpt(.{
                    .cparams = cparams,
                    .src = src,
                    .dict_kind = .attached,
                    .dict = dict_copy,
                    .entropy_seed = entropy_seed,
                });
                var dict_cparams = cparams;
                dict_cparams.hash_log = 12;
                dict_cparams.chain_log = 11;
                try expectSameOpt(.{
                    .cparams = cparams,
                    .src = src,
                    .dict_kind = .attached,
                    .dict = dict_copy,
                    .dict_cparams = dict_cparams,
                    .entropy_seed = entropy_seed,
                    .block_size = 40_000,
                });
            }
            // Entropy tables and no dictionary.
            try expectSameOpt(.{ .cparams = cparams, .src = src, .entropy_seed = 3 });
            try expectSameOpt(.{
                .cparams = cparams,
                .src = src,
                .entropy_seed = 4,
                .literal_mode = .disable,
            });
        }
    }
}

test "opt: long distance match candidates" {
    var ldm: std.ArrayList(c.RawSeq) = .empty;
    defer ldm.deinit(gpa);
    const src = try plantedCopies(4 * block_size_max, 11, &ldm);
    defer gpa.free(src);
    for (strategies) |strategy| {
        for ([_]u32{ 3, 4 }) |min_match_len| {
            try expectSameOpt(.{
                .cparams = levelParams(strategy, min_match_len),
                .src = src,
                .ldm = ldm.items,
            });
            try expectSameOpt(.{
                .cparams = levelParams(strategy, min_match_len),
                .src = src,
                .ldm = ldm.items,
                .block_size = 30_000,
            });
        }
    }
}

test "opt: fuzz parameters, inputs, blocks, dictionaries and candidates" {
    const seed = common.fuzzSeed(0x0f7);
    var prng: std.Random.DefaultPrng = .init(seed);
    const random = prng.random();
    for (0..common.fuzz_cases) |case_nb| {
        const window_log = 10 + random.uintLessThan(u32, 14);
        const cparams: CompressionParameters = .{
            .window_log = window_log,
            .chain_log = 6 + random.uintLessThan(u32, window_log - 4),
            .hash_log = 6 + random.uintLessThan(u32, 15),
            .search_log = 1 + random.uintLessThan(u32, 9),
            .min_match = 3 + random.uintLessThan(u32, 5),
            .target_length = switch (random.uintLessThan(u32, 4)) {
                0 => 0,
                1 => random.uintLessThan(u32, 64),
                2 => random.uintLessThan(u32, 1000),
                else => random.uintLessThan(u32, 5000),
            },
            .strategy = strategies[random.uintLessThan(usize, strategies.len)],
        };
        const dict_size = if (random.boolean()) 0 else random.uintLessThan(usize, 40_000);
        const src_size = switch (random.uintLessThan(u32, 4)) {
            // Never empty: no block compressor is called on an empty block.
            0 => 1 + random.uintLessThan(usize, 100),
            1 => random.uintLessThan(usize, 5000),
            else => random.uintLessThan(usize, 200_000),
        };
        var ldm: std.ArrayList(c.RawSeq) = .empty;
        defer ldm.deinit(gpa);
        const use_ldm = src_size > 10_000 and random.uintLessThan(u32, 4) == 0;
        const buffer = if (use_ldm)
            try plantedCopies(dict_size + src_size, random.int(u64), &ldm)
        else
            try common.generated(
                dict_size + src_size,
                random.float(f64),
                random.float(f64) * 0.5,
                random.int(u32),
            );
        defer gpa.free(buffer);
        const dict_copy = try gpa.dupe(u8, buffer[0..dict_size]);
        defer gpa.free(dict_copy);
        if (use_ldm) {
            // The candidates over the input only: drop those in the
            // dictionary's part, and cut the one across its end.
            var kept: std.ArrayList(c.RawSeq) = .empty;
            defer kept.deinit(gpa);
            var pos: usize = 0;
            var last_end: usize = dict_size;
            for (ldm.items) |seq| {
                const match_start = pos + seq.lit_length;
                pos = match_start + seq.match_length;
                if (match_start < dict_size) continue;
                try kept.append(gpa, .{
                    .offset = seq.offset,
                    .lit_length = @intCast(match_start - last_end),
                    .match_length = seq.match_length,
                });
                last_end = pos;
            }
            ldm.clearRetainingCapacity();
            try ldm.appendSlice(gpa, kept.items);
        }

        var dict_kind: DictKind = .none;
        var dict: []const u8 = &.{};
        var dict_cparams = cparams;
        if (dict_size != 0) {
            switch (random.uintLessThan(u32, 3)) {
                0 => {
                    dict_kind = .ext;
                    dict = buffer[0..dict_size];
                },
                1 => {
                    dict_kind = .ext;
                    dict = dict_copy;
                },
                else => {
                    dict_kind = .attached;
                    dict = dict_copy;
                    dict_cparams.hash_log = 6 + random.uintLessThan(u32, 15);
                    dict_cparams.chain_log = 6 + random.uintLessThan(u32, 15);
                },
            }
        }
        const case: OptCase = .{
            .cparams = cparams,
            .src = buffer[dict_size..],
            .block_size = if (random.boolean())
                block_size_max
            else
                1 + random.uintLessThan(usize, 60_000),
            .dict_kind = dict_kind,
            .dict = dict,
            .dict_cparams = dict_cparams,
            .literal_mode = switch (random.uintLessThan(u32, 4)) {
                0 => .disable,
                1 => .enable,
                else => .auto,
            },
            .entropy_seed = if (random.uintLessThan(u32, 4) == 0) random.int(u32) else null,
            .ldm = ldm.items,
        };
        expectSameOpt(case) catch |err| {
            std.debug.print("opt fuzz: seed {d}, case {d}: {any}, src {d}, dict {d} ({t})\n", .{
                seed,
                case_nb,
                cparams,
                src_size,
                dict_size,
                dict_kind,
            });
            return err;
        };
    }
}
