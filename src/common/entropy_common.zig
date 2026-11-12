//! Readers of entropy table headers, from the original's entropy_common.c,
//! which dictionary loading uses: `readNCount` for FSE distributions and
//! `readStats` for Huffman weights. Both read untrusted bytes, and give the
//! original's result on any input, an error or a value.
//!
//! Huffman weights may be FSE-compressed, so the FSE decoder that
//! `readStats` needs is here too, from the original's fse_decompress.c.

const std = @import("std");
const assert = std.debug.assert;
const Error = @import("../error.zig").Error;
const fse = @import("fse.zig");
const huf = @import("huf.zig");
const bitstream = @import("bitstream.zig");
const highbit32 = bitstream.highbit32;

/// `FSE_readNCount`: reads the distribution header that `writeNCount`
/// writes, into `normalized_counter[0..max_sv_ptr.* + 1]`. Sets
/// `max_sv_ptr` to the largest symbol read and `table_log_ptr` to the
/// table log, and returns the header's size.
pub fn readNCount(
    normalized_counter: []i16,
    max_sv_ptr: *u32,
    table_log_ptr: *u32,
    header_buffer: []const u8,
) Error!usize {
    const hb_size = header_buffer.len;
    if (hb_size < 8) {
        // The reader needs 8 bytes: read a zero-padded copy.
        var buffer: [8]u8 = @splat(0);
        @memcpy(buffer[0..hb_size], header_buffer);
        const count_size = try readNCount(normalized_counter, max_sv_ptr, table_log_ptr, &buffer);
        if (count_size > hb_size) return error.CorruptionDetected;
        return count_size;
    }

    const iend = hb_size;
    var ip: usize = 0;
    var charnum: u32 = 0;
    const max_sv1 = max_sv_ptr.* + 1;
    var previous0 = false;

    // Symbols the header does not reach have a count of 0.
    @memset(normalized_counter[0..max_sv1], 0);
    var bit_stream = std.mem.readInt(u32, header_buffer[0..4], .little);
    var nb_bits: i32 = @as(i32, @intCast(bit_stream & 0xF)) + fse.min_table_log;
    if (nb_bits > fse.table_log_absolute_max) return error.TableLogTooLarge;
    bit_stream >>= 4;
    var bit_count: i32 = 4;
    table_log_ptr.* = @intCast(nb_bits);
    var remaining: i32 = (@as(i32, 1) << @intCast(nb_bits)) + 1;
    var threshold: i32 = @as(i32, 1) << @intCast(nb_bits);
    nb_bits += 1;

    while (true) {
        if (previous0) {
            // Count the repeats: each 2-bit code 0b11 adds three zeros. The
            // high bit set keeps the count defined.
            var repeats: u32 = @ctz(~bit_stream | 0x80000000) >> 1;
            while (repeats >= 12) {
                charnum += 3 * 12;
                if (ip + 7 <= iend) {
                    ip += 3;
                } else {
                    bit_count += @intCast(8 * (ip - (iend - 7)));
                    bit_count &= 31;
                    ip = iend - 4;
                }
                bit_stream = std.mem.readInt(u32, header_buffer[ip..][0..4], .little) >>
                    @intCast(bit_count);
                repeats = @ctz(~bit_stream | 0x80000000) >> 1;
            }
            charnum += 3 * repeats;
            bit_stream >>= @intCast(2 * repeats);
            bit_count += @intCast(2 * repeats);

            // The last repeat, which is not 0b11.
            assert(bit_stream & 3 < 3);
            charnum += bit_stream & 3;
            bit_count += 2;

            // An error, returned after the loop.
            if (charnum >= max_sv1) break;

            // The counts are already 0.
            const advance: usize = @intCast(bit_count >> 3);
            if (ip + 7 <= iend or ip + advance + 4 <= iend) {
                assert(advance <= 3);
                ip += advance;
                bit_count &= 7;
            } else {
                bit_count -= @intCast(8 * (iend - 4 - ip));
                bit_count &= 31;
                ip = iend - 4;
            }
            bit_stream = std.mem.readInt(u32, header_buffer[ip..][0..4], .little) >>
                @intCast(bit_count);
        }
        {
            const max = (2 * threshold - 1) - remaining;
            var count: i32 = undefined;

            if (bit_stream & @as(u32, @intCast(threshold - 1)) < @as(u32, @intCast(max))) {
                count = @intCast(bit_stream & @as(u32, @intCast(threshold - 1)));
                bit_count += nb_bits - 1;
            } else {
                count = @intCast(bit_stream & @as(u32, @intCast(2 * threshold - 1)));
                if (count >= threshold) count -= max;
                bit_count += nb_bits;
            }

            // Extra accuracy.
            count -= 1;
            if (count >= 0) {
                remaining -= count;
            } else {
                assert(count == -1);
                remaining += count;
            }
            normalized_counter[charnum] = @intCast(count);
            charnum += 1;
            previous0 = count == 0;

            assert(threshold > 1);
            if (remaining < threshold) {
                // Folds into the threshold update, since threshold > 1.
                if (remaining <= 1) break;
                nb_bits = @intCast(highbit32(@intCast(remaining)) + 1);
                threshold = @as(i32, 1) << @intCast(nb_bits - 1);
            }
            if (charnum >= max_sv1) break;

            const advance: usize = @intCast(bit_count >> 3);
            if (ip + 7 <= iend or ip + advance + 4 <= iend) {
                ip += advance;
                bit_count &= 7;
            } else {
                bit_count -= @intCast(8 * (iend - 4 - ip));
                bit_count &= 31;
                ip = iend - 4;
            }
            bit_stream = std.mem.readInt(u32, header_buffer[ip..][0..4], .little) >>
                @intCast(bit_count);
        }
    }
    if (remaining != 1) return error.CorruptionDetected;
    // Only possible with too many zeros.
    if (charnum > max_sv1) return error.MaxSymbolValueTooSmall;
    if (bit_count > 32) return error.CorruptionDetected;
    max_sv_ptr.* = charnum - 1;

    ip += @intCast((bit_count + 7) >> 3);
    return ip;
}

