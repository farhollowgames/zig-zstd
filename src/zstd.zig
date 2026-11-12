//! A Zig port of Zstandard's compressor.

const std = @import("std");

pub const params = @import("params.zig");
pub const Error = @import("error.zig").Error;
pub const ErrorCode = @import("error.zig").ErrorCode;
pub const errorCode = @import("error.zig").errorCode;

/// The compressor's parts, public for the oracle tests and the benchmark.
pub const internal = struct {
    pub const bitstream = @import("common/bitstream.zig");
    pub const entropy_common = @import("common/entropy_common.zig");
    pub const fse = @import("common/fse.zig");
    pub const huf = @import("common/huf.zig");
    pub const fse_compress = @import("compress/fse_compress.zig");
    pub const hist = @import("compress/hist.zig");
    pub const huf_compress = @import("compress/huf_compress.zig");
};

test {
    std.testing.refAllDecls(@This());
    _ = @import("common/fse.zig");
    _ = @import("common/huf.zig");
    _ = @import("common/zstd_internal.zig");
    _ = @import("common/bitstream.zig");
    _ = @import("common/entropy_common.zig");
    _ = @import("compress/fse_compress.zig");
    _ = @import("compress/hist.zig");
    _ = @import("compress/huf_compress.zig");
}
