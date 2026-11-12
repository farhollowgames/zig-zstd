//! A Zig port of Zstandard's compressor.

const std = @import("std");

pub const params = @import("params.zig");
pub const Error = @import("error.zig").Error;
pub const ErrorCode = @import("error.zig").ErrorCode;
pub const errorCode = @import("error.zig").errorCode;

/// The compressor's parts, for the oracle tests, which compare each with
/// the original's on its own.
pub const internal = struct {
    pub const compress_internal = @import("compress/compress_internal.zig");
    pub const cwksp = @import("compress/cwksp.zig");
    pub const clevels = @import("compress/clevels.zig");
    pub const fast = @import("compress/fast.zig");
    pub const double_fast = @import("compress/double_fast.zig");
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
    _ = @import("compress/lazy.zig");
}