/// `HUF_readStats`: `readStatsWksp` with a workspace on the stack.
pub fn readStats(
    huff_weight: []u8,
    rank_stats: []u32,
    nb_symbols_ptr: *u32,
    table_log_ptr: *u32,
    src: []const u8,
) Error!usize {
    var workspace: [huf.read_stats_workspace_size_u32]u32 = undefined;
    return readStatsWksp(
        huff_weight,
        rank_stats,
        nb_symbols_ptr,
        table_log_ptr,
        src,
        std.mem.asBytes(&workspace),
    );
}

/// `HUF_readStats_wksp`: reads the Huffman weights `writeCTable` writes.
/// Fills `huff_weight` (one per symbol, the last one implied),
/// `rank_stats[0..huf.table_log_max + 1]` (the number of symbols of each
/// weight), the number of symbols and the table log. Returns the size read.
/// `workspace` holds `huf.read_stats_workspace_size` bytes, aligned on 4.
pub fn readStatsWksp(
    huff_weight: []u8,
    rank_stats: []u32,
    nb_symbols_ptr: *u32,
    table_log_ptr: *u32,
    src: []const u8,
    workspace: []u8,
) Error!usize {
    assert(huff_weight.len >= 1);
    assert(rank_stats.len >= huf.table_log_max + 1);
    if (src.len == 0) return error.SrcSizeWrong;
    var i_size: usize = src[0];
    var o_size: usize = undefined;

    if (i_size >= 128) {
        // Raw weights, 4 bits each.
        o_size = i_size - 127;
        i_size = (o_size + 1) / 2;
        if (i_size + 1 > src.len) return error.SrcSizeWrong;
        if (o_size >= huff_weight.len) return error.CorruptionDetected;
        var n: usize = 0;
        while (n < o_size) : (n += 2) {
            huff_weight[n] = src[1 + n / 2] >> 4;
            huff_weight[n + 1] = src[1 + n / 2] & 15;
        }
    } else {
        // FSE-compressed weights. At most `huff_weight.len - 1` are
        // decoded, as the last one is implied.
        if (i_size + 1 > src.len) return error.SrcSizeWrong;
        o_size = try decompressWksp(
            huff_weight[0 .. huff_weight.len - 1],
            src[1..][0..i_size],
            6,
            workspace,
        );
    }

    // Weight statistics.
    @memset(rank_stats[0 .. huf.table_log_max + 1], 0);
    var weight_total: u32 = 0;
    for (huff_weight[0..o_size]) |weight| {
        if (weight > huf.table_log_max) return error.CorruptionDetected;
        rank_stats[weight] += 1;
        weight_total += (@as(u32, 1) << @intCast(weight)) >> 1;
    }
    if (weight_total == 0) return error.CorruptionDetected;

    // The last symbol's weight is implied: the total must be a power of 2.
    const table_log = highbit32(weight_total) + 1;
    if (table_log > huf.table_log_max) return error.CorruptionDetected;
    table_log_ptr.* = table_log;
    const total = @as(u32, 1) << @intCast(table_log);
    const rest = total - weight_total;
    const verif = @as(u32, 1) << @intCast(highbit32(rest));
    const last_weight = highbit32(rest) + 1;
    // The last value must be a clean power of 2.
    if (verif != rest) return error.CorruptionDetected;
    huff_weight[o_size] = @intCast(last_weight);
    rank_stats[last_weight] += 1;

    // A valid tree has an even number of rank-1 symbols, at least 2.
    if (rank_stats[1] < 2 or rank_stats[1] & 1 != 0) return error.CorruptionDetected;

    nb_symbols_ptr.* = @intCast(o_size + 1);
    return i_size + 1;
}

