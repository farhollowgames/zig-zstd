//! `zig build bench`: the port's one-shot compression against the original's on the same
//! inputs with the same parameters, per compression level, on the Silesia corpus. The port is
//! built in ReleaseFast and the original from reference/ at -O3, both for the same target.
//! Each side keeps one context for a whole row and compresses with `compress2` after setting
//! the level.
//!
//! The low levels (3 and below) compress every whole file as a frame of its own, as an archive
//! would, and sum the time and the bytes. The higher levels compress a sample: the first 2 MiB
//! of each file, each piece a frame of its own. A row's time is the median of several runs,
//! the port and the original taking turns, after one untimed run of each, which also compares
//! the two sides' frames byte for byte. Nothing is pinned to a core.
//!
//! On Linux, transparent huge pages are off for the process, so both sides' tables are on
//! 4 KiB pages. With them on, whether a side's tables land on a huge page turns on where
//! malloc places its context, which follows the order the two sides allocate in.
//!
//! Arguments after `--`: `--levels 1,3,19` picks the levels, `--runs N` sets the number of
//! timed runs, `--quick` samples 4 MiB in all for every level and takes 3 runs (a smoke test),
//! `--markdown` prints the table for doc/BENCHMARKS.md, `--huge-pages` leaves transparent huge
//! pages as the system has them, and `--original-first` has the original compress first in
//! the warm-up, so that it allocates its tables first.

const std = @import("std");
const builtin = @import("builtin");
const zstd = @import("zstd");
const c = @import("upstream");
const bench_options = @import("bench_options");

/// Both sides' allocations: the C allocator, which is what the original's own `malloc` is.
const gpa = std.heap.c_allocator;

const corpus_files = [_][]const u8{
    "dickens", "mozilla", "mr",  "nci",     "ooffice", "osdb",
    "reymont", "samba",   "sao", "webster", "xml",     "x-ray",
};

const levels_default = [_]i32{
    -5, -1, 1,  2,  3,  4,  5,  6,  7,  8,  9,  10,
    11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22,
};

const mib = 1 << 20;
const sample_bytes_per_file = 2 * mib;
const sample_bytes_quick = 4 * mib;
/// Levels up to this compress whole files, the higher ones a sample.
const level_whole_max = 3;
/// Levels from this run fewer times: a run takes minutes.
const level_slow_min = 16;
const runs_default = 5;
const runs_slow = 3;
const runs_quick = 3;

/// The multithreaded rows: these levels with `workers` workers. True runs them; false
/// prints them as skipped, for a port without worker threads.
const port_multithread_merged = true;
const workers = 4;
const levels_multithread = [_]i32{ 3, 19 };

/// What the original is built with, as `benchReferenceLibrary` in build.zig has it.
const original_flags = "-O3 -std=c99 -DXXH_NAMESPACE=ZSTD_ -DZSTD_MULTITHREAD " ++
    "-DZSTD_LEGACY_SUPPORT=0 -fno-sanitize=undefined -fPIC -fvisibility=hidden, " ++
    "plus huf_decompress_amd64.S on x86_64, as a shared library on glibc";

const Options = struct {
    levels: []const i32 = &levels_default,
    runs: ?usize = null,
    quick: bool = false,
    markdown: bool = false,
    huge_pages: bool = false,
    original_first: bool = false,
};

/// The frames a row compresses, each a piece of the corpus.
const Set = struct {
    pieces: []const []const u8,
    bytes: u64,
    /// The largest piece, which sizes the output buffers.
    piece_max: usize,
};

const Row = struct {
    level: i32,
    workers: u32,
    whole: bool,
};

const Timing = struct {
    median_ns: u64,
    min_ns: u64,
    max_ns: u64,

    /// Sorts `samples`.
    fn of(samples: []u64) Timing {
        std.mem.sort(u64, samples, {}, std.sort.asc(u64));
        const mid = samples.len / 2;
        const median_ns = if (samples.len % 2 == 1)
            samples[mid]
        else
            (samples[mid - 1] + samples[mid]) / 2;
        return .{
            .median_ns = median_ns,
            .min_ns = samples[0],
            .max_ns = samples[samples.len - 1],
        };
    }

    fn seconds(ns: u64) f64 {
        return @as(f64, @floatFromInt(ns)) / 1e9;
    }

    /// The input megabytes (1e6 bytes) compressed a second.
    fn rate(self: Timing, input_bytes: u64) f64 {
        return @as(f64, @floatFromInt(input_bytes)) / 1e6 / seconds(self.median_ns);
    }
};

