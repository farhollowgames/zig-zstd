//! Oracle tests of the entropy coders: histograms, FSE, Huffman, the bit
//! stream writer and the table header readers, each called on the port and
//! the original with the same inputs. Every output byte, every table entry
//! and every returned value or error code must be the same.

// --------------------------------------------------------
// Tests
// --------------------------------------------------------

const std = @import("std");
const zstd = @import("zstd");
const c = @import("upstream");
const common = @import("common.zig");

const bitstream = zstd.internal.bitstream;
const entropy_common = zstd.internal.entropy_common;
const fse = zstd.internal.fse;
const huf = zstd.internal.huf;
const fse_compress = zstd.internal.fse_compress;
const hist = zstd.internal.hist;
const huf_compress = zstd.internal.huf_compress;

const testing = std.testing;
const gpa = common.gpa;
const Random = std.Random;

/// Checks that the port's result is the original's: the same size, or the
/// same error code.
fn expectSameResult(expected: usize, actual: zstd.Error!usize) !void {
    const value = actual catch |err| {
        if (c.ZSTD_isError(expected) == 0) {
            std.debug.print("original returned {d}, port {t}\n", .{ expected, err });
            return error.ResultsDiffer;
        }
        const code: u32 = @backingInt(zstd.errorCode(err));
        if (c.ZSTD_getErrorCode(expected) != code) {
            std.debug.print(
                "original failed with {s}, port with {t}\n",
                .{ c.ZSTD_getErrorName(expected), err },
            );
            return error.ResultsDiffer;
        }
        return;
    };
    if (c.ZSTD_isError(expected) != 0) {
        std.debug.print(
            "original failed with {s}, port returned {d}\n",
            .{ c.ZSTD_getErrorName(expected), value },
        );
        return error.ResultsDiffer;
    }
    try testing.expectEqual(expected, value);
}

/// The test inputs, each in its own allocation with 16 bytes of slack after
/// it, since the original's histogram reads 4 bytes from inputs shorter than
/// that.
const Inputs = struct {
    arena: std.heap.ArenaAllocator,
    list: std.ArrayList([]const u8),

    const sizes = [_]usize{
        0,    1,    2,    3,    4,    5,     7,     8,     11,     12,
        13,   15,   16,   17,   31,   64,    100,   255,   256,    1000,
        1499, 1500, 1501, 4096, 5000, 40960, 65536, 70001, 131072,
    };

    fn deinit(inputs: *Inputs) void {
        inputs.arena.deinit();
        inputs.* = undefined;
    }

    fn add(inputs: *Inputs, bytes: []const u8) !void {
        const copy = try inputs.arena.allocator().alloc(u8, bytes.len + 16);
        @memcpy(copy[0..bytes.len], bytes);
        @memset(copy[bytes.len..], 0);
        try inputs.list.append(inputs.arena.allocator(), copy[0..bytes.len]);
    }

    /// Every kind of input at every size: one byte repeated, two symbols,
    /// random bytes, random bytes from small alphabets, a geometric
    /// distribution (deep Huffman trees), and the original's generator at
    /// several match and literal probabilities.
    fn all() !Inputs {
        var inputs: Inputs = .{ .arena = .init(gpa), .list = .empty };
        errdefer inputs.deinit();
        var prng: Random.DefaultPrng = .init(common.fuzzSeed(0x5EED));
        const random = prng.random();
        const generated_probabilities = [_][2]f64{
            .{ 0.0, 0.0 },
            .{ 0.3, 0.0 },
            .{ 0.5, 0.5 },
            .{ 0.7, 0.9 },
            .{ 0.95, 0.2 },
        };
        const buffer = try gpa.alloc(u8, sizes[sizes.len - 1]);
        defer gpa.free(buffer);
        for (sizes) |size| {
            const bytes = buffer[0..size];
            @memset(bytes, 'a');
            try inputs.add(bytes);
            for (bytes) |*byte| byte.* = if (random.boolean()) 'x' else 200;
            try inputs.add(bytes);
            random.bytes(bytes);
            try inputs.add(bytes);
            for ([_]u8{ 3, 12, 40 }) |alphabet| {
                for (bytes) |*byte| byte.* = random.uintLessThan(u8, alphabet);
                try inputs.add(bytes);
            }
            for (bytes) |*byte| byte.* = @min(@ctz(random.int(u64) | (1 << 40)), 40);
            try inputs.add(bytes);
            for (generated_probabilities, 0..) |p, n| {
                c.reference_genBuffer(bytes.ptr, size, p[0], p[1], @intCast(size + n));
                try inputs.add(bytes);
            }
        }
        return inputs;
    }
};

fn largestByte(bytes: []const u8) u32 {
    var largest: u8 = 0;
    for (bytes) |byte| largest = @max(largest, byte);
    return largest;
}

const fill_u32: u32 = 0xA5A5A5A5;

// Histograms.

fn expectSameHistogram(src: []const u8, max_symbol_value: u32, trusted: bool) !void {
    var workspace: [hist.wksp_size_u32 + 1]u32 = undefined;
    const ws_bytes = std.mem.asBytes(&workspace);

    const Kind = enum { count, count_wksp, count_fast, count_fast_wksp, simple, misaligned, small };
    const kinds = [_]Kind{
        .count,
        .count_wksp,
        .count_fast,
        .count_fast_wksp,
        .simple,
        .misaligned,
        .small,
    };
    for (kinds) |kind| {
        const fast = kind == .count_fast or kind == .count_fast_wksp or kind == .simple;
        if (fast and !trusted) continue;
        var expected: [256]c_uint = @splat(fill_u32);
        var actual: [256]u32 = @splat(fill_u32);
        var expected_max: c_uint = max_symbol_value;
        var actual_max: u32 = max_symbol_value;
        const wksp = ws_bytes[4..][0..hist.wksp_size];
        const misaligned = ws_bytes[1..][0..hist.wksp_size];
        const small = ws_bytes[4..][0 .. hist.wksp_size - 1];
        switch (kind) {
            .count => try expectSameResult(
                c.HIST_count(&expected, &expected_max, src.ptr, src.len),
                hist.count(&actual, &actual_max, src),
            ),
            .count_fast => try expectSameResult(
                c.HIST_countFast(&expected, &expected_max, src.ptr, src.len),
                hist.countFast(&actual, &actual_max, src),
            ),
            .count_wksp, .misaligned, .small => {
                const ws = switch (kind) {
                    .misaligned => misaligned,
                    .small => small,
                    else => wksp,
                };
                const original = c.HIST_count_wksp(
                    &expected,
                    &expected_max,
                    src.ptr,
                    src.len,
                    ws.ptr,
                    ws.len,
                );
                try expectSameResult(original, hist.countWksp(&actual, &actual_max, src, ws));
            },
            .count_fast_wksp => {
                const original = c.HIST_countFast_wksp(
                    &expected,
                    &expected_max,
                    src.ptr,
                    src.len,
                    wksp.ptr,
                    wksp.len,
                );
                try expectSameResult(original, hist.countFastWksp(&actual, &actual_max, src, wksp));
            },
            .simple => {
                const original = c.HIST_count_simple(&expected, &expected_max, src.ptr, src.len);
                try testing.expectEqual(original, hist.countSimple(&actual, &actual_max, src));
            },
        }
        try testing.expectEqual(expected_max, actual_max);
        try testing.expectEqualSlices(u32, &expected, &actual);
    }

    var expected: [256]c_uint = @splat(3);
    var actual: [256]u32 = @splat(3);
    c.HIST_add(&expected, src.ptr, src.len);
    hist.add(&actual, src);
    try testing.expectEqualSlices(u32, &expected, &actual);
}

