//! Super-blocks, from the original's zstd_compress_superblock.c: a block's
//! sequences written as several smaller blocks of about the target
//! compressed size, the first with the entropy tables and the others
//! repeating them, so that a decoder can start on each sooner.

const std = @import("std");

const params = @import("../params.zig");
const Error = @import("../error.zig").Error;
const zstd_internal = @import("../common/zstd_internal.zig");
const bitstream = @import("../common/bitstream.zig");
const huf = @import("../common/huf.zig");
const ci = @import("compress_internal.zig");
const hist = @import("hist.zig");
const huf_compress = @import("huf_compress.zig");
const compress_literals = @import("compress_literals.zig");
const compress_sequences = @import("compress_sequences.zig");
const compress = @import("compress.zig");

const assert = std.debug.assert;
const SeqStore = ci.SeqStore;
const SeqDef = ci.SeqDef;
const SymbolEncodingType = zstd_internal.SymbolEncodingType;
const block_header_size = zstd_internal.block_header_size;
const kib = 1 << 10;

fn writeLe24(dst: []u8, value: u32) void {
    std.mem.writeInt(u16, dst[0..2], @truncate(value), .little);
    dst[2] = @truncate(value >> 16);
}

/// `ZSTD_compressSubBlock_literal`: writes the literals section of a
/// sub-block. With `write_entropy`, the section carries the Huffman
/// description, and `entropy_written` says whether it went out; otherwise
/// it repeats the table. The header size is chosen before the size is
/// known, from a bound on the description; a wrong guess falls back to raw
/// literals. Returns the size written, 0 when the sub-block should not be
/// compressed.
fn compressSubBlockLiteral(
    huf_table: []const huf.CElt,
    huf_metadata: *const ci.HufCTablesMetadata,
    literals: []const u8,
    dst: []u8,
    bmi2: bool,
    write_entropy: bool,
    entropy_written: *bool,
) Error!usize {
    _ = bmi2;
    const header: usize = if (write_entropy) 200 else 0;
    const lit_size = literals.len;
    const lh_size: usize = 3 + @as(usize, @intFromBool(lit_size >= 1 * kib - header)) +
        @intFromBool(lit_size >= 16 * kib - header);
    var op: usize = lh_size;
    const single_stream = lh_size == 3;
    const h_type: SymbolEncodingType = if (write_entropy) huf_metadata.h_type else .repeat;
    var c_lit_size: usize = 0;

    entropy_written.* = false;
    if (lit_size == 0 or huf_metadata.h_type == .basic) {
        return compress_literals.noCompressLiterals(dst, literals);
    } else if (huf_metadata.h_type == .rle) {
        return compress_literals.compressRleLiteralsBlock(dst, literals);
    }

    assert(huf_metadata.h_type == .compressed or huf_metadata.h_type == .repeat);

    if (write_entropy and huf_metadata.h_type == .compressed) {
        @memcpy(
            dst[op..][0..huf_metadata.huf_des_size],
            huf_metadata.huf_des_buffer[0..huf_metadata.huf_des_size],
        );
        op += huf_metadata.huf_des_size;
        c_lit_size += huf_metadata.huf_des_size;
    }

    {
        const c_size = if (single_stream)
            huf_compress.compress1XUsingCTable(dst[op..], literals, huf_table)
        else
            huf_compress.compress4XUsingCTable(dst[op..], literals, huf_table);
        op += c_size;
        c_lit_size += c_size;
        if (c_size == 0) return 0;
        // Raw when the literals grow and no description is written.
        if (!write_entropy and c_lit_size >= lit_size) {
            return compress_literals.noCompressLiterals(dst, literals);
        }
        // With the description, growth is allowed while the header size
        // holds.
        if (lh_size < 3 + @as(usize, @intFromBool(c_lit_size >= 1 * kib)) +
            @intFromBool(c_lit_size >= 16 * kib))
        {
            assert(c_lit_size > lit_size);
            return compress_literals.noCompressLiterals(dst, literals);
        }
    }

    // The header.
    const h: u32 = @backingInt(h_type);
    switch (lh_size) {
        // 2 - 2 - 10 - 10
        3 => {
            const lhc = h + (@as(u32, @intFromBool(!single_stream)) << 2) +
                (@as(u32, @intCast(lit_size)) << 4) + (@as(u32, @intCast(c_lit_size)) << 14);
            writeLe24(dst, lhc);
        },
        // 2 - 2 - 14 - 14
        4 => {
            const lhc = h + (2 << 2) + (@as(u32, @intCast(lit_size)) << 4) +
                (@as(u32, @intCast(c_lit_size)) << 18);
            std.mem.writeInt(u32, dst[0..4], lhc, .little);
        },
        // 2 - 2 - 18 - 18
        5 => {
            const lhc = h + (3 << 2) + (@as(u32, @intCast(lit_size)) << 4) +
                @as(u32, @truncate(c_lit_size << 22));
            std.mem.writeInt(u32, dst[0..4], lhc, .little);
            dst[4] = @truncate(c_lit_size >> 10);
        },
        else => unreachable,
    }
    entropy_written.* = true;
    return op;
}

