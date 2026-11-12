//! Oracle tests: the port against the original zstd, built from reference/,
//! on the same inputs. Every compressed frame must be the same, byte for byte,
//! and every frame must decompress through std's decompressor and the
//! original's to the input.

const std = @import("std");
const zstd = @import("zstd");
const c = @import("upstream");

test "ZSTD_VERSION_NUMBER" {
    try std.testing.expectEqual(@as(c_uint, 10507), c.ZSTD_versionNumber());
}