test "histograms: every count, limit and workspace" {
    var inputs: Inputs = try .all();
    defer inputs.deinit();
    for (inputs.list.items) |src| {
        const largest = largestByte(src);
        try expectSameHistogram(src, 255, true);
        try expectSameHistogram(src, 254, largest <= 254);
        try expectSameHistogram(src, largest, true);
        if (largest > 0) try expectSameHistogram(src, largest - 1, false);
        try expectSameHistogram(src, 0, largest == 0);
    }
}

test "histograms: seeded fuzz" {
    const seed = common.fuzzSeed(0x4157);
    var prng: Random.DefaultPrng = .init(seed);
    const random = prng.random();
    var buffer: [6000]u8 = undefined;
    for (0..common.fuzz_cases) |case| {
        errdefer std.debug.print("histograms: seed {d} case {d}\n", .{ seed, case });
        const size = random.uintLessThan(usize, buffer.len - 16);
        const alphabet = random.intRangeAtMost(u32, 1, 256);
        for (buffer[0..size]) |*byte| byte.* = @intCast(random.uintLessThan(u32, alphabet));
        const src = buffer[0..size];
        const max_symbol_value = random.uintAtMost(u32, 255);
        try expectSameHistogram(src, max_symbol_value, largestByte(src) <= max_symbol_value);
    }
}

// The bit stream writer.

test "bit streams: seeded fuzz of fields, flushes and capacities" {
    const seed = common.fuzzSeed(0xB175);
    var prng: Random.DefaultPrng = .init(seed);
    const random = prng.random();
    const field_count_max = 200;
    var values: [field_count_max]usize = undefined;
    var widths: [field_count_max]c_uint = undefined;
    var ops: [field_count_max]u8 = undefined;
    var expected: [field_count_max * 4 + 16]u8 = undefined;
    // Each field fits in the container with the bits left over after a
    // flush; the original's callers keep within the same room.
    const width_max: u32 = if (@sizeOf(usize) > 4) 31 else 24;
    const pending_max = @bitSizeOf(usize) - 1 - width_max;
    var actual: [expected.len]u8 = undefined;

    for (0..common.fuzz_cases) |case| {
        errdefer std.debug.print("bit streams: seed {d} case {d}\n", .{ seed, case });
        const n = random.uintAtMost(usize, field_count_max);
        const fast_flushes = random.boolean();
        var pending: u32 = 0;
        var total_bits: usize = 0;
        for (0..n) |i| {
            widths[i] = random.uintAtMost(u32, width_max);
            values[i] = random.int(usize);
            ops[i] = 0;
            if (random.boolean()) {
                ops[i] |= 1;
                values[i] &= bitstream.mask[widths[i]];
            }
            pending += widths[i];
            total_bits += widths[i];
            if (pending > pending_max or random.uintLessThan(u32, 4) == 0) {
                ops[i] |= if (fast_flushes) 4 else 2;
                pending &= 7;
            }
        }
        // A fast flush needs room for every byte; a safe one may run out.
        const needed = total_bits / 8 + @sizeOf(usize) + 1;
        const capacity = if (fast_flushes)
            random.intRangeAtMost(usize, needed, expected.len)
        else
            random.uintAtMost(usize, @min(needed + 8, expected.len));

        @memset(&expected, 0xEE);
        @memset(&actual, 0xEE);
        const original = c.reference_bitWrite(&expected, capacity, &values, &widths, &ops, n);
        const port: zstd.Error!usize = blk: {
            var bit_c = bitstream.CStream.init(actual[0..capacity]) catch |err| break :blk err;
            for (0..n) |i| {
                if (ops[i] & 1 != 0) bit_c.addBitsFast(values[i], widths[i]) else {
                    bit_c.addBits(values[i], widths[i]);
                }
                if (ops[i] & 2 != 0) bit_c.flushBits();
                if (ops[i] & 4 != 0) bit_c.flushBitsFast();
            }
            break :blk bit_c.close();
        };
        try expectSameResult(original, port);
        try testing.expectEqualSlices(u8, &expected, &actual);
    }
}

// FSE.

test "FSE: optimal table logs" {
    const src_sizes = [_]usize{
        2,
        3,
        4,
        5,
        7,
        8,
        9,
        100,
        1000,
        4096,
        65536,
        1 << 20,
        if (@sizeOf(usize) > 4) (1 << 32) + 5 else std.math.maxInt(usize),
    };
    const max_symbol_values = [_]u32{ 1, 2, 3, 7, 12, 31, 35, 52, 255 };
    for (0..16) |max_table_log| {
        for (src_sizes) |src_size| {
            for (max_symbol_values) |max_symbol_value| {
                const table_log: u32 = @intCast(max_table_log);
                try testing.expectEqual(
                    c.FSE_optimalTableLog(table_log, src_size, max_symbol_value),
                    fse_compress.optimalTableLog(table_log, src_size, max_symbol_value),
                );
                for (0..3) |minus| {
                    const m: u32 = @intCast(minus);
                    const max = max_symbol_value;
                    try testing.expectEqual(
                        c.FSE_optimalTableLog_internal(table_log, src_size, max, m),
                        fse_compress.optimalTableLogInternal(table_log, src_size, max, m),
                    );
                }
            }
        }
    }
    for (0..300) |n| {
        try testing.expectEqual(c.FSE_compressBound(n * 977), fse_compress.compressBound(n * 977));
        const max_symbol_value: u32 = @intCast(n % 256);
        const table_log: u32 = @intCast(n % 16);
        try testing.expectEqual(
            c.FSE_NCountWriteBound(max_symbol_value, table_log),
            fse_compress.ncountWriteBound(max_symbol_value, table_log),
        );
    }
}

/// A normalized distribution of both sides, with its table log.
const Normalized = struct {
    norm: [256]i16,
    table_log: u32,
    max_symbol_value: u32,
};

