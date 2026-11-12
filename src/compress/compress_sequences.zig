//! The sequences section of a compressed block, from the original's
//! zstd_compress_sequences.c: choosing each code table's encoding type,
//! building the tables, and writing the interleaved FSE bit stream.

const std = @import("std");
const assert = std.debug.assert;

const params = @import("../params.zig");
const Error = @import("../error.zig").Error;
const zstd_internal = @import("../common/zstd_internal.zig");
const fse = @import("../common/fse.zig");
const bitstream = @import("../common/bitstream.zig");
const fse_compress = @import("fse_compress.zig");
const compress_internal = @import("compress_internal.zig");

const SymbolEncodingType = zstd_internal.SymbolEncodingType;
const SeqDef = compress_internal.SeqDef;
const max_seq = zstd_internal.max_seq;
const max_fse_log = zstd_internal.max_fse_log;
const is_32bit = @sizeOf(usize) == 4;

/// The original's `ZSTD_DefaultPolicy_e`: whether a table may use the
/// format's default distribution.
pub const DefaultPolicy = enum(u1) { disallowed = 0, allowed = 1 };

/// A cost that cannot be paid; the original uses its error code, the
/// largest size, the same way.
const cost_impossible = std.math.maxInt(usize);

/// -log2(x / 256) in fixed point with 8 fractional bits, rounded down, for
/// x in [0, 256); 0 for x = 0.
const inverse_probability_log256 = [256]u32{
    0,    2048, 1792, 1642, 1536, 1453, 1386, 1329, 1280, 1236, 1197, 1162,
    1130, 1100, 1073, 1047, 1024, 1001, 980,  960,  941,  923,  906,  889,
    874,  859,  844,  830,  817,  804,  791,  779,  768,  756,  745,  734,
    724,  714,  704,  694,  685,  676,  667,  658,  650,  642,  633,  626,
    618,  610,  603,  595,  588,  581,  574,  567,  561,  554,  548,  542,
    535,  529,  523,  517,  512,  506,  500,  495,  489,  484,  478,  473,
    468,  463,  458,  453,  448,  443,  438,  434,  429,  424,  420,  415,
    411,  407,  402,  398,  394,  390,  386,  382,  377,  373,  370,  366,
    362,  358,  354,  350,  347,  343,  339,  336,  332,  329,  325,  322,
    318,  315,  311,  308,  305,  302,  298,  295,  292,  289,  286,  282,
    279,  276,  273,  270,  267,  264,  261,  258,  256,  253,  250,  247,
    244,  241,  239,  236,  233,  230,  228,  225,  222,  220,  217,  215,
    212,  209,  207,  204,  202,  199,  197,  194,  192,  190,  187,  185,
    182,  180,  178,  175,  173,  171,  168,  166,  164,  162,  159,  157,
    155,  153,  151,  149,  146,  144,  142,  140,  138,  136,  134,  132,
    130,  128,  126,  123,  121,  119,  117,  115,  114,  112,  110,  108,
    106,  104,  102,  100,  98,   96,   94,   93,   91,   89,   87,   85,
    83,   82,   80,   78,   76,   74,   73,   71,   69,   67,   66,   64,
    62,   61,   59,   57,   55,   54,   52,   50,   49,   47,   46,   44,
    42,   41,   39,   37,   36,   34,   33,   31,   30,   28,   26,   25,
    23,   22,   20,   19,   17,   16,   14,   13,   11,   10,   8,    7,
    5,    4,    2,    1,
};

/// `ZSTD_getFSEMaxSymbolValue`: the largest symbol `ctable` was built for.
fn fseMaxSymbolValue(ctable: []const u32) u32 {
    return @as([*]const u16, @ptrCast(ctable.ptr))[1];
}

/// `ZSTD_useLowProbCount`: whether rare symbols get -1 rather than 1 in the
/// normalized count. Covers most blocks up to 16 KiB and fades out after.
fn useLowProbCount(nb_seq: usize) bool {
    return nb_seq >= 2048;
}

