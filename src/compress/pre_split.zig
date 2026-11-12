//! The pre-splitter, from the original's zstd_preSplit.c: it cuts a full
//! block where the data seems to change, judged from fingerprints of byte
//! pairs, before any match is searched.

const std = @import("std");
const builtin = @import("builtin");

const hist = @import("hist.zig");
const ci = @import("compress_internal.zig");

const assert = std.debug.assert;
const native_endian = builtin.cpu.arch.endian();
const kib = 1 << 10;

/// `THRESHOLD_PENALTY_RATE`, `THRESHOLD_BASE`, `THRESHOLD_PENALTY`: how far
/// two fingerprints may differ, in sixteenths of their product, before a
/// split; the penalty makes the first chunks harder to split.
const threshold_penalty_rate = 16;
const threshold_base = threshold_penalty_rate - 2;
const threshold_penalty = 3;

/// `HASHLENGTH`: the bytes hashed per event.
const hash_length = 2;
/// `HASHLOG_MAX`, `HASHTABLESIZE`.
const hash_log_max = 10;
const hash_table_size = 1 << hash_log_max;
/// `KNUTH`: the multiplier of the pair hash.
const knuth = 0x9e3779b9;

/// `CHUNKSIZE`: the chunks compared by `splitBlockByChunks`.
const chunk_size = 8 << 10;
/// `SEGMENT_SIZE`: the samples compared by `splitBlockFromBorders`.
const segment_size = 512;

/// `hash2`: the event of the pair at `p`; for a log of 8, its first byte.
inline fn hash2(p: [*]const u8, comptime hash_log: u32) u32 {
    comptime assert(hash_log >= 8);
    if (hash_log == 8) return p[0];
    comptime assert(hash_log <= hash_log_max);
    const pair: u32 = std.mem.readInt(u16, p[0..2], native_endian);
    return (pair *% knuth) >> (32 - hash_log);
}

/// `Fingerprint`: the count of each event, and their total.
const Fingerprint = extern struct {
    events: [hash_table_size]u32,
    nb_events: usize,
};

/// `FPStats`: the fingerprint of the data so far, and of the next chunk.
const FPStats = extern struct {
    past_events: Fingerprint,
    new_events: Fingerprint,
};

comptime {
    assert(ci.slipblock_workspace_size >= @sizeOf(FPStats));
}

/// `initStats`.
fn initStats(fpstats: *FPStats) void {
    fpstats.* = std.mem.zeroes(FPStats);
}

/// `addEvents_generic`: counts the events of `src`, one every
/// `sampling_rate` positions.
inline fn addEvents(
    fp: *Fingerprint,
    src: []const u8,
    comptime sampling_rate: usize,
    comptime hash_log: u32,
) void {
    assert(src.len >= hash_length);
    const limit = src.len - hash_length + 1;
    var n: usize = 0;
    while (n < limit) : (n += sampling_rate) {
        fp.events[hash2(src.ptr + n, hash_log)] += 1;
    }
    fp.nb_events += limit / sampling_rate;
}

/// `recordFingerprint_generic`: the fingerprint of `src` alone.
inline fn recordFingerprint(
    fp: *Fingerprint,
    src: []const u8,
    comptime sampling_rate: usize,
    comptime hash_log: u32,
) void {
    @memset(fp.events[0 .. @as(usize, 1) << hash_log], 0);
    fp.nb_events = 0;
    addEvents(fp, src, sampling_rate, hash_log);
}

/// `RecordEvents_f`.
const RecordEvents = *const fn (fp: *Fingerprint, src: []const u8) void;

/// `ZSTD_recordFingerprint_<rate>`: a sampling rate and the hash log that
/// suits it.
fn recordFingerprintOf(comptime sampling_rate: usize, comptime hash_log: u32) RecordEvents {
    return struct {
        fn record(fp: *Fingerprint, src: []const u8) void {
            recordFingerprint(fp, src, sampling_rate, hash_log);
        }
    }.record;
}

/// `abs64`.
fn abs64(s64: i64) u64 {
    return @abs(s64);
}

/// `fpDistance`: how much two fingerprints differ, each event's count
/// weighed by the other's total. The first `1 << hash_log` events count.
fn fpDistance(
    events1: []const u32,
    nb_events1: usize,
    events2: []const u32,
    nb_events2: usize,
    hash_log: u32,
) u64 {
    assert(hash_log <= hash_log_max);
    const size = @as(usize, 1) << @intCast(hash_log);
    const lanes = 8;
    const Lanes = @Vector(lanes, i64);
    const total1: Lanes = @splat(@intCast(nb_events1));
    const total2: Lanes = @splat(@intCast(nb_events2));
    var distance: @Vector(lanes, u64) = @splat(0);
    var n: usize = 0;
    // The tables are multiples of `lanes` long.
    while (n < size) : (n += lanes) {
        const e1: Lanes = @as(@Vector(lanes, u32), events1[n..][0..lanes].*);
        const e2: Lanes = @as(@Vector(lanes, u32), events2[n..][0..lanes].*);
        distance += @abs(e1 * total2 - e2 * total1);
    }
    return @reduce(.Add, distance);
}

/// `compareFingerprints`: whether `newfp` differs enough from `ref` to
/// split between them.
fn compareFingerprints(
    ref: *const Fingerprint,
    newfp: *const Fingerprint,
    penalty: i32,
    hash_log: u32,
) bool {
    assert(ref.nb_events > 0);
    assert(newfp.nb_events > 0);
    const p50 = @as(u64, ref.nb_events) * @as(u64, newfp.nb_events);
    const deviation = fpDistance(
        &ref.events,
        ref.nb_events,
        &newfp.events,
        newfp.nb_events,
        hash_log,
    );
    const threshold = p50 * @as(u64, @intCast(threshold_base + penalty)) / threshold_penalty_rate;
    return deviation >= threshold;
}

