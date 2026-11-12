//! The `fast` strategy's match finder, from the original's zstd_fast.c: one
//! hash table, searched at every other position and more sparsely the longer
//! it finds nothing, with a repeat-offset check ahead of each position.

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
const hot_code_align = ci.hot_code_align;

/// Positions between the hash table entries a fill always writes.
const fast_hash_fill_step = 3;

/// `ZSTD_fillHashTableForCDict`: fills a dictionary's hash table, with
/// short-cache tags, from `next_to_update` to `end`.
fn fillHashTableForCDict(ms: *MatchState, end: [*]const u8, dtlm: DictTableLoadMethod) void {
    const cparams = &ms.cparams;
    const hash_table = ms.hash_table;
    const h_bits = cparams.hash_log + short_cache_tag_bits;
    const mls = cparams.min_match;
    const base = ms.window.base;
    var ip = base + ms.next_to_update;
    const iend = @intFromPtr(end) -% hash_read_size;

    // Dictionaries are always filled in full.
    assert(dtlm == .full);

    // Every third position goes in; the others only where their entry is empty.
    while (@intFromPtr(ip) + fast_hash_fill_step < iend +% 2) : (ip += fast_hash_fill_step) {
        const curr: u32 = @intCast(@intFromPtr(ip) -% @intFromPtr(base));
        ci.writeTaggedIndex(hash_table, ci.hashPtr(ip, h_bits, mls), curr);

        if (dtlm == .fast) continue;
        for (1..fast_hash_fill_step) |p| {
            const hash_and_tag = ci.hashPtr(ip + p, h_bits, mls);
            if (hash_table[hash_and_tag >> short_cache_tag_bits] == 0) {
                ci.writeTaggedIndex(hash_table, hash_and_tag, curr + @as(u32, @intCast(p)));
            }
        }
    }
}

/// `ZSTD_fillHashTableForCCtx`: fills a context's hash table from
/// `next_to_update` to `end`.
fn fillHashTableForCCtx(ms: *MatchState, end: [*]const u8, dtlm: DictTableLoadMethod) void {
    const cparams = &ms.cparams;
    const hash_table = ms.hash_table;
    const h_bits = cparams.hash_log;
    const mls = cparams.min_match;
    const base = ms.window.base;
    var ip = base + ms.next_to_update;
    const iend = @intFromPtr(end) -% hash_read_size;

    // Contexts are always filled fast.
    assert(dtlm == .fast);

    // Every third position goes in; the others only where their entry is empty.
    while (@intFromPtr(ip) + fast_hash_fill_step < iend +% 2) : (ip += fast_hash_fill_step) {
        const curr: u32 = @intCast(@intFromPtr(ip) -% @intFromPtr(base));
        hash_table[ci.hashPtr(ip, h_bits, mls)] = curr;
        if (dtlm == .fast) continue;
        for (1..fast_hash_fill_step) |p| {
            const hash = ci.hashPtr(ip + p, h_bits, mls);
            if (hash_table[hash] == 0) hash_table[hash] = curr + @as(u32, @intCast(p));
        }
    }
}

/// `ZSTD_fillHashTable`: loads `[base + next_to_update, end)` into the hash
/// table, for a dictionary or a context.
pub fn fillHashTable(
    ms: *MatchState,
    end: [*]const u8,
    dtlm: DictTableLoadMethod,
    tfp: ci.TableFillPurpose,
) void {
    switch (tfp) {
        .for_cdict => fillHashTableForCDict(ms, end, dtlm),
        .for_cctx => fillHashTableForCCtx(ms, end, dtlm),
    }
}

/// `ZSTD_match4Found_cmov`: whether the 4 bytes at `current` match those at
/// `match_address`, a valid match (`match_idx >= idx_low_limit`). Reads a
/// constant instead of an invalid match, so the range check need not branch.
inline fn match4FoundCmov(
    current: [*]const u8,
    match_address: [*]const u8,
    match_idx: u32,
    idx_low_limit: u32,
) bool {
    // Arbitrary bytes, unlikely to match the data.
    const dummy = [4]u8{ 0x12, 0x34, 0x56, 0x78 };
    const mval_addr = ci.selectAddr(match_idx, idx_low_limit, match_address, &dummy);
    // The data test comes first: inlined, the two tests become branches in
    // this order.
    if (std.mem.readInt(u32, current[0..4], native_endian) !=
        std.mem.readInt(u32, mval_addr[0..4], native_endian)) return false;
    return match_idx >= idx_low_limit;
}

/// `ZSTD_match4Found_branch`: as `match4FoundCmov`, with a branch on the
/// range, faster where most candidates are in range.
inline fn match4FoundBranch(
    current: [*]const u8,
    match_address: [*]const u8,
    match_idx: u32,
    idx_low_limit: u32,
) bool {
    const cur = std.mem.readInt(u32, current[0..4], native_endian);
    const mval = if (match_idx >= idx_low_limit)
        std.mem.readInt(u32, match_address[0..4], native_endian)
    else
        cur ^ 1; // Never matches.
    return cur == mval;
}