/// `ZSTD_NCountCost`: the size in bytes of the normalized count header.
fn ncountCost(count: []const u32, max: u32, nb_seq: usize, fse_log: u32) Error!usize {
    var wksp: [fse.ncount_bound]u8 = undefined;
    var norm: [max_seq + 1]i16 = undefined;
    const table_log = fse_compress.optimalTableLog(fse_log, nb_seq, max);
    _ = try fse_compress.normalizeCount(&norm, table_log, count, nb_seq, max, useLowProbCount(nb_seq));
    return fse_compress.writeNCount(&wksp, &norm, max, table_log);
}

/// `ZSTD_entropyCost`: the cost in bits of `count` at the entropy bound.
fn entropyCost(count: []const u32, max: u32, total: usize) usize {
    assert(total > 0);
    var cost: u32 = 0;
    for (count[0 .. max + 1]) |c| {
        var norm: u32 = @intCast((256 * @as(usize, c)) / total);
        if (c != 0 and norm == 0) norm = 1;
        assert(c < total);
        cost += c * inverse_probability_log256[norm];
    }
    return cost >> 8;
}

/// `ZSTD_fseBitCost`: the cost in bits of `count` coded with `ctable`, or
/// an error if `ctable` cannot code one of its symbols.
pub fn fseBitCost(ctable: []const u32, count: []const u32, max: u32) Error!usize {
    const accuracy_log = 8;
    var cost: usize = 0;
    const cstate: fse_compress.CState = .init(ctable);
    if (fseMaxSymbolValue(ctable) < max) return error.Generic;
    for (count[0 .. max + 1], 0..) |c, s| {
        const table_log = cstate.state_log;
        const bad_cost = (table_log + 1) << accuracy_log;
        const bit_cost = fse_compress.bitCost(cstate.symbol_tt, table_log, @intCast(s), accuracy_log);
        if (c == 0) continue;
        if (bit_cost >= bad_cost) return error.Generic;
        cost += @as(usize, c) * bit_cost;
    }
    return cost >> accuracy_log;
}

/// `ZSTD_crossEntropyCost`: the cost in bits of `count` coded with the
/// table `norm` describes. `norm` covers every symbol up to `max` that
/// `count` holds.
pub fn crossEntropyCost(norm: []const i16, accuracy_log: u32, count: []const u32, max: u32) usize {
    assert(accuracy_log <= 8);
    const shift: u5 = @intCast(8 - accuracy_log);
    var cost: usize = 0;
    for (count[0 .. max + 1], norm[0 .. max + 1]) |c, n| {
        const norm_acc: u32 = if (n != -1) @intCast(n) else 1;
        const norm256 = norm_acc << shift;
        assert(norm256 > 0);
        assert(norm256 < 256);
        cost += c * inverse_probability_log256[norm256];
    }
    return cost >> 8;
}

/// `ZSTD_selectEncodingType`: how to code one of the three code tables,
/// and the repeat mode the next block starts from.
pub fn selectEncodingType(
    repeat_mode: *fse.Repeat,
    count: []const u32,
    max: u32,
    most_frequent: usize,
    nb_seq: usize,
    fse_log: u32,
    prev_ctable: []const u32,
    default_norm: []const i16,
    default_norm_log: u32,
    is_default_allowed: DefaultPolicy,
    strategy: params.Strategy,
) SymbolEncodingType {
    const default_allowed = is_default_allowed == .allowed;
    if (most_frequent == nb_seq) {
        repeat_mode.* = .none;
        // With 2 symbols or fewer, the default table is cheaper than RLE's
        // byte, at 5 or 6 bits a symbol; RLE when the default is not allowed.
        if (default_allowed and nb_seq <= 2) return .basic;
        return .rle;
    }
    const strat: u32 = @backingInt(strategy);
    if (strat < @backingInt(params.Strategy.lazy)) {
        if (default_allowed) {
            const static_fse_nb_seq_max = 1000;
            const mult: usize = 10 - strat;
            const base_log = 3;
            // 28-36 for offsets, 56-72 for lengths.
            const dynamic_fse_nb_seq_min = ((@as(usize, 1) << @intCast(default_norm_log)) * mult) >>
                base_log;
            assert(default_norm_log >= 5 and default_norm_log <= 6);
            assert(mult <= 9 and mult >= 7);
            if (repeat_mode.* == .valid and nb_seq < static_fse_nb_seq_max) return .repeat;
            if (nb_seq < dynamic_fse_nb_seq_min or
                most_frequent < (nb_seq >> @intCast(default_norm_log - 1)))
            {
                // Default tables could be repeated, but with these simple
                // heuristics that would be confused with dictionary tables,
                // and careful analysis never checks both.
                repeat_mode.* = .none;
                return .basic;
            }
        }
    } else {
        const basic_cost = if (default_allowed)
            crossEntropyCost(default_norm, default_norm_log, count, max)
        else
            cost_impossible;
        const repeat_cost = if (repeat_mode.* != .none)
            fseBitCost(prev_ctable, count, max) catch cost_impossible
        else
            cost_impossible;
        // The counts come from this block's codes, so the header fits.
        const ncount_cost = ncountCost(count, max, nb_seq, fse_log) catch unreachable;
        const compressed_cost = (ncount_cost << 3) + entropyCost(count, max, nb_seq);

        if (default_allowed) {
            assert(basic_cost != cost_impossible);
            assert(!(repeat_mode.* == .valid and repeat_cost == cost_impossible));
        }
        if (basic_cost <= repeat_cost and basic_cost <= compressed_cost) {
            assert(default_allowed);
            repeat_mode.* = .none;
            return .basic;
        }
        if (repeat_cost <= compressed_cost) {
            assert(repeat_cost != cost_impossible);
            return .repeat;
        }
        assert(compressed_cost < basic_cost and compressed_cost < repeat_cost);
    }
    repeat_mode.* = .check;
    return .compressed;
}