/// `ZSTD_seqDecompressedSize`: the bytes the sequences and `lit_size`
/// literals decode to.
fn seqDecompressedSize(
    seq_store: *const SeqStore,
    sequences: []const SeqDef,
    lit_size: usize,
    last_sub_block: bool,
) usize {
    var match_length_sum: usize = 0;
    var lit_length_sum: usize = 0;
    for (sequences) |*seq| {
        const seq_len = ci.getSequenceLength(seq_store, seq);
        lit_length_sum += seq_len.lit_length;
        match_length_sum += seq_len.match_length;
    }
    if (!last_sub_block) {
        assert(lit_length_sum == lit_size);
    } else {
        assert(lit_length_sum <= lit_size);
    }
    return match_length_sum + lit_size;
}

/// `ZSTD_compressSubBlock_sequences`: writes the sequences section of a
/// sub-block, with the super-block's table descriptions when
/// `write_entropy`, repeating them otherwise; `entropy_written` says
/// whether it succeeded. Returns the size written, or 0 when the
/// sub-block should not be compressed.
fn compressSubBlockSequences(
    fse_tables: *const ci.FseCTables,
    fse_metadata: *const ci.FseCTablesMetadata,
    sequences: []const SeqDef,
    ll_code: []const u8,
    ml_code: []const u8,
    of_code: []const u8,
    cctx_params: *const ci.CCtxParams,
    dst: []u8,
    bmi2: bool,
    write_entropy: bool,
    entropy_written: *bool,
) Error!usize {
    const long_offsets = cctx_params.cparams.window_log > bitstream.accumulator_min;
    const nb_seq = sequences.len;
    var op: usize = 0;

    entropy_written.* = false;
    // The header: up to 3 bytes of count, 1 of encoding types.
    if (dst.len < 3 + 1) return error.DstSizeTooSmall;
    if (nb_seq < 128) {
        dst[op] = @intCast(nb_seq);
        op += 1;
    } else if (nb_seq < zstd_internal.long_nb_seq) {
        dst[op] = @intCast((nb_seq >> 8) + 0x80);
        dst[op + 1] = @truncate(nb_seq);
        op += 2;
    } else {
        dst[op] = 0xFF;
        std.mem.writeInt(
            u16,
            dst[op + 1 ..][0..2],
            @intCast(nb_seq - zstd_internal.long_nb_seq),
            .little,
        );
        op += 3;
    }
    if (nb_seq == 0) return op;

    // The encoding types.
    const seq_head = op;
    op += 1;
    if (write_entropy) {
        dst[seq_head] = (@as(u8, @backingInt(fse_metadata.ll_type)) << 6) +
            (@as(u8, @backingInt(fse_metadata.of_type)) << 4) +
            (@as(u8, @backingInt(fse_metadata.ml_type)) << 2);
        @memcpy(
            dst[op..][0..fse_metadata.fse_tables_size],
            fse_metadata.fse_tables_buffer[0..fse_metadata.fse_tables_size],
        );
        op += fse_metadata.fse_tables_size;
    } else {
        const repeat: u8 = @backingInt(SymbolEncodingType.repeat);
        dst[seq_head] = (repeat << 6) + (repeat << 4) + (repeat << 2);
    }

    {
        const bitstream_size = try compress_sequences.encodeSequences(
            dst[op..],
            &fse_tables.matchlength_ctable,
            ml_code,
            &fse_tables.offcode_ctable,
            of_code,
            &fse_tables.litlength_ctable,
            ll_code,
            sequences,
            long_offsets,
            bmi2,
        );
        op += bitstream_size;
        // Decoders up to 1.3.4 refuse a table description read from fewer
        // than 4 bytes: with a last table of 2 bytes and a bit stream of
        // one, the sub-block is not compressed.
        if (write_entropy and fse_metadata.last_count_size != 0 and
            fse_metadata.last_count_size + bitstream_size < 4)
        {
            assert(fse_metadata.last_count_size + bitstream_size == 3);
            return 0;
        }
    }

    // Decoders up to 1.4.0 refuse a sequences section body under 3 bytes,
    // which repeated tables after RLE ones can give.
    if (op - seq_head < 4) return 0;

    entropy_written.* = true;
    return op;
}

