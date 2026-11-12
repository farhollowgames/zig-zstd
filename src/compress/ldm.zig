//! Long distance matching, from the original's zstd_ldm.c and
//! zstd_ldm_geartab.h: finds long matches far back in the window, ahead of
//! the block compressor, which then compresses the literals between them.
//!
//! A gear hash rolls over the input and marks a split point wherever its top
//! bits are zero, on average every `1 << hash_rate_log` bytes. The
//! `min_match_length` bytes ending at each split are hashed again with
//! XXH64: its low bits pick a bucket of the hash table and its high 32 bits
//! are a checksum to check a candidate against before comparing bytes. Each
//! bucket is a ring of `1 << bucket_size_log` entries.

const std = @import("std");

const params = @import("../params.zig");
const Error = @import("../error.zig").Error;
const ci = @import("compress_internal.zig");
const cwksp = @import("cwksp.zig");
const fast = @import("fast.zig");
const double_fast = @import("double_fast.zig");

const assert = std.debug.assert;
const rep_num = @import("../common/zstd_internal.zig").rep_num;
const ldm_batch_size = ci.ldm_batch_size;
const LdmState = ci.LdmState;
const LdmParams = ci.LdmParams;
const LdmEntry = ci.LdmEntry;
const MatchState = ci.MatchState;
const RawSeq = ci.RawSeq;
const RawSeqStore = ci.RawSeqStore;
const SeqStore = ci.SeqStore;
const BlockCompressor = ci.BlockCompressor;

/// `ZSTD_LDM_DEFAULT_WINDOW_LOG`: the window log long distance matching
/// sets when the caller sets none.
pub const default_window_log = params.window_log_limit_default;

const bucket_size_log_default = 4;
const min_match_length_default = 64;

/// `ldmRollingHashState_t`: the gear hash and the mask of the bits that must
/// be zero at a split point.
pub const RollingHashState = struct {
    rolling: u64,
    stop_mask: u64,
};

/// `ZSTD_ldm_gear_init`: a hash state that splits as `ldm_params` say.
pub fn gearInit(state: *RollingHashState, ldm_params: *const LdmParams) void {
    const max_bits_in_mask = @min(ldm_params.min_match_length, 64);
    const hash_rate_log = ldm_params.hash_rate_log;

    state.rolling = std.math.maxInt(u32);

    // The split must happen every `1 << hash_rate_log` bytes on average, and
    // should depend on the last `min_match_length` bytes. Bit n of a gear
    // hash depends on the last n bytes, so the mask takes `hash_rate_log`
    // bits as high as they can be while depending on no more than
    // `min_match_length` bytes.
    if (hash_rate_log > 0 and hash_rate_log <= max_bits_in_mask) {
        state.stop_mask = ((@as(u64, 1) << @intCast(hash_rate_log)) - 1) <<
            @intCast(max_bits_in_mask - hash_rate_log);
    } else {
        // The degenerate case keeps only the rate.
        state.stop_mask = (@as(u64, 1) << @intCast(hash_rate_log)) - 1;
    }
}

/// `ZSTD_ldm_gear_reset`: meant to feed `data[0..min_match_length]` into
/// the hash without looking for splits, at the start of a block and after a
/// skip. The original computes that hash but never stores it, so the state
/// is left as it is; the port does the same, as the output depends on it.
pub fn gearReset(state: *RollingHashState, data: [*]const u8, min_match_length: usize) void {
    _ = state;
    _ = data;
    _ = min_match_length;
}

/// `ZSTD_ldm_gear_feed`: appends to `splits` the split points in
/// `data[0..size]`, as offsets one past the byte that ends each, until all
/// of `data` is hashed or `splits` is full. `splits` must not be full.
/// Returns the number of bytes hashed.
pub fn gearFeed(
    state: *RollingHashState,
    data: [*]const u8,
    size: usize,
    splits: *[ldm_batch_size]usize,
    num_splits: *u32,
) usize {
    assert(num_splits.* < ldm_batch_size);
    var hash = state.rolling;
    const mask = state.stop_mask;
    var n: usize = 0;

    done: {
        while (n + 3 < size) {
            inline for (0..4) |_| {
                hash = (hash << 1) +% gear_tab[data[n]];
                n += 1;
                if ((hash & mask) == 0) {
                    @branchHint(.unlikely);
                    splits[num_splits.*] = n;
                    num_splits.* += 1;
                    if (num_splits.* == ldm_batch_size) break :done;
                }
            }
        }
        while (n < size) {
            hash = (hash << 1) +% gear_tab[data[n]];
            n += 1;
            if ((hash & mask) == 0) {
                @branchHint(.unlikely);
                splits[num_splits.*] = n;
                num_splits.* += 1;
                if (num_splits.* == ldm_batch_size) break :done;
            }
        }
    }

    state.rolling = hash;
    return n;
}

/// `ZSTD_ldm_adjustParameters`: fills in the parameters left at 0 from
/// `cparams`, and takes its window log.
pub fn adjustParameters(ldm_params: *LdmParams, cparams: *const params.CompressionParameters) void {
    comptime assert(bucket_size_log_default <= params.ldm_bucket_size_log_max);
    const strategy: u32 = @backingInt(cparams.strategy);
    ldm_params.window_log = cparams.window_log;
    if (ldm_params.hash_rate_log == 0) {
        if (ldm_params.hash_log > 0) {
            // Derive the rate from the hash log the caller set.
            assert(ldm_params.hash_log <= params.hash_log_max);
            if (ldm_params.window_log > ldm_params.hash_log) {
                ldm_params.hash_rate_log = ldm_params.window_log - ldm_params.hash_log;
            }
        } else {
            // From rate 7 for fast down to rate 4 for btultra2.
            ldm_params.hash_rate_log = 7 - strategy / 3;
        }
    }
    if (ldm_params.hash_log == 0) {
        // A rate the caller set may exceed the window log: the subtraction
        // then wraps, and the hash log is the maximum.
        const hash_log = ldm_params.window_log -% ldm_params.hash_rate_log;
        ldm_params.hash_log = @max(params.hash_log_min, @min(hash_log, params.hash_log_max));
    }
    if (ldm_params.min_match_length == 0) {
        ldm_params.min_match_length = min_match_length_default;
        if (strategy >= @backingInt(params.Strategy.btultra)) ldm_params.min_match_length /= 2;
    }
    if (ldm_params.bucket_size_log == 0) {
        ldm_params.bucket_size_log = @max(
            bucket_size_log_default,
            @min(strategy, params.ldm_bucket_size_log_max),
        );
    }
    ldm_params.bucket_size_log = @min(ldm_params.bucket_size_log, ldm_params.hash_log);
}