/// `ZSTD_BuildCTableWksp`: the workspace `buildCTable` lays over the entropy
/// workspace.
const BuildCTableWksp = extern struct {
    norm: [max_seq + 1]i16,
    wksp: [fse.buildCTableWorkspaceSizeU32(max_seq, max_fse_log)]u32,
};

/// `ZSTD_buildCTable`: builds `next_ctable` for `h_type`, and writes its
/// description into `dst`: the symbol for RLE, the normalized count for a
/// new table, nothing otherwise. Returns the size written. `count` holds
/// the codes' histogram, which a new table adjusts. `entropy_workspace` is
/// aligned on 4 and holds at least `@sizeOf(BuildCTableWksp)` bytes.
pub fn buildCTable(
    dst: []u8,
    next_ctable: []u32,
    fse_log: u32,
    h_type: SymbolEncodingType,
    count: []u32,
    max: u32,
    code_table: []const u8,
    default_norm: []const i16,
    default_norm_log: u32,
    default_max: u32,
    prev_ctable: []const u32,
    entropy_workspace: []u8,
) Error!usize {
    const nb_seq = code_table.len;
    switch (h_type) {
        .rle => {
            fse_compress.buildCTableRle(next_ctable, @intCast(max));
            if (dst.len == 0) return error.DstSizeTooSmall;
            dst[0] = code_table[0];
            return 1;
        },
        .repeat => {
            @memcpy(next_ctable[0..prev_ctable.len], prev_ctable);
            return 0;
        },
        .basic => {
            try fse_compress.buildCTableWksp(
                next_ctable,
                default_norm,
                default_max,
                default_norm_log,
                entropy_workspace,
            );
            return 0;
        },
        .compressed => {
            assert(entropy_workspace.len >= @sizeOf(BuildCTableWksp));
            const wksp: *BuildCTableWksp = @ptrCast(@alignCast(entropy_workspace.ptr));
            var nb_seq_1 = nb_seq;
            const table_log = fse_compress.optimalTableLog(fse_log, nb_seq, max);
            if (count[code_table[nb_seq - 1]] > 1) {
                count[code_table[nb_seq - 1]] -= 1;
                nb_seq_1 -= 1;
            }
            assert(nb_seq_1 > 1);
            _ = try fse_compress.normalizeCount(
                &wksp.norm,
                table_log,
                count,
                nb_seq_1,
                max,
                useLowProbCount(nb_seq_1),
            );
            const ncount_size = try fse_compress.writeNCount(dst, &wksp.norm, max, table_log);
            try fse_compress.buildCTableWksp(
                next_ctable,
                &wksp.norm,
                max,
                table_log,
                std.mem.sliceAsBytes(&wksp.wksp),
            );
            return ncount_size;
        },
    }
}