/// `mergeEvents`: adds `newfp` to `acc`.
fn mergeEvents(acc: *Fingerprint, newfp: *const Fingerprint) void {
    const lanes = 16;
    const Lanes = @Vector(lanes, u32);
    var n: usize = 0;
    while (n < hash_table_size) : (n += lanes) {
        const sum = @as(
            Lanes,
            acc.events[n..][0..lanes].*,
        ) + @as(Lanes, newfp.events[n..][0..lanes].*);
        acc.events[n..][0..lanes].* = sum;
    }
    acc.nb_events += newfp.nb_events;
}

/// `ZSTD_splitBlock_byChunks`: the size of the first part of a full block,
/// cut at the first chunk too different from the ones before it. `level`
/// (0 to 3) samples more positions, with more precise events.
fn splitBlockByChunks(block: []const u8, level: u32, workspace: []align(8) u8) usize {
    const records_fs = [_]RecordEvents{
        recordFingerprintOf(43, 8),
        recordFingerprintOf(11, 9),
        recordFingerprintOf(5, 10),
        recordFingerprintOf(1, 10),
    };
    const hash_params = [_]u32{ 8, 9, 10, 10 };
    assert(level <= 3);
    const record_f = records_fs[level];
    assert(workspace.len >= @sizeOf(FPStats));
    const fpstats: *FPStats = @ptrCast(workspace.ptr);
    var penalty: i32 = threshold_penalty;
    assert(block.len == 128 * kib);

    initStats(fpstats);
    record_f(&fpstats.past_events, block[0..chunk_size]);
    var pos: usize = chunk_size;
    while (pos <= block.len - chunk_size) : (pos += chunk_size) {
        record_f(&fpstats.new_events, block[pos..][0..chunk_size]);
        if (compareFingerprints(
            &fpstats.past_events,
            &fpstats.new_events,
            penalty,
            hash_params[level],
        )) {
            return pos;
        }
        mergeEvents(&fpstats.past_events, &fpstats.new_events);
        if (penalty > 0) penalty -= 1;
    }
    assert(pos == block.len);
    return block.len;
}

/// `ZSTD_splitBlock_fromBorders`: a cheap split of a full block: when its
/// start and end differ, the middle tells which of them it is closer to,
/// and the block is cut at a quarter, half or three quarters.
fn splitBlockFromBorders(block: []const u8, workspace: []align(8) u8) usize {
    assert(workspace.len >= @sizeOf(FPStats));
    const fpstats: *FPStats = @ptrCast(workspace.ptr);
    assert(block.len == 128 * kib);

    initStats(fpstats);
    hist.add(&fpstats.past_events.events, block[0..segment_size]);
    hist.add(&fpstats.new_events.events, block[block.len - segment_size ..]);
    fpstats.past_events.nb_events = segment_size;
    fpstats.new_events.nb_events = segment_size;
    if (!compareFingerprints(&fpstats.past_events, &fpstats.new_events, 0, 8)) return block.len;

    // The middle's events, in an unused part of the start's table, as the
    // original has them.
    const middle_events = fpstats.past_events.events[512..][0..256];
    hist.add(middle_events, block[block.len / 2 - segment_size / 2 ..][0..segment_size]);
    const middle_nb_events = segment_size;
    const dist_from_begin = fpDistance(
        &fpstats.past_events.events,
        segment_size,
        middle_events,
        middle_nb_events,
        8,
    );
    const dist_from_end = fpDistance(
        &fpstats.new_events.events,
        segment_size,
        middle_events,
        middle_nb_events,
        8,
    );
    const min_distance = segment_size * segment_size / 3;
    if (abs64(
        @as(i64, @intCast(dist_from_begin)) - @as(i64, @intCast(dist_from_end)),
    ) < min_distance) {
        return 64 * kib;
    }
    return if (dist_from_begin > dist_from_end) 32 * kib else 96 * kib;
}

/// `ZSTD_splitBlock`: the size of the first part of a full block of 128
/// KiB, `level` 0 (fastest) to 4 (most precise). `workspace` holds
/// `ci.slipblock_workspace_size` bytes.
pub fn splitBlock(block: []const u8, level: u32, workspace: []align(8) u8) usize {
    assert(level <= 4);
    if (level == 0) return splitBlockFromBorders(block, workspace);
    return splitBlockByChunks(block, level - 1, workspace);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test {
    testing.refAllDecls(@This());
}

test "a uniform block is not split" {
    var workspace: [ci.slipblock_workspace_size]u8 align(8) = undefined;
    const block: [128 * kib]u8 = @splat('a');
    for (0..5) |level| {
        try testing.expectEqual(128 * kib, splitBlock(&block, @intCast(level), &workspace));
    }
}

test "a block that changes halfway is cut there" {
    var workspace: [ci.slipblock_workspace_size]u8 align(8) = undefined;
    var block: [128 * kib]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(1);
    for (block[0 .. 64 * kib]) |*b| b.* = 'a' + prng.random().uintLessThan(u8, 4);
    for (block[64 * kib ..]) |*b| b.* = prng.random().int(u8);
    try testing.expectEqual(64 * kib, splitBlock(&block, 0, &workspace));
    try testing.expectEqual(64 * kib, splitBlock(&block, 4, &workspace));
}