/// `ZSTD_ldm_getTableSize`: the workspace space of the hash table and the
/// bucket offsets; 0 when long distance matching is off.
pub fn getTableSize(ldm_params: LdmParams) usize {
    const ldm_h_size = @as(usize, 1) << @intCast(ldm_params.hash_log);
    const ldm_bucket_size_log = @min(ldm_params.bucket_size_log, ldm_params.hash_log);
    const ldm_bucket_size = @as(usize, 1) << @intCast(ldm_params.hash_log - ldm_bucket_size_log);
    const total_size = cwksp.allocSize(ldm_bucket_size) +
        cwksp.allocSize(ldm_h_size * @sizeOf(LdmEntry));
    return if (ldm_params.enable_ldm == .enable) total_size else 0;
}

/// `ZSTD_ldm_getMaxNbSeq`: the most sequences a chunk of `max_chunk_size`
/// bytes can give; 0 when long distance matching is off.
pub fn getMaxNbSeq(ldm_params: LdmParams, max_chunk_size: usize) usize {
    if (ldm_params.enable_ldm != .enable) return 0;
    return max_chunk_size / ldm_params.min_match_length;
}

/// `ZSTD_ldm_getBucket`: the first entry of the bucket of `hash`.
fn getBucket(ldm_state: *const LdmState, hash: usize, bucket_size_log: u32) [*]LdmEntry {
    return ldm_state.hash_table + (hash << @intCast(bucket_size_log));
}

/// `ZSTD_ldm_insertEntry`: puts `entry` in the bucket of `hash`, over its
/// oldest entry.
fn insertEntry(ldm_state: *LdmState, hash: usize, entry: LdmEntry, bucket_size_log: u32) void {
    const offset = ldm_state.bucket_offsets[hash];
    getBucket(ldm_state, hash, bucket_size_log)[offset] = entry;
    const mask = (@as(u32, 1) << @intCast(bucket_size_log)) - 1;
    ldm_state.bucket_offsets[hash] = @intCast((@as(u32, offset) + 1) & mask);
}

/// `ZSTD_ldm_countBackwardsMatch`: the number of equal bytes before `p_in`
/// and `p_match`, going back no further than `p_anchor` and `p_match_base`.
fn countBackwardsMatch(
    p_in_start: [*]const u8,
    p_anchor: [*]const u8,
    p_match_start: [*]const u8,
    p_match_base: [*]const u8,
) usize {
    var p_in = p_in_start;
    var p_match = p_match_start;
    var match_length: usize = 0;
    while (@intFromPtr(p_in) > @intFromPtr(p_anchor) and
        @intFromPtr(p_match) > @intFromPtr(p_match_base) and
        (p_in - 1)[0] == (p_match - 1)[0])
    {
        p_in -= 1;
        p_match -= 1;
        match_length += 1;
    }
    return match_length;
}

/// `ZSTD_ldm_countBackwardsMatch_2segments`: as `countBackwardsMatch`, but
/// a match that reaches `p_match_base`, the start of the prefix, continues
/// back from the end of the external dictionary.
fn countBackwardsMatch2Segments(
    p_in: [*]const u8,
    p_anchor: [*]const u8,
    p_match: [*]const u8,
    p_match_base: [*]const u8,
    p_ext_dict_start: [*]const u8,
    p_ext_dict_end: [*]const u8,
) usize {
    var match_length = countBackwardsMatch(p_in, p_anchor, p_match, p_match_base);
    if (p_match - match_length != p_match_base or p_match_base == p_ext_dict_start) {
        // The match is all in the external dictionary or all in the prefix.
        return match_length;
    }
    match_length += countBackwardsMatch(
        p_in - match_length,
        p_anchor,
        p_ext_dict_end,
        p_ext_dict_start,
    );
    return match_length;
}

/// `ZSTD_ldm_fillFastTables`: fills the fast and double fast strategies'
/// tables up to `end`, as loading a dictionary does. The other strategies
/// fill theirs in their block compressors.
fn fillFastTables(ms: *MatchState, end: [*]const u8) void {
    switch (ms.cparams.strategy) {
        .fast => fast.fillHashTable(ms, end, .fast, .for_cctx),
        .dfast => double_fast.fillDoubleHashTable(ms, end, .fast, .for_cctx),
        .greedy, .lazy, .lazy2, .btlazy2, .btopt, .btultra, .btultra2 => {},
        // An applied match state's strategy is always one of the above.
        _ => unreachable,
    }
}

/// `ZSTD_ldm_fillHashTable`: inserts the split points of `src` into the hash
/// table, for a dictionary. `src` must be in the long distance matcher's
/// window.
pub fn fillHashTable(ldm_state: *LdmState, src: []const u8, ldm_params: *const LdmParams) void {
    const min_match_length = ldm_params.min_match_length;
    const bucket_size_log = ldm_params.bucket_size_log;
    const h_bits = ldm_params.hash_log - bucket_size_log;
    const hash_mask = (@as(u32, 1) << @intCast(h_bits)) - 1;
    const base = ldm_state.window.base;
    const istart = src.ptr;
    const iend = src.ptr + src.len;
    const splits = &ldm_state.split_indices;
    var hash_state: RollingHashState = undefined;
    var ip = istart;

    gearInit(&hash_state, ldm_params);
    while (@intFromPtr(ip) < @intFromPtr(iend)) {
        var num_splits: u32 = 0;
        const hashed = gearFeed(
            &hash_state,
            ip,
            @intFromPtr(iend) - @intFromPtr(ip),
            splits,
            &num_splits,
        );

        for (splits[0..num_splits]) |split_index| {
            if (@intFromPtr(ip) + split_index >= @intFromPtr(istart) + min_match_length) {
                const split = ip + split_index - min_match_length;
                const xxhash = std.hash.XxHash64.hash(0, split[0..min_match_length]);
                const hash = @as(u32, @truncate(xxhash)) & hash_mask;
                const entry: LdmEntry = .{
                    .offset = @intCast(@intFromPtr(split) -% @intFromPtr(base)),
                    .checksum = @truncate(xxhash >> 32),
                };
                insertEntry(ldm_state, hash, entry, bucket_size_log);
            }
        }

        ip += hashed;
    }
}

/// `ZSTD_ldm_limitTableUpdate`: after a long match, moves `next_to_update`
/// up near `anchor`, so the tables are only filled with the end of the match.
fn limitTableUpdate(ms: *MatchState, anchor: [*]const u8) void {
    const curr: u32 = @intCast(@intFromPtr(anchor) -% @intFromPtr(ms.window.base));
    if (curr > ms.next_to_update + 1024) {
        ms.next_to_update = curr - @min(512, curr - ms.next_to_update - 1024);
    }
}

