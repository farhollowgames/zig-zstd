//! The optimal parser of the btopt, btultra and btultra2 strategies, from the
//! original's zstd_opt.c: a price model built from symbol statistics, a binary
//! tree that finds every match at a position, and a forward pass that prices
//! each way of reaching the positions ahead, followed by a backward pass that
//! stores the cheapest path.

const std = @import("std");
const builtin = @import("builtin");

const params = @import("../params.zig");
const zstd_internal = @import("../common/zstd_internal.zig");
const internal = @import("compress_internal.zig");
const hist = @import("hist.zig");
const huf_compress = @import("huf_compress.zig");
const fse_compress = @import("fse_compress.zig");

const assert = std.debug.assert;
const native_endian = builtin.cpu.arch.endian();

const rep_num = zstd_internal.rep_num;
const opt_num = zstd_internal.opt_num;
const max_lit = zstd_internal.max_lit;
const max_ll = zstd_internal.max_ll;
const max_ml = zstd_internal.max_ml;
const max_off = zstd_internal.max_off;
const min_match = zstd_internal.min_match;

const MatchState = internal.MatchState;
const SeqStore = internal.SeqStore;
const OptState = internal.OptState;
const Optimal = internal.Optimal;
const Match = internal.Match;
const RawSeq = internal.RawSeq;
const RawSeqStore = internal.RawSeqStore;
const DictMode = internal.DictMode;
const highbit32 = internal.highbit32;

/// Scales the literal counts up, so that they adapt faster to new statistics.
const litfreq_add = 2;
const max_price = 1 << 30;
/// Below this source size, the first block's prices come from fixed
/// distributions rather than statistics.
const predef_threshold = 8;

/// Prices are in fractional bits, with this many bits after the point.
const bitcost_accuracy = 8;
const bitcost_multiplier = 1 << bitcost_accuracy;

// ---------------------------------------------------------------------------
// Price functions
// ---------------------------------------------------------------------------

/// `ZSTD_bitWeight`: the cost of a statistic in whole bits.
inline fn bitWeight(stat: u32) u32 {
    return highbit32(stat + 1) * bitcost_multiplier;
}

/// `ZSTD_fracWeight`: the cost of a statistic in fractional bits, by linear
/// interpolation between powers of two.
inline fn fracWeight(raw_stat: u32) u32 {
    const stat = raw_stat + 1;
    const hb = highbit32(stat);
    const b_weight = hb * bitcost_multiplier;
    // Between 1 and 2, in fixed point.
    const f_weight = (stat << bitcost_accuracy) >> @intCast(hb);
    assert(hb + bitcost_accuracy < 31);
    return b_weight + f_weight;
}

/// `WEIGHT`: btopt (level 0) prices in whole bits, btultra in fractions.
inline fn weight(stat: u32, comptime opt_level: u32) u32 {
    return if (opt_level != 0) fracWeight(stat) else bitWeight(stat);
}

/// `ZSTD_compressedLiterals`.
inline fn compressedLiterals(opt_ptr: *const OptState) bool {
    return opt_ptr.literal_compression_mode != .disable;
}

/// `ZSTD_setBasePrices`.
fn setBasePrices(opt_ptr: *OptState, comptime opt_level: u32) void {
    if (compressedLiterals(opt_ptr)) {
        opt_ptr.lit_sum_base_price = weight(opt_ptr.lit_sum, opt_level);
    }
    opt_ptr.lit_length_sum_base_price = weight(opt_ptr.lit_length_sum, opt_level);
    opt_ptr.match_length_sum_base_price = weight(opt_ptr.match_length_sum, opt_level);
    opt_ptr.off_code_sum_base_price = weight(opt_ptr.off_code_sum, opt_level);
}

/// `sum_u32`.
fn sumU32(table: []const u32) u32 {
    var total: u32 = 0;
    for (table) |value| total += value;
    return total;
}

/// `base_directive_e`: whether every downscaled count stays at least 1, or
/// only those that were not 0.
const BaseDirective = enum { base_0_possible, base_1_guaranteed };

/// `ZSTD_downscaleStats`: shifts the counts of `table[0..last_elt_index + 1]`
/// down by `shift`, and returns their new sum.
fn downscaleStats(table: [*]u32, last_elt_index: u32, shift: u32, base1: BaseDirective) u32 {
    assert(shift < 30);
    var sum: u32 = 0;
    for (table[0 .. last_elt_index + 1]) |*stat| {
        const base: u32 = if (base1 == .base_1_guaranteed) 1 else @intFromBool(stat.* > 0);
        const new_stat = base + (stat.* >> @intCast(shift));
        sum += new_stat;
        stat.* = new_stat;
    }
    return sum;
}

/// `ZSTD_scaleStats`: scales the counts down when their sum is above
/// `1 << log_target`, and returns their sum.
fn scaleStats(table: [*]u32, last_elt_index: u32, log_target: u32) u32 {
    const prev_sum = sumU32(table[0 .. last_elt_index + 1]);
    const factor = prev_sum >> @intCast(log_target);
    assert(log_target < 30);
    if (factor <= 1) return prev_sum;
    return downscaleStats(table, last_elt_index, highbit32(factor), .base_1_guaranteed);
}

/// The literal length code counts the first block starts from.
const base_ll_freqs = [max_ll + 1]u32{
    4, 2, 1, 1, 1, 1, 1, 1,
    1, 1, 1, 1, 1, 1, 1, 1,
    1, 1, 1, 1, 1, 1, 1, 1,
    1, 1, 1, 1, 1, 1, 1, 1,
    1, 1, 1, 1,
};

/// The offset code counts the first block starts from.
const base_ofc_freqs = [max_off + 1]u32{
    6, 2, 1, 1, 2, 3, 4, 4,
    4, 3, 2, 1, 1, 1, 1, 1,
    1, 1, 1, 1, 1, 1, 1, 1,
    1, 1, 1, 1, 1, 1, 1, 1,
};

/// `ZSTD_rescaleFreqs`: at the first block (no literal length statistics
/// yet), sets up the statistics, from the dictionary's entropy tables when it
/// has valid ones, else from the block's literals and fixed distributions;
/// at later blocks, scales the statistics down to seed the next block.
fn rescaleFreqs(opt_ptr: *OptState, src: []const u8, comptime opt_level: u32) void {
    const compressed_literals = compressedLiterals(opt_ptr);
    opt_ptr.price_type = .dynamic;

    if (opt_ptr.lit_length_sum == 0) {
        // Too small an input for statistics: fixed prices.
        if (src.len <= predef_threshold) opt_ptr.price_type = .predef;

        const symbol_costs = opt_ptr.symbol_costs.?;
        if (symbol_costs.huf.repeat_mode == .valid) {
            // A Huffman table over the whole alphabet, presumably a
            // dictionary's.
            opt_ptr.price_type = .dynamic;

            if (compressed_literals) {
                const scale_log = 11;
                opt_ptr.lit_sum = 0;
                for (0..max_lit + 1) |lit| {
                    const bit_cost = huf_compress.getNbBitsFromCTable(
                        &symbol_costs.huf.ctable,
                        @intCast(lit),
                    );
                    assert(bit_cost <= scale_log);
                    opt_ptr.lit_freq[lit] = if (bit_cost != 0)
                        @as(u32, 1) << @intCast(scale_log - bit_cost)
                    else
                        1;
                    opt_ptr.lit_sum += opt_ptr.lit_freq[lit];
                }
            }

            opt_ptr.lit_length_sum = freqsFromCTable(
                opt_ptr.lit_length_freq,
                &symbol_costs.fse.litlength_ctable,
                max_ll,
            );
            opt_ptr.match_length_sum = freqsFromCTable(
                opt_ptr.match_length_freq,
                &symbol_costs.fse.matchlength_ctable,
                max_ml,
            );
            opt_ptr.off_code_sum = freqsFromCTable(
                opt_ptr.off_code_freq,
                &symbol_costs.fse.offcode_ctable,
                max_off,
            );
        } else {
            // The first block, without a dictionary.
            if (compressed_literals) {
                // The literals' costs start from their counts in the block.
                var lit: u32 = max_lit;
                _ = hist.countSimple(opt_ptr.lit_freq[0 .. max_lit + 1], &lit, src);
                opt_ptr.lit_sum = downscaleStats(opt_ptr.lit_freq, max_lit, 8, .base_0_possible);
            }

            opt_ptr.lit_length_freq[0 .. max_ll + 1].* = base_ll_freqs;
            opt_ptr.lit_length_sum = sumU32(&base_ll_freqs);

            @memset(opt_ptr.match_length_freq[0 .. max_ml + 1], 1);
            opt_ptr.match_length_sum = max_ml + 1;

            opt_ptr.off_code_freq[0 .. max_off + 1].* = base_ofc_freqs;
            opt_ptr.off_code_sum = sumU32(&base_ofc_freqs);
        }
    } else {
        // A new block: scale the statistics gathered so far down.
        if (compressed_literals) opt_ptr.lit_sum = scaleStats(opt_ptr.lit_freq, max_lit, 12);
        opt_ptr.lit_length_sum = scaleStats(opt_ptr.lit_length_freq, max_ll, 11);
        opt_ptr.match_length_sum = scaleStats(opt_ptr.match_length_freq, max_ml, 11);
        opt_ptr.off_code_sum = scaleStats(opt_ptr.off_code_freq, max_off, 11);
    }

    setBasePrices(opt_ptr, opt_level);
}

