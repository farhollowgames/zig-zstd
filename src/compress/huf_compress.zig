//! The Huffman encoder, from the original's huf_compress.c.
//!
//! A compression table (`CTable`, `huf.CElt` units) keeps the original's
//! layout, since other parts store, compare and copy it: a header entry
//! (table log in the first byte, largest symbol in the second), then one
//! entry per symbol, its bit count in the low byte and its code in the top
//! bits.

const std = @import("std");
const assert = std.debug.assert;
const Error = @import("../error.zig").Error;
const fse = @import("../common/fse.zig");
const huf = @import("../common/huf.zig");
const bitstream = @import("../common/bitstream.zig");
const hot_code_align = @import("../common/zstd_internal.zig").hot_code_align;
const entropy_common = @import("../common/entropy_common.zig");
const fse_compress = @import("fse_compress.zig");
const hist = @import("hist.zig");
const highbit32 = bitstream.highbit32;

const CElt = huf.CElt;
const celt_bits = @bitSizeOf(CElt);

/// `HUF_alignUpWorkspace`: `workspace` from its first address aligned on
/// `alignment`, or an empty slice if it is too short to reach it.
fn alignUpWorkspace(workspace: []u8, alignment: usize) []u8 {
    const add = (alignment - (@intFromPtr(workspace.ptr) & (alignment - 1))) & (alignment - 1);
    if (workspace.len >= add) return workspace[add..];
    return workspace[workspace.len..];
}

fn workspaceAs(comptime T: type, workspace: []u8) *T {
    return @ptrCast(@alignCast(workspace.ptr));
}

const max_fse_table_log_for_huff_header = 6;

/// `HUF_CompressWeightsWksp`.
const CompressWeightsWksp = extern struct {
    ctable: [fse.ctableSizeU32(max_fse_table_log_for_huff_header, huf.table_log_max)]u32,
    scratch_buffer: [
        fse.buildCTableWorkspaceSizeU32(huf.table_log_max, max_fse_table_log_for_huff_header)
    ]u32,
    count: [huf.table_log_max + 1]u32,
    norm: [huf.table_log_max + 1]i16,
};

/// `HUF_compressWeights`: FSE-compresses the weights, with a small table.
/// Returns 0 if they do not compress, 1 if they are all the same.
fn compressWeights(dst: []u8, weight_table: []const u8, workspace_in: []u8) Error!usize {
    const workspace = alignUpWorkspace(workspace_in, @alignOf(u32));
    if (workspace.len < @sizeOf(CompressWeightsWksp)) return error.Generic;
    const wksp = workspaceAs(CompressWeightsWksp, workspace);
    var max_symbol_value: u32 = huf.table_log_max;
    var table_log: u32 = max_fse_table_log_for_huff_header;

    if (weight_table.len <= 1) return 0;

    const max_count = hist.countSimple(&wksp.count, &max_symbol_value, weight_table);
    // A single symbol: RLE.
    if (max_count == weight_table.len) return 1;
    // Each symbol at most once: not compressible.
    if (max_count == 1) return 0;

    table_log = fse_compress.optimalTableLog(table_log, weight_table.len, max_symbol_value);
    _ = try fse_compress.normalizeCount(
        &wksp.norm,
        table_log,
        &wksp.count,
        weight_table.len,
        max_symbol_value,
        false,
    );

    var op: usize = 0;
    op += try fse_compress.writeNCount(dst[op..], &wksp.norm, max_symbol_value, table_log);

    try fse_compress.buildCTableWksp(
        &wksp.ctable,
        &wksp.norm,
        max_symbol_value,
        table_log,
        std.mem.asBytes(&wksp.scratch_buffer),
    );
    const c_size = fse_compress.compressUsingCTable(dst[op..], weight_table, &wksp.ctable);
    // Not enough room for the compressed weights.
    if (c_size == 0) return 0;
    op += c_size;
    return op;
}

fn getNbBits(elt: CElt) usize {
    return elt & 0xFF;
}

fn getValue(elt: CElt) usize {
    return elt & ~@as(usize, 0xFF);
}

fn setNbBits(elt: *CElt, nb_bits: usize) void {
    assert(nb_bits <= huf.table_log_absolute_max);
    elt.* = nb_bits;
}

fn setValue(elt: *CElt, value: usize) void {
    const nb_bits = getNbBits(elt.*);
    if (nb_bits > 0) {
        assert(value >> @intCast(nb_bits) == 0);
        elt.* |= value << @intCast(celt_bits - nb_bits);
    }
}

/// `HUF_CTableHeader`: the first entry of a table.
pub const CTableHeader = struct {
    table_log: u8,
    max_symbol_value: u8,
};

/// `HUF_readCTableHeader`.
pub fn readCTableHeader(ctable: []const CElt) CTableHeader {
    const bytes = std.mem.asBytes(&ctable[0]);
    return .{ .table_log = bytes[0], .max_symbol_value = bytes[1] };
}

fn writeCTableHeader(ctable: []CElt, table_log: u32, max_symbol_value: u32) void {
    ctable[0] = 0;
    const bytes = std.mem.asBytes(&ctable[0]);
    bytes[0] = @intCast(table_log);
    bytes[1] = @intCast(max_symbol_value);
}

/// `HUF_WriteCTableWksp`.
const WriteCTableWksp = extern struct {
    wksp: CompressWeightsWksp,
    bits_to_weight: [huf.table_log_max + 1]u8,
    huff_weight: [huf.symbol_value_max]u8,
};

