//! The default compression parameters of each level, from the original's
//! clevels.h, for four classes of source size.

const params = @import("../params.zig");

const CompressionParameters = params.CompressionParameters;

pub const max_clevel = 22;

fn row(
    window_log: u32,
    chain_log: u32,
    hash_log: u32,
    search_log: u32,
    min_match: u32,
    target_length: u32,
    strategy: params.Strategy,
) CompressionParameters {
    return .{
        .window_log = window_log,
        .chain_log = chain_log,
        .hash_log = hash_log,
        .search_log = search_log,
        .min_match = min_match,
        .target_length = target_length,
        .strategy = strategy,
    };
}

/// `ZSTD_defaultCParameters`: by size class (any size above 256 KiB or
/// unknown, up to 256 KiB, up to 128 KiB, up to 16 KiB), then by level. Row 0
/// is the base for negative levels.
pub const default_cparameters = [4][max_clevel + 1]CompressionParameters{
    // default - for any srcSize > 256 KB
    .{
        // W, C, H, S, L, TL, strategy
        row(19, 12, 13, 1, 6, 1, .fast), // base for negative levels
        row(19, 13, 14, 1, 7, 0, .fast), // level  1
        row(20, 15, 16, 1, 6, 0, .fast), // level  2
        row(21, 16, 17, 1, 5, 0, .dfast), // level  3
        row(21, 18, 18, 1, 5, 0, .dfast), // level  4
        row(21, 18, 19, 3, 5, 2, .greedy), // level  5
        row(21, 18, 19, 3, 5, 4, .lazy), // level  6
        row(21, 19, 20, 4, 5, 8, .lazy), // level  7
        row(21, 19, 20, 4, 5, 16, .lazy2), // level  8
        row(22, 20, 21, 4, 5, 16, .lazy2), // level  9
        row(22, 21, 22, 5, 5, 16, .lazy2), // level 10
        row(22, 21, 22, 6, 5, 16, .lazy2), // level 11
        row(22, 22, 23, 6, 5, 32, .lazy2), // level 12
        row(22, 22, 22, 4, 5, 32, .btlazy2), // level 13
        row(22, 22, 23, 5, 5, 32, .btlazy2), // level 14
        row(22, 23, 23, 6, 5, 32, .btlazy2), // level 15
        row(22, 22, 22, 5, 5, 48, .btopt), // level 16
        row(23, 23, 22, 5, 4, 64, .btopt), // level 17
        row(23, 23, 22, 6, 3, 64, .btultra), // level 18
        row(23, 24, 22, 7, 3, 256, .btultra2), // level 19
        row(25, 25, 23, 7, 3, 256, .btultra2), // level 20
        row(26, 26, 24, 7, 3, 512, .btultra2), // level 21
        row(27, 27, 25, 9, 3, 999, .btultra2), // level 22
    },
    // for srcSize <= 256 KB
    .{
        // W, C, H, S, L, TL, strategy
        row(18, 12, 13, 1, 5, 1, .fast), // base for negative levels
        row(18, 13, 14, 1, 6, 0, .fast), // level  1
        row(18, 14, 14, 1, 5, 0, .dfast), // level  2
        row(18, 16, 16, 1, 4, 0, .dfast), // level  3
        row(18, 16, 17, 3, 5, 2, .greedy), // level  4
        row(18, 17, 18, 5, 5, 2, .greedy), // level  5
        row(18, 18, 19, 3, 5, 4, .lazy), // level  6
        row(18, 18, 19, 4, 4, 4, .lazy), // level  7
        row(18, 18, 19, 4, 4, 8, .lazy2), // level  8
        row(18, 18, 19, 5, 4, 8, .lazy2), // level  9
        row(18, 18, 19, 6, 4, 8, .lazy2), // level 10
        row(18, 18, 19, 5, 4, 12, .btlazy2), // level 11
        row(18, 19, 19, 7, 4, 12, .btlazy2), // level 12
        row(18, 18, 19, 4, 4, 16, .btopt), // level 13
        row(18, 18, 19, 4, 3, 32, .btopt), // level 14
        row(18, 18, 19, 6, 3, 128, .btopt), // level 15
        row(18, 19, 19, 6, 3, 128, .btultra), // level 16
        row(18, 19, 19, 8, 3, 256, .btultra), // level 17
        row(18, 19, 19, 6, 3, 128, .btultra2), // level 18
        row(18, 19, 19, 8, 3, 256, .btultra2), // level 19
        row(18, 19, 19, 10, 3, 512, .btultra2), // level 20
        row(18, 19, 19, 12, 3, 512, .btultra2), // level 21
        row(18, 19, 19, 13, 3, 999, .btultra2), // level 22
    },
    // for srcSize <= 128 KB
    .{
        // W, C, H, S, L, TL, strategy
        row(17, 12, 12, 1, 5, 1, .fast), // base for negative levels
        row(17, 12, 13, 1, 6, 0, .fast), // level  1
        row(17, 13, 15, 1, 5, 0, .fast), // level  2
        row(17, 15, 16, 2, 5, 0, .dfast), // level  3
        row(17, 17, 17, 2, 4, 0, .dfast), // level  4
        row(17, 16, 17, 3, 4, 2, .greedy), // level  5
        row(17, 16, 17, 3, 4, 4, .lazy), // level  6
        row(17, 16, 17, 3, 4, 8, .lazy2), // level  7
        row(17, 16, 17, 4, 4, 8, .lazy2), // level  8
        row(17, 16, 17, 5, 4, 8, .lazy2), // level  9
        row(17, 16, 17, 6, 4, 8, .lazy2), // level 10
        row(17, 17, 17, 5, 4, 8, .btlazy2), // level 11
        row(17, 18, 17, 7, 4, 12, .btlazy2), // level 12
        row(17, 18, 17, 3, 4, 12, .btopt), // level 13
        row(17, 18, 17, 4, 3, 32, .btopt), // level 14
        row(17, 18, 17, 6, 3, 256, .btopt), // level 15
        row(17, 18, 17, 6, 3, 128, .btultra), // level 16
        row(17, 18, 17, 8, 3, 256, .btultra), // level 17
        row(17, 18, 17, 10, 3, 512, .btultra), // level 18
        row(17, 18, 17, 5, 3, 256, .btultra2), // level 19
        row(17, 18, 17, 7, 3, 512, .btultra2), // level 20
        row(17, 18, 17, 9, 3, 512, .btultra2), // level 21
        row(17, 18, 17, 11, 3, 999, .btultra2), // level 22
    },
    // for srcSize <= 16 KB
    .{
        // W, C, H, S, L, TL, strategy
        row(14, 12, 13, 1, 5, 1, .fast), // base for negative levels
        row(14, 14, 15, 1, 5, 0, .fast), // level  1
        row(14, 14, 15, 1, 4, 0, .fast), // level  2
        row(14, 14, 15, 2, 4, 0, .dfast), // level  3
        row(14, 14, 14, 4, 4, 2, .greedy), // level  4
        row(14, 14, 14, 3, 4, 4, .lazy), // level  5
        row(14, 14, 14, 4, 4, 8, .lazy2), // level  6
        row(14, 14, 14, 6, 4, 8, .lazy2), // level  7
        row(14, 14, 14, 8, 4, 8, .lazy2), // level  8
        row(14, 15, 14, 5, 4, 8, .btlazy2), // level  9
        row(14, 15, 14, 9, 4, 8, .btlazy2), // level 10
        row(14, 15, 14, 3, 4, 12, .btopt), // level 11
        row(14, 15, 14, 4, 3, 24, .btopt), // level 12
        row(14, 15, 14, 5, 3, 32, .btultra), // level 13
        row(14, 15, 15, 6, 3, 64, .btultra), // level 14
        row(14, 15, 15, 7, 3, 256, .btultra), // level 15
        row(14, 15, 15, 5, 3, 48, .btultra2), // level 16
        row(14, 15, 15, 6, 3, 128, .btultra2), // level 17
        row(14, 15, 15, 7, 3, 256, .btultra2), // level 18
        row(14, 15, 15, 8, 3, 256, .btultra2), // level 19
        row(14, 15, 15, 8, 3, 512, .btultra2), // level 20
        row(14, 15, 15, 9, 3, 512, .btultra2), // level 21
        row(14, 15, 15, 10, 3, 999, .btultra2), // level 22
    },
};