/// `ZSTD_compressSubBlock`: writes one sub-block, header included.
/// Returns its size, or 0 when it should not be compressed.
fn compressSubBlock(
    entropy: *const ci.EntropyCTables,
    entropy_metadata: *const ci.EntropyCTablesMetadata,
    sequences: []const SeqDef,
    literals: []const u8,
    ll_code: []const u8,
    ml_code: []const u8,
    of_code: []const u8,
    cctx_params: *const ci.CCtxParams,
    dst: []u8,
    bmi2: bool,
    write_lit_entropy: bool,
    write_seq_entropy: bool,
    lit_entropy_written: *bool,
    seq_entropy_written: *bool,
    last_block: u32,
) Error!usize {
    var op: usize = block_header_size;
    {
        const c_lit_size = try compressSubBlockLiteral(
            &entropy.huf.ctable,
            &entropy_metadata.huf_metadata,
            literals,
            dst[op..],
            bmi2,
            write_lit_entropy,
            lit_entropy_written,
        );
        if (c_lit_size == 0) return 0;
        op += c_lit_size;
    }
    {
        const c_seq_size = try compressSubBlockSequences(
            &entropy.fse,
            &entropy_metadata.fse_metadata,
            sequences,
            ll_code,
            ml_code,
            of_code,
            cctx_params,
            dst[op..],
            bmi2,
            write_seq_entropy,
            seq_entropy_written,
        );
        if (c_seq_size == 0) return 0;
        op += c_seq_size;
    }
    // The block header.
    {
        const c_size = op - block_header_size;
        const c_block_header24: u32 = last_block +
            (@as(u32, @backingInt(zstd_internal.BlockType.compressed)) << 1) +
            @as(u32, @truncate(c_size << 3));
        writeLe24(dst, c_block_header24);
    }
    return op;
}

/// `ZSTD_estimateSubBlockSize_literal`: with a header of 3 bytes always.
fn estimateSubBlockSizeLiteral(
    literals: []const u8,
    huf_tables: *const ci.HufCTables,
    huf_metadata: *const ci.HufCTablesMetadata,
    workspace: []align(4) u8,
    write_entropy: bool,
) usize {
    const count_wksp = std.mem.bytesAsSlice(u32, workspace[0 .. 256 * @sizeOf(u32)]);
    var max_symbol_value: u32 = 255;
    const literal_section_header_size = 3;

    switch (huf_metadata.h_type) {
        .basic => return literals.len,
        .rle => return 1,
        .compressed, .repeat => {
            _ = hist.countWksp(
                count_wksp,
                &max_symbol_value,
                literals,
                workspace,
            ) catch return literals.len;
            var c_lit_size_estimate = huf_compress.estimateCompressedSize(
                &huf_tables.ctable,
                count_wksp,
                max_symbol_value,
            );
            if (write_entropy) c_lit_size_estimate += huf_metadata.huf_des_size;
            return c_lit_size_estimate + literal_section_header_size;
        },
    }
}

/// `ZSTD_estimateSubBlockSize_symbolType`.
fn estimateSubBlockSizeSymbolType(
    h_type: SymbolEncodingType,
    code_table: []const u8,
    max_code: u32,
    fse_ctable: []const u32,
    additional_bits: ?[]const u8,
    default_norm: []const i16,
    default_norm_log: u32,
    default_max: u32,
    workspace: []align(4) u8,
) usize {
    const count_wksp = std.mem.bytesAsSlice(
        u32,
        workspace[0 .. (zstd_internal.max_seq + 1) * @sizeOf(u32)],
    );
    const nb_seq = code_table.len;
    var max = max_code;

    _ = hist.countFastWksp(count_wksp, &max, code_table, workspace) catch unreachable;
    const symbol_bits: Error!usize = switch (h_type) {
        // The type was chosen, so it is valid.
        .basic => if (max <= default_max)
            compress_sequences.crossEntropyCost(default_norm, default_norm_log, count_wksp, max)
        else
            error.Generic,
        .rle => 0,
        .compressed, .repeat => compress_sequences.fseBitCost(fse_ctable, count_wksp, max),
    };
    var c_symbol_type_size_estimate_in_bits = symbol_bits catch return nb_seq * 10;
    for (code_table) |code| {
        // An offset code is its number of extra bits.
        c_symbol_type_size_estimate_in_bits += if (additional_bits) |bits| bits[code] else code;
    }
    return c_symbol_type_size_estimate_in_bits / 8;
}