/// `HUF_writeCTable_wksp`: writes the table's description, its weights
/// FSE-compressed or else raw, and returns its size. `workspace` holds
/// `huf.ctable_workspace_size` bytes.
pub fn writeCTableWksp(
    dst: []u8,
    ctable: []const CElt,
    max_symbol_value: u32,
    huff_log: u32,
    workspace_in: []u8,
) Error!usize {
    const ct = ctable[1..];
    const workspace = alignUpWorkspace(workspace_in, @alignOf(u32));
    comptime assert(huf.ctable_workspace_size >= @sizeOf(WriteCTableWksp));
    assert(readCTableHeader(ctable).max_symbol_value == max_symbol_value);
    assert(readCTableHeader(ctable).table_log == huff_log);

    if (workspace.len < @sizeOf(WriteCTableWksp)) return error.Generic;
    if (max_symbol_value > huf.symbol_value_max) return error.MaxSymbolValueTooLarge;
    const wksp = workspaceAs(WriteCTableWksp, workspace);

    // Bit counts to weights.
    wksp.bits_to_weight[0] = 0;
    for (1..huff_log + 1) |n| wksp.bits_to_weight[n] = @intCast(huff_log + 1 - n);
    for (wksp.huff_weight[0..max_symbol_value], ct[0..max_symbol_value]) |*weight, elt| {
        weight.* = wksp.bits_to_weight[getNbBits(elt)];
    }

    // Try compressing the weights with FSE.
    if (dst.len < 1) return error.DstSizeTooSmall;
    const h_size = try compressWeights(
        dst[1..],
        wksp.huff_weight[0..max_symbol_value],
        std.mem.asBytes(&wksp.wksp),
    );
    if (h_size > 1 and h_size < max_symbol_value / 2) {
        dst[0] = @intCast(h_size);
        return h_size + 1;
    }

    // Raw weights, 4 bits each (at most 15). Too many symbols means the
    // source should not have been compressed.
    if (max_symbol_value > (256 - 128)) return error.Generic;
    if ((max_symbol_value + 1) / 2 + 1 > dst.len) return error.DstSizeTooSmall;
    // Wraps for a table of one symbol, as the original's byte does.
    dst[0] = @truncate(128 +% (max_symbol_value -% 1));
    // Pairs the last weight with a defined value.
    wksp.huff_weight[max_symbol_value] = 0;
    var n: usize = 0;
    while (n < max_symbol_value) : (n += 2) {
        dst[n / 2 + 1] = (wksp.huff_weight[n] << 4) + wksp.huff_weight[n + 1];
    }
    return (max_symbol_value + 1) / 2 + 1;
}

/// `HUF_readCTable`: reads a table's description, as `writeCTableWksp`
/// writes it, into `ctable`, and returns its size. Sets
/// `max_symbol_value_ptr` to the table's largest symbol, which must be at
/// most its value on entry, and `has_zero_weights` to whether some symbol
/// up to it has no code.
pub fn readCTable(
    ctable: []CElt,
    max_symbol_value_ptr: *u32,
    src: []const u8,
    has_zero_weights: *bool,
) Error!usize {
    var huff_weight: [huf.symbol_value_max + 1]u8 = undefined;
    var rank_val: [huf.table_log_absolute_max + 1]u32 = undefined;
    var table_log: u32 = 0;
    var nb_symbols: u32 = 0;
    const ct = ctable[1..];

    const read_size = try entropy_common.readStats(
        &huff_weight,
        &rank_val,
        &nb_symbols,
        &table_log,
        src,
    );
    has_zero_weights.* = rank_val[0] > 0;

    if (table_log > huf.table_log_max) return error.TableLogTooLarge;
    if (nb_symbols > max_symbol_value_ptr.* + 1) return error.MaxSymbolValueTooSmall;

    max_symbol_value_ptr.* = nb_symbols - 1;
    writeCTableHeader(ctable, table_log, max_symbol_value_ptr.*);

    // Bit counts.
    for (ct[0..nb_symbols], huff_weight[0..nb_symbols]) |*elt, weight| {
        setNbBits(elt, if (weight != 0) table_log + 1 - weight else 0);
    }

    // Codes.
    var nb_per_rank: [huf.table_log_max + 2]u16 = @splat(0);
    var val_per_rank: [huf.table_log_max + 2]u16 = @splat(0);
    for (ct[0..nb_symbols]) |elt| nb_per_rank[getNbBits(elt)] += 1;
    // The first code of each rank.
    var min: u16 = 0;
    var n = table_log;
    while (n > 0) : (n -= 1) {
        val_per_rank[n] = min;
        min += nb_per_rank[n];
        min >>= 1;
    }
    // Codes within a rank, in symbol order.
    for (ct[0..nb_symbols]) |*elt| {
        const rank = getNbBits(elt.*);
        setValue(elt, val_per_rank[rank]);
        val_per_rank[rank] += 1;
    }
    return read_size;
}

/// `HUF_getNbBitsFromCTable`: the bit count of `symbol_value`'s code, or 0
/// for a symbol beyond the table.
pub fn getNbBitsFromCTable(ctable: []const CElt, symbol_value: u32) u32 {
    assert(symbol_value <= huf.symbol_value_max);
    if (symbol_value > readCTableHeader(ctable).max_symbol_value) return 0;
    return @intCast(getNbBits(ctable[1 + symbol_value]));
}

/// `nodeElt`: a node of the Huffman tree.
const NodeElt = extern struct {
    count: u32,
    parent: u16,
    byte: u8,
    nb_bits: u8,
};

/// Node `n` of the tree, which starts one past the table's first entry, so
/// that index -1 is the table's barrier entry.
inline fn node(huff_node: [*]NodeElt, n: i32) *NodeElt {
    return &(huff_node - 1)[@intCast(n + 1)];
}

