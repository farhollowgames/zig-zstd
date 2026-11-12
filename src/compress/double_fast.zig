//! The `dfast` strategy's match finder, from the original's
//! zstd_double_fast.c: a hash table of 8-byte sequences (the hash table)
//! and one of `min_match`-byte sequences (the chain table's space), the long
//! match tried first.

const std = @import("std");
const builtin = @import("builtin");

const ci = @import("compress_internal.zig");
const zstd_internal = @import("../common/zstd_internal.zig");

const MatchState = ci.MatchState;
const SeqStore = ci.SeqStore;
const DictTableLoadMethod = ci.DictTableLoadMethod;
const assert = std.debug.assert;
const native_endian = builtin.cpu.arch.endian();
const rep_num = zstd_internal.rep_num;
const hash_read_size = ci.hash_read_size;
const short_cache_tag_bits = ci.short_cache_tag_bits;
const search_strength = ci.search_strength;

/// Positions between the entries a fill always writes.
const fast_hash_fill_step = 3;

/// `ZSTD_fillDoubleHashTableForCDict`: fills a dictionary's tables, with
/// short-cache tags, from `next_to_update` to `end`.
fn fillDoubleHashTableForCDict(ms: *MatchState, end: [*]const u8, dtlm: DictTableLoadMethod) void {
    const cparams = &ms.cparams;
    const hash_large = ms.hash_table;
    const h_bits_l = cparams.hash_log + short_cache_tag_bits;
    const mls = cparams.min_match;
    const hash_small = ms.chain_table;
    const h_bits_s = cparams.chain_log + short_cache_tag_bits;
    const base = ms.window.base;
    var ip = base + ms.next_to_update;
    const iend = @intFromPtr(end) -% hash_read_size;

    // Every third position goes in both tables; the others into the large
    // table where their entry is empty.
    while (@intFromPtr(ip) + fast_hash_fill_step - 1 <= iend) : (ip += fast_hash_fill_step) {
        const curr: u32 = @intCast(@intFromPtr(ip) - @intFromPtr(base));
        for (0..fast_hash_fill_step) |i| {
            const sm_hash_and_tag = ci.hashPtr(ip + i, h_bits_s, mls);
            const lg_hash_and_tag = ci.hashPtr(ip + i, h_bits_l, 8);
            const index = curr + @as(u32, @intCast(i));
            if (i == 0) ci.writeTaggedIndex(hash_small, sm_hash_and_tag, index);
            if (i == 0 or hash_large[lg_hash_and_tag >> short_cache_tag_bits] == 0) {
                ci.writeTaggedIndex(hash_large, lg_hash_and_tag, index);
            }
            // Only a full load fills the other positions.
            if (dtlm == .fast) break;
        }
    }
}

/// `ZSTD_fillDoubleHashTableForCCtx`: fills a context's tables from
/// `next_to_update` to `end`.
fn fillDoubleHashTableForCCtx(ms: *MatchState, end: [*]const u8, dtlm: DictTableLoadMethod) void {
    const cparams = &ms.cparams;
    const hash_large = ms.hash_table;
    const h_bits_l = cparams.hash_log;
    const mls = cparams.min_match;
    const hash_small = ms.chain_table;
    const h_bits_s = cparams.chain_log;
    const base = ms.window.base;
    var ip = base + ms.next_to_update;
    const iend = @intFromPtr(end) -% hash_read_size;

    // Every third position goes in both tables; the others into the large
    // table where their entry is empty.
    while (@intFromPtr(ip) + fast_hash_fill_step - 1 <= iend) : (ip += fast_hash_fill_step) {
        const curr: u32 = @intCast(@intFromPtr(ip) - @intFromPtr(base));
        for (0..fast_hash_fill_step) |i| {
            const sm_hash = ci.hashPtr(ip + i, h_bits_s, mls);
            const lg_hash = ci.hashPtr(ip + i, h_bits_l, 8);
            const index = curr + @as(u32, @intCast(i));
            if (i == 0) hash_small[sm_hash] = index;
            if (i == 0 or hash_large[lg_hash] == 0) hash_large[lg_hash] = index;
            // Only a full load fills the other positions.
            if (dtlm == .fast) break;
        }
    }
}

/// `ZSTD_fillDoubleHashTable`: loads `[base + next_to_update, end)` into
/// both tables, for a dictionary or a context.
pub fn fillDoubleHashTable(
    ms: *MatchState,
    end: [*]const u8,
    dtlm: DictTableLoadMethod,
    tfp: ci.TableFillPurpose,
) void {
    switch (tfp) {
        .for_cdict => fillDoubleHashTableForCDict(ms, end, dtlm),
        .for_cctx => fillDoubleHashTableForCCtx(ms, end, dtlm),
    }
}

/// Where the search loops go once a candidate is found.
const Found = enum {
    /// A short match at ip: look for a long one at ip + 1.
    search_next_long,
    /// ip, offset and m_length are set: store the sequence.
    match_found,
    /// The sequence is stored: move past it.
    match_stored,
};

