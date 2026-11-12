//! Huffman coding: the constants and table sizes the compressor shares, from
//! the original's huf.h. The encoder is in compress/huf_compress.zig.

const fse = @import("fse.zig");

/// The largest input one block of Huffman coding takes.
pub const block_size_max = 128 * 1024;
pub const workspace_size = (8 << 10) + 512;
pub const workspace_size_u64 = workspace_size / @sizeOf(u64);
/// The largest table log the library builds.
pub const table_log_max = 12;
pub const table_log_default = 11;
pub const symbol_value_max = 255;
pub const table_log_absolute_max = 12;

pub const ctable_bound = 129;

pub fn blockBound(size: usize) usize {
    return size + (size >> 8) + 8;
}

pub fn compressBound(size: usize) usize {
    return ctable_bound + blockBound(size);
}

/// One entry of a Huffman compression table; the first entry is a header.
pub const CElt = usize;

pub fn ctableSizeSt(max_symbol_value: u32) usize {
    return max_symbol_value + 2;
}

pub const ctable_workspace_size_u32 = 4 * (symbol_value_max + 1) + 192;
pub const ctable_workspace_size = ctable_workspace_size_u32 * @sizeOf(u32);

pub const read_stats_workspace_size_u32 = fse.decompressWorkspaceSizeU32(6, table_log_max - 1);
pub const read_stats_workspace_size = read_stats_workspace_size_u32 * @sizeOf(u32);

/// The original's `HUF_flags_e`, a set of bits.
pub const Flags = packed struct(u32) {
    bmi2: bool = false,
    /// Spend more time searching for the table depth that compresses best.
    optimal_depth: bool = false,
    /// Prefer reusing the previous table when it is valid.
    prefer_repeat: bool = false,
    /// The input is probably incompressible: sample it before building a table.
    suspect_uncompressible: bool = false,
    disable_asm: bool = false,
    disable_fast: bool = false,
    _: u26 = 0,
};

/// Whether a previous block's table may be reused.
pub const Repeat = enum(u32) {
    /// The previous table cannot be used.
    none,
    /// The previous table can be used, but must be checked: it was built by
    /// compress1XRepeat or compress4XRepeat.
    check,
    /// The previous table can be used, and is assumed valid.
    valid,
};