/// `HUF_setMaxHeight`: limits the tree in `huff_node`, sorted from the most
/// frequent symbol to the rarest (`last_non_null`), to `target_nb_bits`,
/// keeping it a valid canonical tree. Returns the largest bit count after.
fn setMaxHeight(huff_node: [*]NodeElt, last_non_null: u32, target_nb_bits: u32) u32 {
    const largest_bits: u32 = huff_node[last_non_null].nb_bits;
    // No symbol over the limit: the tree is already valid.
    if (largest_bits <= target_nb_bits) return largest_bits;

    // Several symbols are over the limit, at least 2.
    var total_cost: i32 = 0;
    const base_cost = @as(u32, 1) << @intCast(largest_bits - target_nb_bits);
    var n: i32 = @intCast(last_non_null);

    // Lower every rank over the limit to it, and add up how far the sum of
    // the ranks is then over 2^largest_bits.
    while (node(huff_node, n).nb_bits > target_nb_bits) {
        const rank_cost = @as(u32, 1) << @intCast(largest_bits - node(huff_node, n).nb_bits);
        const cost = base_cost - rank_cost;
        total_cost += @intCast(cost);
        node(huff_node, n).nb_bits = @intCast(target_nb_bits);
        n -= 1;
    }
    assert(node(huff_node, n).nb_bits <= target_nb_bits);
    // n ends at the smallest symbol using fewer than target_nb_bits.
    while (node(huff_node, n).nb_bits == target_nb_bits) n -= 1;

    // Scale the cost from 2^largest_bits to 2^target_nb_bits; it is a
    // multiple of base_cost.
    assert(@as(u32, @bitCast(total_cost)) & (base_cost - 1) == 0);
    total_cost >>= @intCast(largest_bits - target_nb_bits);
    assert(total_cost > 0);

    // Repay the cost.
    const no_symbol: u32 = 0xF0F0F0F0;
    var rank_last: [huf.table_log_max + 2]u32 = @splat(no_symbol);

    // The position of the last (smallest) symbol of each rank.
    {
        var current_nb_bits = target_nb_bits;
        var pos = n;
        while (pos >= 0) : (pos -= 1) {
            if (node(huff_node, pos).nb_bits >= current_nb_bits) continue;
            current_nb_bits = node(huff_node, pos).nb_bits;
            rank_last[target_nb_bits - current_nb_bits] = @intCast(pos);
        }
    }

    while (total_cost > 0) {
        // Try to lower the next power of 2 above total_cost, since that
        // gains back half the rank.
        var nb_bits_to_decrease = highbit32(@intCast(total_cost)) + 1;
        while (nb_bits_to_decrease > 1) : (nb_bits_to_decrease -= 1) {
            const high_pos = rank_last[nb_bits_to_decrease];
            const low_pos = rank_last[nb_bits_to_decrease - 1];
            if (high_pos == no_symbol) continue;
            // Lower high_pos if lowPos has no symbols, or if removing two
            // of them costs no less.
            if (low_pos == no_symbol) break;
            const high_total = huff_node[high_pos].count;
            const low_total = 2 * huff_node[low_pos].count;
            if (high_total <= low_total) break;
        }
        // Only when no rank-1 symbol is left: find the closest; there is
        // one.
        assert(rank_last[nb_bits_to_decrease] != no_symbol or nb_bits_to_decrease == 1);
        while (nb_bits_to_decrease <= huf.table_log_max and
            rank_last[nb_bits_to_decrease] == no_symbol)
        {
            nb_bits_to_decrease += 1;
        }
        assert(rank_last[nb_bits_to_decrease] != no_symbol);
        // One more bit gains back half the rank's cost.
        total_cost -= @as(i32, 1) << @intCast(nb_bits_to_decrease - 1);
        huff_node[rank_last[nb_bits_to_decrease]].nb_bits += 1;

        // The new rank: if it was empty, this symbol is now its smallest;
        // otherwise this symbol is its largest, and nothing changes.
        if (rank_last[nb_bits_to_decrease - 1] == no_symbol) {
            rank_last[nb_bits_to_decrease - 1] = rank_last[nb_bits_to_decrease];
        }
        // The old rank: a symbol at position 0, the most frequent, was alone
        // in its rank, which is now empty. Otherwise the previous position,
        // the nodes being sorted, is now the rank's smallest, unless it is
        // in another rank, and this one is empty.
        if (rank_last[nb_bits_to_decrease] == 0) {
            rank_last[nb_bits_to_decrease] = no_symbol;
        } else {
            rank_last[nb_bits_to_decrease] -= 1;
            if (huff_node[rank_last[nb_bits_to_decrease]].nb_bits !=
                target_nb_bits - nb_bits_to_decrease)
            {
                rank_last[nb_bits_to_decrease] = no_symbol;
            }
        }
    }

    // The correction can overshoot: then give back weight from the
    // smallest rank only, moving its largest nodes from rank 0 to rank 1.
    while (total_cost < 0) {
        if (rank_last[1] == no_symbol) {
            // No rank-1 symbol: make one from the largest of rank 0.
            while (node(huff_node, n).nb_bits == target_nb_bits) n -= 1;
            node(huff_node, n + 1).nb_bits -= 1;
            assert(n >= 0);
            rank_last[1] = @intCast(n + 1);
            total_cost += 1;
            continue;
        }
        huff_node[rank_last[1] + 1].nb_bits -= 1;
        rank_last[1] += 1;
        total_cost += 1;
    }
    return target_nb_bits;
}

/// `rankPos`.
const RankPos = extern struct {
    base: u16,
    curr: u16,
};

/// The buckets `sort` uses.
const rank_position_table_size = 192;

/// `HUF_buildCTable_wksp_tables`.
const BuildCTableWkspTables = extern struct {
    huff_node_tbl: [2 * (huf.symbol_value_max + 1)]NodeElt,
    rank_position: [rank_position_table_size]RankPos,
};

comptime {
    assert(@sizeOf(BuildCTableWkspTables) == huf.ctable_workspace_size);
}

// Buckets 0 to 165 hold one count each; the rest hold counts by their log2,
// up to `rank_position_max_count_log`.
const rank_position_max_count_log = 32;
const rank_position_log_buckets_begin = (rank_position_table_size - 1) -
    rank_position_max_count_log - 1;
const rank_position_distinct_count_cutoff = rank_position_log_buckets_begin +
    @as(u32, std.math.log2_int(u32, rank_position_log_buckets_begin));

/// `HUF_getIndex`: the bucket of `count`.
fn getIndex(count: u32) u32 {
    if (count < rank_position_distinct_count_cutoff) return count;
    return highbit32(count) + rank_position_log_buckets_begin;
}

/// `HUF_insertionSort`: by decreasing count.
fn insertionSort(huff_node: []NodeElt, low: i32, high: i32) void {
    const size = high - low + 1;
    const nodes = huff_node[@intCast(low)..];
    var i: i32 = 1;
    while (i < size) : (i += 1) {
        const key = nodes[@intCast(i)];
        var j = i - 1;
        while (j >= 0 and nodes[@intCast(j)].count < key.count) : (j -= 1) {
            nodes[@intCast(j + 1)] = nodes[@intCast(j)];
        }
        nodes[@intCast(j + 1)] = key;
    }
}

/// `HUF_swapNodes`, through a temporary: std.mem.swap goes byte by byte.
inline fn swapNodes(a: *NodeElt, b: *NodeElt) void {
    const tmp = a.*;
    a.* = b.*;
    b.* = tmp;
}

/// `HUF_quickSortPartition`: around the rightmost element.
fn quickSortPartition(arr: []NodeElt, low: i32, high: i32) i32 {
    const pivot = arr[@intCast(high)].count;
    var i = low - 1;
    var j = low;
    while (j < high) : (j += 1) {
        if (arr[@intCast(j)].count > pivot) {
            i += 1;
            swapNodes(&arr[@intCast(i)], &arr[@intCast(j)]);
        }
    }
    swapNodes(&arr[@intCast(i + 1)], &arr[@intCast(high)]);
    return i + 1;
}