/// Part of `ZSTD_rescaleFreqs`: counts in `freq[0..max_symbol + 1]` that
/// match the costs of an FSE table, scaled to 1K; returns their sum.
fn freqsFromCTable(freq: [*]u32, ctable: []const u32, max_symbol: u32) u32 {
    const scale_log = 10;
    const state: fse_compress.CState = .init(ctable);
    var sum: u32 = 0;
    for (0..max_symbol + 1) |symbol| {
        const bit_cost = fse_compress.getMaxNbBits(state.symbol_tt, @intCast(symbol));
        assert(bit_cost < scale_log);
        freq[symbol] = if (bit_cost != 0) @as(u32, 1) << @intCast(scale_log - bit_cost) else 1;
        sum += freq[symbol];
    }
    return sum;
}

/// `ZSTD_rawLiteralsCost`: the price of `lit_length` literals at `literals`,
/// without their literal length code.
inline fn rawLiteralsCost(
    literals: [*]const u8,
    lit_length: u32,
    opt_ptr: *const OptState,
    comptime opt_level: u32,
) u32 {
    if (lit_length == 0) return 0;

    // Uncompressed: 8 bits a literal.
    if (!compressedLiterals(opt_ptr)) return (lit_length << 3) * bitcost_multiplier;

    // 6 bits a literal, with no statistics.
    if (opt_ptr.price_type == .predef) return (lit_length * 6) * bitcost_multiplier;

    var price = opt_ptr.lit_sum_base_price * lit_length;
    const lit_price_max = opt_ptr.lit_sum_base_price - bitcost_multiplier;
    assert(opt_ptr.lit_sum_base_price >= bitcost_multiplier);
    for (literals[0..lit_length]) |literal| {
        var lit_price = weight(opt_ptr.lit_freq[literal], opt_level);
        if (lit_price > lit_price_max) {
            @branchHint(.unlikely);
            lit_price = lit_price_max;
        }
        price -= lit_price;
    }
    return price;
}

/// `ZSTD_litLengthPrice`: the price of the literal length code.
inline fn litLengthPrice(lit_length: u32, opt_ptr: *const OptState, comptime opt_level: u32) u32 {
    assert(lit_length <= params.block_size_max);
    if (opt_ptr.price_type == .predef) return weight(lit_length, opt_level);

    // A whole block of literals has no literal length code: price it one bit
    // above the largest length that has one.
    if (lit_length == params.block_size_max) {
        return bitcost_multiplier +
            litLengthPriceDynamic(params.block_size_max - 1, opt_ptr, opt_level);
    }
    return litLengthPriceDynamic(lit_length, opt_ptr, opt_level);
}

inline fn litLengthPriceDynamic(
    lit_length: u32,
    opt_ptr: *const OptState,
    comptime opt_level: u32,
) u32 {
    const ll_code = internal.llCode(lit_length);
    return @as(u32, zstd_internal.ll_bits[ll_code]) * bitcost_multiplier +
        opt_ptr.lit_length_sum_base_price -
        weight(opt_ptr.lit_length_freq[ll_code], opt_level);
}

/// `ZSTD_getMatchPrice`: the price of the match part of a sequence, its
/// offset (`off_base`, as `storeSeq` takes it) and match length. Below
/// level 2 (btopt), long offsets get a handicap, for decompression speed.
inline fn getMatchPrice(
    off_base: u32,
    match_length: u32,
    opt_ptr: *const OptState,
    comptime opt_level: u32,
) u32 {
    const off_code = highbit32(off_base);
    const ml_base = match_length - min_match;
    assert(match_length >= min_match);

    if (opt_ptr.price_type == .predef) {
        // A fixed scheme, with an emulated offset cost.
        return weight(ml_base, opt_level) + (16 + off_code) * bitcost_multiplier;
    }

    var price = off_code * bitcost_multiplier +
        (opt_ptr.off_code_sum_base_price - weight(opt_ptr.off_code_freq[off_code], opt_level));
    if (opt_level < 2 and off_code >= 20) price += (off_code - 19) * 2 * bitcost_multiplier;

    const ml_code = internal.mlCode(ml_base);
    price += @as(u32, zstd_internal.ml_bits[ml_code]) * bitcost_multiplier +
        (opt_ptr.match_length_sum_base_price -
            weight(opt_ptr.match_length_freq[ml_code], opt_level));

    // Makes matches a little more costly, for fewer sequences and faster
    // decompression.
    price += bitcost_multiplier / 5;
    return price;
}

/// `ZSTD_updateStats`: counts one sequence. `literals + lit_length` is at
/// most the end of the input.
fn updateStats(
    opt_ptr: *OptState,
    lit_length: u32,
    literals: [*]const u8,
    off_base: u32,
    match_length: u32,
) void {
    if (compressedLiterals(opt_ptr)) {
        for (literals[0..lit_length]) |literal| opt_ptr.lit_freq[literal] += litfreq_add;
        opt_ptr.lit_sum += lit_length * litfreq_add;
    }

    const ll_code = internal.llCode(lit_length);
    opt_ptr.lit_length_freq[ll_code] += 1;
    opt_ptr.lit_length_sum += 1;

    const off_code = highbit32(off_base);
    assert(off_code <= max_off);
    opt_ptr.off_code_freq[off_code] += 1;
    opt_ptr.off_code_sum += 1;

    const ml_code = internal.mlCode(match_length - min_match);
    opt_ptr.match_length_freq[ml_code] += 1;
    opt_ptr.match_length_sum += 1;
}

/// `ZSTD_readMINMATCH`: the first `length` (3 or 4) bytes at `ptr`, for
/// comparisons only. Reads 4 bytes.
inline fn readMinMatch(ptr: [*]const u8, comptime length: u32) u32 {
    const word = std.mem.readInt(u32, ptr[0..4], native_endian);
    if (length != 3) return word;
    return switch (native_endian) {
        .little => word << 8,
        .big => word >> 8,
    };
}

// ---------------------------------------------------------------------------
// The table of 3-byte matches
// ---------------------------------------------------------------------------

/// `ZSTD_insertAndFindFirstIndexHash3`: inserts every position from
/// `next_to_update3` up to `ip` (excluded) into the 3-byte hash table, and
/// returns the entry for `ip`. Always within the prefix.
fn insertAndFindFirstIndexHash3(
    ms: *const MatchState,
    next_to_update3: *u32,
    ip: [*]const u8,
) u32 {
    const hash_table3 = ms.hash_table3;
    const hash_log3 = ms.hash_log3;
    const base = ms.window.base;
    var idx = next_to_update3.*;
    const target: u32 = @truncate(@intFromPtr(ip) -% @intFromPtr(base));
    const hash3 = internal.hash3Ptr(ip, hash_log3);
    assert(hash_log3 > 0);

    while (idx < target) : (idx += 1) {
        hash_table3[internal.hash3Ptr(base + idx, hash_log3)] = idx;
    }

    next_to_update3.* = target;
    return hash_table3[hash3];
}

// ---------------------------------------------------------------------------
// Binary tree search
// ---------------------------------------------------------------------------