/// `ZSTD_estimateSubBlockSize_sequences`: with a header of 3 bytes always.
fn estimateSubBlockSizeSequences(
    of_code_table: []const u8,
    ll_code_table: []const u8,
    ml_code_table: []const u8,
    fse_tables: *const ci.FseCTables,
    fse_metadata: *const ci.FseCTablesMetadata,
    workspace: []align(4) u8,
    write_entropy: bool,
) usize {
    const sequences_section_header_size = 3;
    var c_seq_size_estimate: usize = 0;
    if (of_code_table.len == 0) return sequences_section_header_size;
    c_seq_size_estimate += estimateSubBlockSizeSymbolType(
        fse_metadata.of_type,
        of_code_table,
        zstd_internal.max_off,
        &fse_tables.offcode_ctable,
        null,
        &zstd_internal.of_default_norm,
        zstd_internal.of_default_norm_log,
        zstd_internal.default_max_off,
        workspace,
    );
    c_seq_size_estimate += estimateSubBlockSizeSymbolType(
        fse_metadata.ll_type,
        ll_code_table,
        zstd_internal.max_ll,
        &fse_tables.litlength_ctable,
        &zstd_internal.ll_bits,
        &zstd_internal.ll_default_norm,
        zstd_internal.ll_default_norm_log,
        zstd_internal.max_ll,
        workspace,
    );
    c_seq_size_estimate += estimateSubBlockSizeSymbolType(
        fse_metadata.ml_type,
        ml_code_table,
        zstd_internal.max_ml,
        &fse_tables.matchlength_ctable,
        &zstd_internal.ml_bits,
        &zstd_internal.ml_default_norm,
        zstd_internal.ml_default_norm_log,
        zstd_internal.max_ml,
        workspace,
    );
    if (write_entropy) c_seq_size_estimate += fse_metadata.fse_tables_size;
    return c_seq_size_estimate + sequences_section_header_size;
}

/// `EstimatedBlockSize`.
const EstimatedBlockSize = struct {
    est_lit_size: usize,
    est_block_size: usize,
};

/// `ZSTD_estimateSubBlockSize`.
fn estimateSubBlockSize(
    literals: []const u8,
    of_code_table: []const u8,
    ll_code_table: []const u8,
    ml_code_table: []const u8,
    entropy: *const ci.EntropyCTables,
    entropy_metadata: *const ci.EntropyCTablesMetadata,
    workspace: []align(4) u8,
    write_lit_entropy: bool,
    write_seq_entropy: bool,
) EstimatedBlockSize {
    var ebs: EstimatedBlockSize = undefined;
    ebs.est_lit_size = estimateSubBlockSizeLiteral(
        literals,
        &entropy.huf,
        &entropy_metadata.huf_metadata,
        workspace,
        write_lit_entropy,
    );
    ebs.est_block_size = estimateSubBlockSizeSequences(
        of_code_table,
        ll_code_table,
        ml_code_table,
        &entropy.fse,
        &entropy_metadata.fse_metadata,
        workspace,
        write_seq_entropy,
    );
    ebs.est_block_size += ebs.est_lit_size + block_header_size;
    return ebs;
}

/// `ZSTD_needSequenceEntropyTables`: whether a table must be written, so
/// cannot just repeat.
fn needSequenceEntropyTables(fse_metadata: *const ci.FseCTablesMetadata) bool {
    const types = [_]SymbolEncodingType{
        fse_metadata.ll_type,
        fse_metadata.ml_type,
        fse_metadata.of_type,
    };
    for (types) |t| {
        if (t == .compressed or t == .rle) return true;
    }
    return false;
}

/// `countLiterals`: the literals of the sequences.
fn countLiterals(seq_store: *const SeqStore, sequences: []const SeqDef) usize {
    var total: usize = 0;
    for (sequences) |*seq| total += ci.getSequenceLength(seq_store, seq).lit_length;
    return total;
}

/// `BYTESCALE`: costs are in 256ths of a byte.
const byte_scale = 256;