/// `ZSTD_ldm_generateSequences_internal`: appends the long matches of `src`
/// to `raw_seq_store`, and returns the number of literals after the last.
/// Fails with `DstSizeTooSmall` when `raw_seq_store` fills up.
fn generateSequencesInternal(
    ldm_state: *LdmState,
    raw_seq_store: *RawSeqStore,
    ldm_params: *const LdmParams,
    src: []const u8,
) Error!usize {
    // The parameters.
    const ext_dict = ldm_state.window.hasExtDict();
    const min_match_length = ldm_params.min_match_length;
    const ents_per_bucket = @as(u32, 1) << @intCast(ldm_params.bucket_size_log);
    const h_bits = ldm_params.hash_log - ldm_params.bucket_size_log;
    const hash_mask = (@as(u32, 1) << @intCast(h_bits)) - 1;
    // The prefix and the external dictionary.
    const dict_limit = ldm_state.window.dict_limit;
    const lowest_index = if (ext_dict) ldm_state.window.low_limit else dict_limit;
    const base = ldm_state.window.base;
    const dict_base: [*]const u8 = if (ext_dict) ldm_state.window.dict_base else undefined;
    const dict_start: [*]const u8 = if (ext_dict) dict_base + lowest_index else undefined;
    const dict_end: [*]const u8 = if (ext_dict) dict_base + dict_limit else undefined;
    const low_prefix_ptr = base + dict_limit;
    // The input.
    const istart = src.ptr;
    const iend = istart + src.len;
    // May be below `istart` for a short input, so only ever compared.
    const ilimit = @intFromPtr(iend) -% ci.hash_read_size;
    var anchor = istart;
    var ip = istart;
    var hash_state: RollingHashState = undefined;
    const splits = &ldm_state.split_indices;
    const candidates = &ldm_state.match_candidates;

    if (src.len < min_match_length) return @intFromPtr(iend) - @intFromPtr(anchor);

    // The first `min_match_length` bytes are skipped; `gearReset` leaves
    // the hash at its initial value, as the original's does.
    gearInit(&hash_state, ldm_params);
    gearReset(&hash_state, ip, min_match_length);
    ip += min_match_length;

    while (@intFromPtr(ip) < ilimit) {
        var num_splits: u32 = 0;
        const hashed = gearFeed(&hash_state, ip, ilimit - @intFromPtr(ip), splits, &num_splits);

        for (splits[0..num_splits], candidates[0..num_splits]) |split_index, *candidate| {
            const split = ip + split_index - min_match_length;
            const xxhash = std.hash.XxHash64.hash(0, split[0..min_match_length]);
            const hash = @as(u32, @truncate(xxhash)) & hash_mask;

            candidate.split = split;
            candidate.hash = hash;
            candidate.checksum = @truncate(xxhash >> 32);
            candidate.bucket = getBucket(ldm_state, hash, ldm_params.bucket_size_log);
            @prefetch(candidate.bucket, .{});
        }

        for (candidates[0..num_splits]) |candidate| {
            var forward_match_length: usize = 0;
            var backward_match_length: usize = 0;
            var best_match_length: usize = 0;
            const split = candidate.split;
            const checksum = candidate.checksum;
            const hash = candidate.hash;
            const bucket = candidate.bucket;
            var best_entry: ?*const LdmEntry = null;
            const new_entry: LdmEntry = .{
                .offset = @intCast(@intFromPtr(split) -% @intFromPtr(base)),
                .checksum = checksum,
            };

            // A split inside the previous match only goes into the table.
            if (@intFromPtr(split) < @intFromPtr(anchor)) {
                insertEntry(ldm_state, hash, new_entry, ldm_params.bucket_size_log);
                continue;
            }

            for (bucket[0..ents_per_bucket]) |*cur| {
                if (cur.checksum != checksum or cur.offset <= lowest_index) continue;
                var cur_forward_match_length: usize = undefined;
                var cur_backward_match_length: usize = undefined;
                if (ext_dict) {
                    const in_dict = cur.offset < dict_limit;
                    const cur_match_base = if (in_dict) dict_base else base;
                    const p_match = cur_match_base + cur.offset;
                    const match_end = if (in_dict) dict_end else iend;
                    const low_match_ptr = if (in_dict) dict_start else low_prefix_ptr;
                    cur_forward_match_length = ci.count2Segments(
                        split,
                        p_match,
                        iend,
                        match_end,
                        low_prefix_ptr,
                    );
                    if (cur_forward_match_length < min_match_length) continue;
                    cur_backward_match_length = countBackwardsMatch2Segments(
                        split,
                        anchor,
                        p_match,
                        low_match_ptr,
                        dict_start,
                        dict_end,
                    );
                } else {
                    const p_match = base + cur.offset;
                    cur_forward_match_length = ci.count(split, p_match, iend);
                    if (cur_forward_match_length < min_match_length) continue;
                    cur_backward_match_length =
                        countBackwardsMatch(split, anchor, p_match, low_prefix_ptr);
                }
                const cur_total_match_length = cur_forward_match_length +
                    cur_backward_match_length;

                if (cur_total_match_length > best_match_length) {
                    best_match_length = cur_total_match_length;
                    forward_match_length = cur_forward_match_length;
                    backward_match_length = cur_backward_match_length;
                    best_entry = cur;
                }
            }

            // No match: only insert the entry.
            const best = best_entry orelse {
                insertEntry(ldm_state, hash, new_entry, ldm_params.bucket_size_log);
                continue;
            };

            // A match.
            const offset = new_entry.offset - best.offset;
            const m_length = forward_match_length + backward_match_length;
            if (raw_seq_store.size == raw_seq_store.capacity) return error.DstSizeTooSmall;
            raw_seq_store.seq.?[raw_seq_store.size] = .{
                .lit_length = @intCast(@intFromPtr(split) - backward_match_length -
                    @intFromPtr(anchor)),
                .match_length = @intCast(m_length),
                .offset = offset,
            };
            raw_seq_store.size += 1;

            // Inserted after the match is stored, as it may replace `best`.
            insertEntry(ldm_state, hash, new_entry, ldm_params.bucket_size_log);

            anchor = split + forward_match_length;

            // A match that ends past the hashed input is a repeating pattern
            // (all zeros, say): if one repetition splits, all do. Only the
            // first goes into the table; the rest are skipped, which makes
            // a run of one byte about 20 times faster.
            if (@intFromPtr(anchor) > @intFromPtr(ip) + hashed) {
                gearReset(&hash_state, anchor - min_match_length, min_match_length);
                // The outer loop goes on at `anchor`, as `ip + hashed`.
                ip = anchor - hashed;
                break;
            }
        }

        ip += hashed;
    }

    return @intFromPtr(iend) - @intFromPtr(anchor);
}

