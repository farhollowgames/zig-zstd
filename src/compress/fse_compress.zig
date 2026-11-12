//! The Finite State Entropy encoder, from the original's fse_compress.c and
//! the inline encoder of its fse.h.
//!
//! A compression table (`CTable`, `u32` units) keeps the original's layout,
//! since other parts store and copy it: a header of two `u16` (table log,
//! largest symbol), then the `u16` state table (`1 << table_log` entries),
//! then one `SymbolTransform` per symbol.

const std = @import("std");
const assert = std.debug.assert;
const Error = @import("../error.zig").Error;
const fse = @import("../common/fse.zig");
const bitstream = @import("../common/bitstream.zig");
const highbit32 = bitstream.highbit32;

/// `FSE_symbolCompressionTransform`.
pub const SymbolTransform = extern struct {
    delta_find_state: i32,
    delta_nb_bits: u32,
};

fn tableU16(ct: [*]u32) [*]u16 {
    return @as([*]u16, @ptrCast(ct)) + 2;
}

fn symbolTransforms(ct: [*]u32, table_log: u32) [*]SymbolTransform {
    const offset: usize = if (table_log != 0) @as(usize, 1) << @intCast(table_log - 1) else 1;
    return @ptrCast(ct + 1 + offset);
}

/// `FSE_buildCTable_wksp`: builds `ct` from a normalized distribution.
/// `workspace` holds `fse.buildCTableWorkspaceSize(max_symbol_value,
/// table_log)` bytes, aligned on 2.
pub fn buildCTableWksp(
    ct: []u32,
    normalized_counter: []const i16,
    max_symbol_value: u32,
    table_log: u32,
    workspace: []u8,
) Error!void {
    const table_size = @as(u32, 1) << @intCast(table_log);
    const table_mask = table_size - 1;
    const step = fse.tableStep(table_size);
    const max_sv1 = max_symbol_value + 1;
    if (fse.buildCTableWorkspaceSize(max_symbol_value, table_log) > workspace.len) {
        return error.TableLogTooLarge;
    }
    assert(ct.len >= fse.ctableSizeU32(table_log, max_symbol_value));
    assert(table_log < 16);
    const table_u16 = tableU16(ct.ptr);
    const symbol_tt = symbolTransforms(ct.ptr, table_log);
    const cumul: []u16 = @as([*]u16, @ptrCast(@alignCast(workspace.ptr)))[0 .. max_sv1 + 1];
    const symbols = workspace[2 * (max_sv1 + 1) ..];
    const table_symbol = symbols[0..table_size];
    var high_threshold = table_size - 1;

    (table_u16 - 2)[0] = @intCast(table_log);
    (table_u16 - 1)[0] = @intCast(max_symbol_value);

    // Symbol start positions.
    cumul[0] = 0;
    for (1..max_sv1 + 1) |u| {
        if (normalized_counter[u - 1] == -1) {
            // A low-probability symbol: one cell at the end of the table.
            cumul[u] = cumul[u - 1] + 1;
            table_symbol[high_threshold] = @intCast(u - 1);
            high_threshold -%= 1;
        } else {
            assert(normalized_counter[u - 1] >= 0);
            cumul[u] = cumul[u - 1] + @as(u16, @intCast(normalized_counter[u - 1]));
        }
    }
    cumul[max_sv1] = @intCast(table_size + 1);

    // Spread the symbols over the table.
    if (high_threshold == table_size - 1) {
        // No low-probability symbols: lay the symbols down in order, eight
        // bytes at a time, then spread them with no variable inner loop.
        const spread = symbols[table_size..];
        var pos: usize = 0;
        var sv: u64 = 0;
        for (normalized_counter[0..max_sv1]) |normalized| {
            const n: usize = @intCast(normalized);
            if (spread.len - pos >= n + 8) {
                std.mem.writeInt(u64, spread[pos..][0..8], sv, .little);
                var i: usize = 8;
                while (i < n) : (i += 8) {
                    std.mem.writeInt(u64, spread[pos + i ..][0..8], sv, .little);
                }
            } else {
                @memset(spread[pos..][0..n], @truncate(sv));
            }
            pos += n;
            sv +%= 0x0101010101010101;
        }
        var position: usize = 0;
        var s: usize = 0;
        while (s < table_size) : (s += 2) {
            table_symbol[position & table_mask] = spread[s];
            table_symbol[(position + step) & table_mask] = spread[s + 1];
            position = (position + 2 * step) & table_mask;
        }
        assert(position == 0);
    } else {
        var position: u32 = 0;
        for (normalized_counter[0..max_sv1], 0..) |freq, symbol| {
            var occurrences: i32 = 0;
            while (occurrences < freq) : (occurrences += 1) {
                table_symbol[position] = @intCast(symbol);
                position = (position + step) & table_mask;
                // Skip the low-probability area.
                while (position > high_threshold) position = (position + step) & table_mask;
            }
        }
        assert(position == 0);
    }

    // The state table, sorted by symbol: the next state of each cell.
    for (table_symbol, 0..) |s, u| {
        table_u16[cumul[s]] = @intCast(table_size + u);
        cumul[s] += 1;
    }

    // The symbol transforms.
    var total: u32 = 0;
    for (normalized_counter[0..max_sv1], 0..) |normalized, s| {
        switch (normalized) {
            // Filled for `getMaxNbBits`, which gives an absent symbol a cost.
            0 => symbol_tt[s].delta_nb_bits = ((table_log + 1) << 16) - table_size,
            -1, 1 => {
                symbol_tt[s].delta_nb_bits = (table_log << 16) - table_size;
                symbol_tt[s].delta_find_state = @as(i32, @intCast(total)) - 1;
                total += 1;
            },
            else => {
                assert(normalized > 1);
                const freq: u32 = @intCast(normalized);
                const max_bits_out = table_log - highbit32(freq - 1);
                const min_state_plus = freq << @intCast(max_bits_out);
                symbol_tt[s].delta_nb_bits = (max_bits_out << 16) - min_state_plus;
                symbol_tt[s].delta_find_state = @as(i32, @intCast(total)) - @as(i32, normalized);
                total += freq;
            },
        }
    }
}