/// Normalizes `count` on both sides and compares; returns the distribution
/// when both succeed with a table (not RLE).
fn expectSameNormalized(
    count: []const u32,
    total: usize,
    max_symbol_value: u32,
    table_log: u32,
    use_low_prob_count: bool,
) !?Normalized {
    var expected: [256]c_short = @splat(0x5555);
    var actual: [256]i16 = @splat(0x5555);
    const original = c.FSE_normalizeCount(
        &expected,
        table_log,
        count.ptr,
        total,
        max_symbol_value,
        @intFromBool(use_low_prob_count),
    );
    const port = fse_compress.normalizeCount(
        &actual,
        table_log,
        count,
        total,
        max_symbol_value,
        use_low_prob_count,
    );
    try expectSameResult(original, if (port) |log| log else |err| err);
    try testing.expectEqualSlices(i16, &expected, &actual);
    if (c.ZSTD_isError(original) != 0 or original == 0) return null;
    return .{
        .norm = actual,
        .table_log = @intCast(original),
        .max_symbol_value = max_symbol_value,
    };
}

/// Writes the distribution's header on both sides into buffers of every
/// size up to the bound, and returns the header.
fn expectSameNCount(n: *const Normalized, header: *[fse.ncount_bound + 8]u8) !usize {
    const bound = fse_compress.ncountWriteBound(n.max_symbol_value, n.table_log);
    var expected: [fse.ncount_bound + 8]u8 = undefined;
    var size: usize = 0;
    var capacity: usize = 0;
    while (capacity <= bound + 2) : (capacity += 1) {
        @memset(&expected, 0xEE);
        @memset(header, 0xEE);
        const original = c.FSE_writeNCount(
            &expected,
            capacity,
            &n.norm,
            n.max_symbol_value,
            n.table_log,
        );
        const port = fse_compress.writeNCount(
            header[0..capacity],
            &n.norm,
            n.max_symbol_value,
            n.table_log,
        );
        try expectSameResult(original, port);
        try testing.expectEqualSlices(u8, &expected, header);
        if (c.ZSTD_isError(original) == 0) size = original;
    }
    return size;
}

/// Reads `header` on both sides with each symbol limit and compares the
/// counts, the limit, the table log and the size read.
fn expectSameReadNCount(header: []const u8, max_symbol_value: u32) !void {
    var expected: [256]c_short = @splat(0x3333);
    var actual: [256]i16 = @splat(0x3333);
    var expected_max: c_uint = max_symbol_value;
    var actual_max: u32 = max_symbol_value;
    var expected_log: c_uint = 99;
    var actual_log: u32 = 99;
    const original = c.FSE_readNCount(
        &expected,
        &expected_max,
        &expected_log,
        header.ptr,
        header.len,
    );
    const port = entropy_common.readNCount(&actual, &actual_max, &actual_log, header);
    try expectSameResult(original, port);
    try testing.expectEqualSlices(i16, &expected, &actual);
    try testing.expectEqual(expected_max, actual_max);
    try testing.expectEqual(expected_log, actual_log);
}

/// Builds the compression table on both sides, with an exact workspace and
/// one byte short, and returns the port's.
fn expectSameFseCTable(n: *const Normalized, ct: []u32) !void {
    const ct_size = fse.ctableSizeU32(n.table_log, n.max_symbol_value);
    const expected = try gpa.alloc(c_uint, ct_size);
    defer gpa.free(expected);
    var workspace: [fse.buildCTableWorkspaceSizeU32(255, fse.max_table_log) + 1]u32 = undefined;
    const ws_size = fse.buildCTableWorkspaceSize(n.max_symbol_value, n.table_log);
    const ws = std.mem.asBytes(&workspace);
    for ([_]usize{ ws_size - 1, ws_size }) |size| {
        @memset(expected, 0);
        @memset(ct[0..ct_size], 0);
        const original = c.FSE_buildCTable_wksp(
            expected.ptr,
            &n.norm,
            n.max_symbol_value,
            n.table_log,
            ws.ptr,
            size,
        );
        const port = fse_compress.buildCTableWksp(
            ct[0..ct_size],
            &n.norm,
            n.max_symbol_value,
            n.table_log,
            ws[0..size],
        );
        try expectSameResult(original, if (port) |_| 0 else |err| err);
        try testing.expectEqualSlices(u32, expected, ct[0..ct_size]);
    }
}

/// Compresses `src` with `ct` on both sides into buffers of several sizes.
fn expectSameFseCompress(src: []const u8, ct: []const u32) !void {
    const bound = fse_compress.compressBound(src.len);
    const expected = try gpa.alloc(u8, bound);
    defer gpa.free(expected);
    const actual = try gpa.alloc(u8, bound);
    defer gpa.free(actual);
    const capacities = [_]usize{
        bound,
        fse.blockBound(src.len),
        fse.blockBound(src.len) - 1,
        src.len / 2 + 9,
        src.len / 8 + 9,
        20,
        9,
        8,
        0,
    };
    for (capacities) |capacity_wanted| {
        const capacity = @min(capacity_wanted, bound);
        @memset(expected, 0xEE);
        @memset(actual, 0xEE);
        const original = c.FSE_compress_usingCTable(
            expected.ptr,
            capacity,
            src.ptr,
            src.len,
            ct.ptr,
        );
        const port = fse_compress.compressUsingCTable(actual[0..capacity], src, ct);
        try testing.expectEqual(original, port);
        try testing.expectEqualSlices(u8, expected, actual);
    }
}

