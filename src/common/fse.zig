//! Finite State Entropy: the constants and table sizes the compressor shares,
//! from the original's fse.h. The encoder is in compress/fse_compress.zig.

/// The largest table log the library builds with its default memory usage.
pub const max_memory_usage = 14;
pub const default_memory_usage = 13;
pub const max_table_log = max_memory_usage - 2;
pub const max_table_size: u32 = 1 << max_table_log;
pub const default_table_log = default_memory_usage - 2;
pub const min_table_log = 5;
pub const table_log_absolute_max = 15;
pub const max_symbol_value = 255;

/// The largest normalized-count header.
pub const ncount_bound = 512;

pub fn blockBound(size: usize) usize {
    return size + (size >> 7) + 4 + @sizeOf(usize);
}

pub fn compressBound(size: usize) usize {
    return ncount_bound + blockBound(size);
}

/// An FSE compression table, as `u32` units; see `ctableSizeU32`.
pub const CTable = u32;

pub fn ctableSizeU32(table_log: u32, symbol_value_max: u32) usize {
    return 1 + (@as(usize, 1) << @intCast(table_log - 1)) + (symbol_value_max + 1) * 2;
}

pub fn buildCTableWorkspaceSizeU32(symbol_value_max: u32, table_log: u32) usize {
    return ((symbol_value_max + 2) + (@as(usize, 1) << @intCast(table_log))) / 2 +
        @sizeOf(u64) / @sizeOf(u32);
}

pub fn buildCTableWorkspaceSize(symbol_value_max: u32, table_log: u32) usize {
    return @sizeOf(u32) * buildCTableWorkspaceSizeU32(symbol_value_max, table_log);
}

pub fn dtableSizeU32(table_log: u32) usize {
    return 1 + (@as(usize, 1) << @intCast(table_log));
}

pub fn buildDTableWorkspaceSize(table_log: u32, symbol_value_max: u32) usize {
    return @sizeOf(i16) * (symbol_value_max + 1) + (@as(usize, 1) << @intCast(table_log)) + 8;
}

pub fn buildDTableWorkspaceSizeU32(table_log: u32, symbol_value_max: u32) usize {
    return (buildDTableWorkspaceSize(table_log, symbol_value_max) + @sizeOf(u32) - 1) /
        @sizeOf(u32);
}

pub fn decompressWorkspaceSizeU32(table_log: u32, symbol_value_max: u32) usize {
    return dtableSizeU32(table_log) + 1 + buildDTableWorkspaceSizeU32(table_log, symbol_value_max) +
        (max_symbol_value + 1) / 2 + 1;
}

pub fn tableStep(table_size: u32) u32 {
    return (table_size >> 1) + (table_size >> 3) + 3;
}

/// Whether a previous block's table may be reused.
pub const Repeat = enum(u32) {
    /// The previous table cannot be used.
    none,
    /// The previous table can be used, but must be checked.
    check,
    /// The previous table can be used, and is assumed valid.
    valid,
};