/// `FSE_NCountWriteBound`: the largest header `writeNCount` writes.
pub fn ncountWriteBound(max_symbol_value: u32, table_log: u32) usize {
    const max_header_size = (((max_symbol_value + 1) * table_log
        // The bit count starts at 4, and the first two symbols may each
        // take one more bit.
    + 4 + 2) / 8)
        // Rounded up to whole bytes, and two for the last flush.
        + 1 + 2;
    return if (max_symbol_value != 0) max_header_size else fse.ncount_bound;
}

/// `FSE_writeNCount_generic`.
fn writeNCountGeneric(
    header: []u8,
    normalized_counter: []const i16,
    max_symbol_value: u32,
    table_log: u32,
    comptime write_is_safe: bool,
) Error!usize {
    const table_size: i32 = @as(i32, 1) << @intCast(table_log);
    var out: usize = 0;
    var bit_stream: u32 = 0;
    // Up to 32: a run of zeros can add 16 bits before the next flush.
    var bit_count: u32 = 0;
    var symbol: u32 = 0;
    const alphabet_size = max_symbol_value + 1;
    var previous_is0 = false;

    // The table size.
    bit_stream += (table_log - fse.min_table_log) << @intCast(bit_count);
    bit_count += 4;

    // One more than the table size, for extra accuracy.
    var remaining: i32 = table_size + 1;
    var threshold: i32 = table_size;
    var nb_bits: u32 = table_log + 1;

    while (symbol < alphabet_size and remaining > 1) {
        if (previous_is0) {
            var start = symbol;
            while (symbol < alphabet_size and normalized_counter[symbol] == 0) symbol += 1;
            // An incorrect distribution.
            if (symbol == alphabet_size) break;
            while (symbol >= start + 24) {
                start += 24;
                bit_stream += @as(u32, 0xFFFF) << @intCast(bit_count);
                if (!write_is_safe and out + 2 > header.len) return error.DstSizeTooSmall;
                header[out] = @truncate(bit_stream);
                header[out + 1] = @truncate(bit_stream >> 8);
                out += 2;
                bit_stream >>= 16;
            }
            while (symbol >= start + 3) {
                start += 3;
                bit_stream += @as(u32, 3) << @intCast(bit_count);
                bit_count += 2;
            }
            bit_stream += (symbol - start) << @intCast(bit_count);
            bit_count += 2;
            if (bit_count > 16) {
                if (!write_is_safe and out + 2 > header.len) return error.DstSizeTooSmall;
                header[out] = @truncate(bit_stream);
                header[out + 1] = @truncate(bit_stream >> 8);
                out += 2;
                bit_stream >>= 16;
                bit_count -= 16;
            }
        }
        {
            var count: i32 = normalized_counter[symbol];
            symbol += 1;
            const max = (2 * threshold - 1) - remaining;
            remaining -= if (count < 0) -count else count;
            // One more, for extra accuracy.
            count += 1;
            // [0..max[ [max..threshold[ (...) [threshold+max 2*threshold[
            if (count >= threshold) count += max;
            bit_stream += @as(u32, @intCast(count)) << @intCast(bit_count);
            bit_count += nb_bits;
            bit_count -= @intFromBool(count < max);
            previous_is0 = count == 1;
            if (remaining < 1) return error.Generic;
            while (remaining < threshold) {
                nb_bits -= 1;
                threshold >>= 1;
            }
        }
        if (bit_count > 16) {
            if (!write_is_safe and out + 2 > header.len) return error.DstSizeTooSmall;
            header[out] = @truncate(bit_stream);
            header[out + 1] = @truncate(bit_stream >> 8);
            out += 2;
            bit_stream >>= 16;
            bit_count -= 16;
        }
    }

    // An incorrect normalized distribution.
    if (remaining != 1) return error.Generic;
    assert(symbol <= alphabet_size);

    // Flush the rest.
    if (!write_is_safe and out + 2 > header.len) return error.DstSizeTooSmall;
    header[out] = @truncate(bit_stream);
    header[out + 1] = @truncate(bit_stream >> 8);
    out += (@as(usize, bit_count) + 7) / 8;
    return out;
}