const Result = struct {
    input_bytes: u64,
    original_bytes: u64,
    port_bytes: u64,
    original: Timing,
    port: Timing,
    frames: usize,
    frames_differing: usize,
    /// A timed run whose compressed size is not the checked run's.
    unstable: bool,
    /// The compressed sizes of every timed run of both sides, so the work stays observable.
    checksum: u64,
};

fn fatal(comptime format: []const u8, args: anytype) noreturn {
    std.debug.print("bench: " ++ format ++ "\n", args);
    std.process.exit(1);
}

/// The port's compressor: one context for a row.
const Port = struct {
    cctx: *zstd.CCtx,

    fn init(row: Row, io: std.Io) !Port {
        const cctx = try zstd.CCtx.create(gpa);
        _ = try cctx.setParameter(.compression_level, row.level);
        if (row.workers != 0) {
            // The workers take their locks through an `Io`.
            cctx.setIo(io);
            _ = try cctx.setParameter(.nb_workers, @intCast(row.workers));
        }
        return .{ .cctx = cctx };
    }

    fn deinit(self: Port) void {
        // `destroy` fails only for a static context.
        self.cctx.destroy() catch unreachable;
    }

    fn compress(self: Port, dst: []u8, src: []const u8) usize {
        return self.cctx.compress2(dst, src) catch |err| fatal("port compress2: {t}", .{err});
    }
};

/// The original's compressor: one context for a row.
const Original = struct {
    cctx: *c.ZSTD_CCtx,

    // ZSTD_c_compressionLevel and ZSTD_c_nbWorkers.
    const level_parameter = 100;
    const workers_parameter = 400;

    fn init(row: Row) !Original {
        const cctx = c.ZSTD_createCCtx() orelse return error.OutOfMemory;
        try check(c.ZSTD_CCtx_setParameter(cctx, level_parameter, row.level));
        if (row.workers != 0) {
            try check(c.ZSTD_CCtx_setParameter(cctx, workers_parameter, @intCast(row.workers)));
        }
        return .{ .cctx = cctx };
    }

    fn deinit(self: Original) void {
        _ = c.ZSTD_freeCCtx(self.cctx);
    }

    fn check(code: usize) !void {
        if (c.ZSTD_isError(code) != 0) return error.OriginalFailed;
    }

    fn compress(self: Original, dst: []u8, src: []const u8) usize {
        const code = c.ZSTD_compress2(self.cctx, dst.ptr, dst.len, src.ptr, src.len);
        if (c.ZSTD_isError(code) != 0) {
            fatal("original ZSTD_compress2: {s}", .{c.ZSTD_getErrorName(code)});
        }
        return code;
    }
};

const Pass = struct { ns: u64, bytes: u64 };

/// One run of `side` over every piece of `set`, timing the compression calls only.
fn timedPass(io: std.Io, side: anytype, set: Set, dst: []u8) Pass {
    var pass: Pass = .{ .ns = 0, .bytes = 0 };
    for (set.pieces) |piece| {
        const t0 = std.Io.Clock.awake.now(io);
        const size = side.compress(dst, piece);
        // The frame and its size stay observable, so the compiler cannot drop the call.
        std.mem.doNotOptimizeAway(size);
        std.mem.doNotOptimizeAway(dst);
        const t1 = std.Io.Clock.awake.now(io);
        pass.ns += @intCast(t0.durationTo(t1).nanoseconds);
        pass.bytes += size;
    }
    return pass;
}