/// `HUF_simpleQuickSort`: by decreasing count, recursing on the smaller
/// side only.
fn simpleQuickSort(arr: []NodeElt, low_in: i32, high_in: i32) void {
    const insertion_sort_threshold = 8;
    var low = low_in;
    var high = high_in;
    if (high - low < insertion_sort_threshold) {
        insertionSort(arr, low, high);
        return;
    }
    while (low < high) {
        const idx = quickSortPartition(arr, low, high);
        if (idx - low < high - idx) {
            simpleQuickSort(arr, low, idx - 1);
            low = idx + 1;
        } else {
            simpleQuickSort(arr, idx + 1, high);
            high = idx - 1;
        }
    }
}

/// `HUF_sort`: sorts the symbols by decreasing count into `huff_node`,
/// filling only `count` and `byte`: a bucket sort, each bucket of large
/// counts then sorted on its own.
fn sort(
    huff_node: []NodeElt,
    count: []const u32,
    max_symbol_value: u32,
    rank_position: *[rank_position_table_size]RankPos,
) void {
    const max_symbol_value1 = max_symbol_value + 1;

    // Each symbol counts toward the base of the bucket below its own, so
    // that a bucket's base is where it begins in the output.
    @memset(rank_position, .{ .base = 0, .curr = 0 });
    for (count[0..max_symbol_value1]) |c| {
        const lower_rank = getIndex(c);
        assert(lower_rank < rank_position_table_size - 1);
        rank_position[lower_rank].base += 1;
    }
    assert(rank_position[rank_position_table_size - 1].base == 0);
    var n: usize = rank_position_table_size - 1;
    while (n > 0) : (n -= 1) {
        rank_position[n - 1].base += rank_position[n].base;
        rank_position[n - 1].curr = rank_position[n - 1].base;
    }

    // Each symbol into its bucket.
    for (count[0..max_symbol_value1], 0..) |c, symbol| {
        const r = getIndex(c) + 1;
        const pos = rank_position[r].curr;
        rank_position[r].curr += 1;
        assert(pos < max_symbol_value1);
        huff_node[pos].count = c;
        huff_node[pos].byte = @intCast(symbol);
    }

    // Sort each bucket of large counts.
    for (rank_position_distinct_count_cutoff..rank_position_table_size - 1) |r| {
        const bucket_size: i32 = @as(i32, rank_position[r].curr) - rank_position[r].base;
        const bucket_start = rank_position[r].base;
        if (bucket_size > 1) {
            assert(bucket_start < max_symbol_value1);
            simpleQuickSort(huff_node[bucket_start..], 0, bucket_size - 1);
        }
    }
}

const start_node = huf.symbol_value_max + 1;

/// `HUF_buildTree`: builds a Huffman tree of unlimited depth in
/// `huff_node`, sorted by `sort`. Returns the position of the smallest
/// symbol.
fn buildTree(huff_node: [*]NodeElt, max_symbol_value: u32) i32 {
    var node_nb: i32 = start_node;

    // The first parent.
    var non_null_rank: i32 = @intCast(max_symbol_value);
    while (node(huff_node, non_null_rank).count == 0) non_null_rank -= 1;
    var low_s = non_null_rank;
    const node_root = node_nb + low_s - 1;
    var low_n = node_nb;
    const first_count = node(huff_node, low_s).count + node(huff_node, low_s - 1).count;
    node(huff_node, node_nb).count = first_count;
    node(huff_node, low_s).parent = @intCast(node_nb);
    node(huff_node, low_s - 1).parent = @intCast(node_nb);
    node_nb += 1;
    low_s -= 2;
    var n = node_nb;
    while (n <= node_root) : (n += 1) node(huff_node, n).count = 1 << 30;
    // A barrier no count reaches.
    node(huff_node, -1).count = 1 << 31;

    // The other parents.
    while (node_nb <= node_root) {
        const n1 = pickSmaller(huff_node, &low_s, &low_n);
        const n2 = pickSmaller(huff_node, &low_s, &low_n);
        node(huff_node, node_nb).count = node(huff_node, n1).count + node(huff_node, n2).count;
        node(huff_node, n1).parent = @intCast(node_nb);
        node(huff_node, n2).parent = @intCast(node_nb);
        node_nb += 1;
    }

    // Bit counts, of unlimited height.
    node(huff_node, node_root).nb_bits = 0;
    n = node_root - 1;
    while (n >= start_node) : (n -= 1) {
        node(huff_node, n).nb_bits = huff_node[node(huff_node, n).parent].nb_bits + 1;
    }
    n = 0;
    while (n <= non_null_rank) : (n += 1) {
        node(huff_node, n).nb_bits = huff_node[node(huff_node, n).parent].nb_bits + 1;
    }
    return non_null_rank;
}

/// The smaller of the next symbol and the next parent, moving past it.
inline fn pickSmaller(huff_node: [*]NodeElt, low_s: *i32, low_n: *i32) i32 {
    if (node(huff_node, low_s.*).count < node(huff_node, low_n.*).count) {
        low_s.* -= 1;
        return low_s.* + 1;
    }
    low_n.* += 1;
    return low_n.* - 1;
}

/// `HUF_buildCTableFromTree`: the table of the tree in `huff_node`, whose
/// largest bit count is `max_nb_bits`.
fn buildCTableFromTree(
    ctable: []CElt,
    huff_node: [*]const NodeElt,
    non_null_rank: i32,
    max_symbol_value: u32,
    max_nb_bits: u32,
) void {
    const ct = ctable[1..];
    var nb_per_rank: [huf.table_log_max + 1]u16 = @splat(0);
    var val_per_rank: [huf.table_log_max + 1]u16 = @splat(0);
    const alphabet_size = max_symbol_value + 1;
    for (huff_node[0..@intCast(non_null_rank + 1)]) |n| nb_per_rank[n.nb_bits] += 1;
    // The first code of each rank.
    var min: u16 = 0;
    var n = max_nb_bits;
    while (n > 0) : (n -= 1) {
        val_per_rank[n] = min;
        min += nb_per_rank[n];
        min >>= 1;
    }
    // Bit counts in symbol order, then codes within each rank.
    for (huff_node[0..alphabet_size]) |sorted| setNbBits(&ct[sorted.byte], sorted.nb_bits);
    for (ct[0..alphabet_size]) |*elt| {
        const rank = getNbBits(elt.*);
        setValue(elt, val_per_rank[rank]);
        val_per_rank[rank] += 1;
    }
    writeCTableHeader(ctable, max_nb_bits, max_symbol_value);
}