/// `ZSTD_ldm_reduceTable`: lowers every offset in `table` by
/// `reducer_value`, to 0 for those below it.
fn reduceTable(table: [*]LdmEntry, size: u32, reducer_value: u32) void {
    for (table[0..size]) |*entry| {
        if (entry.offset < reducer_value) {
            entry.offset = 0;
        } else {
            entry.offset -= reducer_value;
        }
    }
}

/// `ZSTD_ldm_generateSequences`: appends the long matches of `src` to
/// `sequences`, which may be partly read, chunk by chunk. A chunk is at most
/// 1 MiB, so the indexes are corrected and the maximum distance enforced as
/// often as a block's would be. `src` must be in the long distance matcher's
/// window (`Window.update` done). Stops early when `sequences` is full,
/// and fails with `DstSizeTooSmall` when it fills inside a chunk.
pub fn generateSequences(
    ldm_state: *LdmState,
    sequences: *RawSeqStore,
    ldm_params: *const LdmParams,
    src: []const u8,
) Error!void {
    const max_dist = @as(u32, 1) << @intCast(ldm_params.window_log);
    const istart = src.ptr;
    const iend = istart + src.len;
    const max_chunk_size: usize = 1 << 20;
    const nb_chunks = src.len / max_chunk_size + @intFromBool(src.len % max_chunk_size != 0);
    var leftover_size: usize = 0;

    comptime assert(ci.chunk_size_max >= max_chunk_size);
    assert(@intFromPtr(ldm_state.window.next_src) >= @intFromPtr(iend));
    assert(sequences.pos <= sequences.size);
    assert(sequences.size <= sequences.capacity);
    var chunk: usize = 0;
    while (chunk < nb_chunks and sequences.size < sequences.capacity) : (chunk += 1) {
        const chunk_start = istart + chunk * max_chunk_size;
        const remaining = @intFromPtr(iend) - @intFromPtr(chunk_start);
        const chunk_end = if (remaining < max_chunk_size) iend else chunk_start + max_chunk_size;
        const chunk_size = @intFromPtr(chunk_end) - @intFromPtr(chunk_start);
        const prev_size = sequences.size;

        // 1. Correct the indexes when they grow too large.
        const window = &ldm_state.window;
        const loaded_dict_end = ldm_state.loaded_dict_end;
        if (window.needOverflowCorrection(0, max_dist, loaded_dict_end, chunk_start, chunk_end)) {
            const ldm_h_size = @as(u32, 1) << @intCast(ldm_params.hash_log);
            const correction = window.correctOverflow(0, max_dist, chunk_start);
            reduceTable(ldm_state.hash_table, ldm_h_size, correction);
            // The correction invalidates the dictionary.
            ldm_state.loaded_dict_end = 0;
        }
        // 2. Enforce the maximum distance. A chunk is small enough that
        // invalidating at its end loses little of the window. With a
        // dictionary, a sequence may be split in two, so an offset must be
        // valid at the end of its sequence; enforcing it on the whole chunk
        // ensures that.
        window.enforceMaxDist(chunk_end, max_dist, &ldm_state.loaded_dict_end, null);
        // 3. Find the chunk's sequences.
        const new_leftover_size = try generateSequencesInternal(
            ldm_state,
            sequences,
            ldm_params,
            chunk_start[0..chunk_size],
        );
        // 4. The literals left from the chunks before go to the first new
        // sequence, or add up when there is none.
        if (prev_size < sequences.size) {
            sequences.seq.?[prev_size].lit_length += @intCast(leftover_size);
            leftover_size = new_leftover_size;
        } else {
            assert(new_leftover_size == chunk_size);
            leftover_size += chunk_size;
        }
    }
}

/// `ZSTD_ldm_skipSequences`: skips `src_size` bytes of `raw_seq_store`'s
/// sequences, shortening the sequence it stops in. A match cut shorter than
/// `min_match` is dropped, its rest becoming the next sequence's literals.
pub fn skipSequences(raw_seq_store: *RawSeqStore, src_size_start: usize, min_match: u32) void {
    var src_size = src_size_start;
    while (src_size > 0 and raw_seq_store.pos < raw_seq_store.size) {
        const seqs = raw_seq_store.seq.?;
        const seq = &seqs[raw_seq_store.pos];
        if (src_size <= seq.lit_length) {
            // Skip `src_size` literals.
            seq.lit_length -= @intCast(src_size);
            return;
        }
        src_size -= seq.lit_length;
        seq.lit_length = 0;
        if (src_size < seq.match_length) {
            // Skip the first `src_size` bytes of the match.
            seq.match_length -= @intCast(src_size);
            if (seq.match_length < min_match) {
                // Too short a match is left out.
                if (raw_seq_store.pos + 1 < raw_seq_store.size) {
                    seqs[raw_seq_store.pos + 1].lit_length += seq.match_length;
                }
                raw_seq_store.pos += 1;
            }
            return;
        }
        src_size -= seq.match_length;
        seq.match_length = 0;
        raw_seq_store.pos += 1;
    }
}

/// `maybeSplitSequence`: the next sequence, cut at `remaining` bytes when it
/// goes past the block, the rest kept for the next block. An offset of 0
/// means the rest of the block is literals.
pub fn maybeSplitSequence(raw_seq_store: *RawSeqStore, remaining: u32, min_match: u32) RawSeq {
    var sequence = raw_seq_store.seq.?[raw_seq_store.pos];
    assert(sequence.offset > 0);
    // Most sequences are not cut.
    if (remaining >= sequence.lit_length + sequence.match_length) {
        raw_seq_store.pos += 1;
        return sequence;
    }
    // Cut the sequence short.
    if (remaining <= sequence.lit_length) {
        sequence.offset = 0;
    } else if (remaining < sequence.lit_length + sequence.match_length) {
        sequence.match_length = remaining - sequence.lit_length;
        if (sequence.match_length < min_match) sequence.offset = 0;
    }
    // The next block's sequences start after `remaining` bytes.
    skipSequences(raw_seq_store, remaining, min_match);
    return sequence;
}