/// `ZSTD_insertBt1`: adds the position `ip` to the tree. `ip` is at most
/// `iend - 8`; `target` is where `updateTreeInternal` fills up to. Returns
/// the number of positions to move on, more than one over repetitive data.
fn insertBt1(
    ms: *const MatchState,
    ip: [*]const u8,
    iend: [*]const u8,
    target: u32,
    comptime mls: u32,
    comptime ext_dict: bool,
) u32 {
    const cparams = &ms.cparams;
    const hash_table = ms.hash_table;
    const hash_log = cparams.hash_log;
    const h = internal.hashPtr(ip, hash_log, mls);
    const bt = ms.chain_table;
    const bt_log = cparams.chain_log - 1;
    const bt_mask = (@as(u32, 1) << @intCast(bt_log)) - 1;
    var match_index = hash_table[h];
    var common_length_smaller: usize = 0;
    var common_length_larger: usize = 0;
    const base = ms.window.base;
    const dict_base = ms.window.dict_base;
    const dict_limit = ms.window.dict_limit;
    const dict_end = dict_base + dict_limit;
    const prefix_start = base + dict_limit;
    const curr: u32 = @truncate(@intFromPtr(ip) -% @intFromPtr(base));
    const bt_low = if (bt_mask >= curr) 0 else curr - bt_mask;
    var smaller_ptr: *u32 = &bt[2 * (curr & bt_mask)];
    var larger_ptr: *u32 = &bt[2 * (curr & bt_mask) + 1];
    // Takes the writes past the end of the tree, which are then dropped.
    var dummy32: u32 = undefined;
    // Only positions still in the window at the end of the update count.
    const window_low = internal.getLowestMatchIndex(ms, target, cparams.window_log);
    var match_end_idx = curr + 8 + 1;
    var best_length: usize = 8;
    var nb_compares = @as(u32, 1) << @intCast(cparams.search_log);

    assert(curr <= target);
    assert(@intFromPtr(ip) <= @intFromPtr(iend) - 8);
    hash_table[h] = curr;

    assert(window_low > 0);
    while (nb_compares != 0 and match_index >= window_low) : (nb_compares -= 1) {
        const next_ptr = bt + 2 * (match_index & bt_mask);
        // Both neighbours share at least this many bytes with `ip`.
        var match_length = @min(common_length_smaller, common_length_larger);
        assert(match_index < curr);

        var match: [*]const u8 = undefined;
        if (!ext_dict or @as(usize, match_index) + match_length >= dict_limit) {
            match = base + match_index;
            match_length += internal.count(ip + match_length, match + match_length, iend);
        } else {
            match = dict_base + match_index;
            match_length += internal.count2Segments(
                ip + match_length,
                match + match_length,
                iend,
                dict_end,
                prefix_start,
            );
            // For the read of match[match_length] below.
            if (@as(usize, match_index) + match_length >= dict_limit) match = base + match_index;
        }

        if (match_length > best_length) {
            best_length = match_length;
            if (match_length > match_end_idx - match_index) {
                match_end_idx = match_index + @as(u32, @intCast(match_length));
            }
        }

        // Equal up to the end: whether smaller or larger is unknown. Dropping
        // the candidate costs a little compression and keeps the tree sound.
        if (@intFromPtr(ip) + match_length == @intFromPtr(iend)) break;

        if (match[match_length] < ip[match_length]) {
            // The match is smaller than the current position.
            smaller_ptr.* = match_index;
            common_length_smaller = match_length;
            if (match_index <= bt_low) {
                smaller_ptr = &dummy32;
                break;
            }
            smaller_ptr = &next_ptr[1];
            match_index = next_ptr[1];
        } else {
            // The match is larger than the current position.
            larger_ptr.* = match_index;
            common_length_larger = match_length;
            if (match_index <= bt_low) {
                larger_ptr = &dummy32;
                break;
            }
            larger_ptr = &next_ptr[0];
            match_index = next_ptr[0];
        }
    }

    smaller_ptr.* = 0;
    larger_ptr.* = 0;
    var positions: u32 = 0;
    // Skips ahead over long repetitions, for speed.
    if (best_length > 384) positions = @min(192, @as(u32, @intCast(best_length - 384)));
    assert(match_end_idx > curr + 8);
    return @max(positions, match_end_idx - (curr + 8));
}

/// `ZSTD_updateTree_internal`: inserts every position from `next_to_update`
/// up to `ip` (excluded) into the tree.
inline fn updateTreeInternal(
    ms: *MatchState,
    ip: [*]const u8,
    iend: [*]const u8,
    comptime mls: u32,
    comptime dict_mode: DictMode,
) void {
    const base = ms.window.base;
    const target: u32 = @truncate(@intFromPtr(ip) -% @intFromPtr(base));
    var idx = ms.next_to_update;

    while (idx < target) {
        const forward = insertBt1(ms, base + idx, iend, target, mls, dict_mode == .ext_dict);
        assert(idx < idx +% forward);
        idx += forward;
    }
    assert(@intFromPtr(ip) - @intFromPtr(base) <= std.math.maxInt(u32));
    assert(@intFromPtr(iend) - @intFromPtr(base) <= std.math.maxInt(u32));
    ms.next_to_update = target;
}

/// `ZSTD_updateTree`: fills the tree up to `ip`, as loading a dictionary
/// does. The hash takes `min_match` bytes, unbounded, as in the original.
pub fn updateTree(ms: *MatchState, ip: [*]const u8, iend: [*]const u8) void {
    switch (ms.cparams.min_match) {
        inline 5, 6, 7, 8 => |mls| updateTreeInternal(ms, ip, iend, mls, .no_dict),
        else => updateTreeInternal(ms, ip, iend, 4, .no_dict),
    }
}