/// `HUF_buildCTable_wksp`: builds `ctable` from `count`, with codes of at
/// most `max_nb_bits` bits (0 for the default), and returns the largest bit
/// count. `count` needs two symbols with a count. `workspace` holds
/// `huf.ctable_workspace_size` bytes.
pub fn buildCTableWksp(
    ctable: []CElt,
    count: []const u32,
    max_symbol_value: u32,
    max_nb_bits_in: u32,
    workspace_in: []u8,
) Error!u32 {
    const workspace = alignUpWorkspace(workspace_in, @alignOf(u32));
    if (workspace.len < @sizeOf(BuildCTableWkspTables)) return error.WorkSpaceTooSmall;
    const wksp_tables = workspaceAs(BuildCTableWkspTables, workspace);
    const huff_node0 = &wksp_tables.huff_node_tbl;
    const huff_node = huff_node0[1..];
    var max_nb_bits = max_nb_bits_in;

    if (max_nb_bits == 0) max_nb_bits = huf.table_log_default;
    if (max_symbol_value > huf.symbol_value_max) return error.MaxSymbolValueTooLarge;
    @memset(huff_node0, .{ .count = 0, .parent = 0, .byte = 0, .nb_bits = 0 });

    sort(huff_node, count, max_symbol_value, &wksp_tables.rank_position);
    const non_null_rank = buildTree(huff_node.ptr, max_symbol_value);
    max_nb_bits = setMaxHeight(huff_node.ptr, @intCast(non_null_rank), max_nb_bits);
    // The table must fit.
    if (max_nb_bits > huf.table_log_max) return error.Generic;
    buildCTableFromTree(ctable, huff_node.ptr, non_null_rank, max_symbol_value, max_nb_bits);
    return max_nb_bits;
}

/// `HUF_estimateCompressedSize`: the size of `count`'s symbols coded with
/// `ctable`, in whole bytes rounded down.
pub fn estimateCompressedSize(
    ctable: []const CElt,
    count: []const u32,
    max_symbol_value: u32,
) usize {
    const ct = ctable[1..];
    var nb_bits: usize = 0;
    for (ct[0 .. max_symbol_value + 1], count[0 .. max_symbol_value + 1]) |elt, c| {
        nb_bits += getNbBits(elt) * c;
    }
    return nb_bits >> 3;
}

/// `HUF_validateCTable`: whether `ctable` has a code for every symbol
/// `count` has.
pub fn validateCTable(ctable: []const CElt, count: []const u32, max_symbol_value: u32) bool {
    const header = readCTableHeader(ctable);
    const ct = ctable[1..];
    assert(header.table_log <= huf.table_log_absolute_max);
    if (header.max_symbol_value < max_symbol_value) return false;
    var bad = false;
    for (ct[0 .. max_symbol_value + 1], count[0 .. max_symbol_value + 1]) |elt, c| {
        bad = bad or (c != 0 and getNbBits(elt) == 0);
    }
    return !bad;
}

/// `HUF_compressBound`.
pub fn compressBound(size: usize) usize {
    return huf.compressBound(size);
}

/// `HUF_CStream_t`: Huffman's own bit stream. An entry is added whole: the
/// register shifts right by its bit count and takes its code in the top
/// bits. A second register fills without waiting on the first, then
/// merges into it. Its pointers are valid while the caller's buffer is.
const CStream = struct {
    bit_container: [2]usize,
    /// Only the low byte counts: adding a whole entry adds its code too.
    bit_pos: [2]usize,
    start_ptr: [*]u8,
    ptr: [*]u8,
    end_ptr: [*]u8,

    /// `HUF_initCStream`.
    fn init(dst: []u8) Error!CStream {
        if (dst.len <= @sizeOf(usize)) return error.DstSizeTooSmall;
        return .{
            .bit_container = .{ 0, 0 },
            .bit_pos = .{ 0, 0 },
            .start_ptr = dst.ptr,
            .ptr = dst.ptr,
            .end_ptr = dst.ptr + dst.len - @sizeOf(usize),
        };
    }

    /// `HUF_addBits`: with `fast`, the register must keep at least 4 bits
    /// free after, as the entry's bit count is added with its code.
    inline fn addBits(bit_c: *CStream, elt: CElt, comptime idx: usize, comptime fast: bool) void {
        assert(getNbBits(elt) <= huf.table_log_absolute_max);
        bit_c.bit_container[idx] >>= @intCast(getNbBits(elt));
        bit_c.bit_container[idx] |= if (fast) elt else getValue(elt);
        bit_c.bit_pos[idx] +%= elt;
        assert(bit_c.bit_pos[idx] & 0xFF <= celt_bits);
    }

    /// `HUF_zeroIndex1`.
    inline fn zeroIndex1(bit_c: *CStream) void {
        bit_c.bit_container[1] = 0;
        bit_c.bit_pos[1] = 0;
    }

    /// `HUF_mergeIndex1`: the second register into the first.
    inline fn mergeIndex1(bit_c: *CStream) void {
        assert(bit_c.bit_pos[1] & 0xFF < celt_bits);
        bit_c.bit_container[0] >>= @intCast(bit_c.bit_pos[1] & 0xFF);
        bit_c.bit_container[0] |= bit_c.bit_container[1];
        bit_c.bit_pos[0] +%= bit_c.bit_pos[1];
        assert(bit_c.bit_pos[0] & 0xFF <= celt_bits);
    }

    /// `HUF_flushBits`: with `fast`, the caller knows the buffer has room.
    inline fn flushBits(bit_c: *CStream, comptime fast: bool) void {
        const nb_bits = bit_c.bit_pos[0] & 0xFF;
        const nb_bytes = nb_bits >> 3;
        assert(nb_bits > 0);
        assert(nb_bits <= celt_bits);
        // The top nb_bits bits are the ones to write.
        const container = bit_c.bit_container[0] >> @intCast(celt_bits - nb_bits);
        bit_c.bit_pos[0] &= 7;
        assert(@intFromPtr(bit_c.ptr) <= @intFromPtr(bit_c.end_ptr));
        std.mem.writeInt(usize, bit_c.ptr[0..@sizeOf(usize)], container, .little);
        bit_c.ptr += nb_bytes;
        assert(!fast or @intFromPtr(bit_c.ptr) <= @intFromPtr(bit_c.end_ptr));
        if (!fast and @intFromPtr(bit_c.ptr) > @intFromPtr(bit_c.end_ptr)) {
            bit_c.ptr = bit_c.end_ptr;
        }
    }

    /// `HUF_closeCStream`: adds the end mark, a single 1 bit, and returns
    /// the stream's size, or 0 if it did not fit.
    fn close(bit_c: *CStream) usize {
        const end_mark: CElt = 1 | (@as(CElt, 1) << (celt_bits - 1));
        bit_c.addBits(end_mark, 0, false);
        bit_c.flushBits(false);
        const nb_bits = bit_c.bit_pos[0] & 0xFF;
        if (@intFromPtr(bit_c.ptr) >= @intFromPtr(bit_c.end_ptr)) return 0;
        const size = @intFromPtr(bit_c.ptr) - @intFromPtr(bit_c.start_ptr);
        return size + @intFromBool(nb_bits > 0);
    }
};