/// Encodes `src` with one state and extra bits, as the sequence encoder
/// does, on both sides; and compares each symbol's costs.
fn expectSameFseStates(src: []const u8, ct: []const u32, n: *const Normalized, seed: u64) !void {
    if (src.len == 0) return;
    const count: usize = @min(src.len, 4096);
    const extra = try gpa.alloc(c_uint, count);
    defer gpa.free(extra);
    const extra_bits = try gpa.alloc(c_uint, count);
    defer gpa.free(extra_bits);
    var prng: Random.DefaultPrng = .init(seed);
    const random = prng.random();
    // A symbol's bits and its extra bits go in one flush; a 32-bit
    // container holds 7 left over, a symbol's 12 and 12 extra.
    const extra_bits_max: u32 = if (@sizeOf(usize) > 4) 25 else 12;
    for (extra, extra_bits) |*e, *bits| {
        bits.* = random.uintAtMost(u32, extra_bits_max);
        e.* = random.int(u32) & bitstream.mask[bits.*];
    }
    const capacity_max = count * 5 + 16;
    const expected = try gpa.alloc(u8, capacity_max);
    defer gpa.free(expected);
    const actual = try gpa.alloc(u8, capacity_max);
    defer gpa.free(actual);
    const symbols = src[0..count];
    for ([_]usize{ capacity_max, count, 9, 3 }) |capacity| {
        for ([_]bool{ false, true }) |init2| {
            @memset(expected, 0xEE);
            @memset(actual, 0xEE);
            const original = c.reference_fseEncode(
                expected.ptr,
                capacity,
                ct.ptr,
                symbols.ptr,
                extra.ptr,
                extra_bits.ptr,
                count,
                @intFromBool(init2),
            );
            const port = fseEncode(actual[0..capacity], ct, symbols, extra, extra_bits, init2);
            try testing.expectEqual(original, port);
            try testing.expectEqualSlices(u8, expected, actual);
        }
    }
    const state: fse_compress.CState = .init(ct);
    for (0..n.max_symbol_value + 1) |s| {
        const symbol: u32 = @intCast(s);
        try testing.expectEqual(
            c.reference_fseGetMaxNbBits(ct.ptr, symbol),
            fse_compress.getMaxNbBits(state.symbol_tt, symbol),
        );
        for ([_]u32{ 0, 3, 8 }) |accuracy_log| {
            try testing.expectEqual(
                c.reference_fseBitCost(ct.ptr, n.table_log, symbol, accuracy_log),
                fse_compress.bitCost(state.symbol_tt, n.table_log, symbol, accuracy_log),
            );
        }
    }
}

/// The port's side of `reference_fseEncode`.
fn fseEncode(
    dst: []u8,
    ct: []const u32,
    symbols: []const u8,
    extra: []const c_uint,
    extra_bits: []const c_uint,
    init2: bool,
) usize {
    var bit_c = bitstream.CStream.init(dst) catch return 0;
    var i = symbols.len;
    var state: fse_compress.CState = undefined;
    if (init2) {
        i -= 1;
        state = .initWithSymbol(ct, symbols[i]);
        bit_c.addBits(extra[i], extra_bits[i]);
        bit_c.flushBits();
    } else {
        state = .init(ct);
    }
    while (i > 0) {
        i -= 1;
        fse_compress.encodeSymbol(&bit_c, &state, symbols[i]);
        bit_c.addBits(extra[i], extra_bits[i]);
        bit_c.flushBits();
    }
    fse_compress.flushCState(&bit_c, &state);
    return bit_c.close();
}

/// Every FSE step on `src`'s histogram at `table_log`: normalize, write
/// and read the header, build the table, compress, and encode by states.
fn expectSameFsePipeline(
    src: []const u8,
    count: []const u32,
    total: usize,
    max_symbol_value: u32,
    table_log: u32,
    use_low_prob_count: bool,
    full: bool,
) !void {
    const n = try expectSameNormalized(
        count,
        total,
        max_symbol_value,
        table_log,
        use_low_prob_count,
    ) orelse return;

    var header: [fse.ncount_bound + 8]u8 = undefined;
    const header_size = try expectSameNCount(&n, &header);
    try testing.expect(header_size > 0);
    for ([_]u32{ 255, n.max_symbol_value, n.max_symbol_value -| 1 }) |limit| {
        try expectSameReadNCount(header[0..header_size], limit);
    }
    if (full) {
        for (0..header_size) |prefix| try expectSameReadNCount(header[0..prefix], 255);
    }

    var ct: [fse.ctableSizeU32(fse.max_table_log, 255)]u32 = undefined;
    try expectSameFseCTable(&n, &ct);
    const ct_used = ct[0..fse.ctableSizeU32(n.table_log, n.max_symbol_value)];
    if (src.len > 0) {
        try expectSameFseCompress(src, ct_used);
        if (full) try expectSameFseStates(src, ct_used, &n, total);
    }
}

test "FSE: normalize, headers, tables and streams of every input" {
    var inputs: Inputs = try .all();
    defer inputs.deinit();
    for (inputs.list.items) |src| {
        if (src.len < 2) continue;
        var count: [256]u32 = undefined;
        var max_symbol_value: u32 = 255;
        _ = hist.countSimple(&count, &max_symbol_value, src);
        // One symbol is RLE, which FSE does not take.
        if (max_symbol_value == 0) continue;
        const table_logs = [_]u32{ 0, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13 };
        for (table_logs) |table_log| {
            for ([_]bool{ false, true }) |use_low_prob_count| {
                const full = table_log == 6 or table_log == 9 or table_log == 12;
                try expectSameFsePipeline(
                    src,
                    &count,
                    src.len,
                    max_symbol_value,
                    table_log,
                    use_low_prob_count,
                    full,
                );
            }
        }
        // A larger alphabet than the input uses.
        try expectSameFsePipeline(src, &count, src.len, 255, 11, true, false);
    }
}

test "FSE: RLE tables" {
    var expected: [fse.ctableSizeU32(1, 255)]c_uint = undefined;
    var actual: [expected.len]u32 = undefined;
    for (0..256) |symbol| {
        @memset(&expected, fill_u32);
        @memset(&actual, fill_u32);
        try expectSameResult(c.FSE_buildCTable_rle(&expected, @intCast(symbol)), 0);
        fse_compress.buildCTableRle(&actual, @intCast(symbol));
        try testing.expectEqualSlices(u32, &expected, &actual);
    }
    // An RLE table compresses its symbol to nothing but the states.
    const src: [100]u8 = @splat(7);
    fse_compress.buildCTableRle(&actual, 7);
    try expectSameFseCompress(&src, &actual);
}

/// Random counts: a random alphabet with many zeros, ones, or a dominant
/// symbol, which reach the second normalization method.
fn randomCounts(random: Random, count: *[256]u32) struct { total: usize, max: u32 } {
    const max_symbol_value = random.intRangeAtMost(u32, 1, 255);
    const shape = random.uintLessThan(u32, 5);
    var total: usize = 0;
    for (count[0 .. max_symbol_value + 1], 0..) |*c_, s| {
        c_.* = switch (shape) {
            0 => random.uintAtMost(u32, 3),
            1 => if (random.uintLessThan(u32, 4) == 0) random.uintAtMost(u32, 2000) else 0,
            2 => if (s == 0) random.uintAtMost(u32, 100_000) else random.uintAtMost(u32, 2),
            3 => @as(u32, 1) << @intCast(random.uintAtMost(u32, 16)),
            else => random.uintAtMost(u32, 50),
        };
        total += c_.*;
    }
    count[max_symbol_value] = @max(count[max_symbol_value], 1);
    if (count[0] == 0) count[0] = 1;
    total = 0;
    for (count[0 .. max_symbol_value + 1]) |c_| total += c_;
    return .{ .total = total, .max = max_symbol_value };
}