/// `ZSTD_compressBlock_fast_noDict_generic`.
///
/// Each position's search has four dependent steps: hash, table lookup,
/// load of the candidate, compare. Rather than run them one position at a
/// time, the loop overlaps them across the next few positions, like a CPU
/// pipeline (R: repeat-offset check, H: hash, T: table lookup, M: match load
/// and compare):
///
///     pos | time ->
///     N   | ... M
///     N+1 | ...   TM
///     N+2 |    R H   T M
///     N+3 |         H    TM
///     N+4 |           R H   T M
///
/// A match flushes the pipeline; the loop then starts it again with a hash
/// and lookup at N and a hash at N+1.
noinline fn compressBlockFastNoDictGeneric(
    ms: *MatchState,
    seq_store: *SeqStore,
    rep: *[rep_num]u32,
    src: []const u8,
    comptime mls: u32,
    comptime use_cmov: bool,
) align(hot_code_align) usize {
    const cparams = &ms.cparams;
    const hash_table = ms.hash_table;
    const hlog = cparams.hash_log;
    // At least 2.
    const step_size: usize = @as(usize, cparams.target_length) +
        @intFromBool(cparams.target_length == 0) + 1;
    const base = ms.window.base;
    const istart = src.ptr;
    const end_index: u32 = @intCast(@intFromPtr(istart) -% @intFromPtr(base) +% src.len);
    const prefix_start_index = ci.getLowestPrefixIndex(ms, end_index, cparams.window_log);
    const prefix_start = base + prefix_start_index;
    const iend = istart + src.len;
    const ilimit = @intFromPtr(iend) -% hash_read_size;

    var anchor = istart;
    var ip0 = istart;
    var ip1: [*]const u8 = undefined;
    var ip2: [*]const u8 = undefined;
    var ip3: [*]const u8 = undefined;
    var current0: u32 = undefined;

    var rep_offset1 = rep[0];
    var rep_offset2 = rep[1];
    var offset_saved1: u32 = 0;
    var offset_saved2: u32 = 0;

    var hash0: usize = undefined;
    var hash1: usize = undefined;
    var match_idx: u32 = undefined;

    var offcode: u32 = undefined;
    var match0: [*]const u8 = undefined;
    var m_length: usize = undefined;

    // ip0 and ip1 are always adjacent. The step, from ip0 to ip2 and from
    // ip1 to ip3, applies the target length and the acceleration over
    // incompressible data to every other position.
    var step: usize = undefined;
    var next_step: usize = undefined;
    const k_step_incr: usize = 1 << (ci.search_strength - 1);

    if (ip0 == prefix_start) ip0 += 1;
    {
        const curr: u32 = @intCast(@intFromPtr(ip0) -% @intFromPtr(base));
        const window_low = ci.getLowestPrefixIndex(ms, curr, cparams.window_log);
        const max_rep = curr - window_low;
        if (rep_offset2 > max_rep) {
            offset_saved2 = rep_offset2;
            rep_offset2 = 0;
        }
        if (rep_offset1 > max_rep) {
            offset_saved1 = rep_offset1;
            rep_offset1 = 0;
        }
    }

    const State = enum { start, offset, match, cleanup };
    state: switch (State.start) {
        // Requires ip0.
        .start => {
            step = step_size;
            next_step = @intFromPtr(ip0) + k_step_incr;

            // ip0 - anchor == 0, so the step needs no update.
            ip1 = ip0 + 1;
            ip2 = ip0 + step;
            ip3 = ip2 + 1;

            if (@intFromPtr(ip3) >= ilimit) continue :state .cleanup;

            hash0 = ci.hashPtr(ip0, hlog, mls);
            hash1 = ci.hashPtr(ip1, hlog, mls);

            match_idx = hash_table[hash0];

            while (true) {
                // The repeat-offset candidate for ip2.
                const rval = std.mem.readInt(u32, (ip2 - rep_offset1)[0..4], native_endian);

                current0 = @intCast(@intFromPtr(ip0) -% @intFromPtr(base));
                hash_table[hash0] = current0;

                // Both tests are made, with no branch between them.
                if ((std.mem.readInt(u32, ip2[0..4], native_endian) == rval) & (rep_offset1 > 0)) {
                    ip0 = ip2;
                    match0 = ip0 - rep_offset1;
                    m_length = @intFromBool((ip0 - 1)[0] == (match0 - 1)[0]);
                    ip0 -= m_length;
                    match0 -= m_length;
                    offcode = ci.repcode1_to_offbase;
                    m_length += 4;

                    // The next entry is already hashed, and ip1 is before
                    // the match at ip2, so writing it is safe.
                    hash_table[hash1] = @intCast(@intFromPtr(ip1) -% @intFromPtr(base));
                    continue :state .match;
                }

                const found0 = if (use_cmov)
                    match4FoundCmov(ip0, base + match_idx, match_idx, prefix_start_index)
                else
                    match4FoundBranch(ip0, base + match_idx, match_idx, prefix_start_index);
                if (found0) {
                    // Already hashed; ip1 == ip0 + 1, so the search resumes
                    // after it.
                    hash_table[hash1] = @intCast(@intFromPtr(ip1) -% @intFromPtr(base));
                    continue :state .offset;
                }

                // Look up ip1, hash ip2.
                match_idx = hash_table[hash1];
                hash0 = hash1;
                hash1 = ci.hashPtr(ip2, hlog, mls);

                ip0 = ip1;
                ip1 = ip2;
                ip2 = ip3;

                current0 = @intCast(@intFromPtr(ip0) -% @intFromPtr(base));
                hash_table[hash0] = current0;

                const found1 = if (use_cmov)
                    match4FoundCmov(ip0, base + match_idx, match_idx, prefix_start_index)
                else
                    match4FoundBranch(ip0, base + match_idx, match_idx, prefix_start_index);
                if (found1) {
                    // The next entry is already hashed. The shortest match is
                    // 4 bytes, so the search resumes at ip0 + 4 or later; with
                    // a larger step, ip1 could be past that.
                    if (step <= 4) {
                        hash_table[hash1] = @intCast(@intFromPtr(ip1) -% @intFromPtr(base));
                    }
                    continue :state .offset;
                }

                // Look up ip1, hash ip2.
                match_idx = hash_table[hash1];
                hash0 = hash1;
                hash1 = ci.hashPtr(ip2, hlog, mls);

                ip0 = ip1;
                ip1 = ip2;
                ip2 = ip0 + step;
                ip3 = ip1 + step;

                if (@intFromPtr(ip2) >= next_step) {
                    step += 1;
                    @prefetch(ip1 + 64, .{ .locality = 3 });
                    @prefetch(ip1 + 128, .{ .locality = 3 });
                    next_step += k_step_incr;
                }
                if (@intFromPtr(ip3) >= ilimit) break;
            }
            continue :state .cleanup;
        },
        .cleanup => {
            // A few positions are left unsearched: searching them costs more
            // time than it gains.

            // Repeat offsets outside the prefix were set to 0 before the
            // loop, and are restored here for the history. If both were
            // invalid and only the first became valid again, the second is
            // the first's saved value; the second cannot become valid alone.
            if (offset_saved1 != 0 and rep_offset1 != 0) offset_saved2 = offset_saved1;

            rep[0] = if (rep_offset1 != 0) rep_offset1 else offset_saved1;
            rep[1] = if (rep_offset2 != 0) rep_offset2 else offset_saved2;

            return @intFromPtr(iend) - @intFromPtr(anchor);
        },
        // Requires ip0 and match_idx.
        .offset => {
            match0 = base + match_idx;
            rep_offset2 = rep_offset1;
            rep_offset1 = @intCast(@intFromPtr(ip0) - @intFromPtr(match0));
            offcode = ci.offsetToOffbase(rep_offset1);
            m_length = 4;

            // Extend the match backwards.
            while (@intFromPtr(ip0) > @intFromPtr(anchor) and
                @intFromPtr(match0) > @intFromPtr(prefix_start) and
                (ip0 - 1)[0] == (match0 - 1)[0])
            {
                ip0 -= 1;
                match0 -= 1;
                m_length += 1;
            }
            continue :state .match;
        },
        // Requires ip0, match0 and offcode.
        .match => {
            m_length += ci.count(ip0 + m_length, match0 + m_length, iend);

            const lit_length = @intFromPtr(ip0) - @intFromPtr(anchor);
            ci.storeSeq(seq_store, lit_length, anchor, iend, offcode, m_length);

            ip0 += m_length;
            anchor = ip0;

            // Fill the table, and check for an immediate repeat offset.
            if (@intFromPtr(ip0) <= ilimit) {
                // current0 + 2 may be past iend - 8, so it goes in here.
                assert(@intFromPtr(base + current0 + 2) > @intFromPtr(istart));
                hash_table[ci.hashPtr(base + current0 + 2, hlog, mls)] = current0 + 2;
                hash_table[ci.hashPtr(ip0 - 2, hlog, mls)] =
                    @intCast(@intFromPtr(ip0 - 2) -% @intFromPtr(base));

                // A second offset of 0 is invalid.
                if (rep_offset2 > 0) {
                    while (@intFromPtr(ip0) <= ilimit and
                        std.mem.readInt(u32, ip0[0..4], native_endian) ==
                            std.mem.readInt(u32, (ip0 - rep_offset2)[0..4], native_endian))
                    {
                        const r_length = ci.count(ip0 + 4, ip0 + 4 - rep_offset2, iend) + 4;
                        // Swapped through a temporary, as in the original: std.mem.swap goes
                        // byte by byte, which splits both offsets into bytes for the whole loop.
                        const tmp_off = rep_offset2;
                        rep_offset2 = rep_offset1;
                        rep_offset1 = tmp_off;
                        hash_table[ci.hashPtr(ip0, hlog, mls)] =
                            @intCast(@intFromPtr(ip0) -% @intFromPtr(base));
                        ip0 += r_length;
                        ci.storeSeq(seq_store, 0, anchor, iend, ci.repcode1_to_offbase, r_length);
                        anchor = ip0;
                    }
                }
            }
            continue :state .start;
        },
    }
}