/// `sizeBlockSequences`: the number of sequences, at least one, of the next
/// sub-block within `target_budget`, or more until it compresses.
fn sizeBlockSequences(
    sequences: []const SeqDef,
    target_budget: usize,
    avg_lit_cost: usize,
    avg_seq_cost: usize,
    first_sub_block: bool,
) usize {
    var budget: usize = 0;
    // The entropy headers, generously.
    const header_size: usize = @as(usize, @intFromBool(first_sub_block)) * 120 * byte_scale;
    budget += header_size;

    // At least one sequence.
    budget += sequences[0].lit_length * avg_lit_cost + avg_seq_cost;
    if (budget > target_budget) return 1;
    var in_size: usize = @as(
        usize,
        sequences[0].lit_length,
    ) + (@as(usize, sequences[0].ml_base) + zstd_internal.min_match);

    var n: usize = 1;
    while (n < sequences.len) : (n += 1) {
        const current_cost = sequences[n].lit_length * avg_lit_cost + avg_seq_cost;
        budget += current_cost;
        in_size += @as(
            usize,
            sequences[n].lit_length,
        ) + (@as(usize, sequences[n].ml_base) + zstd_internal.min_match);
        // Up to the budget, and on while the sub-block does not compress.
        if (budget > target_budget and budget < in_size * byte_scale) break;
    }
    return n;
}