/// `ZSTD_compressBlock_doubleFast_noDict_generic`.
inline fn compressBlockDoubleFastNoDictGeneric(
    ms: *MatchState,
    seq_store: *SeqStore,
    rep: *[rep_num]u32,
    src: []const u8,
    comptime mls: u32,
) usize {
    const cparams = &ms.cparams;
    const hash_long = ms.hash_table;
    const h_bits_l = cparams.hash_log;
    const hash_small = ms.chain_table;
    const h_bits_s = cparams.chain_log;
    const base = ms.window.base;
    const istart = src.ptr;
    var anchor = istart;
    const end_index: u32 = @intCast(@intFromPtr(istart) - @intFromPtr(base) + src.len);
    // A dictionary, if any, is attached.
    const prefix_lowest_index = ci.getLowestPrefixIndex(ms, end_index, cparams.window_log);
    const prefix_lowest = base + prefix_lowest_index;
    const iend = istart + src.len;
    const ilimit = @intFromPtr(iend) -% hash_read_size;
    var offset_1 = rep[0];
    var offset_2 = rep[1];
    var offset_saved1: u32 = 0;
    var offset_saved2: u32 = 0;

    var m_length: usize = undefined;
    var offset: u32 = undefined;
    var curr: u32 = undefined;

    // The positions to search before the step grows.
    const k_step_incr: usize = 1 << search_strength;
    // Where the step grows next if nothing is found.
    var next_step: usize = undefined;
    var step: usize = undefined;

    // The long hash at ip and ip1.
    var hl0: usize = undefined;
    var hl1: usize = undefined;

    // The long match indexes for ip and ip1.
    var idxl0: u32 = undefined;
    var idxl1: u32 = undefined;

    var matchl0: [*]const u8 = undefined;
    var matchs0: [*]const u8 = undefined;
    var matchl1: [*]const u8 = undefined;

    var ip = istart;
    var ip1: [*]const u8 = undefined;
    // Arbitrary bytes, unlikely to match the data, read instead of the
    // tables' candidates when those are invalid, so the range tests need
    // not branch.
    const dummy = [_]u8{ 0x12, 0x34, 0x56, 0x78, 0x9a, 0xbc, 0xde, 0xf0, 0xe2, 0xb4 };

    if (ip == prefix_lowest) ip += 1;
    {
        const current: u32 = @intCast(@intFromPtr(ip) - @intFromPtr(base));
        const window_low = ci.getLowestPrefixIndex(ms, current, cparams.window_log);
        const max_rep = current - window_low;
        if (offset_2 > max_rep) {
            offset_saved2 = offset_2;
            offset_2 = 0;
        }
        if (offset_1 > max_rep) {
            offset_saved1 = offset_1;
            offset_1 = 0;
        }
    }

    // One iteration per match found and stored.
    while (true) {
        step = 1;
        next_step = @intFromPtr(ip) + k_step_incr;
        ip1 = ip + step;

        if (@intFromPtr(ip1) > ilimit) break;

        hl0 = ci.hashPtr(ip, h_bits_l, 8);
        idxl0 = hash_long[hl0];
        matchl0 = base + idxl0;

        // One iteration per position searched.
        const found: Found = search: while (true) {
            const hs0 = ci.hashPtr(ip, h_bits_s, mls);
            const idxs0 = hash_small[hs0];
            curr = @intCast(@intFromPtr(ip) - @intFromPtr(base));
            matchs0 = base + idxs0;

            hash_small[hs0] = curr;
            hash_long[hl0] = curr;

            // The repeat offset, without a dictionary.
            if (offset_1 > 0 and
                std.mem.readInt(u32, (ip + 1 - offset_1)[0..4], native_endian) ==
                    std.mem.readInt(u32, (ip + 1)[0..4], native_endian))
            {
                m_length = ci.count(ip + 1 + 4, ip + 1 + 4 - offset_1, iend) + 4;
                ip += 1;
                const lit_length = @intFromPtr(ip) - @intFromPtr(anchor);
                ci.storeSeq(seq_store, lit_length, anchor, iend, ci.repcode1_to_offbase, m_length);
                break :search .match_stored;
            }

            hl1 = ci.hashPtr(ip1, h_bits_l, 8);

            // idxl0 > prefix_lowest_index is hard to predict; selecting the
            // address avoids a branch on it, and the code only branches on
            // it when the bytes match, which is rare.
            {
                const matchl0_safe = ci.selectAddr(idxl0, prefix_lowest_index, matchl0, &dummy);

                // A long match in the prefix.
                if (std.mem.readInt(u64, matchl0_safe[0..8], native_endian) ==
                    std.mem.readInt(u64, ip[0..8], native_endian) and matchl0_safe == matchl0)
                {
                    m_length = ci.count(ip + 8, matchl0 + 8, iend) + 8;
                    offset = @intCast(@intFromPtr(ip) - @intFromPtr(matchl0));
                    while (@intFromPtr(ip) > @intFromPtr(anchor) and
                        @intFromPtr(matchl0) > @intFromPtr(prefix_lowest) and
                        (ip - 1)[0] == (matchl0 - 1)[0])
                    {
                        ip -= 1;
                        matchl0 -= 1;
                        m_length += 1;
                    }
                    break :search .match_found;
                }
            }

            idxl1 = hash_long[hl1];
            matchl1 = base + idxl1;

            // The same for the short match.
            const matchs0_safe = ci.selectAddr(idxs0, prefix_lowest_index, matchs0, &dummy);

            // A short match in the prefix.
            if (std.mem.readInt(u32, matchs0_safe[0..4], native_endian) ==
                std.mem.readInt(u32, ip[0..4], native_endian) and matchs0_safe == matchs0)
            {
                break :search .search_next_long;
            }

            if (@intFromPtr(ip1) >= next_step) {
                @prefetch(ip1 + 64, .{ .locality = 3 });
                @prefetch(ip1 + 128, .{ .locality = 3 });
                step += 1;
                next_step += k_step_incr;
            }
            ip = ip1;
            ip1 += step;

            hl0 = hl1;
            idxl0 = idxl1;
            matchl0 = matchl1;
            if (builtin.cpu.arch == .aarch64) @prefetch(ip + 256, .{ .locality = 3 });
            if (@intFromPtr(ip1) > ilimit) return cleanup(
                rep,
                offset_1,
                offset_2,
                offset_saved1,
                offset_saved2,
                iend,
                anchor,
            );
        };

        next: switch (found) {
            .search_next_long => {
                // A short match: look for a longer one.
                m_length = ci.count(ip + 4, matchs0 + 4, iend) + 4;
                offset = @intCast(@intFromPtr(ip) - @intFromPtr(matchs0));

                // A long match at the next position.
                if (idxl1 > prefix_lowest_index and
                    std.mem.readInt(u64, matchl1[0..8], native_endian) ==
                        std.mem.readInt(u64, ip1[0..8], native_endian))
                {
                    const l1len = ci.count(ip1 + 8, matchl1 + 8, iend) + 8;
                    if (l1len > m_length) {
                        // Take the long match instead.
                        ip = ip1;
                        m_length = l1len;
                        offset = @intCast(@intFromPtr(ip) - @intFromPtr(matchl1));
                        matchs0 = matchl1;
                    }
                }

                while (@intFromPtr(ip) > @intFromPtr(anchor) and
                    @intFromPtr(matchs0) > @intFromPtr(prefix_lowest) and
                    (ip - 1)[0] == (matchs0 - 1)[0])
                {
                    ip -= 1;
                    matchs0 -= 1;
                    m_length += 1;
                }
                continue :next .match_found;
            },
            // Requires ip, offset and m_length.
            .match_found => {
                offset_2 = offset_1;
                offset_1 = offset;

                if (step < 4) {
                    // Writing ip1 is unsafe if it is at or past the position
                    // after this match. The shortest match is 4 bytes, so
                    // while the step from ip to ip1 is below 4, ip1 is before
                    // that position; this simpler test is faster.
                    hash_long[hl1] = @intCast(@intFromPtr(ip1) - @intFromPtr(base));
                }

                const lit_length = @intFromPtr(ip) - @intFromPtr(anchor);
                ci.storeSeq(seq_store, lit_length, anchor, iend, ci.offsetToOffbase(offset), m_length);
                continue :next .match_stored;
            },
            .match_stored => {
                ip += m_length;
                anchor = ip;

                if (@intFromPtr(ip) <= ilimit) {
                    // Candidates may be past iend - 8, so they go in here.
                    const index_to_insert = curr + 2;
                    hash_long[ci.hashPtr(base + index_to_insert, h_bits_l, 8)] = index_to_insert;
                    hash_long[ci.hashPtr(ip - 2, h_bits_l, 8)] =
                        @intCast(@intFromPtr(ip - 2) - @intFromPtr(base));
                    hash_small[ci.hashPtr(base + index_to_insert, h_bits_s, mls)] = index_to_insert;
                    hash_small[ci.hashPtr(ip - 1, h_bits_s, mls)] =
                        @intCast(@intFromPtr(ip - 1) - @intFromPtr(base));

                    // Immediate repeat offsets.
                    while (@intFromPtr(ip) <= ilimit and offset_2 > 0 and
                        std.mem.readInt(u32, ip[0..4], native_endian) ==
                            std.mem.readInt(u32, (ip - offset_2)[0..4], native_endian))
                    {
                        const r_length = ci.count(ip + 4, ip + 4 - offset_2, iend) + 4;
                        std.mem.swap(u32, &offset_1, &offset_2);
                        const index: u32 = @intCast(@intFromPtr(ip) - @intFromPtr(base));
                        hash_small[ci.hashPtr(ip, h_bits_s, mls)] = index;
                        hash_long[ci.hashPtr(ip, h_bits_l, 8)] = index;
                        ci.storeSeq(seq_store, 0, anchor, iend, ci.repcode1_to_offbase, r_length);
                        ip += r_length;
                        anchor = ip;
                    }
                }
            },
        }
    }
    return cleanup(rep, offset_1, offset_2, offset_saved1, offset_saved2, iend, anchor);
}