test "FSE: seeded fuzz of distributions and headers" {
    const seed = common.fuzzSeed(0xF5E);
    var prng: Random.DefaultPrng = .init(seed);
    const random = prng.random();
    for (0..common.fuzz_cases) |case| {
        errdefer std.debug.print("FSE distributions: seed {d} case {d}\n", .{ seed, case });
        var count: [256]u32 = @splat(0);
        const counts = randomCounts(random, &count);
        if (counts.total < 2) continue;
        const table_log = random.intRangeAtMost(u32, 4, 13);
        const low_prob = random.boolean();
        const n = try expectSameNormalized(
            &count,
            counts.total,
            counts.max,
            table_log,
            low_prob,
        ) orelse continue;
        var header: [fse.ncount_bound + 8]u8 = undefined;
        const header_size = try expectSameNCount(&n, &header);
        try expectSameReadNCount(header[0..header_size], 255);
        var ct: [fse.ctableSizeU32(fse.max_table_log, 255)]u32 = undefined;
        try expectSameFseCTable(&n, &ct);

        // An incorrect distribution: one count moved by one.
        var wrong = n;
        const s = random.uintAtMost(u32, n.max_symbol_value);
        wrong.norm[s] = if (wrong.norm[s] <= 0) wrong.norm[s] + 1 else wrong.norm[s] - 1;
        _ = try expectSameNCount(&wrong, &header);
    }
}

test "FSE: seeded fuzz of untrusted distribution headers" {
    const seed = common.fuzzSeed(0x2EAD);
    var prng: Random.DefaultPrng = .init(seed);
    const random = prng.random();
    var bytes: [64]u8 = undefined;
    for (0..common.fuzz_cases) |case| {
        errdefer std.debug.print("FSE headers: seed {d} case {d}\n", .{ seed, case });
        const size = random.uintAtMost(usize, bytes.len);
        if (random.boolean()) {
            random.bytes(bytes[0..size]);
        } else {
            // A valid header, then corrupted.
            var count: [256]u32 = @splat(0);
            const counts = randomCounts(random, &count);
            var norm: [256]i16 = undefined;
            const table_log = fse_compress.normalizeCount(
                &norm,
                random.intRangeAtMost(u32, 5, 12),
                &count,
                counts.total,
                counts.max,
                random.boolean(),
            ) catch continue;
            if (table_log == 0) continue;
            var header: [fse.ncount_bound]u8 = undefined;
            const header_size = try fse_compress.writeNCount(&header, &norm, counts.max, table_log);
            const used = @min(size, header_size);
            @memcpy(bytes[0..used], header[0..used]);
            random.bytes(bytes[used..size]);
            for (0..random.uintAtMost(u32, 3)) |_| {
                if (size == 0) break;
                const bit = random.uintLessThan(usize, size * 8);
                bytes[bit / 8] ^= @as(u8, 1) << @intCast(bit % 8);
            }
        }
        const limit = if (random.boolean()) 255 else random.uintAtMost(u32, 255);
        try expectSameReadNCount(bytes[0..size], limit);
    }
}

// Huffman.

const CTable = [huf.ctableSizeSt(255)]usize;
const fill_celt: usize = @truncate(@as(u64, 0x5A5A5A5A5A5A5A5A));

/// A workspace of `huf.workspace_size` bytes, aligned on 8, with room to
/// misalign it.
const Workspace = struct {
    words: [huf.workspace_size_u64 + 1]u64 = undefined,

    fn bytes(ws: *Workspace, offset: usize) []u8 {
        return std.mem.asBytes(&ws.words)[offset..][0..huf.workspace_size];
    }
};

fn expectSameHufCTable(
    count: []const u32,
    max_symbol_value: u32,
    max_nb_bits: u32,
    ws: *Workspace,
    actual: *CTable,
) !usize {
    var expected: CTable = @splat(fill_celt);
    actual.* = @splat(fill_celt);
    const workspace = ws.bytes(0);
    const original = c.HUF_buildCTable_wksp(
        &expected,
        count.ptr,
        max_symbol_value,
        max_nb_bits,
        workspace.ptr,
        workspace.len,
    );
    const port = huf_compress.buildCTableWksp(
        actual,
        count,
        max_symbol_value,
        max_nb_bits,
        workspace,
    );
    try expectSameResult(original, if (port) |bits| bits else |err| err);
    try testing.expectEqualSlices(usize, &expected, actual);
    return original;
}

fn expectSameReadCTable(src: []const u8, max_symbol_value: u32) !void {
    var expected: CTable = @splat(fill_celt);
    var actual: CTable = @splat(fill_celt);
    var expected_max: c_uint = max_symbol_value;
    var actual_max: u32 = max_symbol_value;
    var expected_zero: c_uint = 7;
    var actual_zero = false;
    const original = c.HUF_readCTable(&expected, &expected_max, src.ptr, src.len, &expected_zero);
    const port = huf_compress.readCTable(&actual, &actual_max, src, &actual_zero);
    try expectSameResult(original, port);
    try testing.expectEqualSlices(usize, &expected, &actual);
    try testing.expectEqual(expected_max, actual_max);
    if (expected_zero != 7) try testing.expectEqual(expected_zero != 0, actual_zero);
}

fn expectSameReadStats(src: []const u8, hw_size: usize, ws_size: usize) !void {
    var expected_weights: [256]u8 = @splat(0xEE);
    var actual_weights: [256]u8 = @splat(0xEE);
    var expected_ranks: [huf.table_log_max + 1]u32 = @splat(fill_u32);
    var actual_ranks: [huf.table_log_max + 1]u32 = @splat(fill_u32);
    var expected_symbols: u32 = 77;
    var actual_symbols: u32 = 77;
    var expected_log: u32 = 77;
    var actual_log: u32 = 77;
    var workspace: [huf.read_stats_workspace_size_u32]u32 = undefined;
    const ws = std.mem.asBytes(&workspace)[0..ws_size];
    const original = c.HUF_readStats_wksp(
        &expected_weights,
        hw_size,
        &expected_ranks,
        &expected_symbols,
        &expected_log,
        src.ptr,
        src.len,
        ws.ptr,
        ws.len,
        0,
    );
    const port = entropy_common.readStatsWksp(
        actual_weights[0..hw_size],
        &actual_ranks,
        &actual_symbols,
        &actual_log,
        src,
        ws,
    );
    try expectSameResult(original, port);
    try testing.expectEqualSlices(u8, &expected_weights, &actual_weights);
    try testing.expectEqualSlices(u32, &expected_ranks, &actual_ranks);
    try testing.expectEqual(expected_symbols, actual_symbols);
    try testing.expectEqual(expected_log, actual_log);

    if (hw_size == 256 and ws_size == huf.read_stats_workspace_size) {
        @memset(&expected_weights, 0xEE);
        const plain = c.HUF_readStats(
            &expected_weights,
            hw_size,
            &expected_ranks,
            &expected_symbols,
            &expected_log,
            src.ptr,
            src.len,
        );
        try expectSameResult(plain, port);
        try testing.expectEqualSlices(u8, &expected_weights, &actual_weights);
    }
}

