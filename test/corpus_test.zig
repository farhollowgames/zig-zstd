//! Corpus tests, run only with `-Dcorpus` (the default): every file of the
//! Canterbury corpus's canterbury/, artificial/ and large/ sets at the
//! negative levels -5 and -1 and every positive level; the first 4 MiB of
//! every Silesia file at -5 and every positive level, and each whole
//! Silesia file at levels 1, 3 and 19, in one shot and streamed; the files
//! of test/data at every level. Every frame must be the original's, byte
//! for byte, and decode back through std and the original. One file is in
//! memory at a time, and each prints its progress.

const std = @import("std");
const zstd = @import("zstd");
const c = @import("upstream");
const common = @import("common.zig");
const frame = @import("frame_test.zig");
const stream_test = @import("stream_test.zig");
const test_options = @import("test_options");

const gpa = common.gpa;
const Pair = frame.Pair;
const mib = 1 << 20;

const canterbury_files = [_][]const u8{
    "canterbury/alice29.txt",
    "canterbury/asyoulik.txt",
    "canterbury/cp.html",
    "canterbury/fields.c",
    "canterbury/grammar.lsp",
    "canterbury/kennedy.xls",
    "canterbury/lcet10.txt",
    "canterbury/plrabn12.txt",
    "canterbury/ptt5",
    "canterbury/sum",
    "canterbury/xargs.1",
    "artificial/a.txt",
    "artificial/aaa.txt",
    "artificial/alphabet.txt",
    "artificial/random.txt",
    "large/E.coli",
    "large/bible.txt",
    "large/world192.txt",
};

const silesia_files = [_][]const u8{
    "dickens", "mozilla", "mr",      "nci",
    "ooffice", "osdb",    "reymont", "samba",
    "sao",     "webster", "x-ray",   "xml",
};

const positive_levels = blk: {
    var l: [22]i32 = undefined;
    for (&l, 1..) |*level, i| level.* = @intCast(i);
    break :blk l;
};

/// Compresses `src` at `level` with `compress2` on both and checks the
/// frames and the round trip.
fn expectLevel(pair: Pair, src: []const u8, level: i32) !void {
    errdefer std.debug.print("level {d}\n", .{level});
    try pair.set(.compression_level, level);
    const out = try pair.compress2Frame(src, c.ZSTD_compressBound(src.len)) orelse
        return error.CompressFailed;
    defer gpa.free(out);
    try common.expectRoundTrip(out, src);
}

/// Streams `src` at `level` on both, 1 MiB per call with output windows
/// of 256 KiB, checking every call and the frame.
fn expectStreamed(pair: Pair, src: []const u8, level: i32) !void {
    errdefer std.debug.print("streamed, level {d}\n", .{level});
    try pair.set(.compression_level, level);
    var s = try stream_test.Stream.init(
        pair,
        src,
        c.ZSTD_compressBound(src.len) + 64,
        false,
        false,
    );
    defer s.deinit();
    while (s.in_pos < src.len) {
        _ = try s.step(.{ .kind = .stream2_continue, .in = 1 * mib, .out = 256 << 10 });
    }
    if (!try s.finish(null, 256 << 10)) return error.CompressFailed;
    try s.expectFrame(null);
}

test "corpus: Canterbury, at -5, -1 and every positive level" {
    if (!test_options.corpus) return error.SkipZigTest;
    const pair = try Pair.init();
    defer pair.deinit();
    for (canterbury_files) |name| {
        std.debug.print("corpus: canterbury {s}\n", .{name});
        const src = try common.readFile(test_options.canterbury, name);
        defer gpa.free(src);
        errdefer std.debug.print("canterbury {s}\n", .{name});
        for ([_]i32{ -5, -1 } ++ positive_levels) |level| try expectLevel(pair, src, level);
    }
}

test "corpus: Silesia, the first 4 MiB at -5 and every positive level, whole at 1, 3, 19" {
    if (!test_options.corpus) return error.SkipZigTest;
    const pair = try Pair.init();
    defer pair.deinit();
    for (silesia_files) |name| {
        std.debug.print("corpus: silesia {s}\n", .{name});
        const src = try common.readFile(test_options.silesia, name);
        defer gpa.free(src);
        errdefer std.debug.print("silesia {s}\n", .{name});
        const head = src[0..@min(src.len, 4 * mib)];
        for ([_]i32{-5} ++ positive_levels) |level| try expectLevel(pair, head, level);
        for ([_]i32{ 1, 3, 19 }) |level| {
            std.debug.print("corpus: silesia {s}, whole, level {d}\n", .{ name, level });
            try expectLevel(pair, src, level);
            try expectStreamed(pair, src, level);
        }
    }
}

test "corpus: test data at every level" {
    if (!test_options.corpus) return error.SkipZigTest;
    const pair = try Pair.init();
    defer pair.deinit();
    for ([_][]const u8{ "bc7.bin", "mesh.bin", "snapshot.bin" }) |name| {
        std.debug.print("corpus: test data {s}\n", .{name});
        const src = try common.readFile(test_options.data, name);
        defer gpa.free(src);
        errdefer std.debug.print("test data {s}\n", .{name});
        for (frame.levels) |level| try expectLevel(pair, src, level);
        try expectStreamed(pair, src, 3);
    }
}