/// `ZSTD_compressBlock_fast`: the block compressor without a dictionary.
/// Each variant is a function of its own, so each starts on a page of its
/// own (`hot_code_align`); inlined here, as the original's are, the variants
/// shared one 17 KiB function whose page boundaries fell inside half their
/// loops.
pub fn compressBlockFast(
    ms: *MatchState,
    seq_store: *SeqStore,
    rep: *[rep_num]u32,
    src: []const u8,
) usize {
    const mml = ms.cparams.min_match;
    // The conditional move pays where the range test is hard to predict.
    const use_cmov = ms.cparams.window_log < 19;
    assert(ms.dict_match_state == null);
    if (use_cmov) {
        return switch (mml) {
            5 => compressBlockFastNoDictGeneric(ms, seq_store, rep, src, 5, true),
            6 => compressBlockFastNoDictGeneric(ms, seq_store, rep, src, 6, true),
            7 => compressBlockFastNoDictGeneric(ms, seq_store, rep, src, 7, true),
            // 3 and 4.
            else => compressBlockFastNoDictGeneric(ms, seq_store, rep, src, 4, true),
        };
    }
    return switch (mml) {
        5 => compressBlockFastNoDictGeneric(ms, seq_store, rep, src, 5, false),
        6 => compressBlockFastNoDictGeneric(ms, seq_store, rep, src, 6, false),
        7 => compressBlockFastNoDictGeneric(ms, seq_store, rep, src, 7, false),
        else => compressBlockFastNoDictGeneric(ms, seq_store, rep, src, 4, false),
    };
}