/// `HUF_compress1X_usingCTable_internal_body_loop`: encodes `src` backward,
/// `k_unroll` symbols per flush. `k_last_fast` says whether the last
/// symbol of each group may add its bit count with its code.
inline fn compress1XLoop(
    bit_c: *CStream,
    ip: [*]const u8,
    src_size: usize,
    ct: [*]const CElt,
    comptime k_unroll: i32,
    comptime k_fast_flush: bool,
    comptime k_last_fast: bool,
) void {
    var n: i32 = @intCast(src_size);
    // Join to a multiple of k_unroll.
    var rem = @rem(n, k_unroll);
    if (rem > 0) {
        while (rem > 0) : (rem -= 1) {
            n -= 1;
            bit_c.addBits(ct[ip[@intCast(n)]], 0, false);
        }
        bit_c.flushBits(k_fast_flush);
    }
    assert(@rem(n, k_unroll) == 0);

    // Join to a multiple of 2 * k_unroll.
    if (@rem(n, 2 * k_unroll) != 0) {
        inline for (1..k_unroll) |u| bit_c.addBits(ct[ip[@intCast(n - @as(i32, u))]], 0, true);
        bit_c.addBits(ct[ip[@intCast(n - k_unroll)]], 0, k_last_fast);
        bit_c.flushBits(k_fast_flush);
        n -= k_unroll;
    }
    assert(@rem(n, 2 * k_unroll) == 0);

    while (n > 0) : (n -= 2 * k_unroll) {
        // k_unroll symbols into the first register.
        inline for (1..k_unroll) |u| bit_c.addBits(ct[ip[@intCast(n - @as(i32, u))]], 0, true);
        bit_c.addBits(ct[ip[@intCast(n - k_unroll)]], 0, k_last_fast);
        bit_c.flushBits(k_fast_flush);
        // k_unroll into the second, which fills with no wait on the first.
        bit_c.zeroIndex1();
        inline for (1..k_unroll) |u| {
            bit_c.addBits(ct[ip[@intCast(n - k_unroll - @as(i32, u))]], 1, true);
        }
        bit_c.addBits(ct[ip[@intCast(n - k_unroll - k_unroll)]], 1, k_last_fast);
        bit_c.mergeIndex1();
        bit_c.flushBits(k_fast_flush);
    }
    assert(n == 0);
}

/// `HUF_tightCompressBound`: the most output Huffman can write, with 8
/// bytes for the overwrite; with this much room it needs no bounds checks.
fn tightCompressBound(src_size: usize, table_log: usize) usize {
    return ((src_size * table_log) >> 3) + 8;
}

/// `HUF_compress1X_usingCTable_internal_body`.
fn compress1XUsingCTableInternal(
    dst: []u8,
    src: []const u8,
    ctable: []const CElt,
) align(hot_code_align) usize {
    const table_log: u32 = readCTableHeader(ctable).table_log;
    const ct = ctable[1..].ptr;
    const ip = src.ptr;

    // Not enough room to compress.
    if (dst.len < 8) return 0;
    var bit_c = CStream.init(dst) catch return 0;

    if (dst.len < tightCompressBound(src.len, table_log) or table_log > 11) {
        const unroll = if (@sizeOf(usize) == 4) 2 else 4;
        compress1XLoop(&bit_c, ip, src.len, ct, unroll, false, false);
    } else if (@sizeOf(usize) == 4) {
        switch (table_log) {
            11 => compress1XLoop(&bit_c, ip, src.len, ct, 2, true, false),
            8...10 => compress1XLoop(&bit_c, ip, src.len, ct, 2, true, true),
            else => compress1XLoop(&bit_c, ip, src.len, ct, 3, true, true),
        }
    } else {
        switch (table_log) {
            11 => compress1XLoop(&bit_c, ip, src.len, ct, 5, true, false),
            10 => compress1XLoop(&bit_c, ip, src.len, ct, 5, true, true),
            9 => compress1XLoop(&bit_c, ip, src.len, ct, 6, true, false),
            8 => compress1XLoop(&bit_c, ip, src.len, ct, 7, true, false),
            7 => compress1XLoop(&bit_c, ip, src.len, ct, 8, true, false),
            else => compress1XLoop(&bit_c, ip, src.len, ct, 9, true, true),
        }
    }
    assert(@intFromPtr(bit_c.ptr) <= @intFromPtr(bit_c.end_ptr));
    return bit_c.close();
}

/// `HUF_compress1X_usingCTable`: one Huffman stream of `src`, whose every
/// byte must have a code in `ctable`. Returns its size, or 0 if it does not
/// fit.
pub fn compress1XUsingCTable(dst: []u8, src: []const u8, ctable: []const CElt) usize {
    return compress1XUsingCTableInternal(dst, src, ctable);
}