/// `ZSTD_insertBtAndGetAllMatches`: inserts `ip` into the tree and stores
/// in `matches` every match longer than the ones before it, starting with
/// the repeat offsets, then the 3-byte table, the tree and the dictionary's
/// tree. Returns their number.
inline fn insertBtAndGetAllMatches(
    matches: [*]Match,
    ms: *MatchState,
    next_to_update3: *u32,
    ip: [*]const u8,
    i_limit: [*]const u8,
    comptime dict_mode: DictMode,
    rep: *const [rep_num]u32,
    /// 1 when the literal length before the match is 0, else 0.
    ll0: u32,
    length_to_beat: u32,
    comptime mls: u32,
) u32 {
    const cparams = &ms.cparams;
    const sufficient_len = @min(cparams.target_length, opt_num - 1);
    const base = ms.window.base;
    const curr: u32 = @truncate(@intFromPtr(ip) -% @intFromPtr(base));
    const hash_log = cparams.hash_log;
    const min_match_len: u32 = if (mls == 3) 3 else 4;
    const hash_table = ms.hash_table;
    const h = internal.hashPtr(ip, hash_log, mls);
    var match_index = hash_table[h];
    const bt = ms.chain_table;
    const bt_log = cparams.chain_log - 1;
    const bt_mask = (@as(u32, 1) << @intCast(bt_log)) - 1;
    var common_length_smaller: usize = 0;
    var common_length_larger: usize = 0;
    const dict_base = ms.window.dict_base;
    const dict_limit = ms.window.dict_limit;
    const dict_end = dict_base + dict_limit;
    const prefix_start = base + dict_limit;
    const bt_low = if (bt_mask >= curr) 0 else curr - bt_mask;
    const window_low = internal.getLowestMatchIndex(ms, curr, cparams.window_log);
    const match_low = if (window_low != 0) window_low else 1;
    var smaller_ptr: *u32 = &bt[2 * (curr & bt_mask)];
    var larger_ptr: *u32 = &bt[2 * (curr & bt_mask) + 1];
    // The farthest position any match reaches, to detect repetitive data.
    var match_end_idx = curr + 8 + 1;
    // Takes the writes past the end of the tree, which are then dropped.
    var dummy32: u32 = undefined;
    var mnum: u32 = 0;
    var nb_compares = @as(u32, 1) << @intCast(cparams.search_log);

    const is_dms = dict_mode == .dict_match_state;
    const dms: *const MatchState = if (is_dms) ms.dict_match_state.? else undefined;
    const dms_cparams: *const params.CompressionParameters =
        if (is_dms) &dms.cparams else undefined;
    const dms_base: [*]const u8 = if (is_dms) dms.window.base else undefined;
    const dms_end: [*]const u8 = if (is_dms) dms.window.next_src else undefined;
    const dms_high_limit: u32 = if (is_dms)
        @truncate(@intFromPtr(dms_end) -% @intFromPtr(dms_base))
    else
        0;
    const dms_low_limit: u32 = if (is_dms) dms.window.low_limit else 0;
    const dms_index_delta: u32 = if (is_dms) window_low -% dms_high_limit else 0;
    const dms_hash_log: u32 = if (is_dms) dms_cparams.hash_log else hash_log;
    const dms_bt_log: u32 = if (is_dms) dms_cparams.chain_log - 1 else bt_log;
    const dms_bt_mask: u32 = if (is_dms) (@as(u32, 1) << @intCast(dms_bt_log)) - 1 else 0;
    const dms_bt_low: u32 = if (is_dms and dms_bt_mask < dms_high_limit - dms_low_limit)
        dms_high_limit - dms_bt_mask
    else
        dms_low_limit;

    var best_length: usize = length_to_beat - 1;

    // The repeat offsets.
    assert(ll0 <= 1);
    {
        const last_r = rep_num + ll0;
        var rep_code = ll0;
        while (rep_code < last_r) : (rep_code += 1) {
            const rep_offset = if (rep_code == rep_num) rep[0] - 1 else rep[rep_code];
            const rep_index = curr -% rep_offset;
            var rep_len: u32 = 0;
            assert(curr >= dict_limit);
            // `curr > rep_index >= dict_limit`; the wrap-around discards
            // offsets 0 and -1.
            if (rep_offset -% 1 < curr - dict_limit) {
                // The offset is checked against the window, which shrinks
                // when a dictionary goes out of reach.
                if (rep_index >= window_low and
                    readMinMatch(ip, min_match_len) == readMinMatch(ip - rep_offset, min_match_len))
                {
                    rep_len = @as(u32, @intCast(internal.count(
                        ip + min_match_len,
                        ip + min_match_len - rep_offset,
                        i_limit,
                    ))) + min_match_len;
                }
            } else if (dict_mode == .ext_dict or is_dms) {
                // rep_index < dict_limit or rep_index >= curr.
                const rep_match: [*]const u8 = if (is_dms)
                    @ptrFromInt(@intFromPtr(dms_base) +% rep_index -% dms_index_delta)
                else
                    @ptrFromInt(@intFromPtr(dict_base) +% rep_index);
                assert(curr >= window_low);
                if (dict_mode == .ext_dict and
                    // `curr > rep_index >= window_low`.
                    (rep_offset -% 1 < curr - window_low) and
                    internal.indexOverlapCheck(dict_limit, rep_index) and
                    readMinMatch(ip, min_match_len) == readMinMatch(rep_match, min_match_len))
                {
                    rep_len = @as(u32, @intCast(internal.count2Segments(
                        ip + min_match_len,
                        rep_match + min_match_len,
                        i_limit,
                        dict_end,
                        prefix_start,
                    ))) + min_match_len;
                }
                if (is_dms and
                    // `curr > rep_index >= dms_low_limit`.
                    (rep_offset -% 1 < curr -% (dms_low_limit +% dms_index_delta)) and
                    internal.indexOverlapCheck(dict_limit, rep_index) and
                    readMinMatch(ip, min_match_len) == readMinMatch(rep_match, min_match_len))
                {
                    rep_len = @as(u32, @intCast(internal.count2Segments(
                        ip + min_match_len,
                        rep_match + min_match_len,
                        i_limit,
                        dms_end,
                        prefix_start,
                    ))) + min_match_len;
                }
            }
            // Keeps the longer solution.
            if (rep_len > best_length) {
                best_length = rep_len;
                matches[mnum] = .{
                    .off = internal.repcodeToOffbase(rep_code - ll0 + 1),
                    .len = rep_len,
                };
                mnum += 1;
                if (rep_len > sufficient_len or
                    @intFromPtr(ip) + rep_len == @intFromPtr(i_limit))
                {
                    // The best possible.
                    return mnum;
                }
            }
        }
    }

    // The 3-byte match finder. Dictionaries have no 3-byte table.
    if (mls == 3 and best_length < mls) {
        const match_index3 = insertAndFindFirstIndexHash3(ms, next_to_update3, ip);
        // Longer distances are likely too expensive.
        if (match_index3 >= match_low and curr -% match_index3 < (1 << 18)) {
            const mlen = if (dict_mode == .no_dict or is_dms or match_index3 >= dict_limit)
                internal.count(ip, base + match_index3, i_limit)
            else
                internal.count2Segments(
                    ip,
                    dict_base + match_index3,
                    i_limit,
                    dict_end,
                    prefix_start,
                );

            if (mlen >= mls) {
                best_length = mlen;
                assert(curr > match_index3);
                // No earlier solution: the repeat offsets found none.
                assert(mnum == 0);
                matches[0] = .{
                    .off = internal.offsetToOffbase(curr - match_index3),
                    .len = @intCast(mlen),
                };
                mnum = 1;
                if (mlen > sufficient_len or @intFromPtr(ip) + mlen == @intFromPtr(i_limit)) {
                    // The best possible length: skip the insertion.
                    ms.next_to_update = curr + 1;
                    return 1;
                }
            }
        }
    }

    hash_table[h] = curr;

    while (nb_compares != 0 and match_index >= match_low) : (nb_compares -= 1) {
        const next_ptr = bt + 2 * (match_index & bt_mask);
        // Both neighbours share at least this many bytes with `ip`.
        var match_length = @min(common_length_smaller, common_length_larger);
        assert(curr > match_index);

        var match: [*]const u8 = undefined;
        if (dict_mode == .no_dict or is_dms or
            @as(usize, match_index) + match_length >= dict_limit)
        {
            match = base + match_index;
            match_length += internal.count(ip + match_length, match + match_length, i_limit);
        } else {
            match = dict_base + match_index;
            match_length += internal.count2Segments(
                ip + match_length,
                match + match_length,
                i_limit,
                dict_end,
                prefix_start,
            );
            // For the read of match[match_length] below.
            if (@as(usize, match_index) + match_length >= dict_limit) match = base + match_index;
        }

        if (match_length > best_length) {
            assert(match_end_idx > match_index);
            if (match_length > match_end_idx - match_index) {
                match_end_idx = match_index + @as(u32, @intCast(match_length));
            }
            best_length = match_length;
            matches[mnum] = .{
                .off = internal.offsetToOffbase(curr - match_index),
                .len = @intCast(match_length),
            };
            mnum += 1;
            // Equal up to the end: whether smaller or larger is unknown.
            // Dropping it keeps the tree sound, at a small cost.
            if (match_length > opt_num or
                @intFromPtr(ip) + match_length == @intFromPtr(i_limit))
            {
                // Skips the dictionary's search too.
                if (is_dms) nb_compares = 0;
                break;
            }
        }

        if (match[match_length] < ip[match_length]) {
            // The match is smaller than the current position.
            smaller_ptr.* = match_index;
            common_length_smaller = match_length;
            if (match_index <= bt_low) {
                smaller_ptr = &dummy32;
                break;
            }
            smaller_ptr = &next_ptr[1];
            match_index = next_ptr[1];
        } else {
            larger_ptr.* = match_index;
            common_length_larger = match_length;
            if (match_index <= bt_low) {
                larger_ptr = &dummy32;
                break;
            }
            larger_ptr = &next_ptr[0];
            match_index = next_ptr[0];
        }
    }

    smaller_ptr.* = 0;
    larger_ptr.* = 0;

    assert(nb_compares <= 1 << params.search_log_max);
    if (is_dms and nb_compares != 0) {
        const dms_h = internal.hashPtr(ip, dms_hash_log, mls);
        var dict_match_index = dms.hash_table[dms_h];
        const dms_bt = dms.chain_table;
        common_length_smaller = 0;
        common_length_larger = 0;
        while (nb_compares != 0 and dict_match_index > dms_low_limit) : (nb_compares -= 1) {
            const next_ptr = dms_bt + 2 * (dict_match_index & dms_bt_mask);
            // Both neighbours share at least this many bytes with `ip`.
            var match_length = @min(common_length_smaller, common_length_larger);
            var match: [*]const u8 = dms_base + dict_match_index;
            match_length += internal.count2Segments(
                ip + match_length,
                match + match_length,
                i_limit,
                dms_end,
                prefix_start,
            );
            // For the read of match[match_length] below.
            if (@as(usize, dict_match_index) + match_length >= dms_high_limit) {
                match = @ptrFromInt(@intFromPtr(base) +% dict_match_index +% dms_index_delta);
            }

            if (match_length > best_length) {
                match_index = dict_match_index +% dms_index_delta;
                if (match_length > match_end_idx -% match_index) {
                    match_end_idx = match_index +% @as(u32, @intCast(match_length));
                }
                best_length = match_length;
                matches[mnum] = .{
                    .off = internal.offsetToOffbase(curr - match_index),
                    .len = @intCast(match_length),
                };
                mnum += 1;
                // Equal up to the end: dropped, to keep the tree sound.
                if (match_length > opt_num or
                    @intFromPtr(ip) + match_length == @intFromPtr(i_limit))
                {
                    break;
                }
            }

            // Past the end of the tree.
            if (dict_match_index <= dms_bt_low) break;
            if (match[match_length] < ip[match_length]) {
                common_length_smaller = match_length;
                dict_match_index = next_ptr[1];
            } else {
                // The match is larger than the current position.
                common_length_larger = match_length;
                dict_match_index = next_ptr[0];
            }
        }
    }

    assert(match_end_idx > curr + 8);
    // Skips repetitive patterns.
    ms.next_to_update = match_end_idx - 8;
    return mnum;
}

/// `ZSTD_getAllMatchesFn`.
const GetAllMatchesFn = *const fn (
    matches: [*]Match,
    ms: *MatchState,
    next_to_update3: *u32,
    ip: [*]const u8,
    i_high_limit: [*]const u8,
    rep: *const [rep_num]u32,
    ll0: u32,
    length_to_beat: u32,
) u32;