/// The end of `compressBlockDoubleFastNoDictGeneric`: restores the repeat
/// offsets set aside as invalid, and returns the size of the last literals.
inline fn cleanup(
    rep: *[rep_num]u32,
    offset_1: u32,
    offset_2: u32,
    offset_saved1: u32,
    offset_saved2_start: u32,
    iend: [*]const u8,
    anchor: [*]const u8,
) usize {
    // If offset_1 was invalid and became valid, the saved offsets rotate, as
    // in `fast.compressBlockFastNoDictGeneric`.
    var offset_saved2 = offset_saved2_start;
    if (offset_saved1 != 0 and offset_1 != 0) offset_saved2 = offset_saved1;

    rep[0] = if (offset_1 != 0) offset_1 else offset_saved1;
    rep[1] = if (offset_2 != 0) offset_2 else offset_saved2;

    return @intFromPtr(iend) - @intFromPtr(anchor);
}

/// `PREFETCH_AREA`: prefetches `size` bytes from `p` into the L2 cache.
fn prefetchArea(p: [*]const u8, size: usize) void {
    var pos: usize = 0;
    while (pos < size) : (pos += 64) @prefetch(p + pos, .{ .locality = 2 });
}

/// `ZSTD_compressBlock_doubleFast_dictMatchState_generic`.
inline fn compressBlockDoubleFastDictMatchStateGeneric(
    ms: *MatchState,
    seq_store: *SeqStore,
    rep: *[rep_num]u32,
    src: []const u8,
    comptime mls: u32,
) usize {
    const cparams = &ms.cparams;
    const hash_long = ms.hash_table;
    const h_bits_l = cparams.hash_log;
    const hash_small = ms.chain_table;
    const h_bits_s = cparams.chain_log;
    const base = ms.window.base;
    const istart = src.ptr;
    var ip = istart;
    var anchor = istart;
    const end_index: u32 = @intCast(@intFromPtr(istart) - @intFromPtr(base) + src.len);
    // A dictionary, if any, is attached.
    const prefix_lowest_index = ci.getLowestPrefixIndex(ms, end_index, cparams.window_log);
    const prefix_lowest = base + prefix_lowest_index;
    const iend = istart + src.len;
    const ilimit = @intFromPtr(iend) -% hash_read_size;
    var offset_1 = rep[0];
    var offset_2 = rep[1];

    const dms = ms.dict_match_state.?;
    const dict_cparams = &dms.cparams;
    const dict_hash_long = dms.hash_table;
    const dict_hash_small = dms.chain_table;
    const dict_start_index = dms.window.dict_limit;
    const dict_base = dms.window.base;
    const dict_start = dict_base + dict_start_index;
    const dict_end = dms.window.next_src;
    const dict_index_delta = prefix_lowest_index -
        @as(u32, @intCast(@intFromPtr(dict_end) - @intFromPtr(dict_base)));
    const dict_h_bits_l = dict_cparams.hash_log + short_cache_tag_bits;
    const dict_h_bits_s = dict_cparams.chain_log + short_cache_tag_bits;
    const dict_and_prefix_length: u32 = @intCast(@intFromPtr(ip) - @intFromPtr(prefix_lowest) +
        @intFromPtr(dict_end) - @intFromPtr(dict_start));

    // An attached dictionary is within the window.
    assert(ms.window.dict_limit + (@as(u32, 1) << @intCast(cparams.window_log)) >= end_index);

    if (ms.prefetch_cdict_tables) {
        const hash_table_bytes = (@as(usize, 1) << @intCast(dict_cparams.hash_log)) * @sizeOf(u32);
        const chain_table_bytes = (@as(usize, 1) << @intCast(dict_cparams.chain_log)) * @sizeOf(u32);
        prefetchArea(@ptrCast(dict_hash_long), hash_table_bytes);
        prefetchArea(@ptrCast(dict_hash_small), chain_table_bytes);
    }

    if (dict_and_prefix_length == 0) ip += 1;

    // The repeat-offset checks here do not handle a disabled (0) offset.
    assert(offset_1 <= dict_and_prefix_length);
    assert(offset_2 <= dict_and_prefix_length);

    // `<` rather than `<=`: the repeat offset is checked at ip + 1.
    while (@intFromPtr(ip) < ilimit) {
        var m_length: usize = undefined;
        var offset: u32 = undefined;
        const h2 = ci.hashPtr(ip, h_bits_l, 8);
        const h = ci.hashPtr(ip, h_bits_s, mls);
        const dict_hash_and_tag_l = ci.hashPtr(ip, dict_h_bits_l, 8);
        const dict_hash_and_tag_s = ci.hashPtr(ip, dict_h_bits_s, mls);
        const dict_match_index_and_tag_l = dict_hash_long[dict_hash_and_tag_l >> short_cache_tag_bits];
        const dict_match_index_and_tag_s = dict_hash_small[dict_hash_and_tag_s >> short_cache_tag_bits];
        const dict_tags_match_l = ci.comparePackedTags(dict_match_index_and_tag_l, dict_hash_and_tag_l);
        const dict_tags_match_s = ci.comparePackedTags(dict_match_index_and_tag_s, dict_hash_and_tag_s);
        const curr: u32 = @intCast(@intFromPtr(ip) - @intFromPtr(base));
        const match_index_l = hash_long[h2];
        var match_index_s = hash_small[h];
        var match_long = base + match_index_l;
        var match = base + match_index_s;
        const rep_index = curr + 1 -% offset_1;
        const rep_match = if (rep_index < prefix_lowest_index)
            dict_base + (rep_index -% dict_index_delta)
        else
            base + rep_index;
        hash_small[h] = curr;
        hash_long[h2] = curr;

        const found: Found = found: {
            // The repeat offset.
            if (ci.indexOverlapCheck(prefix_lowest_index, rep_index) and
                std.mem.readInt(u32, rep_match[0..4], native_endian) ==
                    std.mem.readInt(u32, (ip + 1)[0..4], native_endian))
            {
                const rep_match_end = if (rep_index < prefix_lowest_index) dict_end else iend;
                m_length = ci.count2Segments(ip + 1 + 4, rep_match + 4, iend, rep_match_end, prefix_lowest) + 4;
                ip += 1;
                const lit_length = @intFromPtr(ip) - @intFromPtr(anchor);
                ci.storeSeq(seq_store, lit_length, anchor, iend, ci.repcode1_to_offbase, m_length);
                break :found .match_stored;
            }

            if (match_index_l >= prefix_lowest_index and
                std.mem.readInt(u64, match_long[0..8], native_endian) ==
                    std.mem.readInt(u64, ip[0..8], native_endian))
            {
                // A long match in the prefix.
                m_length = ci.count(ip + 8, match_long + 8, iend) + 8;
                offset = @intCast(@intFromPtr(ip) - @intFromPtr(match_long));
                while (@intFromPtr(ip) > @intFromPtr(anchor) and
                    @intFromPtr(match_long) > @intFromPtr(prefix_lowest) and
                    (ip - 1)[0] == (match_long - 1)[0])
                {
                    ip -= 1;
                    match_long -= 1;
                    m_length += 1;
                }
                break :found .match_found;
            } else if (dict_tags_match_l) {
                // A long match in the dictionary.
                const dict_match_index_l = dict_match_index_and_tag_l >> short_cache_tag_bits;
                var dict_match_l = dict_base + dict_match_index_l;
                assert(@intFromPtr(dict_match_l) < @intFromPtr(dict_end));

                if (@intFromPtr(dict_match_l) > @intFromPtr(dict_start) and
                    std.mem.readInt(u64, dict_match_l[0..8], native_endian) ==
                        std.mem.readInt(u64, ip[0..8], native_endian))
                {
                    m_length = ci.count2Segments(ip + 8, dict_match_l + 8, iend, dict_end, prefix_lowest) + 8;
                    offset = curr - dict_match_index_l - dict_index_delta;
                    while (@intFromPtr(ip) > @intFromPtr(anchor) and
                        @intFromPtr(dict_match_l) > @intFromPtr(dict_start) and
                        (ip - 1)[0] == (dict_match_l - 1)[0])
                    {
                        ip -= 1;
                        dict_match_l -= 1;
                        m_length += 1;
                    }
                    break :found .match_found;
                }
            }

            if (match_index_s > prefix_lowest_index) {
                // A short match candidate.
                if (std.mem.readInt(u32, match[0..4], native_endian) ==
                    std.mem.readInt(u32, ip[0..4], native_endian))
                {
                    break :found .search_next_long;
                }
            } else if (dict_tags_match_s) {
                // A short match in the dictionary.
                const dict_match_index_s = dict_match_index_and_tag_s >> short_cache_tag_bits;
                match = dict_base + dict_match_index_s;
                match_index_s = dict_match_index_s + dict_index_delta;

                if (@intFromPtr(match) > @intFromPtr(dict_start) and
                    std.mem.readInt(u32, match[0..4], native_endian) ==
                        std.mem.readInt(u32, ip[0..4], native_endian))
                {
                    break :found .search_next_long;
                }
            }

            ip += ((@intFromPtr(ip) - @intFromPtr(anchor)) >> search_strength) + 1;
            if (builtin.cpu.arch == .aarch64) @prefetch(ip + 256, .{ .locality = 3 });
            continue;
        };

        next: switch (found) {
            .search_next_long => {
                const hl3 = ci.hashPtr(ip + 1, h_bits_l, 8);
                const dict_hash_and_tag_l3 = ci.hashPtr(ip + 1, dict_h_bits_l, 8);
                const match_index_l3 = hash_long[hl3];
                const dict_match_index_and_tag_l3 =
                    dict_hash_long[dict_hash_and_tag_l3 >> short_cache_tag_bits];
                const dict_tags_match_l3 =
                    ci.comparePackedTags(dict_match_index_and_tag_l3, dict_hash_and_tag_l3);
                var match_l3 = base + match_index_l3;
                hash_long[hl3] = curr + 1;

                // A long match in the prefix at the next position.
                if (match_index_l3 >= prefix_lowest_index and
                    std.mem.readInt(u64, match_l3[0..8], native_endian) ==
                        std.mem.readInt(u64, (ip + 1)[0..8], native_endian))
                {
                    m_length = ci.count(ip + 9, match_l3 + 8, iend) + 8;
                    ip += 1;
                    offset = @intCast(@intFromPtr(ip) - @intFromPtr(match_l3));
                    while (@intFromPtr(ip) > @intFromPtr(anchor) and
                        @intFromPtr(match_l3) > @intFromPtr(prefix_lowest) and
                        (ip - 1)[0] == (match_l3 - 1)[0])
                    {
                        ip -= 1;
                        match_l3 -= 1;
                        m_length += 1;
                    }
                    continue :next .match_found;
                } else if (dict_tags_match_l3) {
                    // A long match in the dictionary at the next position.
                    const dict_match_index_l3 = dict_match_index_and_tag_l3 >> short_cache_tag_bits;
                    var dict_match_l3 = dict_base + dict_match_index_l3;
                    assert(@intFromPtr(dict_match_l3) < @intFromPtr(dict_end));
                    if (@intFromPtr(dict_match_l3) > @intFromPtr(dict_start) and
                        std.mem.readInt(u64, dict_match_l3[0..8], native_endian) ==
                            std.mem.readInt(u64, (ip + 1)[0..8], native_endian))
                    {
                        m_length = ci.count2Segments(ip + 1 + 8, dict_match_l3 + 8, iend, dict_end, prefix_lowest) + 8;
                        ip += 1;
                        offset = curr + 1 - dict_match_index_l3 - dict_index_delta;
                        while (@intFromPtr(ip) > @intFromPtr(anchor) and
                            @intFromPtr(dict_match_l3) > @intFromPtr(dict_start) and
                            (ip - 1)[0] == (dict_match_l3 - 1)[0])
                        {
                            ip -= 1;
                            dict_match_l3 -= 1;
                            m_length += 1;
                        }
                        continue :next .match_found;
                    }
                }

                // No long match at the next position: take the short one.
                if (match_index_s < prefix_lowest_index) {
                    m_length = ci.count2Segments(ip + 4, match + 4, iend, dict_end, prefix_lowest) + 4;
                    offset = curr - match_index_s;
                    while (@intFromPtr(ip) > @intFromPtr(anchor) and
                        @intFromPtr(match) > @intFromPtr(dict_start) and
                        (ip - 1)[0] == (match - 1)[0])
                    {
                        ip -= 1;
                        match -= 1;
                        m_length += 1;
                    }
                } else {
                    m_length = ci.count(ip + 4, match + 4, iend) + 4;
                    offset = @intCast(@intFromPtr(ip) - @intFromPtr(match));
                    while (@intFromPtr(ip) > @intFromPtr(anchor) and
                        @intFromPtr(match) > @intFromPtr(prefix_lowest) and
                        (ip - 1)[0] == (match - 1)[0])
                    {
                        ip -= 1;
                        match -= 1;
                        m_length += 1;
                    }
                }
                continue :next .match_found;
            },
            .match_found => {
                offset_2 = offset_1;
                offset_1 = offset;

                const lit_length = @intFromPtr(ip) - @intFromPtr(anchor);
                ci.storeSeq(seq_store, lit_length, anchor, iend, ci.offsetToOffbase(offset), m_length);
                continue :next .match_stored;
            },
            .match_stored => {
                ip += m_length;
                anchor = ip;

                if (@intFromPtr(ip) <= ilimit) {
                    // Candidates may be past iend - 8, so they go in here.
                    const index_to_insert = curr + 2;
                    hash_long[ci.hashPtr(base + index_to_insert, h_bits_l, 8)] = index_to_insert;
                    hash_long[ci.hashPtr(ip - 2, h_bits_l, 8)] =
                        @intCast(@intFromPtr(ip - 2) - @intFromPtr(base));
                    hash_small[ci.hashPtr(base + index_to_insert, h_bits_s, mls)] = index_to_insert;
                    hash_small[ci.hashPtr(ip - 1, h_bits_s, mls)] =
                        @intCast(@intFromPtr(ip - 1) - @intFromPtr(base));

                    // Immediate repeat offsets.
                    while (@intFromPtr(ip) <= ilimit) {
                        const current2: u32 = @intCast(@intFromPtr(ip) - @intFromPtr(base));
                        const rep_index2 = current2 -% offset_2;
                        const rep_match2 = if (rep_index2 < prefix_lowest_index)
                            dict_base + rep_index2 - dict_index_delta
                        else
                            base + rep_index2;
                        if (ci.indexOverlapCheck(prefix_lowest_index, rep_index2) and
                            std.mem.readInt(u32, rep_match2[0..4], native_endian) ==
                                std.mem.readInt(u32, ip[0..4], native_endian))
                        {
                            const rep_end2 = if (rep_index2 < prefix_lowest_index) dict_end else iend;
                            const rep_length2 = ci.count2Segments(ip + 4, rep_match2 + 4, iend, rep_end2, prefix_lowest) + 4;
                            std.mem.swap(u32, &offset_1, &offset_2);
                            ci.storeSeq(seq_store, 0, anchor, iend, ci.repcode1_to_offbase, rep_length2);
                            hash_small[ci.hashPtr(ip, h_bits_s, mls)] = current2;
                            hash_long[ci.hashPtr(ip, h_bits_l, 8)] = current2;
                            ip += rep_length2;
                            anchor = ip;
                            continue;
                        }
                        break;
                    }
                }
            },
        }
    }

    rep[0] = offset_1;
    rep[1] = offset_2;

    return @intFromPtr(iend) - @intFromPtr(anchor);
}