/// `HUF_compress4X_usingCTable_internal`: four streams, after a jump table
/// of their first three sizes. Returns 0 if `src` is too small to gain or a
/// stream does not fit.
fn compress4XUsingCTableInternal(dst: []u8, src: []const u8, ctable: []const CElt) usize {
    // The first three segments.
    const segment_size = (src.len + 3) / 4;
    var ip: usize = 0;
    // The jump table.
    var op: usize = 6;

    // The least room to compress in.
    if (dst.len < 6 + 1 + 1 + 1 + 8) return 0;
    // Too small an input to gain anything.
    if (src.len < 12) return 0;

    inline for (0..3) |segment| {
        const c_size = compress1XUsingCTableInternal(dst[op..], src[ip..][0..segment_size], ctable);
        if (c_size == 0 or c_size > 65535) return 0;
        std.mem.writeInt(u16, dst[2 * segment ..][0..2], @intCast(c_size), .little);
        op += c_size;
        ip += segment_size;
    }
    assert(ip <= src.len);
    const c_size = compress1XUsingCTableInternal(dst[op..], src[ip..], ctable);
    if (c_size == 0 or c_size > 65535) return 0;
    op += c_size;
    return op;
}

/// `HUF_compress4X_usingCTable`: four Huffman streams of `src`, as
/// `compress1XUsingCTable`.
pub fn compress4XUsingCTable(dst: []u8, src: []const u8, ctable: []const CElt) usize {
    return compress4XUsingCTableInternal(dst, src, ctable);
}

/// `HUF_nbStreams_e`.
const NbStreams = enum { single_stream, four_streams };

/// `HUF_compressCTable_internal`: the streams after `op` bytes already in
/// `dst`; 0 if the whole is not smaller than `src` less one byte.
fn compressCTableInternal(
    dst: []u8,
    op_in: usize,
    src: []const u8,
    nb_streams: NbStreams,
    ctable: []const CElt,
) usize {
    const c_size = switch (nb_streams) {
        .single_stream => compress1XUsingCTableInternal(dst[op_in..], src, ctable),
        .four_streams => compress4XUsingCTableInternal(dst[op_in..], src, ctable),
    };
    // Not compressible.
    if (c_size == 0) return 0;
    const op = op_in + c_size;
    if (op >= src.len - 1) return 0;
    return op;
}

/// `HUF_compress_tables_t`.
const CompressTables = extern struct {
    count: [huf.symbol_value_max + 1]u32,
    ctable: [huf.ctableSizeSt(huf.symbol_value_max)]CElt,
    wksps: extern union {
        build_ctable_wksp: BuildCTableWkspTables,
        write_ctable_wksp: WriteCTableWksp,
        hist_wksp: [hist.wksp_size_u32]u32,
    },
};

const workspace_max_alignment = 8;

comptime {
    assert(@sizeOf(CompressTables) + workspace_max_alignment <= huf.workspace_size);
}

const suspect_incompressible_sample_size = 4096;
/// At least 2.
const suspect_incompressible_sample_ratio = 10;

/// `HUF_cardinality`: the number of symbols with a count.
pub fn cardinality(count: []const u32, max_symbol_value: u32) u32 {
    var result: u32 = 0;
    for (count[0 .. max_symbol_value + 1]) |c| result += @intFromBool(c != 0);
    return result;
}

/// `HUF_minTableLog`: the smallest table log for `symbol_cardinality`
/// symbols.
pub fn minTableLog(symbol_cardinality: u32) u32 {
    return highbit32(symbol_cardinality) + 1;
}

/// `HUF_optimalTableLog`: the table log to build with. With
/// `flags.optimal_depth`, tries each table log from the smallest up and
/// keeps the one whose header and codes are smallest, building in `table`
/// and `workspace` (at least `huf.ctable_workspace_size` bytes); otherwise
/// estimates it as FSE does.
pub fn optimalTableLog(
    max_table_log: u32,
    src_size: usize,
    max_symbol_value: u32,
    workspace: []u8,
    table: []CElt,
    count: []const u32,
    flags: huf.Flags,
) u32 {
    assert(src_size > 1);
    assert(workspace.len >= @sizeOf(BuildCTableWkspTables));
    if (!flags.optimal_depth) {
        // The cheap estimate, from FSE.
        return fse_compress.optimalTableLogInternal(max_table_log, src_size, max_symbol_value, 1);
    }

    const dst = workspace[@sizeOf(WriteCTableWksp)..];
    const symbol_cardinality = cardinality(count, max_symbol_value);
    const min_table_log = minTableLog(symbol_cardinality);
    var opt_size: usize = std.math.maxInt(usize) - 1;
    var opt_log = max_table_log;

    // Search until the size grows.
    var opt_log_guess = min_table_log;
    while (opt_log_guess <= max_table_log) : (opt_log_guess += 1) {
        const built = buildCTableWksp(table, count, max_symbol_value, opt_log_guess, workspace);
        const max_bits = built catch continue;
        if (max_bits < opt_log_guess and opt_log_guess > min_table_log) break;
        const h_size = writeCTableWksp(dst, table, max_symbol_value, max_bits, workspace) catch
            continue;
        const new_size = estimateCompressedSize(table, count, max_symbol_value) + h_size;
        if (new_size > opt_size + 1) break;
        if (new_size < opt_size) {
            opt_size = new_size;
            opt_log = opt_log_guess;
        }
    }
    assert(opt_log <= huf.table_log_max);
    return opt_log;
}