/// `FSE_writeNCount`: writes the normalized distribution's header into
/// `buffer`, and returns its size.
pub fn writeNCount(
    buffer: []u8,
    normalized_counter: []const i16,
    max_symbol_value: u32,
    table_log: u32,
) Error!usize {
    if (table_log > fse.max_table_log) return error.TableLogTooLarge;
    if (table_log < fse.min_table_log) return error.Generic;
    if (buffer.len < ncountWriteBound(max_symbol_value, table_log)) {
        return writeNCountGeneric(buffer, normalized_counter, max_symbol_value, table_log, false);
    }
    return writeNCountGeneric(buffer, normalized_counter, max_symbol_value, table_log, true);
}

/// `FSE_minTableLog`: the smallest table log that can represent the
/// distribution.
fn minTableLog(src_size: usize, max_symbol_value: u32) u32 {
    assert(src_size > 1);
    const min_bits_src = highbit32(@truncate(src_size)) + 1;
    const min_bits_symbols = highbit32(max_symbol_value) + 2;
    return @min(min_bits_src, min_bits_symbols);
}

/// `FSE_optimalTableLog_internal`.
pub fn optimalTableLogInternal(
    max_table_log: u32,
    src_size: usize,
    max_symbol_value: u32,
    minus: u32,
) u32 {
    assert(src_size > 1);
    // Wraps for tiny inputs, which then keep the larger table log.
    const max_bits_src = highbit32(@truncate(src_size - 1)) -% minus;
    var table_log = max_table_log;
    const min_bits = minTableLog(src_size, max_symbol_value);
    if (table_log == 0) table_log = fse.default_table_log;
    // Accuracy can be reduced.
    if (max_bits_src < table_log) table_log = max_bits_src;
    // A minimum is needed to represent every symbol.
    if (min_bits > table_log) table_log = min_bits;
    if (table_log < fse.min_table_log) table_log = fse.min_table_log;
    if (table_log > fse.max_table_log) table_log = fse.max_table_log;
    return table_log;
}

/// `FSE_optimalTableLog`.
pub fn optimalTableLog(max_table_log: u32, src_size: usize, max_symbol_value: u32) u32 {
    return optimalTableLogInternal(max_table_log, src_size, max_symbol_value, 2);
}