/// `FSE_DTableHeader`.
const DTableHeader = extern struct {
    table_log: u16,
    fast_mode: u16,
};

/// `FSE_decode_t`.
const Decode = extern struct {
    new_state: u16,
    symbol: u8,
    nb_bits: u8,
};

/// `FSE_BUILD_DTABLE_WKSP_SIZE`.
fn buildDTableWkspSize(table_log: u32, max_symbol_value: u32) u64 {
    const table_size = @as(u64, 1) << @intCast(table_log);
    return @sizeOf(i16) * (@as(u64, max_symbol_value) + 1) + table_size + 8;
}

/// `FSE_buildDTable_internal`: builds the decoding table `dt` (a header,
/// then `1 << table_log` entries) from a normalized distribution.
fn buildDTable(
    dt: [*]u32,
    normalized_counter: []const i16,
    max_symbol_value: u32,
    table_log: u32,
    workspace: []u8,
) Error!void {
    if (buildDTableWkspSize(table_log, max_symbol_value) > workspace.len) {
        return error.MaxSymbolValueTooLarge;
    }
    if (max_symbol_value > fse.max_symbol_value) return error.MaxSymbolValueTooLarge;
    if (table_log > fse.max_table_log) return error.TableLogTooLarge;

    const table_decode: [*]Decode = @ptrCast(dt + 1);
    const max_sv1 = max_symbol_value + 1;
    const symbol_next: []u16 = @as([*]u16, @ptrCast(@alignCast(workspace.ptr)))[0..max_sv1];
    const spread = workspace[2 * max_sv1 ..];
    const table_size = @as(u32, 1) << @intCast(table_log);
    var high_threshold = table_size - 1;

    // Lay down the low-probability symbols.
    var header: DTableHeader = .{ .table_log = @intCast(table_log), .fast_mode = 1 };
    const large_limit: i16 = @intCast(@as(u32, 1) << @intCast(table_log - 1));
    for (normalized_counter[0..max_sv1], symbol_next, 0..) |normalized, *next, s| {
        if (normalized == -1) {
            table_decode[high_threshold].symbol = @intCast(s);
            high_threshold -%= 1;
            next.* = 1;
        } else {
            if (normalized >= large_limit) header.fast_mode = 0;
            next.* = @intCast(normalized);
        }
    }
    @as(*DTableHeader, @ptrCast(dt)).* = header;

    // Spread the symbols.
    const table_mask = table_size - 1;
    const step = fse.tableStep(table_size);
    if (high_threshold == table_size - 1) {
        // No low-probability symbols: lay them down in order, eight bytes at
        // a time, then spread them with no variable inner loop. The
        // workspace check leaves 8 bytes past the table for the overwrite.
        var pos: usize = 0;
        var sv: u64 = 0;
        for (normalized_counter[0..max_sv1]) |normalized| {
            const n: usize = @intCast(normalized);
            std.mem.writeInt(u64, spread[pos..][0..8], sv, .little);
            var i: usize = 8;
            while (i < n) : (i += 8) std.mem.writeInt(u64, spread[pos + i ..][0..8], sv, .little);
            pos += n;
            sv +%= 0x0101010101010101;
        }
        var position: usize = 0;
        var s: usize = 0;
        while (s < table_size) : (s += 2) {
            table_decode[position & table_mask].symbol = spread[s];
            table_decode[(position + step) & table_mask].symbol = spread[s + 1];
            position = (position + 2 * step) & table_mask;
        }
        assert(position == 0);
    } else {
        var position: u32 = 0;
        for (normalized_counter[0..max_sv1], 0..) |normalized, s| {
            var i: i32 = 0;
            while (i < normalized) : (i += 1) {
                table_decode[position].symbol = @intCast(s);
                position = (position + step) & table_mask;
                // Skip the low-probability area.
                while (position > high_threshold) position = (position + step) & table_mask;
            }
        }
        // Every cell must be reached once, or the distribution is wrong.
        if (position != 0) return error.Generic;
    }

    // The decoding table.
    for (table_decode[0..table_size]) |*entry| {
        const next_state: u32 = symbol_next[entry.symbol];
        symbol_next[entry.symbol] += 1;
        entry.nb_bits = @intCast(table_log - highbit32(next_state));
        entry.new_state = @intCast((next_state << @intCast(entry.nb_bits)) - table_size);
    }
}

