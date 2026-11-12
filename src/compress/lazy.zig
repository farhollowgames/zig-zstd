//! The lazy match finders, from the original's zstd_lazy.c: the greedy, lazy
//! and lazy2 strategies over a hash chain or the row-based match finder,
//! btlazy2 over a binary tree, and the dedicated dictionary search.
//!
//! The original instantiates its search functions by macros over the
//! minimum match length (4 to 6), the row log (4 to 6), the search method
//! and the dictionary mode; here they are compile-time parameters, so each
//! instantiation compiles to code of its own.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");

const params = @import("../params.zig");
const zstd_internal = @import("../common/zstd_internal.zig");
const internal = @import("compress_internal.zig");

const assert = std.debug.assert;
const native_endian = builtin.cpu.arch.endian();
const rep_num = zstd_internal.rep_num;
const MatchState = internal.MatchState;
const SeqStore = internal.SeqStore;
const DictMode = internal.DictMode;
const hot_code_align = internal.hot_code_align;
const CompressionParameters = params.CompressionParameters;
const count = internal.count;
const count2Segments = internal.count2Segments;
const highbit32 = internal.highbit32;
const hashPtr = internal.hashPtr;
const hashPtrSalted = internal.hashPtrSalted;
const offsetToOffbase = internal.offsetToOffbase;
const repcode1_to_offbase = internal.repcode1_to_offbase;

/// The log of the number of entries in a bucket of the dedicated dictionary
/// search's hash table: all but the last are positions, the last a pointer
/// into its chain table.
pub const lazy_ddss_bucket_log = 2;
/// The bits of a row hash kept in the tag table.
pub const row_hash_tag_bits = 8;

/// Past this step over data without matches, only searched positions are
/// inserted.
const lazy_skipping_step = 8;
const row_hash_tag_mask: u32 = (1 << row_hash_tag_bits) - 1;
/// The most entries a row has, in every configuration.
const row_hash_max_entries = 64;
const row_hash_cache_mask = internal.row_hash_cache_size - 1;

/// `searchMethod_e`.
pub const SearchMethod = enum(u32) { hash_chain = 0, binary_tree = 1, row_hash = 2 };

// ---------------------------------------------------------------------------
// Binary tree search
// ---------------------------------------------------------------------------

/// `ZSTD_updateDUBT`: adds the positions from `next_to_update` up to `ip` to
/// the hash table and, unsorted, to the tree, as a chain would.
fn updateDUBT(ms: *MatchState, ip: [*]const u8, iend: [*]const u8, comptime mls: u32) void {
    const cparams = &ms.cparams;
    const hash_table = ms.hash_table;
    const hash_log = cparams.hash_log;

    const bt = ms.chain_table;
    const bt_log = cparams.chain_log - 1;
    const bt_mask = (@as(u32, 1) << @intCast(bt_log)) - 1;

    const base = ms.window.base;
    const target: u32 = @truncate(@intFromPtr(ip) -% @intFromPtr(base));
    var idx = ms.next_to_update;

    // The hash reads 8 bytes.
    assert(@intFromPtr(ip) + 8 <= @intFromPtr(iend));
    // So that base + idx is valid.
    assert(idx >= ms.window.dict_limit);
    while (idx < target) : (idx += 1) {
        const h = hashPtr(base + idx, hash_log, mls);
        const match_index = hash_table[h];

        const next_candidate = bt + 2 * (idx & bt_mask);
        hash_table[h] = idx;
        next_candidate[0] = match_index;
        next_candidate[1] = internal.dubt_unsorted_mark;
    }
    ms.next_to_update = target;
}