/// `FSE_normalizeM2`: the second method, for when the first fails.
fn normalizeM2(
    norm: []i16,
    table_log: u32,
    count: []const u32,
    total_in: usize,
    max_symbol_value: u32,
    low_prob_count: i16,
) Error!void {
    const not_yet_assigned: i16 = -2;
    var total = total_in;
    var distributed: u32 = 0;

    const low_threshold: u32 = @truncate(total >> @intCast(table_log));
    var low_one: u32 = @truncate((total * 3) >> @intCast(table_log + 1));

    for (count[0 .. max_symbol_value + 1], norm[0 .. max_symbol_value + 1]) |c, *n| {
        if (c == 0) {
            n.* = 0;
        } else if (c <= low_threshold) {
            n.* = low_prob_count;
            distributed += 1;
            total -= c;
        } else if (c <= low_one) {
            n.* = 1;
            distributed += 1;
            total -= c;
        } else {
            n.* = not_yet_assigned;
        }
    }
    var to_distribute = (@as(u32, 1) << @intCast(table_log)) - distributed;

    if (to_distribute == 0) return;

    if (total / to_distribute > low_one) {
        // A risk of rounding to zero.
        low_one = @truncate((total * 3) / (to_distribute * 2));
        for (count[0 .. max_symbol_value + 1], norm[0 .. max_symbol_value + 1]) |c, *n| {
            if (n.* == not_yet_assigned and c <= low_one) {
                n.* = 1;
                distributed += 1;
                total -= c;
            }
        }
        to_distribute = (@as(u32, 1) << @intCast(table_log)) - distributed;
    }

    if (distributed == max_symbol_value + 1) {
        // Every value is poor, so the data is probably incompressible: give
        // the remaining points to the most frequent symbol.
        var max_v: usize = 0;
        var max_c: u32 = 0;
        for (count[0 .. max_symbol_value + 1], 0..) |c, s| {
            if (c > max_c) {
                max_v = s;
                max_c = c;
            }
        }
        norm[max_v] += @intCast(to_distribute);
        return;
    }

    if (total == 0) {
        // Every symbol was low enough for `low_one` or `low_threshold`.
        var s: u32 = 0;
        while (to_distribute > 0) : (s = (s + 1) % (max_symbol_value + 1)) {
            if (norm[s] > 0) {
                to_distribute -= 1;
                norm[s] += 1;
            }
        }
        return;
    }

    const v_step_log: u6 = @intCast(62 - table_log);
    const mid: u64 = (@as(u64, 1) << (v_step_log - 1)) - 1;
    // Scaled on the remaining total.
    const total_u32: u32 = @truncate(total);
    const r_step: u64 = ((@as(u64, 1) << v_step_log) * to_distribute + mid) / total_u32;
    var tmp_total: u64 = mid;
    for (count[0 .. max_symbol_value + 1], norm[0 .. max_symbol_value + 1]) |c, *n| {
        if (n.* == not_yet_assigned) {
            const end = tmp_total + c * r_step;
            const s_start: u32 = @truncate(tmp_total >> v_step_log);
            const s_end: u32 = @truncate(end >> v_step_log);
            const weight = s_end - s_start;
            if (weight < 1) return error.Generic;
            n.* = @intCast(weight);
            tmp_total = end;
        }
    }
}

/// `FSE_normalizeCount`: scales `count` (summing to `total`) to a
/// distribution summing to `1 << table_log`. Returns the table log, or 0 if
/// one symbol has every count, for RLE. With `use_low_prob_count`, rare
/// symbols get -1, a cell of their own that resets the state.
pub fn normalizeCount(
    normalized_counter: []i16,
    table_log_in: u32,
    count: []const u32,
    total: usize,
    max_symbol_value: u32,
    use_low_prob_count: bool,
) Error!u32 {
    var table_log = table_log_in;
    if (table_log == 0) table_log = fse.default_table_log;
    if (table_log < fse.min_table_log) return error.Generic;
    if (table_log > fse.max_table_log) return error.TableLogTooLarge;
    // Too small a table log: compression is potentially impossible.
    if (table_log < minTableLog(total, max_symbol_value)) return error.Generic;

    const rtb_table = [_]u32{ 0, 473195, 504333, 520860, 550000, 700000, 750000, 830000 };
    const low_prob_count: i16 = if (use_low_prob_count) -1 else 1;
    const scale: u6 = @intCast(62 - table_log);
    const total_u32: u32 = @truncate(total);
    const step: u64 = (@as(u64, 1) << 62) / total_u32;
    const v_step: u64 = @as(u64, 1) << (scale - 20);
    var still_to_distribute: i32 = @as(i32, 1) << @intCast(table_log);
    var largest: usize = 0;
    var largest_p: i16 = 0;
    const low_threshold: u32 = @truncate(total >> @intCast(table_log));

    for (count[0 .. max_symbol_value + 1], 0..) |c, s| {
        // One symbol has every count: RLE.
        if (c == total) return 0;
        if (c == 0) {
            normalized_counter[s] = 0;
            continue;
        }
        if (c <= low_threshold) {
            normalized_counter[s] = low_prob_count;
            still_to_distribute -= 1;
        } else {
            var proba: i16 = @intCast((c * step) >> scale);
            if (proba < 8) {
                const rest_to_beat = v_step * rtb_table[@intCast(proba)];
                const rest = c * step - (@as(u64, @intCast(proba)) << scale);
                proba += @intFromBool(rest > rest_to_beat);
            }
            if (proba > largest_p) {
                largest_p = proba;
                largest = s;
            }
            normalized_counter[s] = proba;
            still_to_distribute -= proba;
        }
    }
    if (-still_to_distribute >= (normalized_counter[largest] >> 1)) {
        // A corner case: the other method.
        try normalizeM2(
            normalized_counter,
            table_log,
            count,
            total,
            max_symbol_value,
            low_prob_count,
        );
    } else {
        normalized_counter[largest] += @intCast(still_to_distribute);
    }
    return table_log;
}

