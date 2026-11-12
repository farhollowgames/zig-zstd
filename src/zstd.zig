//! A Zig port of Zstandard's compressor.

const std = @import("std");

pub const params = @import("params.zig");
pub const Error = @import("error.zig").Error;
pub const ErrorCode = @import("error.zig").ErrorCode;
pub const errorCode = @import("error.zig").errorCode;

/// The compressor's parts, public for the oracle tests and the benchmark.
pub const internal = struct {
    pub const compress_internal = @import("compress/compress_internal.zig");
    pub const cwksp = @import("compress/cwksp.zig");
    pub const clevels = @import("compress/clevels.zig");
    pub const fast = @import("compress/fast.zig");
    pub const double_fast = @import("compress/double_fast.zig");
    pub const bitstream = @import("common/bitstream.zig");
    pub const entropy_common = @import("common/entropy_common.zig");
    pub const fse = @import("common/fse.zig");
    pub const huf = @import("common/huf.zig");
    pub const fse_compress = @import("compress/fse_compress.zig");
    pub const hist = @import("compress/hist.zig");
    pub const huf_compress = @import("compress/huf_compress.zig");
    pub const zstd_internal = @import("common/zstd_internal.zig");
    pub const compress_literals = @import("compress/compress_literals.zig");
    pub const compress_sequences = @import("compress/compress_sequences.zig");
    pub const ldm = @import("compress/ldm.zig");
    pub const opt = @import("compress/opt.zig");
    pub const lazy = @import("compress/lazy.zig");
};

test {
    std.testing.refAllDecls(@This());
    _ = @import("common/fse.zig");
    _ = @import("common/huf.zig");
    _ = @import("common/zstd_internal.zig");
    _ = @import("compress/compress_internal.zig");
    _ = @import("compress/cwksp.zig");
    _ = @import("compress/clevels.zig");
    _ = @import("compress/fast.zig");
    _ = @import("compress/double_fast.zig");
    _ = @import("common/bitstream.zig");
    _ = @import("common/entropy_common.zig");
    _ = @import("compress/fse_compress.zig");
    _ = @import("compress/hist.zig");
    _ = @import("compress/huf_compress.zig");
    _ = @import("compress/compress_literals.zig");
    _ = @import("compress/compress_sequences.zig");
    _ = @import("compress/ldm.zig");
    _ = @import("compress/opt.zig");
    _ = @import("compress/lazy.zig");
}