/// `ZSTD_insertDUBT1`: sorts one position already inserted but unsorted
/// into the tree. `curr` is at least `bt_low`.
fn insertDUBT1(
    ms: *const MatchState,
    curr: u32,
    input_end: [*]const u8,
    nb_compares_max: u32,
    bt_low: u32,
    comptime dict_mode: DictMode,
) void {
    const cparams = &ms.cparams;
    const bt = ms.chain_table;
    const bt_log = cparams.chain_log - 1;
    const bt_mask = (@as(u32, 1) << @intCast(bt_log)) - 1;
    var common_length_smaller: usize = 0;
    var common_length_larger: usize = 0;
    const base = ms.window.base;
    const dict_base = ms.window.dict_base;
    const dict_limit = ms.window.dict_limit;
    const ip = if (curr >= dict_limit) base + curr else dict_base + curr;
    const iend = if (curr >= dict_limit) input_end else dict_base + dict_limit;
    const dict_end = dict_base + dict_limit;
    const prefix_start = base + dict_limit;
    var smaller_ptr: *u32 = &bt[2 * (curr & bt_mask)];
    var larger_ptr: *u32 = &bt[2 * (curr & bt_mask) + 1];
    // The candidate is unsorted: the next sorted candidate is at its smaller
    // entry, and its larger entry holds the previous unsorted candidate,
    // already saved, so it can be overwritten.
    var match_index = smaller_ptr.*;
    // Takes the last write when the search stops past the tree's end.
    var dummy32: u32 = undefined;
    const window_valid = ms.window.low_limit;
    const max_distance = @as(u32, 1) << @intCast(cparams.window_log);
    const window_low = if (curr -% window_valid > max_distance)
        curr - max_distance
    else
        window_valid;
    var nb_compares = nb_compares_max;

    assert(curr >= bt_low);
    // ZSTD_count reads up to iend.
    assert(@intFromPtr(ip) < @intFromPtr(iend));

    while (nb_compares != 0 and match_index > window_low) : (nb_compares -= 1) {
        const next_ptr = bt + 2 * (match_index & bt_mask);
        // The bytes every candidate further on shares with ip.
        var match_length = @min(common_length_smaller, common_length_larger);
        var match: [*]const u8 = undefined;
        assert(match_index < curr);
        // Every candidate is sorted now, though a real index can equal the
        // unsorted mark.

        if (dict_mode != .ext_dict or
            match_index + match_length >= dict_limit or // Both in the prefix.
            curr < dict_limit) // Both in the external dictionary.
        {
            const in_prefix = dict_mode != .ext_dict or match_index + match_length >= dict_limit;
            const m_base = if (in_prefix) base else dict_base;
            match = m_base + match_index;
            match_length += count(ip + match_length, match + match_length, iend);
        } else {
            match = dict_base + match_index;
            match_length += count2Segments(
                ip + match_length,
                match + match_length,
                iend,
                dict_end,
                prefix_start,
            );
            // For the read of match[match_length] below.
            if (match_index + match_length >= dict_limit) match = base + match_index;
        }

        // Equal to the end: whether it is smaller or larger is unknown. It is
        // dropped, which costs a little ratio but keeps the tree consistent.
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
}

/// `ZSTD_DUBT_findBetterDictMatch`: searches the dictionary's tree for a
/// match better than `best_length`, with the compares left.
fn dubtFindBetterDictMatch(
    ms: *const MatchState,
    ip: [*]const u8,
    iend: [*]const u8,
    offset_ptr: *usize,
    best_length_found: usize,
    nb_compares_left: u32,
    comptime mls: u32,
    comptime dict_mode: DictMode,
) usize {
    comptime assert(dict_mode == .dict_match_state);
    const dms = ms.dict_match_state.?;
    const dms_cparams = &dms.cparams;
    const dict_hash_table = dms.hash_table;
    const hash_log = dms_cparams.hash_log;
    const h = hashPtr(ip, hash_log, mls);
    var dict_match_index = dict_hash_table[h];

    const base = ms.window.base;
    const prefix_start = base + ms.window.dict_limit;
    const curr: u32 = @truncate(@intFromPtr(ip) -% @intFromPtr(base));
    const dict_base = dms.window.base;
    const dict_end = dms.window.next_src;
    const dict_high_limit: u32 = @truncate(@intFromPtr(dms.window.next_src) -%
        @intFromPtr(dms.window.base));
    const dict_low_limit = dms.window.low_limit;
    const dict_index_delta = ms.window.low_limit - dict_high_limit;

    const dict_bt = dms.chain_table;
    const bt_log = dms_cparams.chain_log - 1;
    const bt_mask = (@as(u32, 1) << @intCast(bt_log)) - 1;
    const bt_low = if (bt_mask >= dict_high_limit - dict_low_limit)
        dict_low_limit
    else
        dict_high_limit - bt_mask;

    var common_length_smaller: usize = 0;
    var common_length_larger: usize = 0;
    var best_length = best_length_found;
    var nb_compares = nb_compares_left;

    while (nb_compares != 0 and dict_match_index > dict_low_limit) : (nb_compares -= 1) {
        const next_ptr = dict_bt + 2 * (dict_match_index & bt_mask);
        var match_length = @min(common_length_smaller, common_length_larger);
        var match = dict_base + dict_match_index;
        match_length += count2Segments(
            ip + match_length,
            match + match_length,
            iend,
            dict_end,
            prefix_start,
        );
        // For the read of match[match_length] below.
        if (dict_match_index + match_length >= dict_high_limit) {
            match = base + dict_match_index + dict_index_delta;
        }

        if (match_length > best_length) {
            const match_index = dict_match_index + dict_index_delta;
            const gain: i32 = 4 * @as(i32, @intCast(match_length - best_length));
            const cost: i32 = @bitCast(highbit32(curr - match_index + 1) -%
                highbit32(@as(u32, @truncate(offset_ptr.*)) + 1));
            if (gain > cost) {
                best_length = match_length;
                offset_ptr.* = offsetToOffbase(curr - match_index);
            }
            // At the end of the input ip[match_length] is not valid: whether
            // the match is smaller or larger is unknown, so the search ends.
            if (@intFromPtr(ip) + match_length == @intFromPtr(iend)) break;
        }

        if (match[match_length] < ip[match_length]) {
            if (dict_match_index <= bt_low) break;
            common_length_smaller = match_length;
            dict_match_index = next_ptr[1];
        } else {
            // The match is larger than the current position.
            if (dict_match_index <= bt_low) break;
            common_length_larger = match_length;
            dict_match_index = next_ptr[0];
        }
    }
    return best_length;
}

/// `ZSTD_DUBT_findBestMatch`: sorts the unsorted candidates of ip's hash,
/// then searches the tree for the longest match, inserting ip.
fn dubtFindBestMatch(
    ms: *MatchState,
    ip: [*]const u8,
    iend: [*]const u8,
    off_base_ptr: *usize,
    comptime mls: u32,
    comptime dict_mode: DictMode,
) usize {
    comptime assert(dict_mode != .dedicated_dict_search);
    const cparams = &ms.cparams;
    const hash_table = ms.hash_table;
    const hash_log = cparams.hash_log;
    const h = hashPtr(ip, hash_log, mls);
    var match_index = hash_table[h];

    const base = ms.window.base;
    const curr: u32 = @truncate(@intFromPtr(ip) -% @intFromPtr(base));
    const window_low = internal.getLowestMatchIndex(ms, curr, cparams.window_log);

    const bt = ms.chain_table;
    const bt_log = cparams.chain_log - 1;
    const bt_mask = (@as(u32, 1) << @intCast(bt_log)) - 1;
    const bt_low = if (bt_mask >= curr) 0 else curr - bt_mask;
    const unsort_limit = @max(bt_low, window_low);

    var next_candidate: *u32 = &bt[2 * (match_index & bt_mask)];
    var unsorted_mark: *u32 = &bt[2 * (match_index & bt_mask) + 1];
    var nb_compares = @as(u32, 1) << @intCast(cparams.search_log);
    var nb_candidates = nb_compares;
    var previous_candidate: u32 = 0;

    // The hash reads 8 bytes.
    assert(@intFromPtr(ip) <= @intFromPtr(iend) - 8);

    // Walk to the end of the unsorted candidates.
    while (match_index > unsort_limit and
        unsorted_mark.* == internal.dubt_unsorted_mark and
        nb_candidates > 1)
    {
        // The unsorted marks become a chain back to the first candidate.
        unsorted_mark.* = previous_candidate;
        previous_candidate = match_index;
        match_index = next_candidate.*;
        next_candidate = &bt[2 * (match_index & bt_mask)];
        unsorted_mark = &bt[2 * (match_index & bt_mask) + 1];
        nb_candidates -= 1;
    }

    // A last candidate still unsorted is dropped: a little worse ratio for
    // speed.
    if (match_index > unsort_limit and unsorted_mark.* == internal.dubt_unsorted_mark) {
        next_candidate.* = 0;
        unsorted_mark.* = 0;
    }

    // Sort the candidates stacked, back to the first; ends on index 0.
    match_index = previous_candidate;
    while (match_index != 0) {
        const next_candidate_idx = bt[2 * (match_index & bt_mask) + 1];
        insertDUBT1(ms, match_index, iend, nb_candidates, unsort_limit, dict_mode);
        match_index = next_candidate_idx;
        nb_candidates += 1;
    }

    // Find the longest match.
    var common_length_smaller: usize = 0;
    var common_length_larger: usize = 0;
    const dict_base = ms.window.dict_base;
    const dict_limit = ms.window.dict_limit;
    const dict_end = dict_base + dict_limit;
    const prefix_start = base + dict_limit;
    var smaller_ptr: *u32 = &bt[2 * (curr & bt_mask)];
    var larger_ptr: *u32 = &bt[2 * (curr & bt_mask) + 1];
    var match_end_idx = curr + 8 + 1;
    // Takes the last write when the search stops past the tree's end.
    var dummy32: u32 = undefined;
    var best_length: usize = 0;

    match_index = hash_table[h];
    hash_table[h] = curr;

    while (nb_compares != 0 and match_index > window_low) : (nb_compares -= 1) {
        const next_ptr = bt + 2 * (match_index & bt_mask);
        var match_length = @min(common_length_smaller, common_length_larger);
        var match: [*]const u8 = undefined;

        if (dict_mode != .ext_dict or match_index + match_length >= dict_limit) {
            match = base + match_index;
            match_length += count(ip + match_length, match + match_length, iend);
        } else {
            match = dict_base + match_index;
            match_length += count2Segments(
                ip + match_length,
                match + match_length,
                iend,
                dict_end,
                prefix_start,
            );
            // For the read of match[match_length] below.
            if (match_index + match_length >= dict_limit) match = base + match_index;
        }

        if (match_length > best_length) {
            if (match_length > match_end_idx - match_index) {
                match_end_idx = match_index + @as(u32, @intCast(match_length));
            }
            const gain: i32 = 4 * @as(i32, @intCast(match_length - best_length));
            const cost: i32 = @bitCast(highbit32(curr - match_index + 1) -%
                highbit32(@truncate(off_base_ptr.*)));
            if (gain > cost) {
                best_length = match_length;
                off_base_ptr.* = offsetToOffbase(curr - match_index);
            }
            // Equal to the end: whether it is smaller or larger is unknown.
            // Dropped, for consistency, at a little cost in ratio.
            if (@intFromPtr(ip) + match_length == @intFromPtr(iend)) {
                // No compares left for the dictionary either.
                if (dict_mode == .dict_match_state) nb_compares = 0;
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

    assert(nb_compares <= 1 << params.search_log_max);
    if (dict_mode == .dict_match_state and nb_compares != 0) {
        best_length = dubtFindBetterDictMatch(
            ms,
            ip,
            iend,
            off_base_ptr,
            best_length,
            nb_compares,
            mls,
            dict_mode,
        );
    }

    // Skips repetitive patterns.
    ms.next_to_update = match_end_idx - 8;
    return best_length;
}

/// `ZSTD_BtFindBestMatch`: updates the tree up to ip, then finds the best
/// match there.
inline fn btFindBestMatch(
    ms: *MatchState,
    ip: [*]const u8,
    i_limit: [*]const u8,
    off_base_ptr: *usize,
    comptime mls: u32,
    comptime dict_mode: DictMode,
) usize {
    // A position skipped after a long match.
    if (@intFromPtr(ip) < @intFromPtr(ms.window.base + ms.next_to_update)) return 0;
    updateDUBT(ms, ip, i_limit, mls);
    return dubtFindBestMatch(ms, ip, i_limit, off_base_ptr, mls, dict_mode);
}

// ---------------------------------------------------------------------------
// Dedicated dictionary search
// ---------------------------------------------------------------------------

/// `ZSTD_dedicatedDictSearch_lazy_loadDictionary`: fills a dictionary's
/// tables for the dedicated search, up to `ip`. Each bucket of the hash
/// table holds the latest positions of its hash and, in its last entry, the
/// start and length of the rest of its chain in the chain table.
pub fn dedicatedDictSearchLazyLoadDictionary(ms: *MatchState, ip: [*]const u8) void {
    const base = ms.window.base;
    const target: u32 = @truncate(@intFromPtr(ip) -% @intFromPtr(base));
    const hash_table = ms.hash_table;
    const chain_table = ms.chain_table;
    const chain_size = @as(u32, 1) << @intCast(ms.cparams.chain_log);
    var idx = ms.next_to_update;
    const min_chain = if (chain_size < target - idx) target - chain_size else idx;
    const bucket_size: u32 = 1 << lazy_ddss_bucket_log;
    const cache_size = bucket_size - 1;
    // Wraps for a search log below 2, which then takes the limit.
    const chain_attempts = (@as(u32, 1) << @intCast(ms.cparams.search_log)) -% cache_size;
    const chain_limit = if (chain_attempts > 255) 255 else chain_attempts;

    // The hash table is larger by a factor of `bucket_size`: for now it keeps
    // one entry per hash, and the rest of its space holds a temporary chain
    // table.
    const hash_log = ms.cparams.hash_log - lazy_ddss_bucket_log;
    const tmp_hash_table = hash_table;
    const tmp_chain_table = hash_table + (@as(usize, 1) << @intCast(hash_log));
    const tmp_chain_size: u32 = @as(u32, (1 << lazy_ddss_bucket_log) - 1) << @intCast(hash_log);
    const tmp_min_chain = if (tmp_chain_size < target) target - tmp_chain_size else idx;

    assert(ms.cparams.chain_log <= 24);
    assert(ms.cparams.hash_log > ms.cparams.chain_log);
    assert(idx != 0);
    assert(tmp_min_chain <= min_chain);

    // Fill a plain hash table and chain table.
    while (idx < target) : (idx += 1) {
        const h: u32 = @intCast(hashPtr(base + idx, hash_log, ms.cparams.min_match));
        if (idx >= tmp_min_chain) tmp_chain_table[idx - tmp_min_chain] = hash_table[h];
        tmp_hash_table[h] = idx;
    }

    // Sort the chains into the chain table.
    {
        var chain_pos: u32 = 0;
        var hash_idx: u32 = 0;
        while (hash_idx < @as(u32, 1) << @intCast(hash_log)) : (hash_idx += 1) {
            var chain_count: u32 = 0;
            var count_beyond_min_chain: u32 = 0;
            var i = tmp_hash_table[hash_idx];
            while (i >= tmp_min_chain and chain_count < cache_size) : (chain_count += 1) {
                // Skip to the first position past the bucket's cache.
                if (i < min_chain) count_beyond_min_chain += 1;
                i = tmp_chain_table[i - tmp_min_chain];
            }
            if (chain_count == cache_size) {
                chain_count = 0;
                while (chain_count < chain_limit) {
                    if (i < min_chain) {
                        // Only `cache_size` entries beyond `min_chain` may be
                        // pulled in, to replace those the cache took out of
                        // the chain table. This reaches further back with as
                        // many entries in all, so the chains fit in the space
                        // of a regular chain table.
                        if (i == 0) break;
                        count_beyond_min_chain += 1;
                        if (count_beyond_min_chain > cache_size) break;
                    }
                    chain_table[chain_pos] = i;
                    chain_pos += 1;
                    chain_count += 1;
                    if (i < tmp_min_chain) break;
                    i = tmp_chain_table[i - tmp_min_chain];
                }
            } else {
                chain_count = 0;
            }
            tmp_hash_table[hash_idx] = if (chain_count != 0)
                ((chain_pos - chain_count) << 8) + chain_count
            else
                0;
        }
        assert(chain_pos <= chain_size);
    }

    // Move the chain pointers into the last entry of each bucket, from the
    // last bucket down, so that no entry is overwritten before it is read.
    {
        var hash_idx: u32 = @as(u32, 1) << @intCast(hash_log);
        while (hash_idx != 0) {
            hash_idx -= 1;
            const bucket_idx = hash_idx << lazy_ddss_bucket_log;
            const chain_packed_pointer = tmp_hash_table[hash_idx];
            for (0..cache_size) |i| hash_table[bucket_idx + i] = 0;
            hash_table[bucket_idx + bucket_size - 1] = chain_packed_pointer;
        }
    }

    // Fill the buckets of the hash table.
    idx = ms.next_to_update;
    while (idx < target) : (idx += 1) {
        const hash: u32 = @intCast(hashPtr(base + idx, hash_log, ms.cparams.min_match));
        const h = hash << lazy_ddss_bucket_log;
        // Shift the bucket's cache down by one.
        var i: u32 = cache_size - 1;
        while (i != 0) : (i -= 1) hash_table[h + i] = hash_table[h + i - 1];
        hash_table[h] = idx;
    }

    ms.next_to_update = target;
}

/// `ZSTD_dedicatedDictSearch_lazy_search`: the longest match in the
/// dedicated search's tables of `dms`, if longer than `ml`; else `ml`.
inline fn dedicatedDictSearchLazySearch(
    offset_ptr: *usize,
    ml_found: usize,
    nb_attempts: u32,
    dms: *const MatchState,
    ip: [*]const u8,
    i_limit: [*]const u8,
    prefix_start: [*]const u8,
    curr: u32,
    dict_limit: u32,
    dds_idx: usize,
) usize {
    var ml = ml_found;
    const dds_lowest_index = dms.window.dict_limit;
    const dds_base = dms.window.base;
    const dds_end = dms.window.next_src;
    const dds_size: u32 = @truncate(@intFromPtr(dds_end) -% @intFromPtr(dds_base));
    const dds_index_delta = dict_limit - dds_size;
    const bucket_size: u32 = 1 << lazy_ddss_bucket_log;
    const bucket_limit = if (nb_attempts < bucket_size - 1) nb_attempts else bucket_size - 1;

    for (0..bucket_size - 1) |i| @prefetch(dds_base + dms.hash_table[dds_idx + i], .{});
    {
        const chain_packed_pointer = dms.hash_table[dds_idx + bucket_size - 1];
        const chain_index = chain_packed_pointer >> 8;
        @prefetch(dms.chain_table + chain_index, .{});
    }

    var dds_attempt: u32 = 0;
    while (dds_attempt < bucket_limit) : (dds_attempt += 1) {
        var current_ml: usize = 0;
        const match_index = dms.hash_table[dds_idx + dds_attempt];
        const match = dds_base + match_index;

        if (match_index == 0) return ml;

        // The table's construction promises both.
        assert(match_index >= dds_lowest_index);
        assert(@intFromPtr(match) + 4 <= @intFromPtr(dds_end));
        if (std.mem.readInt(u32, match[0..4], native_endian) ==
            std.mem.readInt(u32, ip[0..4], native_endian))
        {
            // match_index is at most dict_limit - 4, by the table's construction.
            current_ml = count2Segments(ip + 4, match + 4, i_limit, dds_end, prefix_start) + 4;
        }

        if (current_ml > ml) {
            ml = current_ml;
            offset_ptr.* = offsetToOffbase(curr - (match_index + dds_index_delta));
            // The longest possible, and the next attempt could read past the end.
            if (@intFromPtr(ip) + current_ml == @intFromPtr(i_limit)) return ml;
        }
    }

    {
        const chain_packed_pointer = dms.hash_table[dds_idx + bucket_size - 1];
        var chain_index = chain_packed_pointer >> 8;
        const chain_length = chain_packed_pointer & 0xFF;
        const chain_attempts = nb_attempts - dds_attempt;
        const chain_limit = if (chain_attempts > chain_length) chain_length else chain_attempts;

        for (0..chain_limit) |i| @prefetch(dds_base + dms.chain_table[chain_index + i], .{});

        var chain_attempt: u32 = 0;
        while (chain_attempt < chain_limit) : ({
            chain_attempt += 1;
            chain_index += 1;
        }) {
            var current_ml: usize = 0;
            const match_index = dms.chain_table[chain_index];
            const match = dds_base + match_index;

            // The table's construction promises both.
            assert(match_index >= dds_lowest_index);
            assert(@intFromPtr(match) + 4 <= @intFromPtr(dds_end));
            if (std.mem.readInt(u32, match[0..4], native_endian) ==
                std.mem.readInt(u32, ip[0..4], native_endian))
            {
                current_ml = count2Segments(ip + 4, match + 4, i_limit, dds_end, prefix_start) +
                    4;
            }

            if (current_ml > ml) {
                ml = current_ml;
                offset_ptr.* = offsetToOffbase(curr - (match_index + dds_index_delta));
                if (@intFromPtr(ip) + current_ml == @intFromPtr(i_limit)) break;
            }
        }
    }
    return ml;
}

// ---------------------------------------------------------------------------
// Hash chain
// ---------------------------------------------------------------------------

/// `ZSTD_insertAndFindFirstIndex_internal`: adds the positions up to ip
/// (excluded) to the chains and returns the latest position with ip's hash.
/// Every position is in the prefix.
inline fn insertAndFindFirstIndexInternal(
    ms: *MatchState,
    cparams: *const CompressionParameters,
    ip: [*]const u8,
    mls: u32,
    lazy_skipping: bool,
) u32 {
    const hash_table = ms.hash_table;
    const hash_log = cparams.hash_log;
    const chain_table = ms.chain_table;
    const chain_mask = (@as(u32, 1) << @intCast(cparams.chain_log)) - 1;
    const base = ms.window.base;
    const target: u32 = @truncate(@intFromPtr(ip) -% @intFromPtr(base));
    var idx = ms.next_to_update;

    while (idx < target) {
        const h = hashPtr(base + idx, hash_log, mls);
        chain_table[idx & chain_mask] = hash_table[h];
        hash_table[h] = idx;
        idx += 1;
        // In lazy skipping mode, not every position is inserted.
        if (lazy_skipping) break;
    }

    ms.next_to_update = target;
    return hash_table[hashPtr(ip, hash_log, mls)];
}

/// `ZSTD_insertAndFindFirstIndex`: adds the positions up to ip to the hash
/// chains, for the dictionary loader.
pub fn insertAndFindFirstIndex(ms: *MatchState, ip: [*]const u8) u32 {
    return insertAndFindFirstIndexInternal(ms, &ms.cparams, ip, ms.cparams.min_match, false);
}

/// `ZSTD_HcFindBestMatch`: the longest match at ip down the hash chain, then
/// in the dictionary.
inline fn hcFindBestMatch(
    ms: *MatchState,
    ip: [*]const u8,
    i_limit: [*]const u8,
    offset_ptr: *usize,
    comptime mls: u32,
    comptime dict_mode: DictMode,
) usize {
    const cparams = &ms.cparams;
    const chain_table = ms.chain_table;
    const chain_size = @as(u32, 1) << @intCast(cparams.chain_log);
    const chain_mask = chain_size - 1;
    const base = ms.window.base;
    const dict_base = ms.window.dict_base;
    const dict_limit = ms.window.dict_limit;
    const prefix_start = base + dict_limit;
    const dict_end = dict_base + dict_limit;
    const curr: u32 = @truncate(@intFromPtr(ip) -% @intFromPtr(base));
    const max_distance = @as(u32, 1) << @intCast(cparams.window_log);
    const lowest_valid = ms.window.low_limit;
    const within_max_distance = if (curr -% lowest_valid > max_distance)
        curr - max_distance
    else
        lowest_valid;
    const is_dictionary = ms.loaded_dict_end != 0;
    const low_limit = if (is_dictionary) lowest_valid else within_max_distance;
    const min_chain = if (curr > chain_size) curr - chain_size else 0;
    var nb_attempts = @as(u32, 1) << @intCast(cparams.search_log);
    var ml: usize = 4 - 1;

    const dms = ms.dict_match_state;
    const dds_hash_log: u32 = if (dict_mode == .dedicated_dict_search)
        dms.?.cparams.hash_log - lazy_ddss_bucket_log
    else
        0;
    const dds_idx: usize = if (dict_mode == .dedicated_dict_search)
        hashPtr(ip, dds_hash_log, mls) << lazy_ddss_bucket_log
    else
        0;

    if (dict_mode == .dedicated_dict_search) @prefetch(dms.?.hash_table + dds_idx, .{});

    var match_index = insertAndFindFirstIndexInternal(ms, cparams, ip, mls, ms.lazy_skipping);

    while ((match_index >= low_limit) & (nb_attempts > 0)) : (nb_attempts -= 1) {
        var current_ml: usize = 0;
        if (dict_mode != .ext_dict or match_index >= dict_limit) {
            const match = base + match_index;
            // Without an external dictionary, every candidate is in the prefix.
            assert(match_index >= dict_limit);
            // The 4 bytes ending at match + ml: a candidate that differs there
            // is no longer than the best so far.
            if (std.mem.readInt(u32, (match + ml - 3)[0..4], native_endian) ==
                std.mem.readInt(u32, (ip + ml - 3)[0..4], native_endian))
            {
                current_ml = count(ip, match, i_limit);
            }
        } else {
            const match = dict_base + match_index;
            assert(@intFromPtr(match) + 4 <= @intFromPtr(dict_end));
            // match_index is at most dict_limit - 4, by the table's construction.
            if (std.mem.readInt(u32, match[0..4], native_endian) ==
                std.mem.readInt(u32, ip[0..4], native_endian))
            {
                current_ml = count2Segments(ip + 4, match + 4, i_limit, dict_end, prefix_start) +
                    4;
            }
        }

        if (current_ml > ml) {
            ml = current_ml;
            offset_ptr.* = offsetToOffbase(curr - match_index);
            // The longest possible, and the next attempt could read past the end.
            if (@intFromPtr(ip) + current_ml == @intFromPtr(i_limit)) break;
        }

        if (match_index <= min_chain) break;
        match_index = chain_table[match_index & chain_mask];
    }

    assert(nb_attempts <= 1 << params.search_log_max);
    if (dict_mode == .dedicated_dict_search) {
        ml = dedicatedDictSearchLazySearch(
            offset_ptr,
            ml,
            nb_attempts,
            dms.?,
            ip,
            i_limit,
            prefix_start,
            curr,
            dict_limit,
            dds_idx,
        );
    } else if (dict_mode == .dict_match_state) {
        const d = dms.?;
        const dms_chain_table = d.chain_table;
        const dms_chain_size = @as(u32, 1) << @intCast(d.cparams.chain_log);
        const dms_chain_mask = dms_chain_size - 1;
        const dms_lowest_index = d.window.dict_limit;
        const dms_base = d.window.base;
        const dms_end = d.window.next_src;
        const dms_size: u32 = @truncate(@intFromPtr(dms_end) -% @intFromPtr(dms_base));
        const dms_index_delta = dict_limit - dms_size;
        const dms_min_chain = if (dms_size > dms_chain_size) dms_size - dms_chain_size else 0;

        match_index = d.hash_table[hashPtr(ip, d.cparams.hash_log, mls)];

        while ((match_index >= dms_lowest_index) & (nb_attempts > 0)) : (nb_attempts -= 1) {
            var current_ml: usize = 0;
            const match = dms_base + match_index;
            assert(@intFromPtr(match) + 4 <= @intFromPtr(dms_end));
            if (std.mem.readInt(u32, match[0..4], native_endian) ==
                std.mem.readInt(u32, ip[0..4], native_endian))
            {
                current_ml = count2Segments(ip + 4, match + 4, i_limit, dms_end, prefix_start) + 4;
            }

            if (current_ml > ml) {
                ml = current_ml;
                assert(curr > match_index + dms_index_delta);
                offset_ptr.* = offsetToOffbase(curr - (match_index + dms_index_delta));
                if (@intFromPtr(ip) + current_ml == @intFromPtr(i_limit)) break;
            }

            if (match_index <= dms_min_chain) break;

            match_index = dms_chain_table[match_index & dms_chain_mask];
        }
    }

    return ml;
}

// ---------------------------------------------------------------------------
// Row-based match finder
// ---------------------------------------------------------------------------

// The hash of a position splits into a row and an 8-bit tag. The hash table
// is cut into rows of 16, 32 or 64 entries, each a circular buffer whose
// head is the first byte of its row in the tag table; the other bytes hold
// the tags of the entries. A search compares the row's tags with ip's tag
// at once, and checks only the entries whose tags match. The hash is salted
// by a value that changes when the context is reset, so that a table reused
// without clearing does not give stale matches.

/// The tag compare the row matcher takes: the original's SSE2 or NEON path,
/// in `@Vector` form, where the original takes them; with intrinsics on, the
/// SSE2 form on any other little-endian target; the scalar SWAR path with
/// intrinsics off and on big-endian targets, as in the original.
const MaskPath = enum { sse2, neon, swar };

const mask_path: MaskPath = blk: {
    if (!build_options.intrinsics) break :blk .swar;
    if (native_endian != .little) break :blk .swar;
    const cpu = builtin.cpu;
    if (cpu.arch.isX86()) break :blk .sse2;
    if (cpu.arch.isAarch64()) break :blk .neon;
    if (cpu.arch.isArm() and std.Target.arm.featureSetHas(cpu.features, .neon)) break :blk .neon;
    break :blk .sse2;
};

/// `ZSTD_row_nextIndex`: the next entry of a row to write, moving its head
/// back by one; entry 0 holds the head, so it is skipped.
inline fn rowNextIndex(tag_row: [*]u8, row_mask: u32) u32 {
    var next = (@as(u32, tag_row[0]) -% 1) & row_mask;
    next += if (next == 0) row_mask else 0;
    tag_row[0] = @intCast(next);
    return next;
}

/// `ZSTD_row_prefetch`: prefetches one row of the hash table and the tag table.
inline fn rowPrefetch(
    hash_table: [*]const u32,
    tag_table: [*]const u8,
    rel_row: u32,
    row_log: u32,
) void {
    @prefetch(hash_table + rel_row, .{});
    if (row_log >= 5) {
        // More of the hash table does not help for rows of 64 entries.
        @prefetch(hash_table + rel_row + 16, .{});
    }
    @prefetch(tag_table + rel_row, .{});
    if (row_log == 6) @prefetch(tag_table + rel_row + 32, .{});
    assert(row_log == 4 or row_log == 5 or row_log == 6);
    // The workspace aligns the tables so: a row of hashes is 64-byte
    // aligned, a row of tags aligned to its size.
    assert(std.mem.isAligned(@intFromPtr(hash_table + rel_row), 64));
    assert(std.mem.isAligned(@intFromPtr(tag_table + rel_row), @as(usize, 1) << @intCast(row_log)));
}

/// `ZSTD_row_fillHashCache`: fills the hash cache from `idx`, prefetching up
/// to `row_hash_cache_size` rows, not past `i_limit`.
inline fn rowFillHashCache(
    ms: *MatchState,
    base: [*]const u8,
    row_log: u32,
    mls: u32,
    idx_start: u32,
    i_limit: [*]const u8,
) void {
    const hash_table = ms.hash_table;
    const tag_table = ms.tag_table;
    const hash_log = ms.row_hash_log;
    const max_elems_to_prefetch: u32 = if (@intFromPtr(base + idx_start) > @intFromPtr(i_limit))
        0
    else
        @truncate(@intFromPtr(i_limit) - @intFromPtr(base + idx_start) + 1);
    const lim = idx_start + @min(internal.row_hash_cache_size, max_elems_to_prefetch);

    var idx = idx_start;
    while (idx < lim) : (idx += 1) {
        const hash: u32 = @truncate(hashPtrSalted(
            base + idx,
            hash_log + row_hash_tag_bits,
            mls,
            ms.hash_salt,
        ));
        const row = (hash >> row_hash_tag_bits) << @intCast(row_log);
        rowPrefetch(hash_table, tag_table, row, row_log);
        ms.hash_cache[idx & row_hash_cache_mask] = hash;
    }
}

/// `ZSTD_row_nextCachedHash`: the hash of `base + idx` from the cache, which
/// takes the hash `row_hash_cache_size` positions on in its place, and
/// prefetches that hash's row.
inline fn rowNextCachedHash(
    cache: *[internal.row_hash_cache_size]u32,
    hash_table: [*]const u32,
    tag_table: [*]const u8,
    base: [*]const u8,
    idx: u32,
    hash_log: u32,
    row_log: u32,
    mls: u32,
    hash_salt: u64,
) u32 {
    const new_hash: u32 = @truncate(hashPtrSalted(
        base + idx + internal.row_hash_cache_size,
        hash_log + row_hash_tag_bits,
        mls,
        hash_salt,
    ));
    const row = (new_hash >> row_hash_tag_bits) << @intCast(row_log);
    rowPrefetch(hash_table, tag_table, row, row_log);
    const hash = cache[idx & row_hash_cache_mask];
    cache[idx & row_hash_cache_mask] = new_hash;
    return hash;
}

/// `ZSTD_row_update_internalImpl`: inserts the positions from
/// `update_start_idx` to `update_end_idx` into the rows.
inline fn rowUpdateInternalImpl(
    ms: *MatchState,
    update_start_idx: u32,
    update_end_idx: u32,
    mls: u32,
    row_log: u32,
    row_mask: u32,
    comptime use_cache: bool,
) void {
    const hash_table = ms.hash_table;
    const tag_table = ms.tag_table;
    const hash_log = ms.row_hash_log;
    const base = ms.window.base;

    var idx = update_start_idx;
    while (idx < update_end_idx) : (idx += 1) {
        const hash: u32 = if (use_cache)
            rowNextCachedHash(
                &ms.hash_cache,
                hash_table,
                tag_table,
                base,
                idx,
                hash_log,
                row_log,
                mls,
                ms.hash_salt,
            )
        else
            @truncate(hashPtrSalted(base + idx, hash_log + row_hash_tag_bits, mls, ms.hash_salt));
        const rel_row = (hash >> row_hash_tag_bits) << @intCast(row_log);
        const row = hash_table + rel_row;
        const tag_row = tag_table + rel_row;
        const pos = rowNextIndex(tag_row, row_mask);

        // The cache holds the hashes of the positions ahead.
        assert(hash == hashPtrSalted(base + idx, hash_log + row_hash_tag_bits, mls, ms.hash_salt));
        tag_row[pos] = @truncate(hash & row_hash_tag_mask);
        row[pos] = idx;
    }
}

/// `ZSTD_row_update_internal`: inserts the positions up to ip into the rows
/// and moves `next_to_update` there. With the cache, after a long match only
/// the positions at its start and its end are inserted.
inline fn rowUpdateInternal(
    ms: *MatchState,
    ip: [*]const u8,
    mls: u32,
    row_log: u32,
    row_mask: u32,
    comptime use_cache: bool,
) void {
    var idx = ms.next_to_update;
    const base = ms.window.base;
    const target: u32 = @truncate(@intFromPtr(ip) -% @intFromPtr(base));
    const skip_threshold = 384;
    const max_match_start_positions_to_update = 96;
    const max_match_end_positions_to_update = 32;

    if (use_cache) {
        // Only with the cache: a dictionary is loaded whole.
        if (target -% idx > skip_threshold) {
            @branchHint(.unlikely);
            const bound = idx + max_match_start_positions_to_update;
            rowUpdateInternalImpl(ms, idx, bound, mls, row_log, row_mask, use_cache);
            idx = target - max_match_end_positions_to_update;
            rowFillHashCache(ms, base, row_log, mls, idx, ip + 1);
        }
    }
    assert(target >= idx);
    rowUpdateInternalImpl(ms, idx, target, mls, row_log, row_mask, use_cache);
    ms.next_to_update = target;
}

/// `ZSTD_row_update`: inserts the positions up to ip into the rows, for the
/// dictionary loader.
pub fn rowUpdate(ms: *MatchState, ip: [*]const u8) void {
    const row_log = std.math.clamp(ms.cparams.search_log, 4, 6);
    const row_mask = (@as(u32, 1) << @intCast(row_log)) - 1;
    // The hashes stop at 6 bytes.
    const mls = @min(ms.cparams.min_match, 6);
    rowUpdateInternal(ms, ip, mls, row_log, row_mask, false);
}

/// `ZSTD_row_matchMaskGroupWidth`: the bits per entry in a match mask. NEON
/// has no movemask, so its compare sets 4 bits per entry in rows of 16 and
/// 2 in rows of 32.
fn rowMatchMaskGroupWidth(comptime path: MaskPath, comptime row_entries: u32) u32 {
    comptime assert(row_entries == 16 or row_entries == 32 or row_entries == 64);
    if (path == .neon) {
        return switch (row_entries) {
            16 => 4,
            32 => 2,
            else => 1,
        };
    }
    return 1;
}

/// `ZSTD_row_getSSEMask`: one bit per entry, entry i at bit i, then rotated
/// right by the row's head.
inline fn rowGetSseMask(comptime nb_chunks: u32, src: [*]const u8, tag: u8, head: u32) u64 {
    comptime assert(nb_chunks == 1 or nb_chunks == 2 or nb_chunks == 4);
    const n = 16 * nb_chunks;
    const chunk: @Vector(n, u8) = src[0..n].*;
    const comparison_mask: @Vector(n, u8) = @splat(tag);
    const matches: @Int(.unsigned, n) = @bitCast(chunk == comparison_mask);
    return std.math.rotr(@Int(.unsigned, n), matches, head);
}

/// The 0xFF and 0x00 bytes of NEON's `vceqq_u8`.
inline fn neonCompare(chunk: @Vector(16, u8), dup: @Vector(16, u8)) @Vector(16, u8) {
    const all_ones: @Vector(16, u8) = @splat(0xFF);
    const zeros: @Vector(16, u8) = @splat(0);
    return @select(u8, chunk == dup, all_ones, zeros);
}

/// NEON's `vshrn_n_u16`: each 16-bit lane of `v` shifted right by `n` and
/// narrowed to its low byte.
inline fn neonShrn(v: @Vector(16, u8), comptime n: u4) @Vector(8, u8) {
    const lanes: @Vector(8, u16) = @bitCast(v);
    return @truncate(lanes >> @splat(n));
}

/// NEON's `vsriq_n_u8`: `b` shifted right by `n`, inserted below the top `n`
/// bits of `a`.
inline fn neonSri(a: @Vector(16, u8), b: @Vector(16, u8), comptime n: u3) @Vector(16, u8) {
    const keep: @Vector(16, u8) = @splat(~@as(u8, 0xFF >> n));
    return (a & keep) | (b >> @splat(n));
}

/// The indexes `start`, `start + stride`, ... of a shuffle.
fn stridedIndexes(comptime len: usize, comptime start: i32, comptime stride: i32) [len]i32 {
    var indexes: [len]i32 = undefined;
    for (&indexes, 0..) |*index, i| index.* = start + stride * @as(i32, @intCast(i));
    return indexes;
}

/// `ZSTD_row_getNEONMask`: the match mask of NEON's compare, rotated right by
/// `head_grouped`, the head times the group width. Rows of 16 entries give 4
/// bits per entry, of which the highest is kept; rows of 32, 2 bits with the
/// lowest kept; rows of 64, one bit, as SSE2's.
inline fn rowGetNeonMask(
    comptime row_entries: u32,
    src: [*]const u8,
    tag: u8,
    head_grouped: u32,
) u64 {
    comptime assert(row_entries == 16 or row_entries == 32 or row_entries == 64);
    const dup: @Vector(16, u8) = @splat(tag);
    switch (row_entries) {
        16 => {
            // Each 16-bit lane shifted by 4 and narrowed: 4 bits per entry.
            const chunk: @Vector(16, u8) = src[0..16].*;
            const res = neonShrn(neonCompare(chunk, dup), 4);
            const matches: u64 = @bitCast(res);
            return std.math.rotr(u64, matches, head_grouped) & 0x8888888888888888;
        },
        32 => {
            // vld2q_u16: the even and the odd 16-bit lanes apart; each byte
            // of the result takes 2 bits for each of 4 entries.
            const lanes: @Vector(16, u16) = @bitCast(@as(@Vector(32, u8), src[0..32].*));
            const even = @shuffle(u16, lanes, undefined, stridedIndexes(8, 0, 2));
            const odd = @shuffle(u16, lanes, undefined, stridedIndexes(8, 1, 2));
            const chunk0: @Vector(16, u8) = @bitCast(even);
            const chunk1: @Vector(16, u8) = @bitCast(odd);
            const t0 = neonShrn(neonCompare(chunk0, dup), 6);
            const t1 = neonShrn(neonCompare(chunk1, dup), 6);
            // vsli_n_u8(t0, t1, 4).
            const res = (t1 << @splat(4)) | (t0 & @as(@Vector(8, u8), @splat(0x0F)));
            const matches: u64 = @bitCast(res);
            return std.math.rotr(u64, matches, head_grouped) & 0x5555555555555555;
        },
        else => {
            // vld4q_u8: every fourth byte apart, then the compares packed
            // into one bit per entry.
            const bytes: @Vector(64, u8) = src[0..64].*;
            const cmp0 = neonCompare(@shuffle(u8, bytes, undefined, stridedIndexes(16, 0, 4)), dup);
            const cmp1 = neonCompare(@shuffle(u8, bytes, undefined, stridedIndexes(16, 1, 4)), dup);
            const cmp2 = neonCompare(@shuffle(u8, bytes, undefined, stridedIndexes(16, 2, 4)), dup);
            const cmp3 = neonCompare(@shuffle(u8, bytes, undefined, stridedIndexes(16, 3, 4)), dup);
            const t0 = neonSri(cmp1, cmp0, 1);
            const t1 = neonSri(cmp3, cmp2, 1);
            const t2 = neonSri(t1, t0, 2);
            const t3 = neonSri(t2, t2, 4);
            const t4 = neonShrn(t3, 4);
            const matches: u64 = @bitCast(t4);
            return std.math.rotr(u64, matches, head_grouped);
        },
    }
}

/// The original's SWAR path of `ZSTD_row_getMatchMask`: the row read a word
/// at a time, one bit per entry, entry i at bit i, rotated right by the head.
inline fn rowGetSwarMask(
    comptime row_entries: u32,
    src: [*]const u8,
    tag: u8,
    head_grouped: u32,
) u64 {
    const chunk_size = @sizeOf(usize);
    const shift_amount = chunk_size * 8 - chunk_size;
    const x_ff: usize = std.math.maxInt(usize);
    const x01 = x_ff / 0xFF;
    const x80 = x01 << 7;
    const splat_char = @as(usize, tag) * x01;
    var matches: u64 = 0;
    var i: usize = row_entries - chunk_size;
    comptime assert(chunk_size == 4 or chunk_size == 8);
    if (native_endian == .little) {
        const extract_magic = (x_ff / 0x7F) >> chunk_size;
        while (true) {
            var chunk = std.mem.readInt(usize, src[i..][0..chunk_size], native_endian);
            chunk ^= splat_char;
            chunk = (((chunk | x80) - x01) | chunk) & x80;
            matches <<= chunk_size;
            matches |= (chunk *% extract_magic) >> shift_amount;
            if (i == 0) break;
            i -= chunk_size;
        }
    } else {
        // Big endian: the bits are reversed as they are extracted.
        const msb = x_ff ^ (x_ff >> 1);
        const extract_magic = (msb / 0x1FF) | msb;
        while (true) {
            var chunk = std.mem.readInt(usize, src[i..][0..chunk_size], native_endian);
            chunk ^= splat_char;
            chunk = (((chunk | x80) - x01) | chunk) & x80;
            matches <<= chunk_size;
            matches |= ((chunk >> 7) *% extract_magic) >> shift_amount;
            if (i == 0) break;
            i -= chunk_size;
        }
    }
    matches = ~matches;
    return switch (row_entries) {
        16 => std.math.rotr(u16, @truncate(matches), head_grouped),
        32 => std.math.rotr(u32, @truncate(matches), head_grouped),
        else => std.math.rotr(u64, matches, head_grouped),
    };
}

/// `ZSTD_row_getMatchMask`: a mask with the nth group of bits (of the group
/// width) set where the nth entry's tag equals `tag`. The row is a circular
/// buffer starting at its head, so the mask is rotated by `head_grouped`,
/// to line up with the entries of the hash table.
inline fn rowGetMatchMask(
    comptime path: MaskPath,
    tag_row: [*]const u8,
    tag: u8,
    head_grouped: u32,
    comptime row_entries: u32,
) u64 {
    comptime assert(row_entries == 16 or row_entries == 32 or row_entries == 64);
    comptime assert(row_entries <= row_hash_max_entries);
    comptime assert(rowMatchMaskGroupWidth(path, row_entries) * row_entries <= 64);
    return switch (path) {
        .sse2 => rowGetSseMask(row_entries / 16, tag_row, tag, head_grouped),
        .neon => rowGetNeonMask(row_entries, tag_row, tag, head_grouped),
        .swar => rowGetSwarMask(row_entries, tag_row, tag, head_grouped),
    };
}

/// `ZSTD_RowFindBestMatch`: inserts the positions up to ip into the rows,
/// compares ip's tag with its row's at once, checks the entries whose tags
/// match, newest first, and inserts ip; then searches the dictionary.
inline fn rowFindBestMatch(
    ms: *MatchState,
    ip: [*]const u8,
    i_limit: [*]const u8,
    offset_ptr: *usize,
    comptime mls: u32,
    comptime dict_mode: DictMode,
    comptime row_log: u32,
) usize {
    const hash_table = ms.hash_table;
    const tag_table = ms.tag_table;
    const hash_cache = &ms.hash_cache;
    const hash_log = ms.row_hash_log;
    const cparams = &ms.cparams;
    const base = ms.window.base;
    const dict_base = ms.window.dict_base;
    const dict_limit = ms.window.dict_limit;
    const prefix_start = base + dict_limit;
    const dict_end = dict_base + dict_limit;
    const curr: u32 = @truncate(@intFromPtr(ip) -% @intFromPtr(base));
    const max_distance = @as(u32, 1) << @intCast(cparams.window_log);
    const lowest_valid = ms.window.low_limit;
    const within_max_distance = if (curr -% lowest_valid > max_distance)
        curr - max_distance
    else
        lowest_valid;
    const is_dictionary = ms.loaded_dict_end != 0;
    const low_limit = if (is_dictionary) lowest_valid else within_max_distance;
    const row_entries: u32 = 1 << row_log;
    const row_mask = row_entries - 1;
    // At most as many searches as a row has entries.
    const capped_search_log = @min(cparams.search_log, row_log);
    const group_width = comptime rowMatchMaskGroupWidth(mask_path, row_entries);
    const hash_salt = ms.hash_salt;
    var nb_attempts = @as(u32, 1) << @intCast(capped_search_log);
    var ml: usize = 4 - 1;
    var hash: u32 = undefined;

    // The dictionary's, for its search after the context's.
    const dms = ms.dict_match_state;
    var dds_idx: usize = 0;
    // The context's rows cap the searches; the dedicated search takes more.
    var dds_extra_attempts: u32 = 0;
    var dms_tag: u32 = 0;
    var dms_row: [*]u32 = undefined;
    var dms_tag_row: [*]u8 = undefined;

    if (dict_mode == .dedicated_dict_search) {
        const dds_hash_log = dms.?.cparams.hash_log - lazy_ddss_bucket_log;
        dds_idx = hashPtr(ip, dds_hash_log, mls) << lazy_ddss_bucket_log;
        @prefetch(dms.?.hash_table + dds_idx, .{});
        dds_extra_attempts = if (cparams.search_log > row_log)
            @as(u32, 1) << @intCast(cparams.search_log - row_log)
        else
            0;
    }

    if (dict_mode == .dict_match_state) {
        const d = dms.?;
        const dms_hash_table = d.hash_table;
        const dms_tag_table = d.tag_table;
        const dms_hash: u32 = @truncate(hashPtr(ip, d.row_hash_log + row_hash_tag_bits, mls));
        const dms_rel_row = (dms_hash >> row_hash_tag_bits) << row_log;
        dms_tag = dms_hash & row_hash_tag_mask;
        dms_tag_row = dms_tag_table + dms_rel_row;
        dms_row = dms_hash_table + dms_rel_row;
        rowPrefetch(dms_hash_table, dms_tag_table, dms_rel_row, row_log);
    }

    // Insert the positions up to ip, excluded.
    if (!ms.lazy_skipping) {
        rowUpdateInternal(ms, ip, mls, row_log, row_mask, true);
        hash = rowNextCachedHash(
            hash_cache,
            hash_table,
            tag_table,
            base,
            curr,
            hash_log,
            row_log,
            mls,
            hash_salt,
        );
    } else {
        // In lazy skipping mode only searched positions are inserted, and
        // the hash cache is not kept up to date.
        hash = @truncate(hashPtrSalted(ip, hash_log + row_hash_tag_bits, mls, hash_salt));
        ms.next_to_update = curr;
    }
    // Entropy for the next salt.
    ms.hash_salt_entropy +%= hash;

    {
        const rel_row = (hash >> row_hash_tag_bits) << row_log;
        const tag = hash & row_hash_tag_mask;
        const row = hash_table + rel_row;
        const tag_row = tag_table + rel_row;
        const head_grouped = (tag_row[0] & row_mask) * group_width;
        var match_buffer: [row_hash_max_entries]u32 = undefined;
        var num_matches: usize = 0;
        var curr_match: usize = 0;
        var matches = rowGetMatchMask(mask_path, tag_row, @intCast(tag), head_grouped, row_entries);

        // Collect the candidates, prefetching each.
        while (matches > 0 and nb_attempts > 0) : (matches &= matches - 1) {
            const match_pos = ((head_grouped + @ctz(matches)) / group_width) & row_mask;
            const match_index = row[match_pos];
            if (match_pos == 0) continue;
            assert(num_matches < row_entries);
            if (match_index < low_limit) break;
            if (dict_mode != .ext_dict or match_index >= dict_limit) {
                @prefetch(base + match_index, .{});
            } else {
                @prefetch(dict_base + match_index, .{});
            }
            match_buffer[num_matches] = match_index;
            num_matches += 1;
            nb_attempts -= 1;
        }

        // Insert ip too, which saves the next update one step.
        {
            const pos = rowNextIndex(tag_row, row_mask);
            tag_row[pos] = @intCast(tag);
            row[pos] = ms.next_to_update;
            ms.next_to_update += 1;
        }

        // Find the longest match.
        while (curr_match < num_matches) : (curr_match += 1) {
            const match_index = match_buffer[curr_match];
            var current_ml: usize = 0;
            // The rows hold only positions inserted before ip.
            assert(match_index < curr);
            assert(match_index >= low_limit);

            if (dict_mode != .ext_dict or match_index >= dict_limit) {
                const match = base + match_index;
                // Without an external dictionary, every candidate is in the prefix.
                assert(match_index >= dict_limit);
                // The 4 bytes ending at match + ml: a candidate that differs
                // there is no longer than the best so far.
                if (std.mem.readInt(u32, (match + ml - 3)[0..4], native_endian) ==
                    std.mem.readInt(u32, (ip + ml - 3)[0..4], native_endian))
                {
                    current_ml = count(ip, match, i_limit);
                }
            } else {
                const match = dict_base + match_index;
                assert(@intFromPtr(match) + 4 <= @intFromPtr(dict_end));
                // match_index is at most dict_limit - 4, by the table's construction.
                if (std.mem.readInt(u32, match[0..4], native_endian) ==
                    std.mem.readInt(u32, ip[0..4], native_endian))
                {
                    current_ml = count2Segments(
                        ip + 4,
                        match + 4,
                        i_limit,
                        dict_end,
                        prefix_start,
                    ) + 4;
                }
            }

            if (current_ml > ml) {
                ml = current_ml;
                offset_ptr.* = offsetToOffbase(curr - match_index);
                // The longest possible, and the next attempt could read past the end.
                if (@intFromPtr(ip) + current_ml == @intFromPtr(i_limit)) break;
            }
        }
    }

    assert(nb_attempts <= 1 << params.search_log_max);
    if (dict_mode == .dedicated_dict_search) {
        ml = dedicatedDictSearchLazySearch(
            offset_ptr,
            ml,
            nb_attempts + dds_extra_attempts,
            dms.?,
            ip,
            i_limit,
            prefix_start,
            curr,
            dict_limit,
            dds_idx,
        );
    } else if (dict_mode == .dict_match_state) {
        const d = dms.?;
        const dms_lowest_index = d.window.dict_limit;
        const dms_base = d.window.base;
        const dms_end = d.window.next_src;
        const dms_size: u32 = @truncate(@intFromPtr(dms_end) -% @intFromPtr(dms_base));
        const dms_index_delta = dict_limit - dms_size;

        const head_grouped = (dms_tag_row[0] & row_mask) * group_width;
        var match_buffer: [row_hash_max_entries]u32 = undefined;
        var num_matches: usize = 0;
        var curr_match: usize = 0;
        var matches = rowGetMatchMask(
            mask_path,
            dms_tag_row,
            @intCast(dms_tag),
            head_grouped,
            row_entries,
        );

        while (matches > 0 and nb_attempts > 0) : (matches &= matches - 1) {
            const match_pos = ((head_grouped + @ctz(matches)) / group_width) & row_mask;
            const match_index = dms_row[match_pos];
            if (match_pos == 0) continue;
            if (match_index < dms_lowest_index) break;
            @prefetch(dms_base + match_index, .{});
            match_buffer[num_matches] = match_index;
            num_matches += 1;
            nb_attempts -= 1;
        }

        while (curr_match < num_matches) : (curr_match += 1) {
            const match_index = match_buffer[curr_match];
            var current_ml: usize = 0;
            assert(match_index >= dms_lowest_index);
            assert(match_index < curr);

            const match = dms_base + match_index;
            assert(@intFromPtr(match) + 4 <= @intFromPtr(dms_end));
            if (std.mem.readInt(u32, match[0..4], native_endian) ==
                std.mem.readInt(u32, ip[0..4], native_endian))
            {
                current_ml = count2Segments(ip + 4, match + 4, i_limit, dms_end, prefix_start) + 4;
            }

            if (current_ml > ml) {
                ml = current_ml;
                assert(curr > match_index + dms_index_delta);
                offset_ptr.* = offsetToOffbase(curr - (match_index + dms_index_delta));
                if (@intFromPtr(ip) + current_ml == @intFromPtr(i_limit)) break;
            }
        }
    }
    return ml;
}

// ---------------------------------------------------------------------------
// Search dispatch
// ---------------------------------------------------------------------------

// Each search function is kept out of line, as the original's are, for code
// size and compile time; `searchMax` switches to them.

/// `ZSTD_BtFindBestMatch_{dictMode}_{mls}`.
noinline fn btSearchFn(
    comptime dict_mode: DictMode,
    comptime mls: u32,
    ms: *MatchState,
    ip: [*]const u8,
    i_limit: [*]const u8,
    off_base_ptr: *usize,
) align(hot_code_align) usize {
    assert(std.math.clamp(ms.cparams.min_match, 4, 6) == mls);
    return btFindBestMatch(ms, ip, i_limit, off_base_ptr, mls, dict_mode);
}

/// `ZSTD_HcFindBestMatch_{dictMode}_{mls}`.
noinline fn hcSearchFn(
    comptime dict_mode: DictMode,
    comptime mls: u32,
    ms: *MatchState,
    ip: [*]const u8,
    i_limit: [*]const u8,
    offset_ptr: *usize,
) align(hot_code_align) usize {
    assert(std.math.clamp(ms.cparams.min_match, 4, 6) == mls);
    return hcFindBestMatch(ms, ip, i_limit, offset_ptr, mls, dict_mode);
}

/// `ZSTD_RowFindBestMatch_{dictMode}_{mls}_{rowLog}`.
noinline fn rowSearchFn(
    comptime dict_mode: DictMode,
    comptime mls: u32,
    comptime row_log: u32,
    ms: *MatchState,
    ip: [*]const u8,
    i_limit: [*]const u8,
    offset_ptr: *usize,
) align(hot_code_align) usize {
    assert(std.math.clamp(ms.cparams.min_match, 4, 6) == mls);
    assert(std.math.clamp(ms.cparams.search_log, 4, 6) == row_log);
    return rowFindBestMatch(ms, ip, i_limit, offset_ptr, mls, dict_mode, row_log);
}

/// `ZSTD_searchMax`: the longest match at ip, by `search_method` and
/// `dict_mode`, fixed at compile time, and `mls` and `row_log`, from 4 to 6.
/// Returns its length, below `mls` when there is none, and stores its
/// offset in `offset_ptr`. A switch, not a function pointer: indirect calls
/// cost much more with the Spectre mitigations.
inline fn searchMax(
    ms: *MatchState,
    ip: [*]const u8,
    iend: [*]const u8,
    offset_ptr: *usize,
    mls: u32,
    row_log: u32,
    comptime search_method: SearchMethod,
    comptime dict_mode: DictMode,
) usize {
    switch (search_method) {
        .hash_chain => switch (mls) {
            inline 4, 5, 6 => |m| return hcSearchFn(dict_mode, m, ms, ip, iend, offset_ptr),
            else => unreachable,
        },
        .binary_tree => switch (mls) {
            inline 4, 5, 6 => |m| return btSearchFn(dict_mode, m, ms, ip, iend, offset_ptr),
            else => unreachable,
        },
        .row_hash => switch (mls) {
            inline 4, 5, 6 => |m| switch (row_log) {
                inline 4, 5, 6 => |r| return rowSearchFn(dict_mode, m, r, ms, ip, iend, offset_ptr),
                else => unreachable,
            },
            else => unreachable,
        },
    }
}

// ---------------------------------------------------------------------------
// The lazy parser
// ---------------------------------------------------------------------------

/// `ZSTD_compressBlock_lazy_generic`: the greedy (depth 0), lazy (1) and
/// lazy2 (2) parsers without an external dictionary. At depth 1 and 2, a
/// match found is kept only if no better one starts at the next one or two
/// positions.
fn compressBlockLazyGeneric(
    ms: *MatchState,
    seq_store: *SeqStore,
    rep: *[rep_num]u32,
    src: []const u8,
    comptime search_method: SearchMethod,
    comptime depth: u32,
    comptime dict_mode: DictMode,
) usize {
    const istart = src.ptr;
    var ip = istart;
    var anchor = istart;
    const iend = istart + src.len;
    const ilimit = if (search_method == .row_hash)
        iend - 8 - internal.row_hash_cache_size
    else
        iend - 8;
    const base = ms.window.base;
    const prefix_lowest_index = ms.window.dict_limit;
    const prefix_lowest = base + prefix_lowest_index;
    const mls = std.math.clamp(ms.cparams.min_match, 4, 6);
    const row_log = std.math.clamp(ms.cparams.search_log, 4, 6);

    var offset_1 = rep[0];
    var offset_2 = rep[1];
    var offset_saved1: u32 = 0;
    var offset_saved2: u32 = 0;

    const is_dms = dict_mode == .dict_match_state;
    const is_dds = dict_mode == .dedicated_dict_search;
    const is_dxs = is_dms or is_dds;
    const dms = ms.dict_match_state;
    const dict_lowest_index: u32 = if (is_dxs) dms.?.window.dict_limit else 0;
    const dict_base: [*]const u8 = if (is_dxs) dms.?.window.base else undefined;
    const dict_lowest: [*]const u8 = if (is_dxs) dict_base + dict_lowest_index else undefined;
    const dict_end: [*]const u8 = if (is_dxs) dms.?.window.next_src else undefined;
    const dict_index_delta: u32 = if (is_dxs)
        prefix_lowest_index - @as(u32, @truncate(@intFromPtr(dict_end) -% @intFromPtr(dict_base)))
    else
        0;
    const dict_length: usize = if (is_dxs) @intFromPtr(dict_end) - @intFromPtr(dict_lowest) else 0;
    const dict_and_prefix_length: u32 =
        @truncate((@intFromPtr(ip) - @intFromPtr(prefix_lowest)) + dict_length);

    ip += @intFromBool(dict_and_prefix_length == 0);
    if (dict_mode == .no_dict) {
        const curr: u32 = @truncate(@intFromPtr(ip) -% @intFromPtr(base));
        const window_low = internal.getLowestPrefixIndex(ms, curr, ms.cparams.window_log);
        const max_rep = curr - window_low;
        if (offset_2 > max_rep) {
            offset_saved2 = offset_2;
            offset_2 = 0;
        }
        if (offset_1 > max_rep) {
            offset_saved1 = offset_1;
            offset_1 = 0;
        }
    }
    if (is_dxs) {
        // The dictionary modes' repeat checks cannot take a repeat offset of
        // 0 as disabled.
        assert(offset_1 <= dict_and_prefix_length);
        assert(offset_2 <= dict_and_prefix_length);
    }

    ms.lazy_skipping = false;

    if (search_method == .row_hash) {
        rowFillHashCache(ms, base, row_log, mls, ms.next_to_update, ilimit);
    }

    while (@intFromPtr(ip) < @intFromPtr(ilimit)) {
        var match_length: usize = 0;
        var off_base: usize = repcode1_to_offbase;
        var start = ip + 1;

        store_sequence: {
            // Check the repeat offset.
            if (is_dxs) {
                const rep_index = @as(u32, @truncate(@intFromPtr(ip) -% @intFromPtr(base))) +
                    1 -% offset_1;
                const rep_match = if (rep_index < prefix_lowest_index)
                    dict_base + (rep_index -% dict_index_delta)
                else
                    base + rep_index;
                if (internal.indexOverlapCheck(prefix_lowest_index, rep_index) and
                    std.mem.readInt(u32, rep_match[0..4], native_endian) ==
                        std.mem.readInt(u32, (ip + 1)[0..4], native_endian))
                {
                    const rep_match_end = if (rep_index < prefix_lowest_index) dict_end else iend;
                    match_length = count2Segments(
                        ip + 1 + 4,
                        rep_match + 4,
                        iend,
                        rep_match_end,
                        prefix_lowest,
                    ) + 4;
                    if (depth == 0) break :store_sequence;
                }
            }
            if (dict_mode == .no_dict and
                ((offset_1 > 0) & (std.mem.readInt(u32, (ip + 1 - offset_1)[0..4], native_endian) ==
                    std.mem.readInt(u32, (ip + 1)[0..4], native_endian))))
            {
                match_length = count(ip + 1 + 4, ip + 1 + 4 - offset_1, iend) + 4;
                if (depth == 0) break :store_sequence;
            }

            // The first search, at depth 0.
            {
                var offbase_found: usize = 999999999;
                const ml2 = searchMax(
                    ms,
                    ip,
                    iend,
                    &offbase_found,
                    mls,
                    row_log,
                    search_method,
                    dict_mode,
                );
                if (ml2 > match_length) {
                    match_length = ml2;
                    start = ip;
                    off_base = offbase_found;
                }
            }

            if (match_length < 4) {
                // Jump faster over incompressible data.
                const step = ((@intFromPtr(ip) - @intFromPtr(anchor)) >> internal.search_strength) +
                    1;
                ip += step;
                // Past 8 bytes a step, about 2 KB without a match, only the
                // positions searched (one in a step) are inserted. The
                // cutoff keeps the ratio loss low on ordinary data.
                ms.lazy_skipping = step > lazy_skipping_step;
                continue;
            }

            // Look for a better match at the next positions.
            if (depth >= 1) {
                while (@intFromPtr(ip) < @intFromPtr(ilimit)) {
                    ip += 1;
                    if (dict_mode == .no_dict and off_base != 0 and
                        ((offset_1 > 0) & (std.mem.readInt(u32, ip[0..4], native_endian) ==
                            std.mem.readInt(u32, (ip - offset_1)[0..4], native_endian))))
                    {
                        const ml_rep = count(ip + 4, ip + 4 - offset_1, iend) + 4;
                        const gain2: i32 = @intCast(ml_rep * 3);
                        const gain1: i32 = @as(i32, @intCast(match_length * 3)) -
                            @as(i32, @intCast(highbit32(@intCast(off_base)))) + 1;
                        if (ml_rep >= 4 and gain2 > gain1) {
                            match_length = ml_rep;
                            off_base = repcode1_to_offbase;
                            start = ip;
                        }
                    }
                    if (is_dxs) {
                        const rep_curr: u32 = @truncate(@intFromPtr(ip) -% @intFromPtr(base));
                        const rep_index = rep_curr -% offset_1;
                        const rep_match = if (rep_index < prefix_lowest_index)
                            dict_base + (rep_index -% dict_index_delta)
                        else
                            base + rep_index;
                        if (internal.indexOverlapCheck(prefix_lowest_index, rep_index) and
                            std.mem.readInt(u32, rep_match[0..4], native_endian) ==
                                std.mem.readInt(u32, ip[0..4], native_endian))
                        {
                            const rep_match_end = if (rep_index < prefix_lowest_index)
                                dict_end
                            else
                                iend;
                            const ml_rep = count2Segments(
                                ip + 4,
                                rep_match + 4,
                                iend,
                                rep_match_end,
                                prefix_lowest,
                            ) + 4;
                            const gain2: i32 = @intCast(ml_rep * 3);
                            const gain1: i32 = @as(i32, @intCast(match_length * 3)) -
                                @as(i32, @intCast(highbit32(@intCast(off_base)))) + 1;
                            if (ml_rep >= 4 and gain2 > gain1) {
                                match_length = ml_rep;
                                off_base = repcode1_to_offbase;
                                start = ip;
                            }
                        }
                    }
                    {
                        var ofb_candidate: usize = 999999999;
                        const ml2 = searchMax(
                            ms,
                            ip,
                            iend,
                            &ofb_candidate,
                            mls,
                            row_log,
                            search_method,
                            dict_mode,
                        );
                        // A rough estimate of the bits each saves.
                        const gain2: i32 = @as(i32, @intCast(ml2 * 4)) -
                            @as(i32, @intCast(highbit32(@truncate(ofb_candidate))));
                        const gain1: i32 = @as(i32, @intCast(match_length * 4)) -
                            @as(i32, @intCast(highbit32(@intCast(off_base)))) + 4;
                        if (ml2 >= 4 and gain2 > gain1) {
                            match_length = ml2;
                            off_base = ofb_candidate;
                            start = ip;
                            // Look for a better one still.
                            continue;
                        }
                    }

                    // And one position further for lazy2.
                    if (depth == 2 and @intFromPtr(ip) < @intFromPtr(ilimit)) {
                        ip += 1;
                        if (dict_mode == .no_dict and off_base != 0 and
                            ((offset_1 > 0) & (std.mem.readInt(u32, ip[0..4], native_endian) ==
                                std.mem.readInt(u32, (ip - offset_1)[0..4], native_endian))))
                        {
                            const ml_rep = count(ip + 4, ip + 4 - offset_1, iend) + 4;
                            const gain2: i32 = @intCast(ml_rep * 4);
                            const gain1: i32 = @as(i32, @intCast(match_length * 4)) -
                                @as(i32, @intCast(highbit32(@intCast(off_base)))) + 1;
                            if (ml_rep >= 4 and gain2 > gain1) {
                                match_length = ml_rep;
                                off_base = repcode1_to_offbase;
                                start = ip;
                            }
                        }
                        if (is_dxs) {
                            const rep_index = @as(u32, @truncate(@intFromPtr(ip) -%
                                @intFromPtr(base))) -% offset_1;
                            const rep_match = if (rep_index < prefix_lowest_index)
                                dict_base + (rep_index -% dict_index_delta)
                            else
                                base + rep_index;
                            if (internal.indexOverlapCheck(prefix_lowest_index, rep_index) and
                                std.mem.readInt(u32, rep_match[0..4], native_endian) ==
                                    std.mem.readInt(u32, ip[0..4], native_endian))
                            {
                                const rep_match_end = if (rep_index < prefix_lowest_index)
                                    dict_end
                                else
                                    iend;
                                const ml_rep = count2Segments(
                                    ip + 4,
                                    rep_match + 4,
                                    iend,
                                    rep_match_end,
                                    prefix_lowest,
                                ) + 4;
                                const gain2: i32 = @intCast(ml_rep * 4);
                                const gain1: i32 = @as(i32, @intCast(match_length * 4)) -
                                    @as(i32, @intCast(highbit32(@intCast(off_base)))) + 1;
                                if (ml_rep >= 4 and gain2 > gain1) {
                                    match_length = ml_rep;
                                    off_base = repcode1_to_offbase;
                                    start = ip;
                                }
                            }
                        }
                        {
                            var ofb_candidate: usize = 999999999;
                            const ml2 = searchMax(
                                ms,
                                ip,
                                iend,
                                &ofb_candidate,
                                mls,
                                row_log,
                                search_method,
                                dict_mode,
                            );
                            const gain2: i32 = @as(i32, @intCast(ml2 * 4)) -
                                @as(i32, @intCast(highbit32(@truncate(ofb_candidate))));
                            const gain1: i32 = @as(i32, @intCast(match_length * 4)) -
                                @as(i32, @intCast(highbit32(@intCast(off_base)))) + 7;
                            if (ml2 >= 4 and gain2 > gain1) {
                                match_length = ml2;
                                off_base = ofb_candidate;
                                start = ip;
                                continue;
                            }
                        }
                    }
                    // Nothing better: store the match found.
                    break;
                }
            }

            // Extend the match backwards.
            if (internal.offbaseIsOffset(@intCast(off_base))) {
                const offset = internal.offbaseToOffset(@intCast(off_base));
                if (dict_mode == .no_dict) {
                    // Only within the prefix.
                    while (((@intFromPtr(start) > @intFromPtr(anchor)) &
                        (@intFromPtr(start) - offset > @intFromPtr(prefix_lowest))) and
                        (start - 1)[0] == (start - offset - 1)[0])
                    {
                        start -= 1;
                        match_length += 1;
                    }
                }
                if (is_dxs) {
                    const match_index: u32 =
                        @truncate((@intFromPtr(start) -% @intFromPtr(base)) -% offset);
                    var match = if (match_index < prefix_lowest_index)
                        dict_base + match_index - dict_index_delta
                    else
                        base + match_index;
                    const m_start = if (match_index < prefix_lowest_index)
                        dict_lowest
                    else
                        prefix_lowest;
                    while (@intFromPtr(start) > @intFromPtr(anchor) and
                        @intFromPtr(match) > @intFromPtr(m_start) and
                        (start - 1)[0] == (match - 1)[0])
                    {
                        start -= 1;
                        match -= 1;
                        match_length += 1;
                    }
                }
                offset_2 = offset_1;
                offset_1 = offset;
            }
        }

        // Store the sequence.
        {
            const lit_length = @intFromPtr(start) - @intFromPtr(anchor);
            const off_base_stored: u32 = @intCast(off_base);
            internal.storeSeq(seq_store, lit_length, anchor, iend, off_base_stored, match_length);
            ip = start + match_length;
            anchor = ip;
        }
        if (ms.lazy_skipping) {
            // A match ends lazy skipping; the hash cache is filled again.
            if (search_method == .row_hash) {
                rowFillHashCache(ms, base, row_log, mls, ms.next_to_update, ilimit);
            }
            ms.lazy_skipping = false;
        }

        // Take the second repeat offset right away while it matches.
        if (is_dxs) {
            while (@intFromPtr(ip) <= @intFromPtr(ilimit)) {
                const current2: u32 = @truncate(@intFromPtr(ip) -% @intFromPtr(base));
                const rep_index = current2 -% offset_2;
                const rep_match = if (rep_index < prefix_lowest_index)
                    dict_base - dict_index_delta + rep_index
                else
                    base + rep_index;
                if (internal.indexOverlapCheck(prefix_lowest_index, rep_index) and
                    std.mem.readInt(u32, rep_match[0..4], native_endian) ==
                        std.mem.readInt(u32, ip[0..4], native_endian))
                {
                    const rep_end2 = if (rep_index < prefix_lowest_index) dict_end else iend;
                    match_length = count2Segments(
                        ip + 4,
                        rep_match + 4,
                        iend,
                        rep_end2,
                        prefix_lowest,
                    ) + 4;
                    // Swap the first two repeat offsets.
                    const offset = offset_2;
                    offset_2 = offset_1;
                    offset_1 = offset;
                    internal.storeSeq(
                        seq_store,
                        0,
                        anchor,
                        iend,
                        repcode1_to_offbase,
                        match_length,
                    );
                    ip += match_length;
                    anchor = ip;
                    continue;
                }
                break;
            }
        }

        if (dict_mode == .no_dict) {
            while (((@intFromPtr(ip) <= @intFromPtr(ilimit)) & (offset_2 > 0)) and
                std.mem.readInt(u32, ip[0..4], native_endian) ==
                    std.mem.readInt(u32, (ip - offset_2)[0..4], native_endian))
            {
                match_length = count(ip + 4, ip + 4 - offset_2, iend) + 4;
                // Swap the first two repeat offsets.
                const offset = offset_2;
                offset_2 = offset_1;
                offset_1 = offset;
                internal.storeSeq(seq_store, 0, anchor, iend, repcode1_to_offbase, match_length);
                ip += match_length;
                anchor = ip;
            }
        }
    }

    // An offset that started invalid (saved) and a first offset that became
    // valid: the saved offsets rotate, as in the fast match finder.
    offset_saved2 = if (offset_saved1 != 0 and offset_1 != 0) offset_saved1 else offset_saved2;

    // The repeat offsets for the next block.
    rep[0] = if (offset_1 != 0) offset_1 else offset_saved1;
    rep[1] = if (offset_2 != 0) offset_2 else offset_saved2;

    // The size of the last literals.
    return @intFromPtr(iend) - @intFromPtr(anchor);
}

/// `ZSTD_compressBlock_lazy_extDict_generic`: the parsers of
/// `compressBlockLazyGeneric` with an external dictionary below the prefix.
fn compressBlockLazyExtDictGeneric(
    ms: *MatchState,
    seq_store: *SeqStore,
    rep: *[rep_num]u32,
    src: []const u8,
    comptime search_method: SearchMethod,
    comptime depth: u32,
) usize {
    const istart = src.ptr;
    var ip = istart;
    var anchor = istart;
    const iend = istart + src.len;
    const ilimit = if (search_method == .row_hash)
        iend - 8 - internal.row_hash_cache_size
    else
        iend - 8;
    const base = ms.window.base;
    const dict_limit = ms.window.dict_limit;
    const prefix_start = base + dict_limit;
    const dict_base = ms.window.dict_base;
    const dict_end = dict_base + dict_limit;
    const dict_start = dict_base + ms.window.low_limit;
    const window_log = ms.cparams.window_log;
    const mls = std.math.clamp(ms.cparams.min_match, 4, 6);
    const row_log = std.math.clamp(ms.cparams.search_log, 4, 6);

    var offset_1 = rep[0];
    var offset_2 = rep[1];

    ms.lazy_skipping = false;

    ip += @intFromBool(ip == prefix_start);
    if (search_method == .row_hash) {
        rowFillHashCache(ms, base, row_log, mls, ms.next_to_update, ilimit);
    }

    while (@intFromPtr(ip) < @intFromPtr(ilimit)) {
        var match_length: usize = 0;
        var off_base: usize = repcode1_to_offbase;
        var start = ip + 1;
        var curr: u32 = @truncate(@intFromPtr(ip) -% @intFromPtr(base));

        store_sequence: {
            // Check the repeat offset, at curr + 1.
            {
                const window_low = internal.getLowestMatchIndex(ms, curr + 1, window_log);
                const rep_index = curr + 1 -% offset_1;
                const rep_base = if (rep_index < dict_limit) dict_base else base;
                const rep_match = rep_base + rep_index;
                if (internal.indexOverlapCheck(dict_limit, rep_index) &
                    (offset_1 <= curr + 1 - window_low))
                {
                    if (std.mem.readInt(u32, (ip + 1)[0..4], native_endian) ==
                        std.mem.readInt(u32, rep_match[0..4], native_endian))
                    {
                        // A repeat offset matches: take it.
                        const rep_end = if (rep_index < dict_limit) dict_end else iend;
                        match_length = count2Segments(
                            ip + 1 + 4,
                            rep_match + 4,
                            iend,
                            rep_end,
                            prefix_start,
                        ) + 4;
                        if (depth == 0) break :store_sequence;
                    }
                }
            }

            // The first search, at depth 0.
            {
                var ofb_candidate: usize = 999999999;
                const ml2 = searchMax(
                    ms,
                    ip,
                    iend,
                    &ofb_candidate,
                    mls,
                    row_log,
                    search_method,
                    .ext_dict,
                );
                if (ml2 > match_length) {
                    match_length = ml2;
                    start = ip;
                    off_base = ofb_candidate;
                }
            }

            if (match_length < 4) {
                // Jump faster over incompressible data.
                const step = (@intFromPtr(ip) - @intFromPtr(anchor)) >> internal.search_strength;
                ip += step + 1;
                // Past 8 bytes a step, about 2 KB without a match, only the
                // positions searched (one in a step) are inserted. The
                // cutoff keeps the ratio loss low on ordinary data.
                ms.lazy_skipping = step > lazy_skipping_step;
                continue;
            }

            // Look for a better match at the next positions.
            if (depth >= 1) {
                while (@intFromPtr(ip) < @intFromPtr(ilimit)) {
                    ip += 1;
                    curr += 1;
                    // Check the repeat offset.
                    if (off_base != 0) {
                        const window_low = internal.getLowestMatchIndex(ms, curr, window_log);
                        const rep_index = curr -% offset_1;
                        const rep_base = if (rep_index < dict_limit) dict_base else base;
                        const rep_match = rep_base + rep_index;
                        // That is, curr > rep_index >= window_low.
                        if (internal.indexOverlapCheck(dict_limit, rep_index) &
                            (offset_1 <= curr - window_low))
                        {
                            if (std.mem.readInt(u32, ip[0..4], native_endian) ==
                                std.mem.readInt(u32, rep_match[0..4], native_endian))
                            {
                                const rep_end = if (rep_index < dict_limit) dict_end else iend;
                                const rep_length = count2Segments(
                                    ip + 4,
                                    rep_match + 4,
                                    iend,
                                    rep_end,
                                    prefix_start,
                                ) + 4;
                                const gain2: i32 = @intCast(rep_length * 3);
                                const gain1: i32 = @as(i32, @intCast(match_length * 3)) -
                                    @as(i32, @intCast(highbit32(@intCast(off_base)))) + 1;
                                if (rep_length >= 4 and gain2 > gain1) {
                                    match_length = rep_length;
                                    off_base = repcode1_to_offbase;
                                    start = ip;
                                }
                            }
                        }
                    }

                    // Search, at depth 1.
                    {
                        var ofb_candidate: usize = 999999999;
                        const ml2 = searchMax(
                            ms,
                            ip,
                            iend,
                            &ofb_candidate,
                            mls,
                            row_log,
                            search_method,
                            .ext_dict,
                        );
                        // A rough estimate of the bits each saves.
                        const gain2: i32 = @as(i32, @intCast(ml2 * 4)) -
                            @as(i32, @intCast(highbit32(@truncate(ofb_candidate))));
                        const gain1: i32 = @as(i32, @intCast(match_length * 4)) -
                            @as(i32, @intCast(highbit32(@intCast(off_base)))) + 4;
                        if (ml2 >= 4 and gain2 > gain1) {
                            match_length = ml2;
                            off_base = ofb_candidate;
                            start = ip;
                            // Look for a better one still.
                            continue;
                        }
                    }

                    // And one position further for lazy2.
                    if (depth == 2 and @intFromPtr(ip) < @intFromPtr(ilimit)) {
                        ip += 1;
                        curr += 1;
                        // Check the repeat offset.
                        if (off_base != 0) {
                            const window_low = internal.getLowestMatchIndex(ms, curr, window_log);
                            const rep_index = curr -% offset_1;
                            const rep_base = if (rep_index < dict_limit) dict_base else base;
                            const rep_match = rep_base + rep_index;
                            // That is, curr > rep_index >= window_low.
                            if (internal.indexOverlapCheck(dict_limit, rep_index) &
                                (offset_1 <= curr - window_low))
                            {
                                if (std.mem.readInt(u32, ip[0..4], native_endian) ==
                                    std.mem.readInt(u32, rep_match[0..4], native_endian))
                                {
                                    const rep_end = if (rep_index < dict_limit) dict_end else iend;
                                    const rep_length = count2Segments(
                                        ip + 4,
                                        rep_match + 4,
                                        iend,
                                        rep_end,
                                        prefix_start,
                                    ) + 4;
                                    const gain2: i32 = @intCast(rep_length * 4);
                                    const gain1: i32 = @as(i32, @intCast(match_length * 4)) -
                                        @as(i32, @intCast(highbit32(@intCast(off_base)))) + 1;
                                    if (rep_length >= 4 and gain2 > gain1) {
                                        match_length = rep_length;
                                        off_base = repcode1_to_offbase;
                                        start = ip;
                                    }
                                }
                            }
                        }

                        // Search, at depth 2.
                        {
                            var ofb_candidate: usize = 999999999;
                            const ml2 = searchMax(
                                ms,
                                ip,
                                iend,
                                &ofb_candidate,
                                mls,
                                row_log,
                                search_method,
                                .ext_dict,
                            );
                            const gain2: i32 = @as(i32, @intCast(ml2 * 4)) -
                                @as(i32, @intCast(highbit32(@truncate(ofb_candidate))));
                            const gain1: i32 = @as(i32, @intCast(match_length * 4)) -
                                @as(i32, @intCast(highbit32(@intCast(off_base)))) + 7;
                            if (ml2 >= 4 and gain2 > gain1) {
                                match_length = ml2;
                                off_base = ofb_candidate;
                                start = ip;
                                continue;
                            }
                        }
                    }
                    // Nothing better: store the match found.
                    break;
                }
            }

            // Extend the match backwards.
            if (internal.offbaseIsOffset(@intCast(off_base))) {
                const offset = internal.offbaseToOffset(@intCast(off_base));
                const match_index: u32 =
                    @truncate((@intFromPtr(start) -% @intFromPtr(base)) -% offset);
                var match = if (match_index < dict_limit)
                    dict_base + match_index
                else
                    base + match_index;
                const m_start = if (match_index < dict_limit) dict_start else prefix_start;
                while (@intFromPtr(start) > @intFromPtr(anchor) and
                    @intFromPtr(match) > @intFromPtr(m_start) and
                    (start - 1)[0] == (match - 1)[0])
                {
                    start -= 1;
                    match -= 1;
                    match_length += 1;
                }
                offset_2 = offset_1;
                offset_1 = offset;
            }
        }

        // Store the sequence.
        {
            const lit_length = @intFromPtr(start) - @intFromPtr(anchor);
            const off_base_stored: u32 = @intCast(off_base);
            internal.storeSeq(seq_store, lit_length, anchor, iend, off_base_stored, match_length);
            ip = start + match_length;
            anchor = ip;
        }
        if (ms.lazy_skipping) {
            // A match ends lazy skipping; the hash cache is filled again.
            if (search_method == .row_hash) {
                rowFillHashCache(ms, base, row_log, mls, ms.next_to_update, ilimit);
            }
            ms.lazy_skipping = false;
        }

        // Take the second repeat offset right away while it matches.
        while (@intFromPtr(ip) <= @intFromPtr(ilimit)) {
            const rep_current: u32 = @truncate(@intFromPtr(ip) -% @intFromPtr(base));
            const window_low = internal.getLowestMatchIndex(ms, rep_current, window_log);
            const rep_index = rep_current -% offset_2;
            const rep_base = if (rep_index < dict_limit) dict_base else base;
            const rep_match = rep_base + rep_index;
            // That is, rep_current > rep_index >= window_low.
            if (internal.indexOverlapCheck(dict_limit, rep_index) &
                (offset_2 <= rep_current - window_low))
            {
                if (std.mem.readInt(u32, ip[0..4], native_endian) ==
                    std.mem.readInt(u32, rep_match[0..4], native_endian))
                {
                    const rep_end = if (rep_index < dict_limit) dict_end else iend;
                    match_length = count2Segments(
                        ip + 4,
                        rep_match + 4,
                        iend,
                        rep_end,
                        prefix_start,
                    ) + 4;
                    // Swap the first two repeat offsets.
                    const offset = offset_2;
                    offset_2 = offset_1;
                    offset_1 = offset;
                    internal.storeSeq(
                        seq_store,
                        0,
                        anchor,
                        iend,
                        repcode1_to_offbase,
                        match_length,
                    );
                    ip += match_length;
                    anchor = ip;
                    continue;
                }
            }
            break;
        }
    }

    // The repeat offsets for the next block.
    rep[0] = offset_1;
    rep[1] = offset_2;

    // The size of the last literals.
    return @intFromPtr(iend) - @intFromPtr(anchor);
}

// ---------------------------------------------------------------------------
// Block compressors
// ---------------------------------------------------------------------------

// Each has the `internal.BlockCompressor` signature: it finds the sequences
// of one block of `src`, stores them in `seq_store`, updates `rep`, and
// returns the size of the literals after the last sequence.

/// The block compressor of the original's `ZSTD_compressBlock_*` for
/// `search_method`, `depth` and `dict_mode`: `compressBlockLazyGeneric`, or
/// `compressBlockLazyExtDictGeneric` with an external dictionary.
fn blockCompressor(
    comptime search_method: SearchMethod,
    comptime depth: u32,
    comptime dict_mode: DictMode,
) fn (*MatchState, *SeqStore, *[rep_num]u32, []const u8) usize {
    return struct {
        fn compress(
            ms: *MatchState,
            seq_store: *SeqStore,
            rep: *[rep_num]u32,
            src: []const u8,
        ) align(hot_code_align) usize {
            if (dict_mode == .ext_dict) {
                return compressBlockLazyExtDictGeneric(
                    ms,
                    seq_store,
                    rep,
                    src,
                    search_method,
                    depth,
                );
            }
            return compressBlockLazyGeneric(
                ms,
                seq_store,
                rep,
                src,
                search_method,
                depth,
                dict_mode,
            );
        }
    }.compress;
}

/// `ZSTD_compressBlock_greedy`.
pub const compressBlockGreedy = blockCompressor(.hash_chain, 0, .no_dict);
/// `ZSTD_compressBlock_greedy_dictMatchState`.
pub const compressBlockGreedyDictMatchState = blockCompressor(.hash_chain, 0, .dict_match_state);
/// `ZSTD_compressBlock_greedy_dedicatedDictSearch`.
pub const compressBlockGreedyDedicatedDictSearch =
    blockCompressor(.hash_chain, 0, .dedicated_dict_search);
/// `ZSTD_compressBlock_greedy_row`.
pub const compressBlockGreedyRow = blockCompressor(.row_hash, 0, .no_dict);
/// `ZSTD_compressBlock_greedy_dictMatchState_row`.
pub const compressBlockGreedyDictMatchStateRow = blockCompressor(.row_hash, 0, .dict_match_state);
/// `ZSTD_compressBlock_greedy_dedicatedDictSearch_row`.
pub const compressBlockGreedyDedicatedDictSearchRow =
    blockCompressor(.row_hash, 0, .dedicated_dict_search);
/// `ZSTD_compressBlock_lazy`.
pub const compressBlockLazy = blockCompressor(.hash_chain, 1, .no_dict);
/// `ZSTD_compressBlock_lazy_dictMatchState`.
pub const compressBlockLazyDictMatchState = blockCompressor(.hash_chain, 1, .dict_match_state);
/// `ZSTD_compressBlock_lazy_dedicatedDictSearch`.
pub const compressBlockLazyDedicatedDictSearch =
    blockCompressor(.hash_chain, 1, .dedicated_dict_search);
/// `ZSTD_compressBlock_lazy_row`.
pub const compressBlockLazyRow = blockCompressor(.row_hash, 1, .no_dict);
/// `ZSTD_compressBlock_lazy_dictMatchState_row`.
pub const compressBlockLazyDictMatchStateRow = blockCompressor(.row_hash, 1, .dict_match_state);
/// `ZSTD_compressBlock_lazy_dedicatedDictSearch_row`.
pub const compressBlockLazyDedicatedDictSearchRow =
    blockCompressor(.row_hash, 1, .dedicated_dict_search);
/// `ZSTD_compressBlock_lazy2`.
pub const compressBlockLazy2 = blockCompressor(.hash_chain, 2, .no_dict);
/// `ZSTD_compressBlock_lazy2_dictMatchState`.
pub const compressBlockLazy2DictMatchState = blockCompressor(.hash_chain, 2, .dict_match_state);
/// `ZSTD_compressBlock_lazy2_dedicatedDictSearch`.
pub const compressBlockLazy2DedicatedDictSearch =
    blockCompressor(.hash_chain, 2, .dedicated_dict_search);
/// `ZSTD_compressBlock_lazy2_row`.
pub const compressBlockLazy2Row = blockCompressor(.row_hash, 2, .no_dict);
/// `ZSTD_compressBlock_lazy2_dictMatchState_row`.
pub const compressBlockLazy2DictMatchStateRow = blockCompressor(.row_hash, 2, .dict_match_state);
/// `ZSTD_compressBlock_lazy2_dedicatedDictSearch_row`.
pub const compressBlockLazy2DedicatedDictSearchRow =
    blockCompressor(.row_hash, 2, .dedicated_dict_search);
/// `ZSTD_compressBlock_btlazy2`.
pub const compressBlockBtlazy2 = blockCompressor(.binary_tree, 2, .no_dict);
/// `ZSTD_compressBlock_btlazy2_dictMatchState`.
pub const compressBlockBtlazy2DictMatchState = blockCompressor(.binary_tree, 2, .dict_match_state);
/// `ZSTD_compressBlock_greedy_extDict`.
pub const compressBlockGreedyExtDict = blockCompressor(.hash_chain, 0, .ext_dict);
/// `ZSTD_compressBlock_greedy_extDict_row`.
pub const compressBlockGreedyExtDictRow = blockCompressor(.row_hash, 0, .ext_dict);
/// `ZSTD_compressBlock_lazy_extDict`.
pub const compressBlockLazyExtDict = blockCompressor(.hash_chain, 1, .ext_dict);
/// `ZSTD_compressBlock_lazy_extDict_row`.
pub const compressBlockLazyExtDictRow = blockCompressor(.row_hash, 1, .ext_dict);
/// `ZSTD_compressBlock_lazy2_extDict`.
pub const compressBlockLazy2ExtDict = blockCompressor(.hash_chain, 2, .ext_dict);
/// `ZSTD_compressBlock_lazy2_extDict_row`.
pub const compressBlockLazy2ExtDictRow = blockCompressor(.row_hash, 2, .ext_dict);
/// `ZSTD_compressBlock_btlazy2_extDict`.
pub const compressBlockBtlazy2ExtDict = blockCompressor(.binary_tree, 2, .ext_dict);

// --------------------------------------------------------
// Tests
// --------------------------------------------------------

const testing = std.testing;

test {
    // Compiles every block compressor and loader.
    testing.refAllDecls(@This());
}

/// The row entries, in the order a search visits them, whose tags `mask`
/// marks, for a mask of group width `group_width` rotated by the head.
fn visitedEntries(
    buffer: []u32,
    mask_start: u64,
    head: u32,
    group_width: u32,
    row_entries: u32,
) []u32 {
    var mask = mask_start;
    var n: usize = 0;
    const head_grouped = head * group_width;
    while (mask > 0) : (mask &= mask - 1) {
        buffer[n] = ((head_grouped + @ctz(mask)) / group_width) & (row_entries - 1);
        n += 1;
    }
    return buffer[0..n];
}

fn expectSameVisits(comptime row_entries: u32, row: []const u8, tag: u8, head: u32) !void {
    var swar_buffer: [64]u32 = undefined;
    var sse_buffer: [64]u32 = undefined;
    var neon_buffer: [64]u32 = undefined;
    const swar = rowGetSwarMask(row_entries, row.ptr, tag, head);
    const sse = rowGetSseMask(row_entries / 16, row.ptr, tag, head);
    // SSE2's and the scalar path's masks are the same.
    try testing.expectEqual(swar, sse);
    const neon_width = rowMatchMaskGroupWidth(.neon, row_entries);
    const neon = rowGetNeonMask(row_entries, row.ptr, tag, head * neon_width);
    const expected = visitedEntries(&swar_buffer, swar, head, 1, row_entries);
    const sse_visits = visitedEntries(&sse_buffer, sse, head, 1, row_entries);
    try testing.expectEqualSlices(u32, expected, sse_visits);
    try testing.expectEqualSlices(
        u32,
        expected,
        visitedEntries(&neon_buffer, neon, head, neon_width, row_entries),
    );
    // Every entry whose tag matches, from the head on, wrapping.
    var in_order: [64]u32 = undefined;
    var n: usize = 0;
    for (0..row_entries) |k| {
        const entry: u32 = @intCast((head + k) & (row_entries - 1));
        if (row[entry] == tag) {
            in_order[n] = entry;
            n += 1;
        }
    }
    try testing.expectEqualSlices(u32, in_order[0..n], expected);
}

test "the SSE2, NEON and SWAR tag compares visit the same entries" {
    var prng = std.Random.DefaultPrng.init(0x726f77);
    const random = prng.random();
    var row: [64]u8 align(64) = undefined;
    for (0..2000) |case| {
        // Few tag values, so that rows hold many matches.
        const values: u8 = if (case % 2 == 0) 4 else 255;
        for (&row) |*byte| byte.* = random.uintLessThan(u8, values);
        const tag = random.uintLessThan(u8, values);
        inline for (.{ 16, 32, 64 }) |row_entries| {
            const head = random.uintLessThan(u32, row_entries);
            try expectSameVisits(row_entries, &row, tag, head);
        }
    }
    // Every entry matches; no entry matches.
    @memset(&row, 7);
    inline for (.{ 16, 32, 64 }) |row_entries| {
        try expectSameVisits(row_entries, &row, 7, 3);
        try expectSameVisits(row_entries, &row, 8, 3);
    }
}

test "rowNextIndex moves the head back and skips entry 0" {
    var tag_row: [16]u8 = @splat(0);
    const mask: u32 = 15;
    var expected: u32 = 15;
    for (0..40) |_| {
        const pos = rowNextIndex(&tag_row, mask);
        try testing.expectEqual(expected, pos);
        try testing.expectEqual(@as(u8, @intCast(pos)), tag_row[0]);
        expected = if (expected == 1) 15 else expected - 1;
    }
}
