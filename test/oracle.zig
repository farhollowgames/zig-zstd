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

const common = @import("common.zig");

test "the harness: the original's frames decode through std and the original" {
    const input = try common.generated(300_000, 0.5, 0.0, 7);
    defer common.gpa.free(input);
    for ([_]i32{ -5, 1, 3, 19 }) |level| {
        const frame = try common.upstreamCompress2(&.{
            .{ .param = 100, .value = level },
            .{ .param = 201, .value = 1 },
        }, input);
        defer common.gpa.free(frame);
        try common.expectRoundTrip(frame, input);
    }
    const golden = try common.readFile(
        @import("test_options").reference,
        "tests/golden-compression/http",
    );
    defer common.gpa.free(golden);
    try std.testing.expect(golden.len > 0);
}

test {
    _ = @import("core_test.zig");
    _ = @import("entropy_test.zig");
    _ = @import("literals_sequences_test.zig");
    _ = @import("ldm_test.zig");
}

test {
    _ = @import("opt_test.zig");
}

test {
    _ = @import("frame_test.zig");
}