/// `ZSTD_ldm_skipRawSeqStoreBytes`: moves `raw_seq_store`'s read position
/// on by `nb_bytes`, for the optimal parser, which reads the sequences as
/// candidates without cutting them.
pub fn skipRawSeqStoreBytes(raw_seq_store: *RawSeqStore, nb_bytes: usize) void {
    var curr_pos: u32 = @intCast(raw_seq_store.pos_in_sequence + nb_bytes);
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

/// `ZSTD_ldm_blockCompress`: compresses the block `src` with the long
/// matches of `raw_seq_store`, running `block_compressor` (the one
/// `selectBlockCompressor` picks for `ms`) over the literals between them.
/// The optimal parsers take the matches as candidates instead, through
/// `ms.ldm_seq_store`, which then points at `raw_seq_store` until the next
/// block. Returns the size of the last literals.
pub fn blockCompress(
    raw_seq_store: *RawSeqStore,
    ms: *MatchState,
    seq_store: *SeqStore,
    rep: *[rep_num]u32,
    block_compressor: BlockCompressor,
    src: []const u8,
) usize {
    const min_match = ms.cparams.min_match;
    const istart = src.ptr;
    const iend = istart + src.len;
    var ip = istart;

    if (@backingInt(ms.cparams.strategy) >= @backingInt(params.Strategy.btopt)) {
        ms.ldm_seq_store = raw_seq_store;
        const last_ll_size = block_compressor(ms, seq_store, rep, src);
        skipRawSeqStoreBytes(raw_seq_store, src.len);
        return last_ll_size;
    }

    assert(raw_seq_store.pos <= raw_seq_store.size);
    assert(raw_seq_store.size <= raw_seq_store.capacity);
    // The block compressor runs on the literals before each sequence.
    while (raw_seq_store.pos < raw_seq_store.size and @intFromPtr(ip) < @intFromPtr(iend)) {
        const remaining: u32 = @intCast(@intFromPtr(iend) - @intFromPtr(ip));
        const sequence = maybeSplitSequence(raw_seq_store, remaining, min_match);
        // The rest of the block is literals.
        if (sequence.offset == 0) break;

        assert(@intFromPtr(ip) + sequence.lit_length + sequence.match_length <=
            @intFromPtr(iend));

        limitTableUpdate(ms, ip);
        fillFastTables(ms, ip);
        const new_lit_length = block_compressor(ms, seq_store, rep, ip[0..sequence.lit_length]);
        ip += sequence.lit_length;
        var i: usize = rep_num - 1;
        while (i > 0) : (i -= 1) rep[i] = rep[i - 1];
        rep[0] = sequence.offset;
        ci.storeSeq(
            seq_store,
            new_lit_length,
            ip - new_lit_length,
            iend,
            ci.offsetToOffbase(sequence.offset),
            sequence.match_length,
        );
        ip += sequence.match_length;
    }
    limitTableUpdate(ms, ip);
    fillFastTables(ms, ip);
    // The last literals.
    return block_compressor(ms, seq_store, rep, ip[0 .. @intFromPtr(iend) - @intFromPtr(ip)]);
}

/// `ZSTD_ldm_gearTab`: the gear hash's random value of each byte.
const gear_tab = [256]u64{
    0xf5b8f72c5f77775c, 0x84935f266b7ac412, 0xb647ada9ca730ccc,
    0xb065bb4b114fb1de, 0x34584e7e8c3a9fd0, 0x4e97e17c6ae26b05,
    0x3a03d743bc99a604, 0xcecd042422c4044f, 0x76de76c58524259e,
    0x9c8528f65badeaca, 0x86563706e2097529, 0x2902475fa375d889,
    0xafb32a9739a5ebe6, 0xce2714da3883e639, 0x21eaf821722e69e,
    0x37b628620b628,    0x49a8d455d88caf5,  0x8556d711e6958140,
    0x4f7ae74fc605c1f,  0x829f0c3468bd3a20, 0x4ffdc885c625179e,
    0x8473de048a3daf1b, 0x51008822b05646b2, 0x69d75d12b2d1cc5f,
    0x8c9d4a19159154bc, 0xc3cc10f4abbd4003, 0xd06ddc1cecb97391,
    0xbe48e6e7ed80302e, 0x3481db31cee03547, 0xacc3f67cdaa1d210,
    0x65cb771d8c7f96cc, 0x8eb27177055723dd, 0xc789950d44cd94be,
    0x934feadc3700b12b, 0x5e485f11edbdf182, 0x1e2e2a46fd64767a,
    0x2969ca71d82efa7c, 0x9d46e9935ebbba2e, 0xe056b67e05e6822b,
    0x94d73f55739d03a0, 0xcd7010bdb69b5a03, 0x455ef9fcd79b82f4,
    0x869cb54a8749c161, 0x38d1a4fa6185d225, 0xb475166f94bbe9bb,
    0xa4143548720959f1, 0x7aed4780ba6b26ba, 0xd0ce264439e02312,
    0x84366d746078d508, 0xa8ce973c72ed17be, 0x21c323a29a430b01,
    0x9962d617e3af80ee, 0xab0ce91d9c8cf75b, 0x530e8ee6d19a4dbc,
    0x2ef68c0cf53f5d72, 0xc03a681640a85506, 0x496e4e9f9c310967,
    0x78580472b59b14a0, 0x273824c23b388577, 0x66bf923ad45cb553,
    0x47ae1a5a2492ba86, 0x35e304569e229659, 0x4765182a46870b6f,
    0x6cbab625e9099412, 0xddac9a2e598522c1, 0x7172086e666624f2,
    0xdf5003ca503b7837, 0x88c0c1db78563d09, 0x58d51865acfc289d,
    0x177671aec65224f1, 0xfb79d8a241e967d7, 0x2be1e101cad9a49a,
    0x6625682f6e29186b, 0x399553457ac06e50, 0x35dffb4c23abb74,
    0x429db2591f54aade, 0xc52802a8037d1009, 0x6acb27381f0b25f3,
    0xf45e2551ee4f823b, 0x8b0ea2d99580c2f7, 0x3bed519cbcb4e1e1,
    0xff452823dbb010a,  0x9d42ed614f3dd267, 0x5b9313c06257c57b,
    0xa114b8008b5e1442, 0xc1fe311c11c13d4b, 0x66e8763ea34c5568,
    0x8b982af1c262f05d, 0xee8876faaa75fbb7, 0x8a62a4d0d172bb2a,
    0xc13d94a3b7449a97, 0x6dbbba9dc15d037c, 0xc786101f1d92e0f1,
    0xd78681a907a0b79b, 0xf61aaf2962c9abb9, 0x2cfd16fcd3cb7ad9,
    0x868c5b6744624d21, 0x25e650899c74ddd7, 0xba042af4a7c37463,
    0x4eb1a539465a3eca, 0xbe09dbf03b05d5ca, 0x774e5a362b5472ba,
    0x47a1221229d183cd, 0x504b0ca18ef5a2df, 0xdffbdfbde2456eb9,
    0x46cd2b2fbee34634, 0xf2aef8fe819d98c3, 0x357f5276d4599d61,
    0x24a5483879c453e3, 0x88026889192b4b9,  0x28da96671782dbec,
    0x4ef37c40588e9aaa, 0x8837b90651bc9fb3, 0xc164f741d3f0e5d6,
    0xbc135a0a704b70ba, 0x69cd868f7622ada,  0xbc37ba89e0b9c0ab,
    0x47c14a01323552f6, 0x4f00794bacee98bb, 0x7107de7d637a69d5,
    0x88af793bb6f2255e, 0xf3c6466b8799b598, 0xc288c616aa7f3b59,
    0x81ca63cf42fca3fd, 0x88d85ace36a2674b, 0xd056bd3792389e7,
    0xe55c396c4e9dd32d, 0xbefb504571e6c0a6, 0x96ab32115e91e8cc,
    0xbf8acb18de8f38d1, 0x66dae58801672606, 0x833b6017872317fb,
    0xb87c16f2d1c92864, 0xdb766a74e58b669c, 0x89659f85c61417be,
    0xc8daad856011ea0c, 0x76a4b565b6fe7eae, 0xa469d085f6237312,
    0xaaf0365683a3e96c, 0x4dbb746f8424f7b8, 0x638755af4e4acc1,
    0x3d7807f5bde64486, 0x17be6d8f5bbb7639, 0x903f0cd44dc35dc,
    0x67b672eafdf1196c, 0xa676ff93ed4c82f1, 0x521d1004c5053d9d,
    0x37ba9ad09ccc9202, 0x84e54d297aacfb51, 0xa0b4b776a143445,
    0x820d471e20b348e,  0x1874383cb83d46dc, 0x97edeec7a1efe11c,
    0xb330e50b1bdc42aa, 0x1dd91955ce70e032, 0xa514cdb88f2939d5,
    0x2791233fd90db9d3, 0x7b670a4cc50f7a9b, 0x77c07d2a05c6dfa5,
    0xe3778b6646d0a6fa, 0xb39c8eda47b56749, 0x933ed448addbef28,
    0xaf846af6ab7d0bf4, 0xe5af208eb666e49,  0x5e6622f73534cd6a,
    0x297daeca42ef5b6e, 0x862daef3d35539a6, 0xe68722498f8e1ea9,
    0x981c53093dc0d572, 0xfa09b0bfbf86fbf5, 0x30b1e96166219f15,
    0x70e7d466bdc4fb83, 0x5a66736e35f2a8e9, 0xcddb59d2b7c1baef,
    0xd6c7d247d26d8996, 0xea4e39eac8de1ba3, 0x539c8bb19fa3aff2,
    0x9f90e4c5fd508d8,  0xa34e5956fbaf3385, 0x2e2f8e151d3ef375,
    0x173691e9b83faec1, 0xb85a8d56bf016379, 0x8382381267408ae3,
    0xb90f901bbdc0096d, 0x7c6ad32933bcec65, 0x76bb5e2f2c8ad595,
    0x390f851a6cf46d28, 0xc3e6064da1c2da72, 0xc52a0c101cfa5389,
    0xd78eaf84a3fbc530, 0x3781b9e2288b997e, 0x73c2f6dea83d05c4,
    0x4228e364c5b5ed7,  0x9d7a3edf0da43911, 0x8edcfeda24686756,
    0x5e7667a7b7a9b3a1, 0x4c4f389fa143791d, 0xb08bc1023da7cddc,
    0x7ab4be3ae529b1cc, 0x754e6132dbe74ff9, 0x71635442a839df45,
    0x2f6fb1643fbe52de, 0x961e0a42cf7a8177, 0xf3b45d83d89ef2ea,
    0xee3de4cf4a6e3e9b, 0xcd6848542c3295e7, 0xe4cee1664c78662f,
    0x9947548b474c68c4, 0x25d73777a5ed8b0b, 0xc915b1d636b7fc,
    0x21c2ba75d9b0d2da, 0x5f6b5dcf608a64a1, 0xdcf333255ff9570c,
    0x633b922418ced4ee, 0xc136dde0b004b34a, 0x58cc83b05d4b2f5a,
    0x5eb424dda28e42d2, 0x62df47369739cd98, 0xb4e0b42485e4ce17,
    0x16e1f0c1f9a8d1e7, 0x8ec3916707560ebf, 0x62ba6e2df2cc9db3,
    0xcbf9f4ff77d83a16, 0x78d9d7d07d2bbcc4, 0xef554ce1e02c41f4,
    0x8d7581127eccf94d, 0xa9b53336cb3c8a05, 0x38c42c0bf45c4f91,
    0x640893cdf4488863, 0x80ec34bc575ea568, 0x39f324f5b48eaa40,
    0xe9d9ed1f8eff527f, 0x9224fc058cc5a214, 0xbaba00b04cfe7741,
    0x309a9f120fcf52af, 0xa558f3ec65626212, 0x424bec8b7adabe2f,
    0x41622513a6aea433, 0xb88da2d5324ca798, 0xd287733b245528a4,
    0x9a44697e6d68aec3, 0x7b1093be2f49bb28, 0x50bbec632e3d8aad,
    0x6cd90723e1ea8283, 0x897b9e7431b02bf3, 0x219efdcb338a7047,
    0x3b0311f0a27c0656, 0xdb17bf91c0db96e7, 0x8cd4fd6b4e85a5b2,
    0xfab071054ba6409d, 0x40d6fe831fa9dfd9, 0xaf358debad7d791e,
    0xeb8d0e25a65e3e58, 0xbbcbd3df14e08580, 0xcf751f27ecdab2b,
    0x2b4da14f2613d8f4,
};

// --------------------------------------------------------
// Tests
// --------------------------------------------------------

const testing = std.testing;

/// Splits found one byte at a time, without the unrolling and the batches.
fn splitsOneByOne(
    gpa: std.mem.Allocator,
    state: RollingHashState,
    data: []const u8,
) !std.ArrayList(usize) {
    var splits: std.ArrayList(usize) = .empty;
    var hash = state.rolling;
    for (data, 1..) |byte, n| {
        hash = (hash << 1) +% gear_tab[byte];
        if (hash & state.stop_mask == 0) try splits.append(gpa, n);
    }
    return splits;
}

test "gearFeed finds every split, in batches" {
    const gpa = testing.allocator;
    var prng: std.Random.DefaultPrng = .init(0x1d3);
    const random = prng.random();
    const data = try gpa.alloc(u8, 20_000);
    defer gpa.free(data);
    random.bytes(data);

    for ([_]u32{ 0, 1, 3, 5, 7, 12 }) |hash_rate_log| {
        for ([_]u32{ 4, 16, 64, 200 }) |min_match_length| {
            const ldm_params: LdmParams = .{
                .hash_rate_log = hash_rate_log,
                .min_match_length = min_match_length,
            };
            var state: RollingHashState = undefined;
            gearInit(&state, &ldm_params);
            var expected = try splitsOneByOne(gpa, state, data);
            defer expected.deinit(gpa);

            var found: std.ArrayList(usize) = .empty;
            defer found.deinit(gpa);
            var splits: [ldm_batch_size]usize = undefined;
            var pos: usize = 0;
            while (pos < data.len) {
                var num_splits: u32 = 0;
                // Uneven feeds, so the unrolled loop and the tail both run.
                const size = @min(data.len - pos, random.uintAtMost(usize, 300));
                const hashed = gearFeed(&state, data[pos..].ptr, size, &splits, &num_splits);
                try testing.expect(hashed <= size);
                if (hashed < size) try testing.expectEqual(ldm_batch_size, num_splits);
                for (splits[0..num_splits]) |split| try found.append(gpa, pos + split);
                pos += hashed;
            }
            try testing.expectEqualSlices(usize, expected.items, found.items);
        }
    }
}

test "gearInit puts the mask's bits as high as the match length allows" {
    var state: RollingHashState = undefined;
    gearInit(&state, &.{ .hash_rate_log = 7, .min_match_length = 64 });
    try testing.expectEqual(@as(u64, std.math.maxInt(u32)), state.rolling);
    try testing.expectEqual(@as(u64, 0x7F) << 57, state.stop_mask);
    gearInit(&state, &.{ .hash_rate_log = 4, .min_match_length = 32 });
    try testing.expectEqual(@as(u64, 0xF) << 28, state.stop_mask);
    gearInit(&state, &.{ .hash_rate_log = 9, .min_match_length = 6 });
    try testing.expectEqual(@as(u64, 0x1FF), state.stop_mask);
    gearInit(&state, &.{ .hash_rate_log = 0, .min_match_length = 64 });
    try testing.expectEqual(@as(u64, 0), state.stop_mask);
}

test "gearReset leaves the state as it is, as the original's does" {
    const data = "0123456789abcdefghijklmnopqrstuvwxyz0123456789abcdefghijklmnopqrstuvwxyz";
    var state: RollingHashState = .{ .rolling = 0x1234, .stop_mask = 0xF0 };
    gearReset(&state, data, 64);
    try testing.expectEqual(RollingHashState{ .rolling = 0x1234, .stop_mask = 0xF0 }, state);
}

test "adjustParameters fills in the defaults from the strategy" {
    var ldm_params: LdmParams = .{ .enable_ldm = .enable };
    const cparams: params.CompressionParameters = .{
        .window_log = 27,
        .chain_log = 22,
        .hash_log = 22,
        .search_log = 1,
        .min_match = 5,
        .target_length = 0,
        .strategy = .dfast,
    };
    adjustParameters(&ldm_params, &cparams);
    try testing.expectEqual(LdmParams{
        .enable_ldm = .enable,
        .hash_log = 20,
        .bucket_size_log = 4,
        .min_match_length = 64,
        .hash_rate_log = 7,
        .window_log = 27,
    }, ldm_params);

    var strong: LdmParams = .{ .enable_ldm = .enable, .hash_log = 8, .bucket_size_log = 8 };
    var btultra2 = cparams;
    btultra2.strategy = .btultra2;
    btultra2.window_log = 20;
    adjustParameters(&strong, &btultra2);
    try testing.expectEqual(@as(u32, 12), strong.hash_rate_log);
    try testing.expectEqual(@as(u32, 32), strong.min_match_length);
    try testing.expectEqual(@as(u32, 8), strong.bucket_size_log);

    // A rate above the window log: the hash log takes its maximum.
    var wide: LdmParams = .{ .enable_ldm = .enable, .hash_rate_log = 25 };
    var small = cparams;
    small.window_log = 10;
    adjustParameters(&wide, &small);
    try testing.expectEqual(params.hash_log_max, wide.hash_log);
}

test "table sizes and sequence bound" {
    const ldm_params: LdmParams = .{
        .enable_ldm = .enable,
        .hash_log = 20,
        .bucket_size_log = 4,
        .min_match_length = 64,
    };
    try testing.expectEqual((1 << 16) + (1 << 20) * 8, getTableSize(ldm_params));
    try testing.expectEqual(@as(usize, 2048), getMaxNbSeq(ldm_params, 1 << 17));
    var off = ldm_params;
    off.enable_ldm = .disable;
    try testing.expectEqual(@as(usize, 0), getTableSize(off));
    try testing.expectEqual(@as(usize, 0), getMaxNbSeq(off, 1 << 17));
}

test "insertEntry fills each bucket as a ring" {
    var table: [4 * 4]LdmEntry = @splat(.{ .offset = 0, .checksum = 0 });
    var offsets: [4]u8 = @splat(0);
    var ldm_state: LdmState = .{ .hash_table = &table, .bucket_offsets = &offsets };
    for (0..6) |i| {
        insertEntry(&ldm_state, 2, .{ .offset = @intCast(i + 10), .checksum = 7 }, 2);
    }
    try testing.expectEqual(@as(u8, 2), offsets[2]);
    const bucket = table[8..12];
    try testing.expectEqual(@as(u32, 14), bucket[0].offset);
    try testing.expectEqual(@as(u32, 15), bucket[1].offset);
    try testing.expectEqual(@as(u32, 12), bucket[2].offset);
    try testing.expectEqual(@as(u32, 13), bucket[3].offset);
    try testing.expectEqual(@as(u32, 0), table[4].offset);
    try testing.expectEqual(@as(u32, 0), table[12].offset);
}

test "backward counts stop at the anchor, the match base, a difference" {
    const text = "xxabcdefgh__abcdefgh";
    const p: [*]const u8 = text;
    // From the ends of the two "abcdefgh", back.
    try testing.expectEqual(@as(usize, 8), countBackwardsMatch(p + 20, p + 12, p + 10, p));
    try testing.expectEqual(@as(usize, 5), countBackwardsMatch(p + 20, p + 15, p + 10, p));
    try testing.expectEqual(@as(usize, 3), countBackwardsMatch(p + 20, p + 12, p + 10, p + 7));
    try testing.expectEqual(@as(usize, 0), countBackwardsMatch(p + 20, p + 20, p + 10, p));

    // The match starts the prefix; the dictionary ends with what comes before.
    const dict = "....12345";
    const prefix = "6789";
    const input = "zz123456789";
    const in: [*]const u8 = input;
    const d: [*]const u8 = dict;
    const prefix_ptr: [*]const u8 = prefix;
    try testing.expectEqual(@as(usize, 5), countBackwardsMatch2Segments(
        in + 7,
        in,
        prefix_ptr,
        prefix_ptr,
        d,
        d + dict.len,
    ));
    // The match base is the dictionary's start: nothing before it.
    try testing.expectEqual(@as(usize, 0), countBackwardsMatch2Segments(
        in + 7,
        in,
        d,
        d,
        d,
        d + dict.len,
    ));
}

test "reduceTable clamps offsets below the correction to 0" {
    var table = [_]LdmEntry{
        .{ .offset = 5, .checksum = 1 },
        .{ .offset = 100, .checksum = 2 },
        .{ .offset = 99, .checksum = 3 },
    };
    reduceTable(&table, table.len, 99);
    try testing.expectEqual(@as(u32, 0), table[0].offset);
    try testing.expectEqual(@as(u32, 1), table[1].offset);
    try testing.expectEqual(@as(u32, 0), table[2].offset);
    try testing.expectEqual(@as(u32, 2), table[1].checksum);
}

test "skipSequences and maybeSplitSequence cut a sequence across blocks" {
    var seqs = [_]RawSeq{
        .{ .offset = 100, .lit_length = 10, .match_length = 50 },
        .{ .offset = 200, .lit_length = 5, .match_length = 40 },
    };
    var store: RawSeqStore = .{ .seq = &seqs, .size = seqs.len, .capacity = seqs.len };
    // A block of 30 bytes: the first sequence is cut 20 bytes into its match.
    const first = maybeSplitSequence(&store, 30, 4);
    try testing.expectEqual(RawSeq{ .offset = 100, .lit_length = 10, .match_length = 20 }, first);
    try testing.expectEqual(@as(usize, 0), store.pos);
    try testing.expectEqual(RawSeq{ .offset = 100, .lit_length = 0, .match_length = 30 }, seqs[0]);
    // A block that cuts the rest of the match below the minimum match drops it.
    const second = maybeSplitSequence(&store, 28, 4);
    try testing.expectEqual(@as(u32, 28), second.match_length);
    try testing.expectEqual(@as(usize, 1), store.pos);
    try testing.expectEqual(@as(u32, 5 + 2), seqs[1].lit_length);
    // A block inside the literals is all literals.
    const third = maybeSplitSequence(&store, 7, 4);
    try testing.expectEqual(@as(u32, 0), third.offset);
    try testing.expectEqual(@as(u32, 0), seqs[1].lit_length);
    // The whole sequence fits.
    const fourth = maybeSplitSequence(&store, 1000, 4);
    try testing.expectEqual(RawSeq{ .offset = 200, .lit_length = 0, .match_length = 40 }, fourth);
    try testing.expectEqual(@as(usize, 2), store.pos);
}

test "skipRawSeqStoreBytes moves the position inside and across sequences" {
    const seqs = [_]RawSeq{
        .{ .offset = 100, .lit_length = 10, .match_length = 50 },
        .{ .offset = 200, .lit_length = 5, .match_length = 40 },
    };
    var copy = seqs;
    var store: RawSeqStore = .{ .seq = &copy, .size = copy.len, .capacity = copy.len };
    skipRawSeqStoreBytes(&store, 25);
    try testing.expectEqual(@as(usize, 0), store.pos);
    try testing.expectEqual(@as(usize, 25), store.pos_in_sequence);
    skipRawSeqStoreBytes(&store, 40);
    try testing.expectEqual(@as(usize, 1), store.pos);
    try testing.expectEqual(@as(usize, 5), store.pos_in_sequence);
    skipRawSeqStoreBytes(&store, 40);
    try testing.expectEqual(@as(usize, 2), store.pos);
    try testing.expectEqual(@as(usize, 0), store.pos_in_sequence);
    try testing.expectEqualSlices(RawSeq, &seqs, &copy);
}

/// A block compressor that finds nothing, and records what it was given.
const LiteralsOnly = struct {
    var calls: std.ArrayList([]const u8) = .empty;

    fn compress(
        ms: *MatchState,
        seq_store: *SeqStore,
        rep: *[rep_num]u32,
        src: []const u8,
    ) usize {
        _ = ms;
        _ = seq_store;
        _ = rep;
        calls.append(testing.allocator, src) catch @panic("out of memory");
        return src.len;
    }
};

test "blockCompress stores the long matches between the compressor's literals" {
    const gpa = testing.allocator;
    var src: [1000]u8 = undefined;
    for (&src, 0..) |*byte, i| byte.* = @truncate(i *% 31);
    const cparams: params.CompressionParameters = .{
        .window_log = 17,
        .chain_log = 16,
        .hash_log = 16,
        .search_log = 4,
        .min_match = 4,
        .target_length = 0,
        .strategy = .greedy,
    };
    const block = try ci.BlockTest.create(gpa, cparams, &src, .none, null);
    defer block.destroy();
    var seqs = [_]RawSeq{
        .{ .offset = 300, .lit_length = 400, .match_length = 100 },
        .{ .offset = 50, .lit_length = 20, .match_length = 600 },
    };
    var store: RawSeqStore = .{ .seq = &seqs, .size = seqs.len, .capacity = seqs.len };
    LiteralsOnly.calls = .empty;
    defer LiteralsOnly.calls.deinit(gpa);

    const last = blockCompress(
        &store,
        &block.ms,
        &block.seq_store,
        &block.rep,
        LiteralsOnly.compress,
        &src,
    );
    // The second match is cut at the end of the block.
    try testing.expectEqual(@as(usize, 0), last);
    try testing.expectEqual(@as(usize, 1), store.pos);
    try testing.expectEqual(RawSeq{ .offset = 50, .lit_length = 0, .match_length = 120 }, seqs[1]);
    const calls = LiteralsOnly.calls.items;
    try testing.expectEqual(@as(usize, 3), calls.len);
    try testing.expectEqual(@as(usize, 400), calls[0].len);
    try testing.expectEqual(@intFromPtr(&src[500]), @intFromPtr(calls[1].ptr));
    try testing.expectEqual(@as(usize, 20), calls[1].len);
    try testing.expectEqual(@as(usize, 0), calls[2].len);
    try testing.expectEqual([3]u32{ 50, 300, 1 }, block.rep);

    const stored = block.seq_store.sequences_start[0..2];
    try testing.expectEqual(ci.offsetToOffbase(300), stored[0].off_base);
    try testing.expectEqual(@as(u16, 400), stored[0].lit_length);
    try testing.expectEqual(@as(u16, 100 - 3), stored[0].ml_base);
    try testing.expectEqual(ci.offsetToOffbase(50), stored[1].off_base);
    try testing.expectEqual(@as(u16, 20), stored[1].lit_length);
    try testing.expectEqual(@as(u16, 480 - 3), stored[1].ml_base);
    const literals = block.storedLiterals();
    try testing.expectEqual(@as(usize, 420), literals.len);
    try testing.expectEqualSlices(u8, src[0..400], literals[0..400]);
    try testing.expectEqualSlices(u8, src[500..520], literals[400..]);
}