/// `FSE_buildCTable_rle`: a table that always encodes `symbol_value`, in
/// no bits.
pub fn buildCTableRle(ct: []u32, symbol_value: u8) void {
    assert(ct.len >= 2 + 2 * (@as(usize, symbol_value) + 1));
    const table_u16 = tableU16(ct.ptr);
    const symbol_tt: [*]SymbolTransform = @ptrCast(ct.ptr + 2);
    (table_u16 - 2)[0] = 0;
    (table_u16 - 1)[0] = symbol_value;
    table_u16[0] = 0;
    table_u16[1] = 0;
    symbol_tt[symbol_value] = .{ .delta_find_state = 0, .delta_nb_bits = 0 };
}

inline fn flushBits(bit_c: *bitstream.CStream, comptime fast: bool) void {
    if (fast) bit_c.flushBitsFast() else bit_c.flushBits();
}

/// `FSE_compress_usingCTable_generic`.
fn compressUsingCTableGeneric(
    dst: []u8,
    src: []const u8,
    ct: []const u32,
    comptime fast: bool,
) usize {
    if (src.len <= 2) return 0;
    // Not enough room for a bit stream.
    var bit_c = bitstream.CStream.init(dst) catch return 0;
    var ip: usize = src.len;
    var state1: CState = undefined;
    var state2: CState = undefined;

    const container_bits = @bitSizeOf(bitstream.Container);

    if (src.len & 1 != 0) {
        state1 = .initWithSymbol(ct, src[ip - 1]);
        state2 = .initWithSymbol(ct, src[ip - 2]);
        ip -= 3;
        encodeSymbol(&bit_c, &state1, src[ip]);
        flushBits(&bit_c, fast);
    } else {
        state2 = .initWithSymbol(ct, src[ip - 1]);
        state1 = .initWithSymbol(ct, src[ip - 2]);
        ip -= 2;
    }

    // Join to a multiple of 4.
    const size = src.len - 2;
    if (container_bits > fse.max_table_log * 4 + 7 and size & 2 != 0) {
        encodeSymbol(&bit_c, &state2, src[ip - 1]);
        encodeSymbol(&bit_c, &state1, src[ip - 2]);
        ip -= 2;
        flushBits(&bit_c, fast);
    }

    // Two or four symbols per loop.
    while (ip > 0) {
        ip -= 1;
        encodeSymbol(&bit_c, &state2, src[ip]);
        if (container_bits < fse.max_table_log * 2 + 7) flushBits(&bit_c, fast);
        ip -= 1;
        encodeSymbol(&bit_c, &state1, src[ip]);
        if (container_bits > fse.max_table_log * 4 + 7) {
            encodeSymbol(&bit_c, &state2, src[ip - 1]);
            encodeSymbol(&bit_c, &state1, src[ip - 2]);
            ip -= 2;
        }
        flushBits(&bit_c, fast);
    }

    flushCState(&bit_c, &state2);
    flushCState(&bit_c, &state1);
    return bit_c.close();
}

/// `FSE_compress_usingCTable`: encodes `src` with `ct`, which must hold
/// every byte of it. Returns the size written, or 0 if it does not fit or
/// `src` has at most 2 bytes.
pub fn compressUsingCTable(dst: []u8, src: []const u8, ct: []const u32) usize {
    if (dst.len >= fse.blockBound(src.len)) return compressUsingCTableGeneric(dst, src, ct, true);
    return compressUsingCTableGeneric(dst, src, ct, false);
}

/// `FSE_compressBound`.
pub fn compressBound(size: usize) usize {
    return fse.compressBound(size);
}