/// Writes `table`'s description on both sides into buffers of every size up
/// to the bound, and returns it.
fn expectSameWriteCTable(
    table: *const CTable,
    max_symbol_value: u32,
    huff_log: u32,
    ws: *Workspace,
    description: *[huf.ctable_bound + 8]u8,
) !usize {
    var expected: [huf.ctable_bound + 8]u8 = undefined;
    var size: usize = 0;
    var capacity: usize = 0;
    while (capacity <= huf.ctable_bound + 2) : (capacity += 1) {
        @memset(&expected, 0xEE);
        @memset(description, 0xEE);
        const workspace = ws.bytes(0)[0..huf.ctable_workspace_size];
        const original = c.HUF_writeCTable_wksp(
            &expected,
            capacity,
            table,
            max_symbol_value,
            huff_log,
            workspace.ptr,
            workspace.len,
        );
        const port = huf_compress.writeCTableWksp(
            description[0..capacity],
            table,
            max_symbol_value,
            huff_log,
            workspace,
        );
        try expectSameResult(original, port);
        try testing.expectEqualSlices(u8, &expected, description);
        if (c.ZSTD_isError(original) == 0) size = original;
    }
    return size;
}

fn expectSameUsingCTable(src: []const u8, table: *const CTable, four: bool) !void {
    const table_log = huf_compress.readCTableHeader(table).table_log;
    const tight = ((src.len * table_log) >> 3) + 8;
    const bound = @max(huf_compress.compressBound(src.len), tight + 8);
    const expected = try gpa.alloc(u8, bound);
    defer gpa.free(expected);
    const actual = try gpa.alloc(u8, bound);
    defer gpa.free(actual);
    const capacities = [_]usize{
        bound,
        tight + 7,
        tight + 6,
        tight,
        tight - 1,
        src.len / 2,
        17,
        16,
        9,
        8,
        7,
        0,
    };
    for (capacities) |capacity| {
        @memset(expected, 0xEE);
        @memset(actual, 0xEE);
        const original = if (four)
            c.HUF_compress4X_usingCTable(expected.ptr, capacity, src.ptr, src.len, table, 0)
        else
            c.HUF_compress1X_usingCTable(expected.ptr, capacity, src.ptr, src.len, table, 0);
        const port = if (four)
            huf_compress.compress4XUsingCTable(actual[0..capacity], src, table)
        else
            huf_compress.compress1XUsingCTable(actual[0..capacity], src, table);
        try testing.expectEqual(original, port);
        try testing.expectEqualSlices(u8, expected, actual);
    }
}

test "Huffman: tables, descriptions and streams of every input" {
    var inputs: Inputs = try .all();
    defer inputs.deinit();
    var ws: Workspace = .{};
    for (inputs.list.items, 0..) |src, index| {
        var count: [256]u32 = undefined;
        var max_symbol_value: u32 = 255;
        _ = hist.countSimple(&count, &max_symbol_value, src);
        const symbols = huf_compress.cardinality(&count, max_symbol_value);
        try testing.expectEqual(c.HUF_cardinality(&count, max_symbol_value), symbols);
        if (symbols < 2) continue;
        const min_log = huf_compress.minTableLog(symbols);
        try testing.expectEqual(c.HUF_minTableLog(symbols), min_log);

        var max_nb_bits: u32 = 0;
        while (max_nb_bits <= 14) : (max_nb_bits += 1) {
            if (max_nb_bits != 0 and max_nb_bits < min_log) continue;
            var table: CTable = undefined;
            const original = try expectSameHufCTable(
                &count,
                max_symbol_value,
                max_nb_bits,
                &ws,
                &table,
            );
            if (c.ZSTD_isError(original) != 0) continue;
            const huff_log: u32 = @intCast(original);

            for (0..256) |s| {
                const symbol: u32 = @intCast(s);
                try testing.expectEqual(
                    c.HUF_getNbBitsFromCTable(&table, symbol),
                    huf_compress.getNbBitsFromCTable(&table, symbol),
                );
            }
            try testing.expectEqual(
                c.HUF_estimateCompressedSize(&table, &count, max_symbol_value),
                huf_compress.estimateCompressedSize(&table, &count, max_symbol_value),
            );
            // The table against another input's counts.
            const other = inputs.list.items[(index * 7 + 3) % inputs.list.items.len];
            var other_count: [256]u32 = undefined;
            var other_max: u32 = 255;
            _ = hist.countSimple(&other_count, &other_max, other);
            for ([_]u32{ other_max, max_symbol_value }) |limit| {
                try testing.expectEqual(
                    c.HUF_validateCTable(&table, &other_count, limit) != 0,
                    huf_compress.validateCTable(&table, &other_count, limit),
                );
                try testing.expectEqual(
                    c.HUF_estimateCompressedSize(&table, &other_count, limit),
                    huf_compress.estimateCompressedSize(&table, &other_count, limit),
                );
            }

            var description: [huf.ctable_bound + 8]u8 = undefined;
            const size = try expectSameWriteCTable(
                &table,
                max_symbol_value,
                huff_log,
                &ws,
                &description,
            );
            if (size > 0) {
                for ([_]u32{ 255, max_symbol_value, max_symbol_value - 1 }) |limit| {
                    try expectSameReadCTable(description[0..size], limit);
                }
                for (0..size) |prefix| try expectSameReadCTable(description[0..prefix], 255);
                const ws_size = huf.read_stats_workspace_size;
                for ([_]usize{ 256, max_symbol_value + 1, 5, 1 }) |hw_size| {
                    try expectSameReadStats(description[0..size], hw_size, ws_size);
                }
            }

            if (max_nb_bits == 0 or max_nb_bits % 2 == 1 or max_nb_bits == 12) {
                try expectSameUsingCTable(src, &table, false);
                try expectSameUsingCTable(src, &table, true);
            }
        }
    }
}