/// `ZSTD_btGetAllMatches_internal`: fills the tree up to `ip`, then finds
/// the matches at `ip`; none at a position the tree skipped.
inline fn btGetAllMatchesInternal(
    matches: [*]Match,
    ms: *MatchState,
    next_to_update3: *u32,
    ip: [*]const u8,
    i_high_limit: [*]const u8,
    rep: *const [rep_num]u32,
    ll0: u32,
    length_to_beat: u32,
    comptime dict_mode: DictMode,
    comptime mls: u32,
) u32 {
    assert(std.math.clamp(ms.cparams.min_match, 3, 6) == mls);
    if (@intFromPtr(ip) < @intFromPtr(ms.window.base) +% ms.next_to_update) return 0;
    updateTreeInternal(ms, ip, i_high_limit, mls, dict_mode);
    return insertBtAndGetAllMatches(
        matches,
        ms,
        next_to_update3,
        ip,
        i_high_limit,
        dict_mode,
        rep,
        ll0,
        length_to_beat,
        mls,
    );
}

/// `ZSTD_btGetAllMatches_<dictMode>_<mls>`.
fn btGetAllMatches(comptime dict_mode: DictMode, comptime mls: u32) GetAllMatchesFn {
    return struct {
        fn getAllMatches(
            matches: [*]Match,
            ms: *MatchState,
            next_to_update3: *u32,
            ip: [*]const u8,
            i_high_limit: [*]const u8,
            rep: *const [rep_num]u32,
            ll0: u32,
            length_to_beat: u32,
        ) u32 {
            return btGetAllMatchesInternal(
                matches,
                ms,
                next_to_update3,
                ip,
                i_high_limit,
                rep,
                ll0,
                length_to_beat,
                dict_mode,
                mls,
            );
        }
    }.getAllMatches;
}

/// `ZSTD_selectBtGetAllMatches`: the match finder for `dict_mode` and the
/// match length, 3 to 6.
fn selectBtGetAllMatches(ms: *const MatchState, comptime dict_mode: DictMode) GetAllMatchesFn {
    const get_all_matches_fns = comptime [4]GetAllMatchesFn{
        btGetAllMatches(dict_mode, 3),
        btGetAllMatches(dict_mode, 4),
        btGetAllMatches(dict_mode, 5),
        btGetAllMatches(dict_mode, 6),
    };
    const mls = std.math.clamp(ms.cparams.min_match, 3, 6);
    return get_all_matches_fns[mls - 3];
}

// ---------------------------------------------------------------------------
// Long distance matches
// ---------------------------------------------------------------------------

/// `ZSTD_optLdm_t`: the long distance matcher's candidate for the block.
const OptLdm = struct {
    /// The block's candidates; a copy of the match state's store.
    seq_store: RawSeqStore,
    /// Where the current candidate starts in the block.
    start_pos_in_block: u32,
    /// Where the current candidate ends in the block.
    end_pos_in_block: u32,
    /// The current candidate's offset.
    offset: u32,
};