fn measure(io: std.Io, row: Row, set: Set, runs: usize, original_allocates: bool) !Result {
    const port: Port = try .init(row, io);
    defer port.deinit();
    const original: Original = try .init(row);
    defer original.deinit();

    const capacity = c.ZSTD_compressBound(set.piece_max);
    const port_out = try gpa.alloc(u8, capacity);
    defer gpa.free(port_out);
    const original_out = try gpa.alloc(u8, capacity);
    defer gpa.free(original_out);
    const port_samples = try gpa.alloc(u64, runs);
    defer gpa.free(port_samples);
    const original_samples = try gpa.alloc(u64, runs);
    defer gpa.free(original_samples);

    // The warm-up run of each side, untimed, which compares the frames byte for byte.
    var result: Result = .{
        .input_bytes = set.bytes,
        .original_bytes = 0,
        .port_bytes = 0,
        .original = undefined,
        .port = undefined,
        .frames = set.pieces.len,
        .frames_differing = 0,
        .unstable = false,
        .checksum = 0,
    };
    for (set.pieces) |piece| {
        // The side that compresses the first piece first allocates its tables first.
        var port_size: usize = undefined;
        var original_size: usize = undefined;
        if (original_allocates) {
            original_size = original.compress(original_out, piece);
            port_size = port.compress(port_out, piece);
        } else {
            port_size = port.compress(port_out, piece);
            original_size = original.compress(original_out, piece);
        }
        result.port_bytes += port_size;
        result.original_bytes += original_size;
        const same = std.mem.eql(u8, port_out[0..port_size], original_out[0..original_size]);
        if (!same) result.frames_differing += 1;
    }

    // Taking turns, the side that goes first alternating, spreads drift in clock speed and
    // cache state over both.
    for (port_samples, original_samples, 0..) |*port_ns, *original_ns, run| {
        const original_first = run % 2 == 0;
        var original_pass: Pass = undefined;
        if (original_first) original_pass = timedPass(io, original, set, original_out);
        const port_pass = timedPass(io, port, set, port_out);
        if (!original_first) original_pass = timedPass(io, original, set, original_out);
        port_ns.* = port_pass.ns;
        original_ns.* = original_pass.ns;
        if (port_pass.bytes != result.port_bytes) result.unstable = true;
        if (original_pass.bytes != result.original_bytes) result.unstable = true;
        result.checksum += port_pass.bytes + original_pass.bytes;
    }
    result.port = .of(port_samples);
    result.original = .of(original_samples);
    return result;
}

// --------------------------------------------------------
// The input
// --------------------------------------------------------

const Corpus = struct {
    files: [corpus_files.len][]const u8,
    bytes: u64,

    /// Reads the corpus; null when it is not fetched.
    fn load(io: std.Io) !?Corpus {
        if (bench_options.silesia.len == 0) return null;
        var corpus: Corpus = .{ .files = undefined, .bytes = 0 };
        for (corpus_files, &corpus.files) |name, *file| {
            const path = try std.fs.path.join(gpa, &.{ bench_options.silesia, name });
            defer gpa.free(path);
            file.* = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited) catch |err| {
                if (err == error.FileNotFound) return null;
                return err;
            };
            corpus.bytes += file.len;
        }
        return corpus;
    }

    /// Every whole file as a frame.
    fn whole(self: *const Corpus) !Set {
        const pieces = try gpa.alloc([]const u8, self.files.len);
        var piece_max: usize = 0;
        for (pieces, self.files) |*piece, file| {
            piece.* = file;
            piece_max = @max(piece_max, file.len);
        }
        return .{ .pieces = pieces, .bytes = self.bytes, .piece_max = piece_max };
    }

    /// The first `per_file` bytes of every file, each a frame.
    fn sample(self: *const Corpus, per_file: usize) !Set {
        const pieces = try gpa.alloc([]const u8, self.files.len);
        var bytes: u64 = 0;
        var piece_max: usize = 0;
        for (pieces, self.files) |*piece, file| {
            piece.* = file[0..@min(file.len, per_file)];
            bytes += piece.len;
            piece_max = @max(piece_max, piece.len);
        }
        return .{ .pieces = pieces, .bytes = bytes, .piece_max = piece_max };
    }
};

// --------------------------------------------------------
// The table
// --------------------------------------------------------

const column_names = [_][]const u8{
    "row",
    "MB in",
    "original bytes",
    "port bytes",
    "ratio",
    "original MB/s",
    "port MB/s",
    "original s (min-max)",
    "port s (min-max)",
    "port / original",
};
const column_count = column_names.len;
const cell_size = 96;