/// `FSE_DState_t`: points into a decoding table, valid while it is.
const DState = struct {
    state: usize,
    table: [*]const Decode,

    /// `FSE_initDState`.
    fn init(bit_d: *bitstream.DStream, dt: [*]const u32) DState {
        const header: *const DTableHeader = @ptrCast(dt);
        const state = bit_d.readBits(header.table_log);
        _ = bit_d.reload();
        return .{ .state = state, .table = @ptrCast(dt + 1) };
    }

    /// `FSE_decodeSymbol`, or with `fast` `FSE_decodeSymbolFast`, which
    /// needs every entry to read at least one bit.
    inline fn decodeSymbol(d_state: *DState, bit_d: *bitstream.DStream, comptime fast: bool) u8 {
        const info = d_state.table[d_state.state];
        const low_bits = if (fast)
            bit_d.readBitsFast(info.nb_bits)
        else
            bit_d.readBits(info.nb_bits);
        d_state.state = info.new_state + low_bits;
        return info.symbol;
    }
};

/// `FSE_decompress_usingDTable_generic`.
fn decompressUsingDTable(
    dst: []u8,
    c_src: []const u8,
    dt: [*]const u32,
    comptime fast: bool,
) Error!usize {
    const container_bits = @bitSizeOf(bitstream.Container);
    const omax: isize = @intCast(dst.len);
    const olimit = omax - 3;
    var op: isize = 0;

    var bit_d = try bitstream.DStream.init(c_src);
    var state1: DState = .init(&bit_d, dt);
    var state2: DState = .init(&bit_d, dt);

    if (bit_d.reload() == .overflow) return error.CorruptionDetected;

    // Four symbols per loop. The reload runs whether or not the output has
    // room, as in the original.
    while (true) : (op += 4) {
        const status = bit_d.reload();
        if (!(status == .unfinished and op < olimit)) break;
        const o: usize = @intCast(op);
        dst[o] = state1.decodeSymbol(&bit_d, fast);
        if (fse.max_table_log * 2 + 7 > container_bits) _ = bit_d.reload();
        dst[o + 1] = state2.decodeSymbol(&bit_d, fast);
        if (fse.max_table_log * 4 + 7 > container_bits) {
            if (@backingInt(bit_d.reload()) > @backingInt(bitstream.DStreamStatus.unfinished)) {
                op += 2;
                break;
            }
        }
        dst[o + 2] = state1.decodeSymbol(&bit_d, fast);
        if (fse.max_table_log * 2 + 7 > container_bits) _ = bit_d.reload();
        dst[o + 3] = state2.decodeSymbol(&bit_d, fast);
    }

    // The tail: the stream ends exactly at `completed`.
    while (true) {
        if (op > omax - 2) return error.DstSizeTooSmall;
        dst[@intCast(op)] = state1.decodeSymbol(&bit_d, fast);
        op += 1;
        if (bit_d.reload() == .overflow) {
            dst[@intCast(op)] = state2.decodeSymbol(&bit_d, fast);
            op += 1;
            break;
        }

        if (op > omax - 2) return error.DstSizeTooSmall;
        dst[@intCast(op)] = state2.decodeSymbol(&bit_d, fast);
        op += 1;
        if (bit_d.reload() == .overflow) {
            dst[@intCast(op)] = state1.decodeSymbol(&bit_d, fast);
            op += 1;
            break;
        }
    }
    return @intCast(op);
}