/// `FSE_CState_t`: the state of one encoder over a table. It points into
/// the table, and is valid while the table is unchanged.
pub const CState = struct {
    value: isize,
    state_table: [*]const u16,
    symbol_tt: [*]const SymbolTransform,
    state_log: u32,

    /// `FSE_initCState`.
    pub fn init(ct: []const u32) CState {
        const table_log: u32 = @as([*]const u16, @ptrCast(ct.ptr))[0];
        const ct_ptr: [*]u32 = @constCast(ct.ptr);
        return .{
            .value = @as(isize, 1) << @intCast(table_log),
            .state_table = tableU16(ct_ptr),
            .symbol_tt = symbolTransforms(ct_ptr, table_log),
            .state_log = table_log,
        };
    }

    /// `FSE_initCState2`: as `init`, but the first symbol encoded, `symbol`
    /// (the last one decoded), takes the smallest state, which costs no
    /// bits.
    pub fn initWithSymbol(ct: []const u32, symbol: u32) CState {
        var state: CState = .init(ct);
        const symbol_tt = state.symbol_tt[symbol];
        const nb_bits_out = (symbol_tt.delta_nb_bits + (1 << 15)) >> 16;
        const value = (nb_bits_out << 16) - symbol_tt.delta_nb_bits;
        const index = @as(isize, value >> @intCast(nb_bits_out)) + symbol_tt.delta_find_state;
        state.value = state.state_table[@intCast(index)];
        return state;
    }
};

/// `FSE_encodeSymbol`: at most `table_log` bits; the caller flushes.
pub inline fn encodeSymbol(bit_c: *bitstream.CStream, state: *CState, symbol: u32) void {
    const symbol_tt = state.symbol_tt[symbol];
    const nb_bits_out: u32 = @intCast((state.value + symbol_tt.delta_nb_bits) >> 16);
    bit_c.addBits(@bitCast(state.value), nb_bits_out);
    const index = (state.value >> @intCast(nb_bits_out)) + symbol_tt.delta_find_state;
    state.value = state.state_table[@intCast(index)];
}

/// `FSE_flushCState`: writes the final state, which the decoder reads first.
pub fn flushCState(bit_c: *bitstream.CStream, state: *const CState) void {
    bit_c.addBits(@bitCast(state.value), state.state_log);
    bit_c.flushBits();
}

/// `FSE_getMaxNbBits`: the most bits `symbol_value` costs, rounded up; an
/// absent symbol costs `table_log + 1`.
pub fn getMaxNbBits(symbol_tt: [*]const SymbolTransform, symbol_value: u32) u32 {
    return (symbol_tt[symbol_value].delta_nb_bits + ((1 << 16) - 1)) >> 16;
}

/// `FSE_bitCost`: the approximate cost of `symbol_value`, in fixed point
/// with `accuracy_log` fractional bits; an absent symbol costs
/// `table_log + 1`.
pub fn bitCost(
    symbol_tt: [*]const SymbolTransform,
    table_log: u32,
    symbol_value: u32,
    accuracy_log: u32,
) u32 {
    const delta_nb_bits = symbol_tt[symbol_value].delta_nb_bits;
    const min_nb_bits = delta_nb_bits >> 16;
    const threshold = (min_nb_bits + 1) << 16;
    assert(table_log < 16);
    assert(accuracy_log < 31 - table_log);
    const table_size = @as(u32, 1) << @intCast(table_log);
    const delta_from_threshold = threshold - (delta_nb_bits + table_size);
    // A linear interpolation, very approximate.
    const scaled = delta_from_threshold << @intCast(accuracy_log);
    const normalized_delta = scaled >> @intCast(table_log);
    const bit_multiplier = @as(u32, 1) << @intCast(accuracy_log);
    assert(normalized_delta <= bit_multiplier);
    return (min_nb_bits + 1) * bit_multiplier - normalized_delta;
}

// --------------------------------------------------------
// Tests
// --------------------------------------------------------

const testing = std.testing;

test "a normalized distribution sums to the table size" {
    const count = [_]u32{ 100, 1, 0, 50, 7, 3, 300 };
    var norm: [count.len]i16 = undefined;
    var total: usize = 0;
    for (count) |c| total += c;
    const table_log = try normalizeCount(&norm, 6, &count, total, count.len - 1, true);
    var sum: i32 = 0;
    for (norm) |n| sum += @abs(n);
    try testing.expectEqual(@as(i32, 1) << @intCast(table_log), sum);
}

test "a single symbol normalizes to RLE" {
    const count = [_]u32{ 0, 9, 0 };
    var norm: [count.len]i16 = undefined;
    try testing.expectEqual(@as(u32, 0), try normalizeCount(&norm, 5, &count, 9, 2, false));
}