/// `PREFETCH_AREA`: prefetches `size` bytes from `p` into the L2 cache.
fn prefetchArea(p: [*]const u8, size: usize) void {
    var pos: usize = 0;
    while (pos < size) : (pos += 64) @prefetch(p + pos, .{ .locality = 2 });
}

/// `ZSTD_compressBlock_fast_dictMatchState_generic`. `has_step` is not
/// used to specialise, as in the original.
noinline fn compressBlockFastDictMatchStateGeneric(
    ms: *MatchState,
    seq_store: *SeqStore,
    rep: *[rep_num]u32,
    src: []const u8,
    comptime mls: u32,
    comptime has_step: bool,
) align(hot_code_align) usize {
    _ = has_step;
    const cparams = &ms.cparams;
    const hash_table = ms.hash_table;
    const hlog = cparams.hash_log;
    // A target length of 0 still steps by 1.
    const step_size: u32 = cparams.target_length + @intFromBool(cparams.target_length == 0);
    const base = ms.window.base;
    const istart = src.ptr;
    var ip0 = istart;
    var ip1 = ip0 + step_size;
    var anchor = istart;
    const prefix_start_index = ms.window.dict_limit;
    const prefix_start = base + prefix_start_index;
    const iend = istart + src.len;
    const ilimit = @intFromPtr(iend) -% hash_read_size;
    var offset_1 = rep[0];
    var offset_2 = rep[1];

    const dms = ms.dict_match_state.?;
    const dict_cparams = &dms.cparams;
    const dict_hash_table = dms.hash_table;
    const dict_start_index = dms.window.dict_limit;
    const dict_base = dms.window.base;
    const dict_start = dict_base + dict_start_index;
    const dict_end = dms.window.next_src;
    const dict_index_delta = prefix_start_index -
        @as(u32, @intCast(@intFromPtr(dict_end) -% @intFromPtr(dict_base)));
    const dict_and_prefix_length: u32 = @intCast(@intFromPtr(istart) - @intFromPtr(prefix_start) +
        @intFromPtr(dict_end) - @intFromPtr(dict_start));
    const dict_h_bits = dict_cparams.hash_log + short_cache_tag_bits;

    // An attached dictionary is within the window.
    const max_distance = @as(u32, 1) << @intCast(cparams.window_log);
    const end_index: u32 = @intCast(@intFromPtr(istart) -% @intFromPtr(base) +% src.len);
    assert(end_index - prefix_start_index <= max_distance);

    // Dictionary indexes translate to this window's without underflow.
    assert(prefix_start_index >=
        @as(u32, @intCast(@intFromPtr(dict_end) -% @intFromPtr(dict_base))));

    if (ms.prefetch_cdict_tables) {
        const hash_table_bytes = (@as(usize, 1) << @intCast(dict_cparams.hash_log)) * @sizeOf(u32);
        prefetchArea(@ptrCast(dict_hash_table), hash_table_bytes);
    }

    if (dict_and_prefix_length == 0) ip0 += 1;
    // The repeat-offset checks here do not handle a disabled (0) offset.
    assert(offset_1 <= dict_and_prefix_length);
    assert(offset_2 <= dict_and_prefix_length);

    assert(step_size >= 1);
    outer: while (@intFromPtr(ip1) <= ilimit) {
        // ip0 < ip1, so the repeat-offset check at ip0 + 1 is safe.
        var m_length: usize = undefined;
        var hash0 = ci.hashPtr(ip0, hlog, mls);

        const dict_hash_and_tag0 = ci.hashPtr(ip0, dict_h_bits, mls);
        var dict_match_index_and_tag = dict_hash_table[dict_hash_and_tag0 >> short_cache_tag_bits];
        var dict_tags_match = ci.comparePackedTags(dict_match_index_and_tag, dict_hash_and_tag0);

        var match_index = hash_table[hash0];
        var curr: u32 = @intCast(@intFromPtr(ip0) -% @intFromPtr(base));
        var step: usize = step_size;
        const k_step_incr: usize = 1 << ci.search_strength;
        var next_step = @intFromPtr(ip0) + k_step_incr;

        while (true) {
            const match = base + match_index;
            const rep_index = curr + 1 -% offset_1;
            const rep_match = if (rep_index < prefix_start_index)
                dict_base + (rep_index -% dict_index_delta)
            else
                base + rep_index;
            const hash1 = ci.hashPtr(ip1, hlog, mls);
            const dict_hash_and_tag1 = ci.hashPtr(ip1, dict_h_bits, mls);
            hash_table[hash0] = curr;

            if (ci.indexOverlapCheck(prefix_start_index, rep_index) and
                std.mem.readInt(u32, rep_match[0..4], native_endian) ==
                    std.mem.readInt(u32, (ip0 + 1)[0..4], native_endian))
            {
                const rep_match_end = if (rep_index < prefix_start_index) dict_end else iend;
                m_length = ci.count2Segments(ip0 + 1 + 4, rep_match + 4, iend, rep_match_end, prefix_start) + 4;
                ip0 += 1;
                const lit_length = @intFromPtr(ip0) - @intFromPtr(anchor);
                ci.storeSeq(seq_store, lit_length, anchor, iend, ci.repcode1_to_offbase, m_length);
                break;
            }

            if (dict_tags_match) {
                // A possible match in the dictionary.
                const dict_match_index = dict_match_index_and_tag >> short_cache_tag_bits;
                var dict_match = dict_base + dict_match_index;
                if (dict_match_index > dict_start_index and
                    std.mem.readInt(u32, dict_match[0..4], native_endian) ==
                        std.mem.readInt(u32, ip0[0..4], native_endian))
                {
                    // As the external-dictionary parse does, use a dictionary
                    // match only when the prefix candidate is invalid.
                    if (match_index <= prefix_start_index) {
                        const offset: u32 = curr - dict_match_index - dict_index_delta;
                        m_length = ci.count2Segments(ip0 + 4, dict_match + 4, iend, dict_end, prefix_start) + 4;
                        while (@intFromPtr(ip0) > @intFromPtr(anchor) and
                            @intFromPtr(dict_match) > @intFromPtr(dict_start) and
                            (ip0 - 1)[0] == (dict_match - 1)[0])
                        {
                            ip0 -= 1;
                            dict_match -= 1;
                            m_length += 1;
                        }
                        offset_2 = offset_1;
                        offset_1 = offset;
                        const lit_length = @intFromPtr(ip0) - @intFromPtr(anchor);
                        ci.storeSeq(seq_store, lit_length, anchor, iend, ci.offsetToOffbase(offset), m_length);
                        break;
                    }
                }
            }

            if (match4FoundCmov(ip0, match, match_index, prefix_start_index)) {
                // A match of 4 bytes or more in the prefix.
                const offset: u32 = @intCast(@intFromPtr(ip0) - @intFromPtr(match));
                var match_back = match;
                m_length = ci.count(ip0 + 4, match + 4, iend) + 4;
                while (@intFromPtr(ip0) > @intFromPtr(anchor) and
                    @intFromPtr(match_back) > @intFromPtr(prefix_start) and
                    (ip0 - 1)[0] == (match_back - 1)[0])
                {
                    ip0 -= 1;
                    match_back -= 1;
                    m_length += 1;
                }
                offset_2 = offset_1;
                offset_1 = offset;
                const lit_length = @intFromPtr(ip0) - @intFromPtr(anchor);
                ci.storeSeq(seq_store, lit_length, anchor, iend, ci.offsetToOffbase(offset), m_length);
                break;
            }

            dict_match_index_and_tag = dict_hash_table[dict_hash_and_tag1 >> short_cache_tag_bits];
            dict_tags_match = ci.comparePackedTags(dict_match_index_and_tag, dict_hash_and_tag1);
            match_index = hash_table[hash1];

            if (@intFromPtr(ip1) >= next_step) {
                step += 1;
                next_step += k_step_incr;
            }
            ip0 = ip1;
            ip1 = ip1 + step;
            if (@intFromPtr(ip1) > ilimit) break :outer;

            curr = @intCast(@intFromPtr(ip0) -% @intFromPtr(base));
            hash0 = hash1;
        }

        // A match was found.
        assert(m_length != 0);
        ip0 += m_length;
        anchor = ip0;

        if (@intFromPtr(ip0) <= ilimit) {
            // curr + 2 may be past iend - 8, so it goes in here.
            assert(@intFromPtr(base + curr + 2) > @intFromPtr(istart));
            hash_table[ci.hashPtr(base + curr + 2, hlog, mls)] = curr + 2;
            hash_table[ci.hashPtr(ip0 - 2, hlog, mls)] =
                @intCast(@intFromPtr(ip0 - 2) -% @intFromPtr(base));

            // Immediate repeat offsets.
            while (@intFromPtr(ip0) <= ilimit) {
                const current2: u32 = @intCast(@intFromPtr(ip0) -% @intFromPtr(base));
                const rep_index2 = current2 -% offset_2;
                const rep_match2 = if (rep_index2 < prefix_start_index)
                    dict_base - dict_index_delta + rep_index2
                else
                    base + rep_index2;
                if (ci.indexOverlapCheck(prefix_start_index, rep_index2) and
                    std.mem.readInt(u32, rep_match2[0..4], native_endian) ==
                        std.mem.readInt(u32, ip0[0..4], native_endian))
                {
                    const rep_end2 = if (rep_index2 < prefix_start_index) dict_end else iend;
                    const rep_length2 = ci.count2Segments(ip0 + 4, rep_match2 + 4, iend, rep_end2, prefix_start) + 4;
                    const tmp_off = offset_2;
                    offset_2 = offset_1;
                    offset_1 = tmp_off;
                    ci.storeSeq(seq_store, 0, anchor, iend, ci.repcode1_to_offbase, rep_length2);
                    hash_table[ci.hashPtr(ip0, hlog, mls)] = current2;
                    ip0 += rep_length2;
                    anchor = ip0;
                    continue;
                }
                break;
            }
        }

        assert(ip0 == anchor);
        ip1 = ip0 + step_size;
    }

    rep[0] = offset_1;
    rep[1] = offset_2;

    return @intFromPtr(iend) - @intFromPtr(anchor);
}