/// `ZSTD_compressBlock_doubleFast`: the block compressor without a dictionary.
pub fn compressBlockDoubleFast(
    ms: *MatchState,
    seq_store: *SeqStore,
    rep: *[rep_num]u32,
    src: []const u8,
) usize {
    return switch (ms.cparams.min_match) {
        5 => compressBlockDoubleFastNoDictGeneric(ms, seq_store, rep, src, 5),
        6 => compressBlockDoubleFastNoDictGeneric(ms, seq_store, rep, src, 6),
        7 => compressBlockDoubleFastNoDictGeneric(ms, seq_store, rep, src, 7),
        // 3 and 4.
        else => compressBlockDoubleFastNoDictGeneric(ms, seq_store, rep, src, 4),
    };
}

/// `ZSTD_compressBlock_doubleFast_dictMatchState`: the block compressor
/// with an attached dictionary.
pub fn compressBlockDoubleFastDictMatchState(
    ms: *MatchState,
    seq_store: *SeqStore,
    rep: *[rep_num]u32,
    src: []const u8,
) usize {
    return switch (ms.cparams.min_match) {
        5 => compressBlockDoubleFastDictMatchStateGeneric(ms, seq_store, rep, src, 5),
        6 => compressBlockDoubleFastDictMatchStateGeneric(ms, seq_store, rep, src, 6),
        7 => compressBlockDoubleFastDictMatchStateGeneric(ms, seq_store, rep, src, 7),
        else => compressBlockDoubleFastDictMatchStateGeneric(ms, seq_store, rep, src, 4),
    };
}