/// `FSE_DecompressWksp`: the start of the decoder's workspace.
const DecompressWksp = extern struct {
    ncount: [fse.max_symbol_value + 1]i16,
};

/// `FSE_decompress_wksp_bmi2`: decodes an FSE header and stream into `dst`,
/// with a table log of at most `max_log`. `workspace` is aligned on 4.
fn decompressWksp(dst: []u8, c_src: []const u8, max_log: u32, workspace: []u8) Error!usize {
    if (workspace.len < @sizeOf(DecompressWksp)) return error.Generic;
    const wksp: *DecompressWksp = @ptrCast(@alignCast(workspace.ptr));
    const dtable: [*]u32 = @as([*]u32, @ptrCast(@alignCast(workspace.ptr))) +
        @sizeOf(DecompressWksp) / @sizeOf(u32);

    var table_log: u32 = undefined;
    var max_symbol_value: u32 = fse.max_symbol_value;
    const ncount_length = try readNCount(&wksp.ncount, &max_symbol_value, &table_log, c_src);
    if (table_log > max_log) return error.TableLogTooLarge;
    assert(ncount_length <= c_src.len);
    const stream = c_src[ncount_length..];

    const needed = fse.decompressWorkspaceSizeU32(table_log, max_symbol_value) * @sizeOf(u32);
    if (needed > workspace.len) return error.TableLogTooLarge;
    const dtable_size = fse.dtableSizeU32(table_log) * @sizeOf(u32);
    const rest = workspace[@sizeOf(DecompressWksp) + dtable_size ..];

    try buildDTable(dtable, &wksp.ncount, max_symbol_value, table_log, rest);
    const header: *const DTableHeader = @ptrCast(dtable);
    if (header.fast_mode != 0) return decompressUsingDTable(dst, stream, dtable, true);
    return decompressUsingDTable(dst, stream, dtable, false);
}

// --------------------------------------------------------
// Tests
// --------------------------------------------------------

const testing = std.testing;

test "raw weights read back" {
    // Weights 1, 1, then the implied last: three symbols of 2, 2 and 1 bits.
    const src = [_]u8{ 128 + 1, 0x11 };
    var weights: [256]u8 = undefined;
    var rank_stats: [huf.table_log_max + 1]u32 = undefined;
    var nb_symbols: u32 = undefined;
    var table_log: u32 = undefined;
    const size = try readStats(&weights, &rank_stats, &nb_symbols, &table_log, &src);
    try testing.expectEqual(@as(usize, 2), size);
    try testing.expectEqual(@as(u32, 3), nb_symbols);
    try testing.expectEqual(@as(u32, 2), table_log);
    try testing.expectEqualSlices(u8, &.{ 1, 1, 2 }, weights[0..3]);
}

test "a distribution header reads back from padding" {
    // Table log 5, then symbol 0 with all 32 cells, written as 63 in 6 bits.
    const header = [_]u8{ 0xF0, 0x03 };
    var counts: [4]i16 = undefined;
    var max_sv: u32 = 3;
    var table_log: u32 = undefined;
    const size = try readNCount(&counts, &max_sv, &table_log, &header);
    try testing.expectEqual(@as(usize, 2), size);
    try testing.expectEqual(@as(u32, 5), table_log);
    try testing.expectEqual(@as(u32, 0), max_sv);
    try testing.expectEqual(@as(i16, 32), counts[0]);

    var weights: [256]u8 = undefined;
    var rank_stats: [huf.table_log_max + 1]u32 = undefined;
    var nb_symbols: u32 = undefined;
    const no_input = readStats(&weights, &rank_stats, &nb_symbols, &table_log, &.{});
    try testing.expectError(error.SrcSizeWrong, no_input);
}