/// `ZSTD_compressSubBlock_multi`: writes the super-block as sub-blocks, the
/// entropy tables in the first, the others repeating them. All are
/// compressed but maybe the last, which may be raw. Returns the size
/// written, or 0 when the super-block does not compress.
fn compressSubBlockMulti(
    seq_store: *const SeqStore,
    prev_cblock: *const ci.CompressedBlockState,
    next_cblock: *ci.CompressedBlockState,
    entropy_metadata: *const ci.EntropyCTablesMetadata,
    cctx_params: *const ci.CCtxParams,
    dst: []u8,
    src: []const u8,
    bmi2: bool,
    last_block: u32,
    workspace: []align(4) u8,
) Error!usize {
    const nb_seqs = (@intFromPtr(seq_store.sequences) - @intFromPtr(
        seq_store.sequences_start,
    )) / @sizeOf(SeqDef);
    const all_seqs = seq_store.sequences_start[0..nb_seqs];
    var sp: usize = 0;
    const nb_literals = @intFromPtr(seq_store.lit) - @intFromPtr(seq_store.lit_start);
    const all_lits = seq_store.lit_start[0..nb_literals];
    var lp: usize = 0;
    var ip: usize = 0;
    var op: usize = 0;
    // The code tables follow `sp`.
    // A minimum, against small blocks' side effects.
    const min_target = params.target_cblock_size_min;
    const target_cblock_size = @max(min_target, cctx_params.target_cblock_size);
    var write_lit_entropy = entropy_metadata.huf_metadata.h_type == .compressed;
    var write_seq_entropy = true;

    if (nb_seqs > 0) {
        // An estimate of the whole block.
        const ebs = estimateSubBlockSize(
            all_lits,
            seq_store.of_code[0..nb_seqs],
            seq_store.ll_code[0..nb_seqs],
            seq_store.ml_code[0..nb_seqs],
            &next_cblock.entropy,
            entropy_metadata,
            workspace,
            write_lit_entropy,
            write_seq_entropy,
        );
        const avg_lit_cost =
            if (nb_literals != 0) (ebs.est_lit_size * byte_scale) / nb_literals else byte_scale;
        const avg_seq_cost = ((ebs.est_block_size - ebs.est_lit_size) * byte_scale) / nb_seqs;
        const nb_sub_blocks = @max(
            (ebs.est_block_size + (target_cblock_size / 2)) / target_cblock_size,
            1,
        );
        const avg_block_budget = (ebs.est_block_size * byte_scale) / nb_sub_blocks;
        var block_budget_supp: usize = 0;

        // A super-block estimated not to compress is one raw block.
        if (ebs.est_block_size > src.len) return 0;

        assert(nb_sub_blocks > 0);
        var n: usize = 0;
        while (n < nb_sub_blocks - 1) : (n += 1) {
            // The sequences of the sub-block, with the literals up to the
            // next one.
            const seq_count = sizeBlockSequences(
                all_seqs[sp..],
                avg_block_budget + block_budget_supp,
                avg_lit_cost,
                avg_seq_cost,
                n == 0,
            );
            assert(seq_count <= nb_seqs - sp);
            // The last sequences go to the last sub-block.
            if (sp + seq_count == nb_seqs) break;
            assert(seq_count > 0);
            var lit_entropy_written = false;
            var seq_entropy_written = false;
            const sub_seqs = all_seqs[sp..][0..seq_count];
            const lit_size = countLiterals(seq_store, sub_seqs);
            const decompressed_size = seqDecompressedSize(seq_store, sub_seqs, lit_size, false);
            const c_size = try compressSubBlock(
                &next_cblock.entropy,
                entropy_metadata,
                sub_seqs,
                all_lits[lp..][0..lit_size],
                seq_store.ll_code[sp..][0..seq_count],
                seq_store.ml_code[sp..][0..seq_count],
                seq_store.of_code[sp..][0..seq_count],
                cctx_params,
                dst[op..],
                bmi2,
                write_lit_entropy,
                write_seq_entropy,
                &lit_entropy_written,
                &seq_entropy_written,
                0,
            );
            // A sub-block that does not compress joins the next one.
            if (c_size > 0 and c_size < decompressed_size) {
                assert(ip + decompressed_size <= src.len);
                ip += decompressed_size;
                lp += lit_size;
                op += c_size;
                // The tables are written once.
                if (lit_entropy_written) write_lit_entropy = false;
                if (seq_entropy_written) write_seq_entropy = false;
                sp += seq_count;
                block_budget_supp = 0;
            }
        }
    }

    // The last sub-block.
    {
        var lit_entropy_written = false;
        var seq_entropy_written = false;
        const lit_size = nb_literals - lp;
        const seq_count = nb_seqs - sp;
        const sub_seqs = all_seqs[sp..][0..seq_count];
        const decompressed_size = seqDecompressedSize(seq_store, sub_seqs, lit_size, true);
        const c_size = try compressSubBlock(
            &next_cblock.entropy,
            entropy_metadata,
            sub_seqs,
            all_lits[lp..][0..lit_size],
            seq_store.ll_code[sp..][0..seq_count],
            seq_store.ml_code[sp..][0..seq_count],
            seq_store.of_code[sp..][0..seq_count],
            cctx_params,
            dst[op..],
            bmi2,
            write_lit_entropy,
            write_seq_entropy,
            &lit_entropy_written,
            &seq_entropy_written,
            last_block,
        );
        if (c_size > 0 and c_size < decompressed_size) {
            assert(ip + decompressed_size <= src.len);
            ip += decompressed_size;
            lp += lit_size;
            op += c_size;
            if (lit_entropy_written) write_lit_entropy = false;
            if (seq_entropy_written) write_seq_entropy = false;
            sp += seq_count;
        }
    }

    if (write_lit_entropy) next_cblock.entropy.huf = prev_cblock.entropy.huf;
    // Tables that must be written and were not: a raw block instead.
    if (write_seq_entropy and needSequenceEntropyTables(&entropy_metadata.fse_metadata)) return 0;

    if (ip < src.len) {
        // The rest of the block, raw.
        const c_size = try ci.noCompressBlock(dst[op..], src[ip..], last_block);
        assert(c_size != 0);
        op += c_size;
        // The repeat offsets of the sequences written, the others skipped.
        if (sp < nb_seqs) {
            var rep: ci.Repcodes = .{ .rep = prev_cblock.rep };
            for (all_seqs[0..sp]) |*seq| {
                ci.updateRep(
                    &rep.rep,
                    seq.off_base,
                    @intFromBool(ci.getSequenceLength(seq_store, seq).lit_length == 0),
                );
            }
            next_cblock.rep = rep.rep;
        }
    }
    return op;
}

/// `ZSTD_compressSuperBlock`: writes the context's sequence store as a
/// super-block of `src`. Returns the size written, or 0 when it does not
/// compress.
pub fn compressSuperBlock(zc: *ci.CCtx, dst: []u8, src: []const u8, last_block: u32) Error!usize {
    var entropy_metadata: ci.EntropyCTablesMetadata = undefined;
    const workspace = zc.tmp_workspace[0..zc.tmp_wksp_size];
    try compress.buildBlockEntropyStats(
        &zc.seq_store,
        &zc.block_state.prev_cblock.entropy,
        &zc.block_state.next_cblock.entropy,
        &zc.applied_params,
        &entropy_metadata,
        workspace,
    );
    return compressSubBlockMulti(
        &zc.seq_store,
        zc.block_state.prev_cblock,
        zc.block_state.next_cblock,
        &entropy_metadata,
        &zc.applied_params,
        dst,
        src,
        zc.bmi2,
        last_block,
        workspace,
    );
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test {
    std.testing.refAllDecls(@This());
}
