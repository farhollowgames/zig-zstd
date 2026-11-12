//! Helpers the oracle tests share: compressing with the original under a
//! parameter list, checking that a frame decompresses through std and the
//! original to its input, test inputs, and the fuzz seeds.

const std = @import("std");
const c = @import("upstream");
const test_options = @import("test_options");

pub const gpa = std.testing.allocator;

/// One `ZSTD_CCtx_setParameter` call, by the original's parameter number.
pub const Param = struct {
    param: u32,
    value: i32,
};

/// The first seed of a fuzz test, offset by `-Dfuzz-seed`.
pub fn fuzzSeed(base: u64) u64 {
    return base +% test_options.fuzz_seed;
}

/// The number of cases a fuzz test runs (`-Dfuzz-cases`, default 1000).
pub const fuzz_cases = test_options.fuzz_cases;

/// The original's result: a size, or its error code.
pub const Result = union(enum) {
    size: usize,
    error_code: u32,

    pub fn of(code: usize) Result {
        if (c.ZSTD_isError(code) != 0) return .{ .error_code = c.ZSTD_getErrorCode(code) };
        return .{ .size = code };
    }
};

/// A context of the original with `params` set; the caller frees it with
/// `c.ZSTD_freeCCtx`.
pub fn upstreamCCtx(params: []const Param) !*c.ZSTD_CCtx {
    const cctx = c.ZSTD_createCCtx() orelse return error.OutOfMemory;
    errdefer _ = c.ZSTD_freeCCtx(cctx);
    for (params) |p| {
        const code = c.ZSTD_CCtx_setParameter(cctx, p.param, p.value);
        if (c.ZSTD_isError(code) != 0) return error.UpstreamParameterRefused;
    }
    return cctx;
}

/// `src` compressed by the original's `ZSTD_compress2` with `params`, into
/// a buffer of `compressBound` bytes. The caller frees the frame.
pub fn upstreamCompress2(params: []const Param, src: []const u8) ![]u8 {
    const cctx = try upstreamCCtx(params);
    defer _ = c.ZSTD_freeCCtx(cctx);
    const dst = try gpa.alloc(u8, c.ZSTD_compressBound(src.len));
    errdefer gpa.free(dst);
    const code = c.ZSTD_compress2(cctx, dst.ptr, dst.len, src.ptr, src.len);
    if (c.ZSTD_isError(code) != 0) {
        std.debug.print("upstream: {s}\n", .{c.ZSTD_getErrorName(code)});
        return error.UpstreamFailed;
    }
    return gpa.realloc(dst, code);
}

/// Checks that `frame` decompresses to `expected` through the original's
/// `ZSTD_decompress`, checksum verified, and through std's decompressor.
pub fn expectRoundTrip(frame: []const u8, expected: []const u8) !void {
    try expectUpstreamDecodes(frame, expected, null);
    try expectStdDecodes(frame, expected);
}

/// Checks that the original decompresses `frame` to `expected`, with `dict`
/// as its dictionary when given.
pub fn expectUpstreamDecodes(frame: []const u8, expected: []const u8, dict: ?[]const u8) !void {
    const out = try gpa.alloc(u8, expected.len + 1);
    defer gpa.free(out);
    const code = if (dict) |d| blk: {
        const dctx = c.ZSTD_createDCtx() orelse return error.OutOfMemory;
        defer _ = c.ZSTD_freeDCtx(dctx);
        break :blk c.ZSTD_decompress_usingDict(
            dctx,
            out.ptr,
            out.len,
            frame.ptr,
            frame.len,
            d.ptr,
            d.len,
        );
    } else c.ZSTD_decompress(out.ptr, out.len, frame.ptr, frame.len);
    if (c.ZSTD_isError(code) != 0) {
        std.debug.print("upstream decompress: {s}\n", .{c.ZSTD_getErrorName(code)});
        return error.UpstreamDecompressFailed;
    }
    try std.testing.expectEqualSlices(u8, expected, out[0..code]);
}

/// Checks that std's decompressor gives `expected` from `frame`. std's
/// decoder takes no dictionaries, and does not verify checksums: with
/// `verify_checksum` it panics on the first non-empty block of a frame that
/// has one. The original's decoder verifies them.
pub fn expectStdDecodes(frame: []const u8, expected: []const u8) !void {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var in: std.Io.Reader = .fixed(frame);
    var decompress: std.compress.zstd.Decompress = .init(&in, &.{}, .{
        .verify_checksum = false,
        .window_len = 1 << 31,
    });
    _ = decompress.reader.streamRemaining(&out.writer) catch |err| {
        std.debug.print("std decompress: {t} ({?t})\n", .{ err, decompress.err });
        return error.StdDecompressFailed;
    };
    try std.testing.expectEqualSlices(u8, expected, out.written());
}

/// `size` bytes of the original's generated test data (RDG_genBuffer).
/// The caller frees them.
pub fn generated(size: usize, match_proba: f64, lit_proba: f64, seed: u32) ![]u8 {
    const buffer = try gpa.alloc(u8, size);
    // The generator writes its first byte even for an empty buffer.
    if (size == 0) return buffer;
    c.reference_genBuffer(buffer.ptr, size, match_proba, lit_proba, seed);
    return buffer;
}

/// The bytes of `name` in `dir`, one of the test_options directories. The
/// caller frees them.
pub fn readFile(dir: []const u8, name: []const u8) ![]u8 {
    const path = try std.fs.path.join(gpa, &.{ dir, name });
    defer gpa.free(path);
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, gpa, .unlimited);
}

/// Prints where two frames first differ, then fails.
pub fn expectSameFrame(expected: []const u8, actual: []const u8) !void {
    if (std.mem.eql(u8, expected, actual)) return;
    const first = std.mem.indexOfDiff(u8, expected, actual).?;
    std.debug.print(
        "frames differ at byte {d}: original {d} bytes, port {d} bytes\n",
        .{ first, expected.len, actual.len },
    );
    return error.FramesDiffer;
}