const Table = struct {
    w: *std.Io.Writer,
    markdown: bool,

    fn header(self: Table) !void {
        try self.line(&column_names);
        if (!self.markdown) return;
        try self.w.writeAll("| --- |");
        for (1..column_count - 1) |_| try self.w.writeAll(" ---: |");
        try self.w.writeAll(" --- |\n");
    }

    /// The first and the last column align left, the others right; plain columns are as wide
    /// as their names and cells need (`columnWidth`).
    fn line(self: Table, cells: *const [column_count][]const u8) !void {
        const w = self.w;
        if (self.markdown) {
            try w.writeAll("|");
            for (cells) |cell| try w.print(" {s} |", .{cell});
        } else {
            for (cells, 0..) |cell, column| {
                const left = column == 0 or column == column_count - 1;
                const padding = columnWidth(column) -| cell.len;
                if (column > 0) try w.writeAll("  ");
                if (!left) try w.splatByteAll(' ', padding);
                try w.writeAll(cell);
                if (column == 0) try w.splatByteAll(' ', padding);
            }
        }
        try w.writeAll("\n");
        try w.flush();
    }

    fn result(self: Table, label: []const u8, r: Result) !void {
        var storage: [column_count][cell_size]u8 = undefined;
        var cells: [column_count][]const u8 = undefined;
        const input_mb = @as(f64, @floatFromInt(r.input_bytes)) / 1e6;
        const ratio = @as(f64, @floatFromInt(r.input_bytes)) /
            @as(f64, @floatFromInt(@max(r.original_bytes, 1)));
        const time_ratio = @as(f64, @floatFromInt(r.port.median_ns)) /
            @as(f64, @floatFromInt(@max(r.original.median_ns, 1)));
        cells[0] = label;
        cells[1] = cellText(&storage[1], "{d:.1}", .{input_mb});
        cells[2] = cellText(&storage[2], "{d}", .{r.original_bytes});
        cells[3] = cellText(&storage[3], "{d}", .{r.port_bytes});
        cells[4] = cellText(&storage[4], "{d:.3}", .{ratio});
        cells[5] = cellText(&storage[5], "{d:.1}", .{r.original.rate(r.input_bytes)});
        cells[6] = cellText(&storage[6], "{d:.1}", .{r.port.rate(r.input_bytes)});
        cells[7] = timingCell(&storage[7], r.original);
        cells[8] = timingCell(&storage[8], r.port);
        // When the two sides' spreads overlap, the runs do not settle which side is faster.
        const overlap = r.port.min_ns <= r.original.max_ns and r.original.min_ns <= r.port.max_ns;
        if (overlap) {
            cells[9] = cellText(&storage[9], "{d:.3}, within noise", .{time_ratio});
        } else {
            const verdict = if (time_ratio < 1) "faster" else "slower";
            const share = @abs(1 - time_ratio) * 100;
            cells[9] = cellText(&storage[9], "{d:.3}, {d:.1}% {s}", .{
                time_ratio, share, verdict,
            });
        }
        try self.line(&cells);
        if (r.frames_differing != 0) {
            try self.note("FRAME DIFFERS: {d} of {d} frames differ from the original's " ++
                "(the oracle tests are the authority)", .{ r.frames_differing, r.frames });
        }
        if (r.unstable) {
            try self.note("SIZE CHANGED: a timed run compressed to another size than the " ++
                "checked run", .{});
        }
    }

    fn skipped(self: Table, label: []const u8, why: []const u8) !void {
        var cells: [column_count][]const u8 = @splat("-");
        cells[0] = label;
        cells[column_count - 1] = why;
        try self.line(&cells);
    }

    fn note(self: Table, comptime text: []const u8, args: anytype) !void {
        try self.w.writeAll(if (self.markdown) "\n**" else "  ");
        try self.w.print(text, args);
        try self.w.writeAll(if (self.markdown) "**\n\n" else "\n");
        try self.w.flush();
    }
};

/// The width of a plain column.
fn columnWidth(column: usize) usize {
    const widths = [column_count]usize{ 28, 7, 14, 10, 6, 13, 9, 22, 22, 24 };
    return widths[column];
}

fn cellText(buffer: *[cell_size]u8, comptime text: []const u8, args: anytype) []const u8 {
    return std.fmt.bufPrint(buffer, text, args) catch unreachable;
}