/// `ZSTD_compressBlock_doubleFast_extDict_generic`.
fn compressBlockDoubleFastExtDictGeneric(
    ms: *MatchState,
    seq_store: *SeqStore,
    rep: *[rep_num]u32,
    src: []const u8,
    comptime mls: u32,
) usize {
    const cparams = &ms.cparams;
    const hash_long = ms.hash_table;
    const h_bits_l = cparams.hash_log;
    const hash_small = ms.chain_table;
    const h_bits_s = cparams.chain_log;
    const istart = src.ptr;
    var ip = istart;
    var anchor = istart;
    const iend = istart + src.len;
    const ilimit = @intFromPtr(iend) -% 8;
    const base = ms.window.base;
    const end_index: u32 = @intCast(@intFromPtr(istart) - @intFromPtr(base) + src.len);
    const low_limit = ci.getLowestMatchIndex(ms, end_index, cparams.window_log);
    const dict_start_index = low_limit;
    const dict_limit = ms.window.dict_limit;
    const prefix_start_index = if (dict_limit > low_limit) dict_limit else low_limit;
    const prefix_start = base + prefix_start_index;
    const dict_base = ms.window.dict_base;
    const dict_start = dict_base + dict_start_index;
    const dict_end = dict_base + prefix_start_index;
    var offset_1 = rep[0];
    var offset_2 = rep[1];

    // The external dictionary is out of the window: no dictionary after all.
    if (prefix_start_index == dict_start_index) {
        return compressBlockDoubleFast(ms, seq_store, rep, src);
    }

    // `<` rather than `<=`: the repeat offset is checked at ip + 1.
    while (@intFromPtr(ip) < ilimit) {
        const h_small = ci.hashPtr(ip, h_bits_s, mls);
        const match_index = hash_small[h_small];
        const match_base = if (match_index < prefix_start_index) dict_base else base;
        var match = match_base + match_index;

        const h_long = ci.hashPtr(ip, h_bits_l, 8);
        const match_long_index = hash_long[h_long];
        const match_long_base = if (match_long_index < prefix_start_index) dict_base else base;
        var match_long = match_long_base + match_long_index;

        const curr: u32 = @intCast(@intFromPtr(ip) - @intFromPtr(base));
        // offset_1 is expected at most curr + 1.
        const rep_index = curr + 1 -% offset_1;
        const rep_base = if (rep_index < prefix_start_index) dict_base else base;
        const rep_match = rep_base + rep_index;
        var m_length: usize = undefined;
        hash_small[h_small] = curr;
        hash_long[h_long] = curr;

        // The search is at curr + 1.
        if (ci.indexOverlapCheck(prefix_start_index, rep_index) and
            offset_1 <= curr + 1 - dict_start_index and
            std.mem.readInt(u32, rep_match[0..4], native_endian) ==
                std.mem.readInt(u32, (ip + 1)[0..4], native_endian))
        {
            const rep_match_end = if (rep_index < prefix_start_index) dict_end else iend;
            m_length = ci.count2Segments(ip + 1 + 4, rep_match + 4, iend, rep_match_end, prefix_start) + 4;
            ip += 1;
            const lit_length = @intFromPtr(ip) - @intFromPtr(anchor);
            ci.storeSeq(seq_store, lit_length, anchor, iend, ci.repcode1_to_offbase, m_length);
        } else if (match_long_index > dict_start_index and
            std.mem.readInt(u64, match_long[0..8], native_endian) ==
                std.mem.readInt(u64, ip[0..8], native_endian))
        {
            const match_end = if (match_long_index < prefix_start_index) dict_end else iend;
            const low_match_ptr = if (match_long_index < prefix_start_index) dict_start else prefix_start;
            m_length = ci.count2Segments(ip + 8, match_long + 8, iend, match_end, prefix_start) + 8;
            const offset = curr - match_long_index;
            while (@intFromPtr(ip) > @intFromPtr(anchor) and
                @intFromPtr(match_long) > @intFromPtr(low_match_ptr) and
                (ip - 1)[0] == (match_long - 1)[0])
            {
                ip -= 1;
                match_long -= 1;
                m_length += 1;
            }
            offset_2 = offset_1;
            offset_1 = offset;
            const lit_length = @intFromPtr(ip) - @intFromPtr(anchor);
            ci.storeSeq(seq_store, lit_length, anchor, iend, ci.offsetToOffbase(offset), m_length);
        } else if (match_index > dict_start_index and
            std.mem.readInt(u32, match[0..4], native_endian) ==
                std.mem.readInt(u32, ip[0..4], native_endian))
        {
            const h3 = ci.hashPtr(ip + 1, h_bits_l, 8);
            const match_index3 = hash_long[h3];
            const match3_base = if (match_index3 < prefix_start_index) dict_base else base;
            var match3 = match3_base + match_index3;
            var offset: u32 = undefined;
            hash_long[h3] = curr + 1;
            if (match_index3 > dict_start_index and
                std.mem.readInt(u64, match3[0..8], native_endian) ==
                    std.mem.readInt(u64, (ip + 1)[0..8], native_endian))
            {
                const match_end = if (match_index3 < prefix_start_index) dict_end else iend;
                const low_match_ptr = if (match_index3 < prefix_start_index) dict_start else prefix_start;
                m_length = ci.count2Segments(ip + 9, match3 + 8, iend, match_end, prefix_start) + 8;
                ip += 1;
                offset = curr + 1 - match_index3;
                while (@intFromPtr(ip) > @intFromPtr(anchor) and
                    @intFromPtr(match3) > @intFromPtr(low_match_ptr) and
                    (ip - 1)[0] == (match3 - 1)[0])
                {
                    ip -= 1;
                    match3 -= 1;
                    m_length += 1;
                }
            } else {
                const match_end = if (match_index < prefix_start_index) dict_end else iend;
                const low_match_ptr = if (match_index < prefix_start_index) dict_start else prefix_start;
                m_length = ci.count2Segments(ip + 4, match + 4, iend, match_end, prefix_start) + 4;
                offset = curr - match_index;
                while (@intFromPtr(ip) > @intFromPtr(anchor) and
                    @intFromPtr(match) > @intFromPtr(low_match_ptr) and
                    (ip - 1)[0] == (match - 1)[0])
                {
                    ip -= 1;
                    match -= 1;
                    m_length += 1;
                }
            }
            offset_2 = offset_1;
            offset_1 = offset;
            const lit_length = @intFromPtr(ip) - @intFromPtr(anchor);
            ci.storeSeq(seq_store, lit_length, anchor, iend, ci.offsetToOffbase(offset), m_length);
        } else {
            ip += ((@intFromPtr(ip) - @intFromPtr(anchor)) >> search_strength) + 1;
            continue;
        }

        // On to the next sequence.
        ip += m_length;
        anchor = ip;

        if (@intFromPtr(ip) <= ilimit) {
            // Candidates may be past iend - 8, so they go in here.
            const index_to_insert = curr + 2;
            hash_long[ci.hashPtr(base + index_to_insert, h_bits_l, 8)] = index_to_insert;
            hash_long[ci.hashPtr(ip - 2, h_bits_l, 8)] =
                @intCast(@intFromPtr(ip - 2) - @intFromPtr(base));
            hash_small[ci.hashPtr(base + index_to_insert, h_bits_s, mls)] = index_to_insert;
            hash_small[ci.hashPtr(ip - 1, h_bits_s, mls)] =
                @intCast(@intFromPtr(ip - 1) - @intFromPtr(base));

            // Immediate repeat offsets.
            while (@intFromPtr(ip) <= ilimit) {
                const current2: u32 = @intCast(@intFromPtr(ip) - @intFromPtr(base));
                const rep_index2 = current2 -% offset_2;
                const rep_match2 = if (rep_index2 < prefix_start_index)
                    dict_base + rep_index2
                else
                    base + rep_index2;
                if (ci.indexOverlapCheck(prefix_start_index, rep_index2) and
                    offset_2 <= current2 - dict_start_index and
                    std.mem.readInt(u32, rep_match2[0..4], native_endian) ==
                        std.mem.readInt(u32, ip[0..4], native_endian))
                {
                    const rep_end2 = if (rep_index2 < prefix_start_index) dict_end else iend;
                    const rep_length2 = ci.count2Segments(ip + 4, rep_match2 + 4, iend, rep_end2, prefix_start) + 4;
                    std.mem.swap(u32, &offset_1, &offset_2);
                    ci.storeSeq(seq_store, 0, anchor, iend, ci.repcode1_to_offbase, rep_length2);
                    hash_small[ci.hashPtr(ip, h_bits_s, mls)] = current2;
                    hash_long[ci.hashPtr(ip, h_bits_l, 8)] = current2;
                    ip += rep_length2;
                    anchor = ip;
                    continue;
                }
                break;
            }
        }
    }

    rep[0] = offset_1;
    rep[1] = offset_2;

    return @intFromPtr(iend) - @intFromPtr(anchor);
}

/// `ZSTD_compressBlock_doubleFast_extDict`: the block compressor with an
/// external dictionary.
pub fn compressBlockDoubleFastExtDict(
    ms: *MatchState,
    seq_store: *SeqStore,
    rep: *[rep_num]u32,
    src: []const u8,
) usize {
    return switch (ms.cparams.min_match) {
        5 => compressBlockDoubleFastExtDictGeneric(ms, seq_store, rep, src, 5),
        6 => compressBlockDoubleFastExtDictGeneric(ms, seq_store, rep, src, 6),
        7 => compressBlockDoubleFastExtDictGeneric(ms, seq_store, rep, src, 7),
        else => compressBlockDoubleFastExtDictGeneric(ms, seq_store, rep, src, 4),
    };
}