/// `ZSTD_compressBlock_fast_dictMatchState`: the block compressor with an
/// attached dictionary.
pub fn compressBlockFastDictMatchState(
    ms: *MatchState,
    seq_store: *SeqStore,
    rep: *[rep_num]u32,
    src: []const u8,
) usize {
    const mls = ms.cparams.min_match;
    assert(ms.dict_match_state != null);
    return switch (mls) {
        5 => compressBlockFastDictMatchStateGeneric(ms, seq_store, rep, src, 5, false),
        6 => compressBlockFastDictMatchStateGeneric(ms, seq_store, rep, src, 6, false),
        7 => compressBlockFastDictMatchStateGeneric(ms, seq_store, rep, src, 7, false),
        // 3 and 4.
        else => compressBlockFastDictMatchStateGeneric(ms, seq_store, rep, src, 4, false),
    };
}

/// `ZSTD_compressBlock_fast_extDict_generic`. `has_step` is not used to
/// specialise, as in the original.
noinline fn compressBlockFastExtDictGeneric(
    ms: *MatchState,
    seq_store: *SeqStore,
    rep: *[rep_num]u32,
    src: []const u8,
    comptime mls: u32,
    comptime has_step: bool,
) align(hot_code_align) usize {
    _ = has_step;
    const cparams = &ms.cparams;
    const hash_table = ms.hash_table;
    const hlog = cparams.hash_log;
    // A target length of 0 still steps.
    const step_size: usize = @as(usize, cparams.target_length) +
        @intFromBool(cparams.target_length == 0) + 1;
    const base = ms.window.base;
    const dict_base = ms.window.dict_base;
    const istart = src.ptr;
    var anchor = istart;
    const end_index: u32 = @intCast(@intFromPtr(istart) -% @intFromPtr(base) +% src.len);
    const low_limit = ci.getLowestMatchIndex(ms, end_index, cparams.window_log);
    const dict_start_index = low_limit;
    const dict_start = dict_base + dict_start_index;
    const dict_limit = ms.window.dict_limit;
    const prefix_start_index = if (dict_limit < low_limit) low_limit else dict_limit;
    const prefix_start = base + prefix_start_index;
    const dict_end = dict_base + prefix_start_index;
    const iend = istart + src.len;
    const ilimit = @intFromPtr(iend) -% 8;
    var offset_1 = rep[0];
    var offset_2 = rep[1];
    var offset_saved1: u32 = 0;
    var offset_saved2: u32 = 0;

    var ip0 = istart;
    var ip1: [*]const u8 = undefined;
    var ip2: [*]const u8 = undefined;
    var ip3: [*]const u8 = undefined;
    var current0: u32 = undefined;

    var hash0: usize = undefined;
    var hash1: usize = undefined;
    var idx: u32 = undefined;
    var idx_base: [*]const u8 = undefined;

    var offcode: u32 = undefined;
    var match0: [*]const u8 = undefined;
    var m_length: usize = undefined;
    var match_end: ?[*]const u8 = null;

    var step: usize = undefined;
    var next_step: usize = undefined;
    const k_step_incr: usize = 1 << (ci.search_strength - 1);

    // The external dictionary is out of the window: no dictionary after all.
    if (prefix_start_index == dict_start_index) return compressBlockFast(ms, seq_store, rep, src);

    {
        const curr: u32 = @intCast(@intFromPtr(ip0) -% @intFromPtr(base));
        const max_rep = curr - dict_start_index;
        if (offset_2 >= max_rep) {
            offset_saved2 = offset_2;
            offset_2 = 0;
        }
        if (offset_1 >= max_rep) {
            offset_saved1 = offset_1;
            offset_1 = 0;
        }
    }

    const State = enum { start, offset, match, cleanup };
    state: switch (State.start) {
        // Requires ip0.
        .start => {
            step = step_size;
            next_step = @intFromPtr(ip0) + k_step_incr;

            // ip0 - anchor == 0, so the step needs no update.
            ip1 = ip0 + 1;
            ip2 = ip0 + step;
            ip3 = ip2 + 1;

            if (@intFromPtr(ip3) >= ilimit) continue :state .cleanup;

            hash0 = ci.hashPtr(ip0, hlog, mls);
            hash1 = ci.hashPtr(ip1, hlog, mls);

            idx = hash_table[hash0];
            idx_base = if (idx < prefix_start_index) dict_base else base;

            while (true) {
                {
                    // The repeat-offset candidate for ip2.
                    const current2: u32 = @intCast(@intFromPtr(ip2) -% @intFromPtr(base));
                    const rep_index = current2 -% offset_1;
                    const rep_base = if (rep_index < prefix_start_index) dict_base else base;
                    const ip2_value = std.mem.readInt(u32, ip2[0..4], native_endian);
                    // The subtraction wraps on purpose.
                    const rval = if (prefix_start_index -% rep_index >= 4 and offset_1 > 0)
                        std.mem.readInt(u32, (rep_base + rep_index)[0..4], native_endian)
                    else
                        ip2_value ^ 1; // Never matches.

                    current0 = @intCast(@intFromPtr(ip0) -% @intFromPtr(base));
                    hash_table[hash0] = current0;

                    if (ip2_value == rval) {
                        ip0 = ip2;
                        match0 = rep_base + rep_index;
                        match_end = if (rep_index < prefix_start_index) dict_end else iend;
                        assert(match0 != prefix_start and match0 != dict_start);
                        m_length = @intFromBool((ip0 - 1)[0] == (match0 - 1)[0]);
                        ip0 -= m_length;
                        match0 -= m_length;
                        offcode = ci.repcode1_to_offbase;
                        m_length += 4;
                        continue :state .match;
                    }
                }

                {
                    const ip0_value = std.mem.readInt(u32, ip0[0..4], native_endian);
                    const mval = if (idx >= dict_start_index)
                        std.mem.readInt(u32, (idx_base + idx)[0..4], native_endian)
                    else
                        ip0_value ^ 1; // Never matches.
                    if (ip0_value == mval) continue :state .offset;
                }

                // Look up ip1, hash ip2.
                idx = hash_table[hash1];
                idx_base = if (idx < prefix_start_index) dict_base else base;
                hash0 = hash1;
                hash1 = ci.hashPtr(ip2, hlog, mls);

                ip0 = ip1;
                ip1 = ip2;
                ip2 = ip3;

                current0 = @intCast(@intFromPtr(ip0) -% @intFromPtr(base));
                hash_table[hash0] = current0;

                {
                    const ip0_value = std.mem.readInt(u32, ip0[0..4], native_endian);
                    const mval = if (idx >= dict_start_index)
                        std.mem.readInt(u32, (idx_base + idx)[0..4], native_endian)
                    else
                        ip0_value ^ 1; // Never matches.
                    if (ip0_value == mval) continue :state .offset;
                }

                // Look up ip1, hash ip2.
                idx = hash_table[hash1];
                idx_base = if (idx < prefix_start_index) dict_base else base;
                hash0 = hash1;
                hash1 = ci.hashPtr(ip2, hlog, mls);

                ip0 = ip1;
                ip1 = ip2;
                ip2 = ip0 + step;
                ip3 = ip1 + step;

                if (@intFromPtr(ip2) >= next_step) {
                    step += 1;
                    @prefetch(ip1 + 64, .{ .locality = 3 });
                    @prefetch(ip1 + 128, .{ .locality = 3 });
                    next_step += k_step_incr;
                }
                if (@intFromPtr(ip3) >= ilimit) break;
            }
            continue :state .cleanup;
        },
        .cleanup => {
            // A few positions are left unsearched: searching them costs more
            // time than it gains.

            // If offset_1 was invalid and became valid, the saved offsets
            // rotate, as in `compressBlockFastNoDictGeneric`.
            if (offset_saved1 != 0 and offset_1 != 0) offset_saved2 = offset_saved1;

            rep[0] = if (offset_1 != 0) offset_1 else offset_saved1;
            rep[1] = if (offset_2 != 0) offset_2 else offset_saved2;

            return @intFromPtr(iend) - @intFromPtr(anchor);
        },
        // Requires ip0, idx and idx_base.
        .offset => {
            const offset = current0 - idx;
            const low_match_ptr = if (idx < prefix_start_index) dict_start else prefix_start;
            match_end = if (idx < prefix_start_index) dict_end else iend;
            match0 = idx_base + idx;
            offset_2 = offset_1;
            offset_1 = offset;
            offcode = ci.offsetToOffbase(offset);
            m_length = 4;

            // Extend the match backwards.
            while (@intFromPtr(ip0) > @intFromPtr(anchor) and
                @intFromPtr(match0) > @intFromPtr(low_match_ptr) and
                (ip0 - 1)[0] == (match0 - 1)[0])
            {
                ip0 -= 1;
                match0 -= 1;
                m_length += 1;
            }
            continue :state .match;
        },
        // Requires ip0, match0, offcode and match_end.
        .match => {
            m_length += ci.count2Segments(ip0 + m_length, match0 + m_length, iend, match_end.?, prefix_start);

            const lit_length = @intFromPtr(ip0) - @intFromPtr(anchor);
            ci.storeSeq(seq_store, lit_length, anchor, iend, offcode, m_length);

            ip0 += m_length;
            anchor = ip0;

            // The next hash table entry.
            if (@intFromPtr(ip1) < @intFromPtr(ip0)) {
                hash_table[hash1] = @intCast(@intFromPtr(ip1) -% @intFromPtr(base));
            }

            // Fill the table, and check for an immediate repeat offset.
            if (@intFromPtr(ip0) <= ilimit) {
                // current0 + 2 may be past iend - 8, so it goes in here.
                assert(@intFromPtr(base + current0 + 2) > @intFromPtr(istart));
                hash_table[ci.hashPtr(base + current0 + 2, hlog, mls)] = current0 + 2;
                hash_table[ci.hashPtr(ip0 - 2, hlog, mls)] =
                    @intCast(@intFromPtr(ip0 - 2) -% @intFromPtr(base));

                while (@intFromPtr(ip0) <= ilimit) {
                    const current2: u32 = @intCast(@intFromPtr(ip0) -% @intFromPtr(base));
                    const rep_index2 = current2 -% offset_2;
                    const rep_match2 = if (rep_index2 < prefix_start_index)
                        dict_base + rep_index2
                    else
                        base + rep_index2;
                    if (ci.indexOverlapCheck(prefix_start_index, rep_index2) and offset_2 > 0 and
                        std.mem.readInt(u32, rep_match2[0..4], native_endian) ==
                            std.mem.readInt(u32, ip0[0..4], native_endian))
                    {
                        const rep_end2 = if (rep_index2 < prefix_start_index) dict_end else iend;
                        const rep_length2 = ci.count2Segments(ip0 + 4, rep_match2 + 4, iend, rep_end2, prefix_start) + 4;
                        const tmp_off = offset_2;
                        offset_2 = offset_1;
                        offset_1 = tmp_off;
                        ci.storeSeq(seq_store, 0, anchor, iend, ci.repcode1_to_offbase, rep_length2);
                        hash_table[ci.hashPtr(ip0, hlog, mls)] = current2;
                        ip0 += rep_length2;
                        anchor = ip0;
                        continue;
                    }
                    break;
                }
            }
            continue :state .start;
        },
    }
}

/// `ZSTD_compressBlock_fast_extDict`: the block compressor with an external
/// dictionary.
pub fn compressBlockFastExtDict(
    ms: *MatchState,
    seq_store: *SeqStore,
    rep: *[rep_num]u32,
    src: []const u8,
) usize {
    const mls = ms.cparams.min_match;
    assert(ms.dict_match_state == null);
    return switch (mls) {
        5 => compressBlockFastExtDictGeneric(ms, seq_store, rep, src, 5, false),
        6 => compressBlockFastExtDictGeneric(ms, seq_store, rep, src, 6, false),
        7 => compressBlockFastExtDictGeneric(ms, seq_store, rep, src, 7, false),
        // 3 and 4.
        else => compressBlockFastExtDictGeneric(ms, seq_store, rep, src, 4, false),
    };
}