/// `ZSTD_encodeSequences`: writes the sequences' bit stream, read backward
/// by the decoder, so the last sequence is written first. Each code table
/// holds one code per sequence. `long_offsets` splits offsets too wide for
/// one flush of the bit register.
pub fn encodeSequences(
    dst: []u8,
    ctable_match_length: []const u32,
    ml_code_table: []const u8,
    ctable_offset_bits: []const u32,
    of_code_table: []const u8,
    ctable_lit_length: []const u32,
    ll_code_table: []const u8,
    sequences: []const SeqDef,
    long_offsets: bool,
    bmi2: bool,
) Error!usize {
    _ = bmi2;
    const nb_seq = sequences.len;
    assert(ml_code_table.len >= nb_seq and of_code_table.len >= nb_seq);
    assert(ll_code_table.len >= nb_seq);
    const ll_bits = zstd_internal.ll_bits;
    const ml_bits = zstd_internal.ml_bits;
    const acc_min = bitstream.accumulator_min;

    var block_stream = try bitstream.CStream.init(dst);

    // The first symbols.
    const last = nb_seq - 1;
    var state_match_length: fse_compress.CState = .initWithSymbol(ctable_match_length, ml_code_table[last]);
    var state_offset_bits: fse_compress.CState = .initWithSymbol(ctable_offset_bits, of_code_table[last]);
    var state_lit_length: fse_compress.CState = .initWithSymbol(ctable_lit_length, ll_code_table[last]);
    block_stream.addBits(sequences[last].lit_length, ll_bits[ll_code_table[last]]);
    if (is_32bit) block_stream.flushBits();
    block_stream.addBits(sequences[last].ml_base, ml_bits[ml_code_table[last]]);
    if (is_32bit) block_stream.flushBits();
    if (long_offsets) {
        const of_bits: u32 = of_code_table[last];
        const extra_bits = of_bits - @min(of_bits, acc_min - 1);
        if (extra_bits != 0) {
            block_stream.addBits(sequences[last].off_base, extra_bits);
            block_stream.flushBits();
        }
        block_stream.addBits(sequences[last].off_base >> @intCast(extra_bits), of_bits - extra_bits);
    } else {
        block_stream.addBits(sequences[last].off_base, of_code_table[last]);
    }
    block_stream.flushBits();

    var n = last;
    while (n > 0) {
        n -= 1;
        const ll_code = ll_code_table[n];
        const of_code = of_code_table[n];
        const ml_code = ml_code_table[n];
        const llb: u32 = ll_bits[ll_code];
        const ofb: u32 = of_code;
        const mlb: u32 = ml_bits[ml_code];
        // Bits in the register after each step, on 32 and 64 bits:
        // 15, 15.
        fse_compress.encodeSymbol(&block_stream, &state_offset_bits, of_code);
        // 24, 24.
        fse_compress.encodeSymbol(&block_stream, &state_match_length, ml_code);
        // 7 after a flush.
        if (is_32bit) block_stream.flushBits();
        // 16, 33.
        fse_compress.encodeSymbol(&block_stream, &state_lit_length, ll_code);
        const fse_logs = zstd_internal.ll_fse_log + zstd_internal.ml_fse_log +
            zstd_internal.off_fse_log;
        if (is_32bit or ofb + mlb + llb >= 64 - 7 - fse_logs) block_stream.flushBits();
        block_stream.addBits(sequences[n].lit_length, llb);
        if (is_32bit and llb + mlb > 24) block_stream.flushBits();
        block_stream.addBits(sequences[n].ml_base, mlb);
        if (is_32bit or ofb + mlb + llb > 56) block_stream.flushBits();
        if (long_offsets) {
            const extra_bits = ofb - @min(ofb, acc_min - 1);
            if (extra_bits != 0) {
                block_stream.addBits(sequences[n].off_base, extra_bits);
                block_stream.flushBits();
            }
            // 31.
            block_stream.addBits(sequences[n].off_base >> @intCast(extra_bits), ofb - extra_bits);
        } else {
            // 31.
            block_stream.addBits(sequences[n].off_base, ofb);
        }
        block_stream.flushBits();
    }

    fse_compress.flushCState(&block_stream, &state_match_length);
    fse_compress.flushCState(&block_stream, &state_offset_bits);
    fse_compress.flushCState(&block_stream, &state_lit_length);

    const stream_size = block_stream.close();
    if (stream_size == 0) return error.DstSizeTooSmall;
    return stream_size;
}