test "Huffman: optimal table logs" {
    var inputs: Inputs = try .all();
    defer inputs.deinit();
    var ws: Workspace = .{};
    for (inputs.list.items) |src| {
        if (src.len < 2) continue;
        var count: [256]u32 = undefined;
        var max_symbol_value: u32 = 255;
        _ = hist.countSimple(&count, &max_symbol_value, src);
        if (huf_compress.cardinality(&count, max_symbol_value) < 2) continue;
        for ([_]u32{ 0, 5, 6, 8, 11, 12 }) |max_table_log| {
            for ([_]huf.Flags{ .{}, .{ .optimal_depth = true } }) |flags| {
                var expected: CTable = @splat(fill_celt);
                var actual: CTable = @splat(fill_celt);
                const workspace = ws.bytes(0);
                const original = c.HUF_optimalTableLog(
                    max_table_log,
                    src.len,
                    max_symbol_value,
                    workspace.ptr,
                    workspace.len,
                    &expected,
                    &count,
                    @bitCast(flags),
                );
                const port = huf_compress.optimalTableLog(
                    max_table_log,
                    src.len,
                    max_symbol_value,
                    workspace,
                    &actual,
                    &count,
                    flags,
                );
                try testing.expectEqual(original, port);
                try testing.expectEqualSlices(usize, &expected, &actual);
            }
        }
    }
    for (0..300) |n| {
        try testing.expectEqual(c.HUF_compressBound(n * 977), huf_compress.compressBound(n * 977));
    }
}

/// One side's state across blocks: the previous table and its repeat mode.
const RepeatState = struct {
    table: CTable,
    repeat: huf.Repeat,
};

const RepeatParams = struct {
    four: bool,
    max_symbol_value: u32,
    huff_log: u32,
    flags: huf.Flags,
    /// Whether to pass a table and a repeat mode at all.
    with_table: bool,
    first_repeat: huf.Repeat,
    capacity_divisor: usize,
    block_size: usize,
    ws_offset: usize,
};

/// A table with a code for every symbol, valid for any input.
fn fullTable() !CTable {
    var count: [256]u32 = undefined;
    for (&count, 0..) |*c_, s| c_.* = @intCast(1 + s % 17);
    var table: CTable = @splat(0);
    var ws: Workspace = .{};
    _ = try huf_compress.buildCTableWksp(&table, &count, 255, 11, ws.bytes(0));
    return table;
}

/// Compresses `src` block by block on both sides, keeping each side's
/// table and repeat mode across blocks as the literals compressor does.
fn expectSameRepeat(src: []const u8, params: RepeatParams) !void {
    var p = params;
    // The depth search never goes below the given log, which must leave
    // room for 256 symbols, as the original's callers do.
    if (p.flags.optimal_depth and p.huff_log != 0 and p.huff_log < 9) p.huff_log = 9;
    const full = try fullTable();
    var expected_state: RepeatState = .{ .table = full, .repeat = p.first_repeat };
    var actual_state: RepeatState = expected_state;
    if (p.first_repeat == .check) {
        // A previous block's table, which may miss symbols.
        var count: [256]u32 = @splat(0);
        for (src[0..@min(src.len, 300)]) |byte| count[byte] += 1;
        count[0] += 1;
        count[1] += 1;
        var ws: Workspace = .{};
        expected_state.table = @splat(0);
        _ = try huf_compress.buildCTableWksp(&expected_state.table, &count, 255, 11, ws.bytes(0));
        actual_state = expected_state;
    }
    var expected_ws: Workspace = .{};
    var actual_ws: Workspace = .{};
    const bound = huf_compress.compressBound(p.block_size);
    const expected = try gpa.alloc(u8, bound);
    defer gpa.free(expected);
    const actual = try gpa.alloc(u8, bound);
    defer gpa.free(actual);

    var start: usize = 0;
    while (true) {
        const block = src[start..@min(src.len, start + p.block_size)];
        const capacity = if (p.capacity_divisor == 0) 0 else bound / p.capacity_divisor;
        @memset(expected, 0xEE);
        @memset(actual, 0xEE);
        var expected_repeat: c_uint = @backingInt(expected_state.repeat);
        const ews = expected_ws.bytes(p.ws_offset);
        const original = (if (p.four) &c.HUF_compress4X_repeat else &c.HUF_compress1X_repeat)(
            expected.ptr,
            capacity,
            block.ptr,
            block.len,
            p.max_symbol_value,
            p.huff_log,
            ews.ptr,
            ews.len,
            if (p.with_table) &expected_state.table else null,
            if (p.with_table) &expected_repeat else null,
            @bitCast(p.flags),
        );
        const compress = if (p.four)
            &huf_compress.compress4XRepeat
        else
            &huf_compress.compress1XRepeat;
        const port = compress(
            actual[0..capacity],
            block,
            p.max_symbol_value,
            p.huff_log,
            actual_ws.bytes(p.ws_offset),
            if (p.with_table) &actual_state.table else null,
            if (p.with_table) &actual_state.repeat else null,
            p.flags,
        );
        try expectSameResult(original, port);
        try testing.expectEqualSlices(u8, expected, actual);
        expected_state.repeat = @fromBackingInt(expected_repeat);
        try testing.expectEqual(expected_state.repeat, actual_state.repeat);
        try testing.expectEqualSlices(usize, &expected_state.table, &actual_state.table);

        // A new table is checked before the next block reuses it.
        if (expected_state.repeat == .none) {
            expected_state.repeat = .check;
            actual_state.repeat = .check;
        }
        start += block.len;
        if (start >= src.len) break;
    }
}

const repeat_modes = [_]huf.Repeat{ .none, .check, .valid };

fn flagsOf(bits: u32) huf.Flags {
    return .{
        .optimal_depth = bits & 1 != 0,
        .prefer_repeat = bits & 2 != 0,
        .suspect_uncompressible = bits & 4 != 0,
    };
}

test "Huffman: compressing with repeat modes and flags" {
    var inputs: Inputs = try .all();
    defer inputs.deinit();
    const huff_logs = [_]u32{ 0, 6, 8, 11, 12, 13 };
    const block_sizes = [_]usize{ 1 << 17, 1000, 4096, 50_000, 300 };
    const divisors = [_]usize{ 1, 2, 1, 5, 1, 0, 1, 3 };
    for (inputs.list.items, 0..) |src, index| {
        const largest = largestByte(src);
        for (0..8) |flag_bits| {
            for (0..4) |mode| {
                const variant = index + flag_bits * 5 + mode * 3;
                const flags = flagsOf(@intCast(flag_bits));
                // Sampling for incompressible input trusts the limit.
                const below = if (flags.suspect_uncompressible) 0 else largest -| 1;
                const limits = [_]u32{ 0, 255, below };
                try expectSameRepeat(src, .{
                    .four = variant % 2 == 0,
                    .max_symbol_value = limits[variant % 3],
                    .huff_log = huff_logs[variant % huff_logs.len],
                    .flags = flags,
                    .with_table = mode < 3,
                    .first_repeat = if (mode < 3) repeat_modes[mode] else .none,
                    .capacity_divisor = divisors[variant % divisors.len],
                    .block_size = block_sizes[variant % block_sizes.len],
                    .ws_offset = if (variant % 7 == 0) 4 else 0,
                });
            }
        }
    }
}