/// `ZSTD_optLdm_skipRawSeqStoreBytes`: moves `raw_seq_store`'s position on
/// by `nb_bytes`.
fn optLdmSkipRawSeqStoreBytes(raw_seq_store: *RawSeqStore, nb_bytes: usize) void {
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

/// `ZSTD_opt_getNextMatchAndUpdateSeqStore`: the start and end in the block
/// of the next candidate, and the store's position past it.
fn optGetNextMatchAndUpdateSeqStore(
    opt_ldm: *OptLdm,
    curr_pos_in_block: u32,
    block_bytes_remaining: u32,
) void {
    // No candidate for the rest of the block.
    if (opt_ldm.seq_store.size == 0 or opt_ldm.seq_store.pos >= opt_ldm.seq_store.size) {
        opt_ldm.start_pos_in_block = std.math.maxInt(u32);
        opt_ldm.end_pos_in_block = std.math.maxInt(u32);
        return;
    }
    // The literal and match bytes left, after `pos_in_sequence`.
    const curr_seq = opt_ldm.seq_store.seq.?[opt_ldm.seq_store.pos];
    const pos_in_sequence: u32 = @truncate(opt_ldm.seq_store.pos_in_sequence);
    assert(opt_ldm.seq_store.pos_in_sequence <= curr_seq.lit_length + curr_seq.match_length);
    const curr_block_end_pos = curr_pos_in_block + block_bytes_remaining;
    const literals_bytes_remaining = if (opt_ldm.seq_store.pos_in_sequence < curr_seq.lit_length)
        curr_seq.lit_length - pos_in_sequence
    else
        0;
    const match_bytes_remaining = if (literals_bytes_remaining == 0)
        curr_seq.match_length - (pos_in_sequence - curr_seq.lit_length)
    else
        curr_seq.match_length;

    // The literals go past the end of the block: no candidate.
    if (literals_bytes_remaining >= block_bytes_remaining) {
        opt_ldm.start_pos_in_block = std.math.maxInt(u32);
        opt_ldm.end_pos_in_block = std.math.maxInt(u32);
        optLdmSkipRawSeqStoreBytes(&opt_ldm.seq_store, block_bytes_remaining);
        return;
    }

    // The match may be shorter than the minimum here; `optLdmMaybeAddMatch`
    // rejects it then.
    opt_ldm.start_pos_in_block = curr_pos_in_block + literals_bytes_remaining;
    opt_ldm.end_pos_in_block = opt_ldm.start_pos_in_block + match_bytes_remaining;
    opt_ldm.offset = curr_seq.offset;

    if (opt_ldm.end_pos_in_block > curr_block_end_pos) {
        // The match ends past the block: only its start is usable.
        opt_ldm.end_pos_in_block = curr_block_end_pos;
        optLdmSkipRawSeqStoreBytes(&opt_ldm.seq_store, curr_block_end_pos - curr_pos_in_block);
    } else {
        optLdmSkipRawSeqStoreBytes(
            &opt_ldm.seq_store,
            literals_bytes_remaining + match_bytes_remaining,
        );
    }
}

/// `ZSTD_optLdm_maybeAddMatch`: adds the candidate to `matches` if the
/// position is inside it and it is long enough, keeping `matches` ordered by
/// length.
fn optLdmMaybeAddMatch(
    matches: [*]Match,
    nb_matches: *u32,
    opt_ldm: *const OptLdm,
    curr_pos_in_block: u32,
    min_match_len: u32,
) void {
    const pos_diff = curr_pos_in_block -% opt_ldm.start_pos_in_block;
    const candidate_match_length = opt_ldm.end_pos_in_block -%
        opt_ldm.start_pos_in_block -% pos_diff;

    if (curr_pos_in_block < opt_ldm.start_pos_in_block or
        curr_pos_in_block >= opt_ldm.end_pos_in_block or
        candidate_match_length < min_match_len)
    {
        return;
    }

    if (nb_matches.* == 0 or (candidate_match_length > matches[nb_matches.* - 1].len and
        nb_matches.* < opt_num))
    {
        matches[nb_matches.*] = .{
            .off = internal.offsetToOffbase(opt_ldm.offset),
            .len = candidate_match_length,
        };
        nb_matches.* += 1;
    }
}

/// `ZSTD_optLdm_processMatchCandidate`: moves to the next candidate when
/// the position is past the current one, then adds it to `matches` if it
/// fits.
fn optLdmProcessMatchCandidate(
    opt_ldm: *OptLdm,
    matches: [*]Match,
    nb_matches: *u32,
    curr_pos_in_block: u32,
    remaining_bytes: u32,
    min_match_len: u32,
) void {
    if (opt_ldm.seq_store.size == 0 or opt_ldm.seq_store.pos >= opt_ldm.seq_store.size) return;

    if (curr_pos_in_block >= opt_ldm.end_pos_in_block) {
        if (curr_pos_in_block > opt_ldm.end_pos_in_block) {
            // The parser often comes here some bytes past the end of the
            // candidate: skip those too.
            const pos_overshoot = curr_pos_in_block - opt_ldm.end_pos_in_block;
            optLdmSkipRawSeqStoreBytes(&opt_ldm.seq_store, pos_overshoot);
        }
        optGetNextMatchAndUpdateSeqStore(opt_ldm, curr_pos_in_block, remaining_bytes);
    }
    optLdmMaybeAddMatch(matches, nb_matches, opt_ldm, curr_pos_in_block, min_match_len);
}

// ---------------------------------------------------------------------------
// The optimal parser
// ---------------------------------------------------------------------------

/// `LIT_PRICE`.
inline fn litPrice(p: [*]const u8, opt_ptr: *const OptState, comptime opt_level: u32) i32 {
    return @bitCast(rawLiteralsCost(p, 1, opt_ptr, opt_level));
}

/// `LL_PRICE`.
inline fn llPrice(l: u32, opt_ptr: *const OptState, comptime opt_level: u32) i32 {
    return @bitCast(litLengthPrice(l, opt_ptr, opt_level));
}

/// `LL_INCPRICE`: the price change of one more literal.
inline fn llIncPrice(l: u32, opt_ptr: *const OptState, comptime opt_level: u32) i32 {
    return llPrice(l, opt_ptr, opt_level) - llPrice(l - 1, opt_ptr, opt_level);
}

/// `ZSTD_compressBlock_opt_generic`. Level 0 is btopt, 2 is btultra.
inline fn compressBlockOptGeneric(
    ms: *MatchState,
    seq_store: *SeqStore,
    rep: *[rep_num]u32,
    src: []const u8,
    comptime opt_level: u32,
    comptime dict_mode: DictMode,
) usize {
    comptime assert(opt_level <= 2);
    const opt_state_ptr = &ms.opt;
    const istart = src.ptr;
    var ip = istart;
    var anchor = istart;
    const iend = istart + src.len;
    const ilimit = @intFromPtr(iend) -% 8;
    const base = ms.window.base;
    const prefix_start = base + ms.window.dict_limit;
    const cparams = &ms.cparams;

    const getAllMatches = selectBtGetAllMatches(ms, dict_mode);

    const sufficient_len = @min(cparams.target_length, opt_num - 1);
    const min_match_len: u32 = if (cparams.min_match == 3) 3 else 4;
    var next_to_update3 = ms.next_to_update;

    const opt = opt_state_ptr.price_table;
    const matches = opt_state_ptr.match_table;
    var last_stretch = std.mem.zeroes(Optimal);
    var opt_ldm: OptLdm = .{
        .seq_store = if (ms.ldm_seq_store) |store| store.* else internal.null_raw_seq_store,
        .start_pos_in_block = 0,
        .end_pos_in_block = 0,
        .offset = 0,
    };
    optGetNextMatchAndUpdateSeqStore(&opt_ldm, 0, @intCast(src.len));

    rescaleFreqs(opt_state_ptr, src, opt_level);
    ip += @intFromBool(ip == prefix_start);

    while (@intFromPtr(ip) < ilimit) {
        var cur: u32 = 0;
        var last_pos: u32 = 0;

        shortest_path: {
            // The first match.
            {
                const litlen: u32 = @intCast(@intFromPtr(ip) - @intFromPtr(anchor));
                const ll0 = @intFromBool(litlen == 0);
                var nb_matches = getAllMatches(
                    matches,
                    ms,
                    &next_to_update3,
                    ip,
                    iend,
                    rep,
                    ll0,
                    min_match_len,
                );
                optLdmProcessMatchCandidate(
                    &opt_ldm,
                    matches,
                    &nb_matches,
                    @intCast(@intFromPtr(ip) - @intFromPtr(istart)),
                    @intCast(@intFromPtr(iend) - @intFromPtr(ip)),
                    min_match_len,
                );
                if (nb_matches == 0) {
                    ip += 1;
                    continue;
                }

                // In the forward pass, `opt` holds stretches: a match followed
                // by literals, the reverse of a sequence. Each literal of a
                // run can so keep its own match before it.

                // Only literals so far. Their price is the same on every path
                // and left out, but the literal length's price varies.
                opt[0].mlen = 0;
                opt[0].litlen = litlen;
                opt[0].price = llPrice(litlen, opt_state_ptr, opt_level);
                opt[0].rep = rep.*;

                // A long match is taken at once.
                const max_ml_found = matches[nb_matches - 1].len;
                const max_off_base = matches[nb_matches - 1].off;
                if (max_ml_found > sufficient_len) {
                    last_stretch.litlen = 0;
                    last_stretch.mlen = max_ml_found;
                    last_stretch.off = max_off_base;
                    cur = 0;
                    last_pos = max_ml_found;
                    break :shortest_path;
                }

                // The prices of the first matches, from position 0.
                assert(opt[0].price >= 0);
                var pos: u32 = 1;
                while (pos < min_match_len) : (pos += 1) {
                    opt[pos].price = max_price;
                    opt[pos].mlen = 0;
                    opt[pos].litlen = litlen + pos;
                }
                for (matches[0..nb_matches]) |match| {
                    const off_base = match.off;
                    const end = match.len;
                    while (pos <= end) : (pos += 1) {
                        const match_price: i32 = @bitCast(
                            getMatchPrice(off_base, pos, opt_state_ptr, opt_level),
                        );
                        const sequence_price = opt[0].price + match_price;
                        opt[pos].mlen = pos;
                        opt[pos].off = off_base;
                        // The end of a match.
                        opt[pos].litlen = 0;
                        opt[pos].price = sequence_price + llPrice(0, opt_state_ptr, opt_level);
                    }
                }
                last_pos = pos - 1;
                opt[pos].price = max_price;
            }

            // The positions further on.
            cur = 1;
            while (cur <= last_pos) : (cur += 1) {
                const inr = ip + cur;
                assert(cur <= opt_num);

                // One more literal, if that is cheaper.
                {
                    const litlen = opt[cur - 1].litlen + 1;
                    const price = opt[cur - 1].price +
                        litPrice(ip + cur - 1, opt_state_ptr, opt_level) +
                        llIncPrice(litlen, opt_state_ptr, opt_level);
                    assert(price < 1000000000);
                    if (price <= opt[cur].price) {
                        const prev_match = opt[cur];
                        opt[cur] = opt[cur - 1];
                        opt[cur].litlen = litlen;
                        opt[cur].price = price;
                        // The literal replaced a match, and one literal costs
                        // less than none: the match followed by one literal
                        // may be the cheaper way to the next position.
                        if (opt_level >= 1 and
                            prev_match.litlen == 0 and
                            llIncPrice(1, opt_state_ptr, opt_level) < 0 and
                            @intFromPtr(ip + cur) < @intFromPtr(iend))
                        {
                            const with1literal = prev_match.price +
                                litPrice(ip + cur, opt_state_ptr, opt_level) +
                                llIncPrice(1, opt_state_ptr, opt_level);
                            const with_more_literals = price +
                                litPrice(ip + cur, opt_state_ptr, opt_level) +
                                llIncPrice(litlen + 1, opt_state_ptr, opt_level);
                            if (with1literal < with_more_literals and
                                with1literal < opt[cur + 1].price)
                            {
                                // The repeat offsets after the match, before
                                // they are overwritten.
                                const prev = cur - prev_match.mlen;
                                const new_reps = internal.newRep(
                                    &opt[prev].rep,
                                    prev_match.off,
                                    @intFromBool(opt[prev].litlen == 0),
                                );
                                assert(cur >= prev_match.mlen);
                                opt[cur + 1] = prev_match;
                                opt[cur + 1].rep = new_reps.rep;
                                opt[cur + 1].litlen = 1;
                                opt[cur + 1].price = with1literal;
                                if (last_pos < cur + 1) last_pos = cur + 1;
                            }
                        }
                    }
                }

                // The match at `cur` is now chosen: its repeat offsets follow.
                assert(cur >= opt[cur].mlen);
                if (opt[cur].litlen == 0) {
                    const prev = cur - opt[cur].mlen;
                    const new_reps = internal.newRep(
                        &opt[prev].rep,
                        opt[cur].off,
                        @intFromBool(opt[prev].litlen == 0),
                    );
                    opt[cur].rep = new_reps.rep;
                }

                // The last match starts at least 8 bytes before the end.
                if (@intFromPtr(inr) > ilimit) continue;

                if (cur == last_pos) break;

                // Skips positions the next one beats; about 6% faster, for
                // 0.01 of ratio.
                if (opt_level == 0 and
                    opt[cur + 1].price <= opt[cur].price + bitcost_multiplier / 2)
                {
                    continue;
                }

                assert(opt[cur].price >= 0);
                const ll0 = @intFromBool(opt[cur].litlen == 0);
                const previous_price = opt[cur].price;
                const base_price = previous_price + llPrice(0, opt_state_ptr, opt_level);
                var nb_matches = getAllMatches(
                    matches,
                    ms,
                    &next_to_update3,
                    inr,
                    iend,
                    &opt[cur].rep,
                    ll0,
                    min_match_len,
                );

                optLdmProcessMatchCandidate(
                    &opt_ldm,
                    matches,
                    &nb_matches,
                    @intCast(@intFromPtr(inr) - @intFromPtr(istart)),
                    @intCast(@intFromPtr(iend) - @intFromPtr(inr)),
                    min_match_len,
                );

                if (nb_matches == 0) continue;

                {
                    const longest_ml = matches[nb_matches - 1].len;
                    if (longest_ml > sufficient_len or
                        cur + longest_ml >= opt_num or
                        @intFromPtr(ip) + cur + longest_ml >= @intFromPtr(iend))
                    {
                        last_stretch.mlen = longest_ml;
                        last_stretch.off = matches[nb_matches - 1].off;
                        last_stretch.litlen = 0;
                        last_pos = cur + longest_ml;
                        break :shortest_path;
                    }
                }

                // The prices of the matches found at `cur`.
                for (0..nb_matches) |match_nb| {
                    const offset = matches[match_nb].off;
                    const last_ml = matches[match_nb].len;
                    const start_ml = if (match_nb > 0)
                        matches[match_nb - 1].len + 1
                    else
                        min_match_len;

                    // Downwards.
                    var mlen = last_ml;
                    while (mlen >= start_ml) : (mlen -= 1) {
                        const pos = cur + mlen;
                        const match_price: i32 = @bitCast(
                            getMatchPrice(offset, mlen, opt_state_ptr, opt_level),
                        );
                        const price = base_price + match_price;

                        if (pos > last_pos or price < opt[pos].price) {
                            // Fills the positions in between, for later
                            // comparisons.
                            while (last_pos < pos) {
                                last_pos += 1;
                                opt[last_pos].price = max_price;
                                // Not the end of a match.
                                opt[last_pos].litlen = 1;
                            }
                            opt[pos].mlen = mlen;
                            opt[pos].off = offset;
                            opt[pos].litlen = 0;
                            opt[pos].price = price;
                        } else {
                            // Stops early; about 10% faster, for 0.01 of ratio.
                            if (opt_level == 0) break;
                        }
                    }
                }
                opt[last_pos + 1].price = max_price;
            }

            last_stretch = opt[last_pos];
            assert(cur >= last_stretch.mlen);
            cur = last_pos - last_stretch.mlen;
        }

        // The shortest path: `cur`, `last_pos` and `last_stretch` are set.
        assert(opt[0].mlen == 0);
        assert(last_pos >= last_stretch.mlen);
        assert(cur == last_pos - last_stretch.mlen);

        if (last_stretch.mlen == 0) {
            // No match left: every match was turned into literals.
            assert(last_stretch.litlen == (@intFromPtr(ip) - @intFromPtr(anchor)) + last_pos);
            ip += last_pos;
            continue;
        }
        assert(last_stretch.off > 0);

        // The repeat offsets after the path.
        if (last_stretch.litlen == 0) {
            // The path ends on a match.
            const reps = internal.newRep(
                &opt[cur].rep,
                last_stretch.off,
                @intFromBool(opt[cur].litlen == 0),
            );
            rep.* = reps.rep;
        } else {
            rep.* = last_stretch.rep;
            assert(cur >= last_stretch.litlen);
            cur -= last_stretch.litlen;
        }

        // The path goes into `opt` in reverse order, ending at `store_end`,
        // as sequences (literals, then a match) instead of stretches.
        const store_end = cur + 2;
        var store_start = store_end;
        var stretch_pos = cur;

        assert(store_end < internal.opt_size);
        if (last_stretch.litlen > 0) {
            // The last "sequence" is unfinished: literals only.
            opt[store_end].litlen = last_stretch.litlen;
            opt[store_end].mlen = 0;
            store_start = store_end - 1;
            opt[store_start] = last_stretch;
        }
        // Its literal length is fixed below.
        opt[store_end] = last_stretch;
        store_start = store_end;
        while (true) {
            const next_stretch = opt[stretch_pos];
            opt[store_start].litlen = next_stretch.litlen;
            // The start of the segment.
            if (next_stretch.mlen == 0) break;
            store_start -= 1;
            // Its literal length is fixed on the next pass.
            opt[store_start] = next_stretch;
            assert(next_stretch.litlen + next_stretch.mlen <= stretch_pos);
            stretch_pos -= next_stretch.litlen + next_stretch.mlen;
        }

        // Stores the sequences.
        var store_pos = store_start;
        while (store_pos <= store_end) : (store_pos += 1) {
            const llen = opt[store_pos].litlen;
            const mlen = opt[store_pos].mlen;
            const off_base = opt[store_pos].off;
            const advance = llen + mlen;

            if (mlen == 0) {
                // Literals only: the last "sequence", whose literals start
                // the next series. The anchor stays.
                assert(store_pos == store_end);
                ip = anchor + llen;
                continue;
            }

            assert(@intFromPtr(anchor) + llen <= @intFromPtr(iend));
            updateStats(opt_state_ptr, llen, anchor, off_base, mlen);
            internal.storeSeq(seq_store, llen, anchor, iend, off_base, mlen);
            anchor += advance;
            ip = anchor;
        }

        setBasePrices(opt_state_ptr, opt_level);
    }

    // The size of the last literals.
    return @intFromPtr(iend) - @intFromPtr(anchor);
}

/// `ZSTD_compressBlock_opt0`.
fn compressBlockOpt0(
    ms: *MatchState,
    seq_store: *SeqStore,
    rep: *[rep_num]u32,
    src: []const u8,
    comptime dict_mode: DictMode,
) usize {
    return compressBlockOptGeneric(ms, seq_store, rep, src, 0, dict_mode);
}

/// `ZSTD_compressBlock_opt2`.
fn compressBlockOpt2(
    ms: *MatchState,
    seq_store: *SeqStore,
    rep: *[rep_num]u32,
    src: []const u8,
    comptime dict_mode: DictMode,
) usize {
    return compressBlockOptGeneric(ms, seq_store, rep, src, 2, dict_mode);
}

/// `ZSTD_compressBlock_btopt`.
pub fn compressBlockBtopt(
    ms: *MatchState,
    seq_store: *SeqStore,
    rep: *[rep_num]u32,
    src: []const u8,
) usize {
    return compressBlockOpt0(ms, seq_store, rep, src, .no_dict);
}

/// `ZSTD_initStats_ultra`: a first pass over the first block, only to seed
/// the statistics with better values; its sequences are dropped and the
/// history forgotten. Only for a first block with no dictionary and no long
/// distance matches.
fn initStatsUltra(
    ms: *MatchState,
    seq_store: *SeqStore,
    rep: *const [rep_num]u32,
    src: []const u8,
) void {
    // The repeat offsets the first pass updates.
    var tmp_rep = rep.*;

    assert(ms.opt.lit_length_sum == 0);
    assert(seq_store.sequences == seq_store.sequences_start);
    assert(ms.window.dict_limit == ms.window.low_limit);
    // No prefix; wraps on purpose.
    assert(ms.window.dict_limit -% ms.next_to_update <= 1);

    // Collects the statistics into `ms.opt`.
    _ = compressBlockOpt2(ms, seq_store, &tmp_rep, src, .no_dict);

    // Forgets the first pass, but for the statistics.
    internal.resetSeqStore(seq_store);
    ms.window.base = @ptrFromInt(@intFromPtr(ms.window.base) -% src.len);
    ms.window.dict_limit += @intCast(src.len);
    ms.window.low_limit = ms.window.dict_limit;
    ms.next_to_update = ms.window.dict_limit;
}

/// `ZSTD_compressBlock_btultra`.
pub fn compressBlockBtultra(
    ms: *MatchState,
    seq_store: *SeqStore,
    rep: *[rep_num]u32,
    src: []const u8,
) usize {
    return compressBlockOpt2(ms, seq_store, rep, src, .no_dict);
}

/// `ZSTD_compressBlock_btultra2`: btultra, but the first block of a frame
/// is parsed twice, the first pass only seeding the statistics. That needs
/// nothing loaded before it: no dictionary, prefix or long distance matches.
/// It costs twice the time on the first block, for about 0.5% of its size.
pub fn compressBlockBtultra2(
    ms: *MatchState,
    seq_store: *SeqStore,
    rep: *[rep_num]u32,
    src: []const u8,
) usize {
    const curr: u32 = @truncate(@intFromPtr(src.ptr) -% @intFromPtr(ms.window.base));
    assert(src.len <= params.block_size_max);
    if (ms.opt.lit_length_sum == 0 and
        // No long distance matches stored.
        seq_store.sequences == seq_store.sequences_start and
        // No dictionary.
        ms.window.dict_limit == ms.window.low_limit and
        // The start of the frame: nothing loaded or skipped.
        curr == ms.window.dict_limit and
        // Large enough for statistics.
        src.len > predef_threshold)
    {
        initStatsUltra(ms, seq_store, rep, src);
    }

    return compressBlockOpt2(ms, seq_store, rep, src, .no_dict);
}

/// `ZSTD_compressBlock_btopt_dictMatchState`.
pub fn compressBlockBtoptDictMatchState(
    ms: *MatchState,
    seq_store: *SeqStore,
    rep: *[rep_num]u32,
    src: []const u8,
) usize {
    return compressBlockOpt0(ms, seq_store, rep, src, .dict_match_state);
}

/// `ZSTD_compressBlock_btopt_extDict`.
pub fn compressBlockBtoptExtDict(
    ms: *MatchState,
    seq_store: *SeqStore,
    rep: *[rep_num]u32,
    src: []const u8,
) usize {
    return compressBlockOpt0(ms, seq_store, rep, src, .ext_dict);
}

/// `ZSTD_compressBlock_btultra_dictMatchState`.
pub fn compressBlockBtultraDictMatchState(
    ms: *MatchState,
    seq_store: *SeqStore,
    rep: *[rep_num]u32,
    src: []const u8,
) usize {
    return compressBlockOpt2(ms, seq_store, rep, src, .dict_match_state);
}

/// `ZSTD_compressBlock_btultra_extDict`.
pub fn compressBlockBtultraExtDict(
    ms: *MatchState,
    seq_store: *SeqStore,
    rep: *[rep_num]u32,
    src: []const u8,
) usize {
    return compressBlockOpt2(ms, seq_store, rep, src, .ext_dict);
}

// btultra2 has no dictionary variants: it is for the first block of a frame
// with no prefix only.

// --------------------------------------------------------
// Tests
// --------------------------------------------------------

const testing = std.testing;

test "weights: whole bits for btopt, fractions for btultra" {
    // stat + 1 = 1: no bits.
    try testing.expectEqual(@as(u32, 0), bitWeight(0));
    try testing.expectEqual(@as(u32, 1 << 8), fracWeight(0));
    // stat + 1 = 6: 2 whole bits, plus 6/4 in fixed point.
    try testing.expectEqual(@as(u32, 2 * 256), bitWeight(5));
    try testing.expectEqual(@as(u32, 2 * 256 + (6 << 8) / 4), fracWeight(5));
    try testing.expectEqual(bitWeight(77), weight(77, 0));
    try testing.expectEqual(fracWeight(77), weight(77, 2));
    // Weights grow with the statistic.
    var previous: u32 = 0;
    for (0..5000) |stat| {
        const w = fracWeight(@intCast(stat));
        try testing.expect(w >= previous);
        previous = w;
    }
}

test "downscaleStats and scaleStats" {
    var table = [_]u32{ 0, 1, 255, 256, 1000, 70000 };
    const sum = downscaleStats(&table, table.len - 1, 8, .base_0_possible);
    try testing.expectEqualSlices(u32, &.{ 0, 1, 1, 2, 4, 274 }, &table);
    try testing.expectEqual(@as(u32, 282), sum);

    var guaranteed = [_]u32{ 0, 1, 255, 256 };
    _ = downscaleStats(&guaranteed, guaranteed.len - 1, 8, .base_1_guaranteed);
    try testing.expectEqualSlices(u32, &.{ 1, 1, 1, 2 }, &guaranteed);

    // A sum at most twice the target stays as it is.
    var small = [_]u32{ 1000, 1000, 47 };
    try testing.expectEqual(@as(u32, 2047), scaleStats(&small, small.len - 1, 10));
    try testing.expectEqualSlices(u32, &.{ 1000, 1000, 47 }, &small);
    // A sum of 4 times the target: shifted by 2, every count at least 1.
    var large = [_]u32{ 4000, 96, 0 };
    try testing.expectEqual(@as(u32, 1001 + 25 + 1), scaleStats(&large, large.len - 1, 10));
    try testing.expectEqualSlices(u32, &.{ 1001, 25, 1 }, &large);
}

test "the long distance candidates move through the store" {
    var seqs = [_]RawSeq{
        .{ .offset = 100, .lit_length = 10, .match_length = 20 },
        .{ .offset = 200, .lit_length = 0, .match_length = 50 },
        .{ .offset = 300, .lit_length = 1000, .match_length = 40 },
    };
    var opt_ldm: OptLdm = .{
        .seq_store = .{ .seq = &seqs, .size = seqs.len, .capacity = seqs.len },
        .start_pos_in_block = 0,
        .end_pos_in_block = 0,
        .offset = 0,
    };
    optGetNextMatchAndUpdateSeqStore(&opt_ldm, 0, 500);
    try testing.expectEqual(@as(u32, 10), opt_ldm.start_pos_in_block);
    try testing.expectEqual(@as(u32, 30), opt_ldm.end_pos_in_block);
    try testing.expectEqual(@as(usize, 1), opt_ldm.seq_store.pos);

    var matches: [4]Match = undefined;
    var nb_matches: u32 = 0;
    // Before the candidate: nothing.
    optLdmProcessMatchCandidate(&opt_ldm, &matches, &nb_matches, 5, 495, 4);
    try testing.expectEqual(@as(u32, 0), nb_matches);
    // Inside it: its rest.
    optLdmProcessMatchCandidate(&opt_ldm, &matches, &nb_matches, 12, 488, 4);
    try testing.expectEqual(@as(u32, 1), nb_matches);
    try testing.expectEqual(Match{ .off = 103, .len = 18 }, matches[0]);
    // Its last 3 bytes are too short.
    nb_matches = 0;
    optLdmProcessMatchCandidate(&opt_ldm, &matches, &nb_matches, 27, 473, 4);
    try testing.expectEqual(@as(u32, 0), nb_matches);
    // 2 bytes past its end: the next candidate starts 2 bytes in.
    optLdmProcessMatchCandidate(&opt_ldm, &matches, &nb_matches, 32, 468, 4);
    try testing.expectEqual(@as(u32, 32), opt_ldm.start_pos_in_block);
    try testing.expectEqual(@as(u32, 80), opt_ldm.end_pos_in_block);
    try testing.expectEqual(Match{ .off = 203, .len = 48 }, matches[0]);
    // The next one's literals run past the block: none, and the store skips
    // the rest of the block.
    optLdmProcessMatchCandidate(&opt_ldm, &matches, &nb_matches, 80, 420, 4);
    try testing.expectEqual(std.math.maxInt(u32), opt_ldm.start_pos_in_block);
    try testing.expectEqual(@as(usize, 2), opt_ldm.seq_store.pos);
    try testing.expectEqual(@as(usize, 420), opt_ldm.seq_store.pos_in_sequence);
}

test "prices: fixed scheme and statistics" {
    var lit_freq: [max_lit + 1]u32 = @splat(1);
    var ll_freq = base_ll_freqs;
    var ml_freq: [max_ml + 1]u32 = @splat(1);
    var off_freq = base_ofc_freqs;
    var state: OptState = .{
        .lit_freq = &lit_freq,
        .lit_length_freq = &ll_freq,
        .match_length_freq = &ml_freq,
        .off_code_freq = &off_freq,
        .lit_sum = 256,
        .lit_length_sum = sumU32(&base_ll_freqs),
        .match_length_sum = max_ml + 1,
        .off_code_sum = sumU32(&base_ofc_freqs),
        .price_type = .predef,
    };
    setBasePrices(&state, 2);
    const literals = "abcd";
    try testing.expectEqual(@as(u32, 4 * 6 * 256), rawLiteralsCost(literals, 4, &state, 2));
    try testing.expectEqual(fracWeight(7), litLengthPrice(7, &state, 2));
    try testing.expectEqual(fracWeight(1) + (16 + 3) * 256, getMatchPrice(9, 4, &state, 2));

    state.price_type = .dynamic;
    // Every literal equally likely: 8 bits each.
    try testing.expectEqual(
        4 * (fracWeight(256) - fracWeight(1)),
        rawLiteralsCost(literals, 4, &state, 2),
    );
    state.literal_compression_mode = .disable;
    try testing.expectEqual(@as(u32, 4 * 8 * 256), rawLiteralsCost(literals, 4, &state, 2));
    // The whole block's literal length costs one bit more than one less.
    try testing.expectEqual(
        litLengthPrice(params.block_size_max - 1, &state, 0) + 256,
        litLengthPrice(params.block_size_max, &state, 0),
    );
    // btopt handicaps offset codes of 20 and above: 2 bits a code above 19.
    const far = internal.offsetToOffbase(1 << 21);
    const near = internal.offsetToOffbase(1 << 19);
    try testing.expectEqual(
        @as(u32, 2 * 256 + 2 * 2 * 256),
        getMatchPrice(far, 10, &state, 0) - getMatchPrice(near, 10, &state, 0),
    );
    try testing.expectEqual(
        @as(u32, 2 * 256),
        getMatchPrice(far, 10, &state, 2) - getMatchPrice(near, 10, &state, 2),
    );
}

test {
    _ = &compressBlockBtopt;
    _ = &compressBlockBtoptDictMatchState;
    _ = &compressBlockBtoptExtDict;
    _ = &compressBlockBtultra;
    _ = &compressBlockBtultraDictMatchState;
    _ = &compressBlockBtultraExtDict;
    _ = &compressBlockBtultra2;
    _ = &updateTree;
}