fn timingCell(buffer: *[cell_size]u8, t: Timing) []const u8 {
    return cellText(buffer, "{d:.3} ({d:.3}-{d:.3})", .{
        Timing.seconds(t.median_ns),
        Timing.seconds(t.min_ns),
        Timing.seconds(t.max_ns),
    });
}

// --------------------------------------------------------
// The run
// --------------------------------------------------------

fn parseOptions(arena: std.mem.Allocator, args: []const [:0]const u8) !Options {
    var options: Options = .{};
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg: []const u8 = args[i];
        if (std.mem.eql(u8, arg, "--quick")) {
            options.quick = true;
        } else if (std.mem.eql(u8, arg, "--markdown")) {
            options.markdown = true;
        } else if (std.mem.eql(u8, arg, "--huge-pages")) {
            options.huge_pages = true;
        } else if (std.mem.eql(u8, arg, "--original-first")) {
            options.original_first = true;
        } else if (std.mem.eql(u8, arg, "--runs")) {
            i += 1;
            if (i == args.len) fatal("--runs needs a number", .{});
            const runs = std.fmt.parseInt(usize, args[i], 10) catch fatal("bad --runs", .{});
            if (runs == 0) fatal("--runs needs at least 1", .{});
            options.runs = runs;
        } else if (std.mem.eql(u8, arg, "--levels")) {
            i += 1;
            if (i == args.len) fatal("--levels needs a list such as 1,3,19", .{});
            var levels: std.ArrayList(i32) = .empty;
            var parts = std.mem.splitScalar(u8, args[i], ',');
            while (parts.next()) |part| {
                const level = std.fmt.parseInt(i32, part, 10) catch
                    fatal("bad level '{s}'", .{part});
                try levels.append(arena, level);
            }
            options.levels = levels.items;
        } else if (std.mem.startsWith(u8, arg, "-j")) {
            // `zig build` options a wrapper may put after the benchmark's own.
        } else {
            fatal("unknown argument '{s}'; see the top of bench/bench.zig", .{arg});
        }
    }
    return options;
}

/// The CPU's model name from /proc/cpuinfo, or null where there is none.
fn cpuModel(io: std.Io, arena: std.mem.Allocator) ?[]const u8 {
    // /proc files report a size of 0, so read until the end instead of by size.
    const file = std.Io.Dir.cwd().openFile(io, "/proc/cpuinfo", .{}) catch return null;
    defer file.close(io);
    var read_buffer: [4096]u8 = undefined;
    var reader = file.readerStreaming(io, &read_buffer);
    const text = reader.interface.allocRemaining(arena, .limited(1 << 22)) catch return null;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "model name")) continue;
        const colon = std.mem.findScalar(u8, line, ':') orelse continue;
        return std.mem.trim(u8, line[colon + 1 ..], " \t");
    }
    return null;
}

fn info(w: *std.Io.Writer, markdown: bool, comptime text: []const u8, args: anytype) !void {
    try w.writeAll(if (markdown) "- " else "");
    try w.print(text ++ "\n", args);
}

fn runsFor(options: Options, level: i32) usize {
    if (options.runs) |runs| return runs;
    if (options.quick) return runs_quick;
    return if (level >= level_slow_min) runs_slow else runs_default;
}