test "Huffman: seeded fuzz of compression" {
    const seed = common.fuzzSeed(0x40FF);
    var prng: Random.DefaultPrng = .init(seed);
    const random = prng.random();
    const buffer = try gpa.alloc(u8, 70_000);
    defer gpa.free(buffer);
    for (0..common.fuzz_cases) |case| {
        errdefer std.debug.print("Huffman compression: seed {d} case {d}\n", .{ seed, case });
        const size = if (random.uintLessThan(u32, 10) == 0)
            random.uintAtMost(usize, buffer.len)
        else
            random.uintAtMost(usize, 3000);
        const src = buffer[0..size];
        switch (random.uintLessThan(u32, 3)) {
            0 => c.reference_genBuffer(
                src.ptr,
                size,
                random.float(f64),
                random.float(f64),
                random.int(u32),
            ),
            1 => {
                const alphabet = random.intRangeAtMost(u32, 1, 256);
                for (src) |*byte| byte.* = @intCast(random.uintLessThan(u32, alphabet));
            },
            else => for (src) |*byte| {
                byte.* = @min(@ctz(random.int(u64) | (1 << 50)), random.intRangeAtMost(u8, 1, 50));
            },
        }
        const flags = flagsOf(random.uintLessThan(u32, 8));
        const mode = random.uintLessThan(usize, 4);
        const limit = if (flags.suspect_uncompressible or random.boolean())
            255
        else
            random.uintAtMost(u32, 255);
        try expectSameRepeat(src, .{
            .four = random.boolean(),
            .max_symbol_value = limit,
            .huff_log = random.uintAtMost(u32, 13),
            .flags = flags,
            .with_table = mode < 3,
            .first_repeat = if (mode < 3) repeat_modes[mode] else .none,
            .capacity_divisor = random.uintAtMost(usize, 4),
            .block_size = random.intRangeAtMost(usize, 1, 1 << 17),
            .ws_offset = if (random.boolean()) 4 else 0,
        });
    }
}

test "Huffman: seeded fuzz of untrusted table descriptions" {
    const seed = common.fuzzSeed(0x57A7);
    var prng: Random.DefaultPrng = .init(seed);
    const random = prng.random();
    var ws: Workspace = .{};
    var bytes: [160]u8 = undefined;
    for (0..common.fuzz_cases) |case| {
        errdefer std.debug.print("Huffman descriptions: seed {d} case {d}\n", .{ seed, case });
        var size = random.uintAtMost(usize, bytes.len);
        switch (random.uintLessThan(u32, 3)) {
            0 => random.bytes(bytes[0..size]),
            1 => {
                // Raw weights or an FSE header, of random content.
                random.bytes(bytes[0..size]);
                if (size > 0) {
                    bytes[0] = if (random.boolean())
                        random.intRangeAtMost(u8, 128, 255)
                    else
                        random.uintLessThan(u8, @intCast(@min(size, 128)));
                }
            },
            else => {
                // A valid description, then corrupted.
                var count: [256]u32 = @splat(0);
                const counts = randomCounts(random, &count);
                var table: CTable = undefined;
                const huff_log = huf_compress.buildCTableWksp(
                    &table,
                    &count,
                    counts.max,
                    random.intRangeAtMost(u32, 9, 12),
                    ws.bytes(0),
                ) catch continue;
                const written = huf_compress.writeCTableWksp(
                    &bytes,
                    &table,
                    counts.max,
                    huff_log,
                    ws.bytes(0),
                ) catch continue;
                size = if (random.boolean()) written else @min(size, written);
                for (0..random.uintAtMost(u32, 3)) |_| {
                    if (size == 0) break;
                    const bit = random.uintLessThan(usize, size * 8);
                    bytes[bit / 8] ^= @as(u8, 1) << @intCast(bit % 8);
                }
            },
        }
        const src = bytes[0..size];
        const limit = if (random.boolean()) 255 else random.uintAtMost(u32, 255);
        try expectSameReadCTable(src, limit);
        const hw_size = if (random.boolean()) 256 else random.intRangeAtMost(usize, 1, 256);
        const ws_sizes = [_]usize{ huf.read_stats_workspace_size, 600, 511, 512 + 8 };
        try expectSameReadStats(src, hw_size, ws_sizes[random.uintLessThan(usize, ws_sizes.len)]);
    }
}

test "Huffman: workspaces too small" {
    var inputs: Inputs = try .all();
    defer inputs.deinit();
    var ws: Workspace = .{};
    const src = inputs.list.items[inputs.list.items.len - 3];
    var count: [256]u32 = undefined;
    var max_symbol_value: u32 = 255;
    _ = hist.countSimple(&count, &max_symbol_value, src);
    const workspace = ws.bytes(0);
    var expected: CTable = @splat(fill_celt);
    var actual: CTable = @splat(fill_celt);
    var dst: [huf.ctable_bound]u8 = undefined;

    for ([_]usize{ 0, 100, huf.ctable_workspace_size - 1 }) |size| {
        const original = c.HUF_buildCTable_wksp(&expected, &count, 255, 11, workspace.ptr, size);
        const port = huf_compress.buildCTableWksp(&actual, &count, 255, 11, workspace[0..size]);
        try expectSameResult(original, if (port) |bits| bits else |err| err);
    }
    const huff_log = try huf_compress.buildCTableWksp(&actual, &count, 255, 11, workspace);
    for ([_]usize{ 0, 400, 747 }) |size| {
        const ws_ptr = workspace.ptr;
        const original =
            c.HUF_writeCTable_wksp(&dst, dst.len, &actual, 255, huff_log, ws_ptr, size);
        const port = huf_compress.writeCTableWksp(&dst, &actual, 255, huff_log, workspace[0..size]);
        try expectSameResult(original, port);
    }
    var big: [huf.block_size_max + 1]u8 = @splat(1);
    big[0] = 2;
    // The original's tables take 7944 bytes of the workspace.
    for ([_]usize{ 0, 7000, 7943, 7944 }) |size| {
        const original = c.HUF_compress4X_repeat(
            &dst,
            dst.len,
            src.ptr,
            src.len,
            255,
            11,
            workspace.ptr,
            size,
            null,
            null,
            0,
        );
        const ws_used = workspace[0..size];
        const port = huf_compress.compress4XRepeat(&dst, src, 255, 11, ws_used, null, null, .{});
        try expectSameResult(original, port);
    }
    // A block larger than Huffman takes.
    const original = c.HUF_compress1X_repeat(
        &dst,
        dst.len,
        &big,
        big.len,
        255,
        11,
        workspace.ptr,
        workspace.len,
        null,
        null,
        0,
    );
    const port = huf_compress.compress1XRepeat(&dst, &big, 255, 11, workspace, null, null, .{});
    try expectSameResult(original, port);
}