/// `HUF_compress_internal`.
fn compressInternal(
    dst: []u8,
    src: []const u8,
    max_symbol_value_in: u32,
    huff_log_in: u32,
    nb_streams: NbStreams,
    workspace_in: []u8,
    old_huf_table: ?[]CElt,
    repeat: ?*huf.Repeat,
    flags: huf.Flags,
) Error!usize {
    const workspace = alignUpWorkspace(workspace_in, @alignOf(usize));
    var max_symbol_value = max_symbol_value_in;
    var huff_log = huff_log_in;

    if (workspace.len < @sizeOf(CompressTables)) return error.WorkSpaceTooSmall;
    const table = workspaceAs(CompressTables, workspace);
    // Not compressed.
    if (src.len == 0) return 0;
    // Nothing fits.
    if (dst.len == 0) return 0;
    // The block size limit.
    if (src.len > huf.block_size_max) return error.SrcSizeWrong;
    if (huff_log > huf.table_log_max) return error.TableLogTooLarge;
    if (max_symbol_value > huf.symbol_value_max) return error.MaxSymbolValueTooLarge;
    if (max_symbol_value == 0) max_symbol_value = huf.symbol_value_max;
    if (huff_log == 0) huff_log = huf.table_log_default;

    // A valid old table is used as it is for small inputs.
    if (flags.prefer_repeat and repeat != null and repeat.?.* == .valid) {
        return compressCTableInternal(dst, 0, src, nb_streams, old_huf_table.?);
    }

    // When the input is suspected incompressible, sample it first.
    comptime assert(suspect_incompressible_sample_ratio >= 2);
    const sample_size = suspect_incompressible_sample_size;
    if (flags.suspect_uncompressible and
        src.len >= sample_size * suspect_incompressible_sample_ratio)
    {
        var largest_total: usize = 0;
        var max_symbol_value_begin = max_symbol_value;
        const begin_sample = src[0..sample_size];
        largest_total += hist.countSimple(&table.count, &max_symbol_value_begin, begin_sample);
        var max_symbol_value_end = max_symbol_value;
        const end_sample = src[src.len - sample_size ..];
        largest_total += hist.countSimple(&table.count, &max_symbol_value_end, end_sample);
        // Probably not compressible enough.
        if (largest_total <= ((2 * sample_size) >> 7) + 4) return 0;
    }

    // The symbol statistics.
    const largest = try hist.countWksp(
        &table.count,
        &max_symbol_value,
        src,
        std.mem.asBytes(&table.wksps.hist_wksp),
    );
    // A single symbol: RLE.
    if (largest == src.len) {
        dst[0] = src[0];
        return 1;
    }
    // Probably not compressible enough.
    if (largest <= (src.len >> 7) + 4) return 0;

    // Whether the old table can still be used.
    if (repeat) |r| {
        if (r.* == .check and !validateCTable(old_huf_table.?, &table.count, max_symbol_value)) {
            r.* = .none;
        }
    }
    // An old table is used as it is for small inputs.
    if (flags.prefer_repeat and repeat != null and repeat.?.* != .none) {
        return compressCTableInternal(dst, 0, src, nb_streams, old_huf_table.?);
    }

    // The Huffman tree.
    huff_log = optimalTableLog(
        huff_log,
        src.len,
        max_symbol_value,
        std.mem.asBytes(&table.wksps),
        &table.ctable,
        &table.count,
        flags,
    );
    huff_log = try buildCTableWksp(
        &table.ctable,
        &table.count,
        max_symbol_value,
        huff_log,
        std.mem.asBytes(&table.wksps.build_ctable_wksp),
    );

    // The table's description.
    const h_size = try writeCTableWksp(
        dst,
        &table.ctable,
        max_symbol_value,
        huff_log,
        std.mem.asBytes(&table.wksps.write_ctable_wksp),
    );
    // Whether the old table does better.
    if (repeat != null and repeat.?.* != .none) {
        const old_size = estimateCompressedSize(old_huf_table.?, &table.count, max_symbol_value);
        const new_size = estimateCompressedSize(&table.ctable, &table.count, max_symbol_value);
        if (old_size <= h_size + new_size or h_size + 12 >= src.len) {
            return compressCTableInternal(dst, 0, src, nb_streams, old_huf_table.?);
        }
    }

    // The new table.
    if (h_size + 12 >= src.len) return 0;
    if (repeat) |r| r.* = .none;
    if (old_huf_table) |old| @memcpy(old[0..table.ctable.len], &table.ctable);
    return compressCTableInternal(dst, h_size, src, nb_streams, &table.ctable);
}

/// `HUF_compress1X_repeat`: `src` as a table description and one Huffman
/// stream, with symbols up to `max_symbol_value` (0 for 255) and codes of
/// at most `huff_log` bits (0 for the default). Returns the size, 0 if it
/// does not compress, or 1 if `src` is one byte repeated, written alone.
///
/// `huf_table` is the previous block's table, and `repeat` says whether it
/// may be reused; a new table replaces it, and `repeat` becomes `none`.
/// `workspace` holds `huf.workspace_size` bytes.
pub fn compress1XRepeat(
    dst: []u8,
    src: []const u8,
    max_symbol_value: u32,
    huff_log: u32,
    workspace: []u8,
    huf_table: ?[]CElt,
    repeat: ?*huf.Repeat,
    flags: huf.Flags,
) Error!usize {
    return compressInternal(
        dst,
        src,
        max_symbol_value,
        huff_log,
        .single_stream,
        workspace,
        huf_table,
        repeat,
        flags,
    );
}

/// `HUF_compress4X_repeat`: as `compress1XRepeat`, with four streams.
pub fn compress4XRepeat(
    dst: []u8,
    src: []const u8,
    max_symbol_value: u32,
    huff_log: u32,
    workspace: []u8,
    huf_table: ?[]CElt,
    repeat: ?*huf.Repeat,
    flags: huf.Flags,
) Error!usize {
    return compressInternal(
        dst,
        src,
        max_symbol_value,
        huff_log,
        .four_streams,
        workspace,
        huf_table,
        repeat,
        flags,
    );
}

// --------------------------------------------------------
// Tests
// --------------------------------------------------------

const testing = std.testing;

test "a table reads back from its description" {
    var count: [256]u32 = @splat(0);
    for ("the quick brown fox jumps over the lazy dog, again and again") |byte| count[byte] += 1;
    var ctable: [huf.ctableSizeSt(255)]CElt = undefined;
    var workspace: [huf.workspace_size_u64]u64 = undefined;
    const max_bits = try buildCTableWksp(&ctable, &count, 'z', 11, std.mem.asBytes(&workspace));
    var description: [huf.ctable_bound]u8 = undefined;
    const size = try writeCTableWksp(
        &description,
        &ctable,
        'z',
        max_bits,
        std.mem.asBytes(&workspace),
    );

    var read: [huf.ctableSizeSt(255)]CElt = undefined;
    var max_symbol_value: u32 = 255;
    var has_zero_weights: bool = undefined;
    const read_size =
        try readCTable(&read, &max_symbol_value, description[0..size], &has_zero_weights);
    try testing.expectEqual(size, read_size);
    try testing.expect(has_zero_weights);
    try testing.expectEqual(@as(u32, 'z'), max_symbol_value);
    try testing.expectEqualSlices(CElt, ctable[0 .. 'z' + 2], read[0 .. 'z' + 2]);
}

test "a repeated byte compresses to RLE" {
    const src: [1000]u8 = @splat('a');
    var dst: [1100]u8 = undefined;
    var workspace: [huf.workspace_size_u64]u64 = undefined;
    const workspace_bytes = std.mem.asBytes(&workspace);
    const size = try compress4XRepeat(&dst, &src, 255, 11, workspace_bytes, null, null, .{});
    try testing.expectEqual(@as(usize, 1), size);
    try testing.expectEqual(@as(u8, 'a'), dst[0]);
}