fn rowLabel(arena: std.mem.Allocator, row: Row) ![]const u8 {
    const set = if (row.whole) "whole files" else "sample";
    if (row.workers == 0) return std.fmt.allocPrint(arena, "level {d}, {s}", .{ row.level, set });
    return std.fmt.allocPrint(arena, "level {d}, {s}, {d} workers", .{
        row.level, set, row.workers,
    });
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    const options = try parseOptions(arena, args);
    const markdown = options.markdown;

    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &buffer);
    const w = &stdout.interface;

    const thp_off = builtin.os.tag == .linux and !options.huge_pages;
    if (thp_off) _ = try std.posix.prctl(.SET_THP_DISABLE, .{ 1, 0, 0, 0 });

    const corpus = (try Corpus.load(io)) orelse {
        try w.writeAll("The Silesia corpus is not fetched (its directory is empty or missing), " ++
            "so there is nothing to time; `zig build bench` fetches it when the network is up.\n");
        try w.flush();
        return;
    };
    const whole = try corpus.whole();
    const sample_per_file = if (options.quick)
        sample_bytes_quick / corpus_files.len
    else
        sample_bytes_per_file;
    const sample = try corpus.sample(sample_per_file);

    var command: std.Io.Writer.Allocating = .init(arena);
    try command.writer.writeAll("zig build bench");
    if (args.len > 1) try command.writer.writeAll(" --");
    for (args[1..]) |arg| {
        if (!std.mem.startsWith(u8, arg, "-j")) try command.writer.print(" {s}", .{arg});
    }
    const version = c.ZSTD_versionNumber();
    const runs_text = if (options.runs) |runs|
        try std.fmt.allocPrint(arena, "{d} timed runs", .{runs})
    else if (options.quick)
        try std.fmt.allocPrint(arena, "{d} timed runs", .{runs_quick})
    else
        try std.fmt.allocPrint(arena, "{d} timed runs ({d} from level {d})", .{
            runs_default, runs_slow, level_slow_min,
        });

    try w.writeAll(if (markdown) "## zig-zstd benchmark\n\n" else "zig-zstd benchmark\n");
    try info(w, markdown, "machine: {s}, {d} logical CPUs", .{
        cpuModel(io, arena) orelse "unknown CPU",
        std.Thread.getCpuCount() catch 0,
    });
    try info(w, markdown, "Zig {s}, target {t}-{t}-{t}, CPU model {s}", .{
        builtin.zig_version_string,
        builtin.cpu.arch,
        builtin.os.tag,
        builtin.abi,
        builtin.cpu.model.name,
    });
    try info(w, markdown, "port: ReleaseFast, for that target", .{});
    try info(w, markdown, "original: zstd {d}.{d}.{d} from reference/, same target: {s}", .{
        version / 10000, version / 100 % 100, version % 100, original_flags,
    });
    try info(w, markdown, "memory: transparent huge pages {s}; the {s} allocates first", .{
        if (thp_off) "off for the process" else "as the system has them",
        if (options.original_first) "original" else "port",
    });
    try info(w, markdown, "command: {s}", .{command.written()});
    try info(w, markdown, "corpus: Silesia, {d} files, {d:.1} MB; the whole-file rows take " ++
        "all of it as {d} frames, the sample rows {d:.1} MB as {d} frames", .{
        corpus_files.len,
        @as(f64, @floatFromInt(corpus.bytes)) / 1e6,
        whole.pieces.len,
        @as(f64, @floatFromInt(sample.bytes)) / 1e6,
        sample.pieces.len,
    });
    try info(w, markdown, "method: one `compress2` a frame, a reused context per side; an " ++
        "untimed warm-up of each side, then the median of {s}, the sides taking turns; " ++
        "MB are 1e6 input bytes, the verdict is the time saved or added as a share of " ++
        "the original's, or within noise when the two sides' min-max spreads overlap", .{
        runs_text,
    });
    try w.writeAll("\n");

    var rows: std.ArrayList(Row) = .empty;
    for (options.levels) |level| try rows.append(arena, .{
        .level = level,
        .workers = 0,
        .whole = !options.quick and level <= level_whole_max,
    });
    for (levels_multithread) |level| {
        if (std.mem.findScalar(i32, options.levels, level) == null) continue;
        try rows.append(arena, .{
            .level = level,
            .workers = workers,
            .whole = !options.quick and level <= level_whole_max,
        });
    }

    const table: Table = .{ .w = w, .markdown = markdown };
    try table.header();
    var checksum: u64 = 0;
    var rows_differing: usize = 0;
    for (rows.items) |row| {
        const label = try rowLabel(arena, row);
        if (row.workers != 0 and !port_multithread_merged) {
            try table.skipped(label, "skipped (not merged)");
            continue;
        }
        const set = if (row.whole) whole else sample;
        const runs = runsFor(options, row.level);
        const result = try measure(io, row, set, runs, options.original_first);
        try table.result(label, result);
        checksum += result.checksum;
        rows_differing += @intFromBool(result.frames_differing != 0);
    }

    try w.print("\nsum of the compressed sizes of every timed run, both sides: {d}\n", .{checksum});
    if (rows_differing != 0) {
        try w.print("FRAME DIFFERS in {d} row(s); see the notes above\n", .{rows_differing});
    }
    try w.flush();
}
