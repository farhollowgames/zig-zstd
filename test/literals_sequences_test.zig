//! Oracle tests for a compressed block's two sections: the literals section
//! (`ZSTD_compressLiterals`) and the sequences section's steps (the encoding
//! type of each code table, its table and header, and the bit stream),
//! against the original's functions on the same inputs. Literals and
//! sequences come from real blocks of the fast block compressor, and each
//! run carries its tables from block to block, as a frame does, so the
//! repeat paths are taken.

const std = @import("std");
const zstd = @import("zstd");
const c = @import("upstream");
const common = @import("common.zig");
const test_options = @import("test_options");

const ci = zstd.internal.compress_internal;
const zi = zstd.internal.zstd_internal;
const fast = zstd.internal.fast;
const compress_literals = zstd.internal.compress_literals;
const compress_sequences = zstd.internal.compress_sequences;
const params = zstd.params;
const gpa = common.gpa;
const testing = std.testing;

const HufCTable = @FieldType(ci.HufCTables, "ctable");

/// The original's `ZSTD_hufCTables_t`.
const CHufCTables = extern struct {
    ctable: HufCTable,
    repeat_mode: c_int,
};

extern fn ZSTD_compressLiterals(
    dst: [*]u8,
    dst_capacity: usize,
    src: [*]const u8,
    src_size: usize,
    entropy_workspace: *anyopaque,
    entropy_workspace_size: usize,
    prev_huf: *const CHufCTables,
    next_huf: *CHufCTables,
    strategy: c_int,
    disable_literal_compression: c_int,
    suspect_uncompressible: c_int,
    bmi2: c_int,
) usize;

extern fn ZSTD_selectEncodingType(
    repeat_mode: *c_int,
    count: [*]const u32,
    max: u32,
    most_frequent: usize,
    nb_seq: usize,
    fse_log: u32,
    prev_ctable: [*]const u32,
    default_norm: [*]const i16,
    default_norm_log: u32,
    is_default_allowed: c_int,
    strategy: c_int,
) c_int;

extern fn ZSTD_buildCTable(
    dst: [*]u8,
    dst_capacity: usize,
    next_ctable: [*]u32,
    fse_log: u32,
    h_type: c_int,
    count: [*]u32,
    max: u32,
    code_table: [*]const u8,
    nb_seq: usize,
    default_norm: [*]const i16,
    default_norm_log: u32,
    default_max: u32,
    prev_ctable: [*]const u32,
    prev_ctable_size: usize,
    entropy_workspace: *anyopaque,
    entropy_workspace_size: usize,
) usize;

extern fn ZSTD_encodeSequences(
    dst: [*]u8,
    dst_capacity: usize,
    ctable_match_length: [*]const u32,
    ml_code_table: [*]const u8,
    ctable_offset_bits: [*]const u32,
    of_code_table: [*]const u8,
    ctable_lit_length: [*]const u32,
    ll_code_table: [*]const u8,
    sequences: [*]const ci.SeqDef,
    nb_seq: usize,
    long_offsets: c_int,
    bmi2: c_int,
) usize;

/// A size, or an error code: the port's result in the original's terms.
fn portResult(result: zstd.Error!usize) common.Result {
    const size = result catch |err| return .{ .error_code = @backingInt(zstd.errorCode(err)) };
    return .{ .size = size };
}

const workspace_u64 = ci.entropy_workspace_size / 8;

/// One block of an input, through the fast block compressor: its stored
/// sequences, literals and long length.
const Block = struct {
    test_block: *ci.BlockTest,
    sequences: []const ci.SeqDef,
    literals: []const u8,

    fn init(src: []const u8) !Block {
        const cparams: params.CompressionParameters = .{
            .window_log = 17,
            .chain_log = 16,
            .hash_log = 14,
            .search_log = 1,
            .min_match = 6,
            .target_length = 0,
            .strategy = .fast,
        };
        const block = try ci.BlockTest.create(gpa, cparams, src, .none, fast.fillHashTable);
        _ = block.run(fast.compressBlockFast, src);
        return .{
            .test_block = block,
            .sequences = block.storedSequences(),
            .literals = block.storedLiterals(),
        };
    }

    fn deinit(self: Block) void {
        self.test_block.destroy();
    }
};

/// Inputs: the original's golden inputs (their first 128 KiB), generated
/// data of several kinds, and the same block cut short.
fn inputs() !std.ArrayList([]u8) {
    var list: std.ArrayList([]u8) = .empty;
    errdefer {
        for (list.items) |input| gpa.free(input);
        list.deinit(gpa);
    }
    for ([_][]const u8{
        "http",
        "huffman-compressed-larger",
        "large-literal-and-match-lengths",
        "PR-3517-block-splitter-corruption-test",
    }) |name| {
        const path = try std.fmt.allocPrint(gpa, "tests/golden-compression/{s}", .{name});
        defer gpa.free(path);
        const bytes = try common.readFile(test_options.reference, path);
        defer gpa.free(bytes);
        try list.append(gpa, try gpa.dupe(u8, bytes[0..@min(bytes.len, params.block_size_max)]));
    }
    const generated = [_]struct { size: usize, match: f64, lit: f64, seed: u32 }{
        .{ .size = 128 * 1024, .match = 0.5, .lit = 0.0, .seed = 1 },
        .{ .size = 128 * 1024, .match = 0.9, .lit = 0.2, .seed = 2 },
        .{ .size = 100_000, .match = 0.2, .lit = 0.5, .seed = 3 },
        .{ .size = 4096, .match = 0.7, .lit = 0.0, .seed = 4 },
        .{ .size = 1000, .match = 0.3, .lit = 0.9, .seed = 5 },
        .{ .size = 300, .match = 0.5, .lit = 0.5, .seed = 6 },
        .{ .size = 64 * 1024, .match = 0.98, .lit = 0.0, .seed = 7 },
    };
    for (generated) |g| try list.append(gpa, try common.generated(g.size, g.match, g.lit, g.seed));
    const random = try gpa.alloc(u8, 20_000);
    var prng = std.Random.DefaultPrng.init(42);
    prng.random().bytes(random);
    try list.append(gpa, random);
    return list;
}

fn freeInputs(list: *std.ArrayList([]u8)) void {
    for (list.items) |input| gpa.free(input);
    list.deinit(gpa);
}

/// The literal sources: each block's stored literals, and prefixes of its
/// input, from empty to the whole block.
fn literalSources(input: []const u8, block: Block) [12][]const u8 {
    var sources: [12][]const u8 = undefined;
    sources[0] = block.literals;
    const sizes = [_]usize{ 0, 1, 5, 6, 7, 8, 63, 255, 1023, 16383, input.len };
    for (sizes, 1..) |size, i| sources[i] = input[0..@min(size, input.len)];
    return sources;
}

/// Whether `huf_tables` is a built table with a code for every byte of
/// `src`: its header's largest symbol covers them, and each has bits.
fn coversAll(huf_tables: *const ci.HufCTables, src: []const u8) bool {
    if (huf_tables.repeat_mode == .none) return false;
    const max_symbol: usize = (huf_tables.ctable[0] >> 8) & 0xFF;
    for (src) |byte| {
        if (byte > max_symbol or huf_tables.ctable[1 + @as(usize, byte)] & 0xFF == 0) return false;
    }
    return true;
}

const LiteralsRun = struct {
    port_prev: ci.HufCTables,
    upstream_prev: CHufCTables,
    port_workspace: []u64,
    upstream_workspace: []u64,
    dst_port: []u8,
    dst_upstream: []u8,

    /// Compresses `src` on both sides into the first `capacity` bytes of
    /// the outputs and compares the results, the bytes and the tables left.
    /// With `valid`, the previous table is first marked valid, as a loaded
    /// dictionary leaves it, when it codes every byte of `src`.
    fn step(
        self: *LiteralsRun,
        src: []const u8,
        capacity: usize,
        strategy: params.Strategy,
        disable: bool,
        suspect: bool,
        valid: bool,
    ) !void {
        if (valid and coversAll(&self.port_prev, src)) {
            self.port_prev.repeat_mode = .valid;
            self.upstream_prev.repeat_mode = @backingInt(zstd.internal.huf.Repeat.valid);
        }
        var port_next: ci.HufCTables = undefined;
        var upstream_next: CHufCTables = undefined;
        const port = portResult(compress_literals.compressLiterals(
            self.dst_port[0..capacity],
            src,
            std.mem.sliceAsBytes(self.port_workspace),
            &self.port_prev,
            &port_next,
            strategy,
            disable,
            suspect,
            false,
        ));
        const upstream = common.Result.of(ZSTD_compressLiterals(
            self.dst_upstream.ptr,
            capacity,
            src.ptr,
            src.len,
            self.upstream_workspace.ptr,
            self.upstream_workspace.len * 8,
            &self.upstream_prev,
            &upstream_next,
            @intCast(@backingInt(strategy)),
            @intFromBool(disable),
            @intFromBool(suspect),
            0,
        ));
        try testing.expectEqual(upstream, port);
        switch (upstream) {
            .size => |size| try testing.expectEqualSlices(
                u8,
                self.dst_upstream[0..size],
                self.dst_port[0..size],
            ),
            .error_code => {},
        }
        try testing.expectEqual(upstream_next.repeat_mode, @as(c_int, @intCast(@backingInt(port_next.repeat_mode))));
        try testing.expectEqualSlices(usize, &upstream_next.ctable, &port_next.ctable);
        self.port_prev = port_next;
        self.upstream_prev = upstream_next;
    }
};

test "literals: the literals section against ZSTD_compressLiterals" {
    var list = try inputs();
    defer freeInputs(&list);
    const port_workspace = try gpa.alloc(u64, workspace_u64);
    defer gpa.free(port_workspace);
    const upstream_workspace = try gpa.alloc(u64, workspace_u64);
    defer gpa.free(upstream_workspace);
    const dst_size = params.block_size_max + 64;
    const dst_port = try gpa.alloc(u8, dst_size);
    defer gpa.free(dst_port);
    const dst_upstream = try gpa.alloc(u8, dst_size);
    defer gpa.free(dst_upstream);

    var cases: usize = 0;
    for (1..10) |strat| {
        const strategy: params.Strategy = @fromBackingInt(@as(u32, @intCast(strat)));
        var run: LiteralsRun = .{
            .port_prev = std.mem.zeroes(ci.HufCTables),
            .upstream_prev = std.mem.zeroes(CHufCTables),
            .port_workspace = port_workspace,
            .upstream_workspace = upstream_workspace,
            .dst_port = dst_port,
            .dst_upstream = dst_upstream,
        };
        for (list.items, 0..) |input, input_index| {
            const block = try Block.init(input);
            defer block.deinit();
            for (literalSources(input, block), 0..) |src, source_index| {
                const full = src.len + 8;
                const suspect = (input_index + source_index) % 3 == 0;
                try run.step(src, full, strategy, false, suspect, false);
                try run.step(src, full, strategy, false, suspect, true);
                try run.step(src, full, strategy, true, false, false);
                // Too small for the compressed section, then for raw literals.
                try run.step(src, src.len / 2 + 4, strategy, false, suspect, false);
                try run.step(src, src.len / 8, strategy, false, false, false);
                cases += 5;
            }
        }
    }
    try testing.expect(cases > 3000);
}

/// One code table's settings, as `ZSTD_buildSequencesStatistics` uses them.
const CodeKind = struct {
    max: u32,
    fse_log: u32,
    default_norm: []const i16,
    default_norm_log: u32,
    default_max: u32,
};

const ll_kind: CodeKind = .{
    .max = zi.max_ll,
    .fse_log = zi.ll_fse_log,
    .default_norm = &zi.ll_default_norm,
    .default_norm_log = zi.ll_default_norm_log,
    .default_max = zi.max_ll,
};
const of_kind: CodeKind = .{
    .max = zi.max_off,
    .fse_log = zi.off_fse_log,
    .default_norm = &zi.of_default_norm,
    .default_norm_log = zi.of_default_norm_log,
    .default_max = zi.default_max_off,
};
const ml_kind: CodeKind = .{
    .max = zi.max_ml,
    .fse_log = zi.ml_fse_log,
    .default_norm = &zi.ml_default_norm,
    .default_norm_log = zi.ml_default_norm_log,
    .default_max = zi.max_ml,
};

/// The code tables of a block's sequences, as `ZSTD_seqToCodes` makes them.
const Codes = struct {
    ll: []u8,
    of: []u8,
    ml: []u8,

    fn init(block: Block) !Codes {
        const n = block.sequences.len;
        const self: Codes = .{
            .ll = try gpa.alloc(u8, n),
            .of = try gpa.alloc(u8, n),
            .ml = try gpa.alloc(u8, n),
        };
        for (block.sequences, 0..) |seq, i| {
            self.ll[i] = @intCast(ci.llCode(seq.lit_length));
            self.of[i] = @intCast(ci.highbit32(seq.off_base));
            self.ml[i] = @intCast(ci.mlCode(seq.ml_base));
        }
        const seq_store = &block.test_block.seq_store;
        switch (seq_store.long_length_type) {
            .none => {},
            .literal_length => self.ll[seq_store.long_length_pos] = zi.max_ll,
            .match_length => self.ml[seq_store.long_length_pos] = zi.max_ml,
        }
        return self;
    }

    fn deinit(self: Codes) void {
        gpa.free(self.ll);
        gpa.free(self.of);
        gpa.free(self.ml);
    }
};

/// One side's state for one code table, carried from block to block.
fn TableState(comptime CTable: type) type {
    return struct {
        prev: CTable = std.mem.zeroes(CTable),
        repeat_mode: u32 = 0,
    };
}

const SequencesRun = struct {
    strategy: params.Strategy,
    port_workspace: []u64,
    upstream_workspace: []u64,
    port_ll: TableState(@FieldType(ci.FseCTables, "litlength_ctable")) = .{},
    port_of: TableState(@FieldType(ci.FseCTables, "offcode_ctable")) = .{},
    port_ml: TableState(@FieldType(ci.FseCTables, "matchlength_ctable")) = .{},
    upstream_ll: TableState(@FieldType(ci.FseCTables, "litlength_ctable")) = .{},
    upstream_of: TableState(@FieldType(ci.FseCTables, "offcode_ctable")) = .{},
    upstream_ml: TableState(@FieldType(ci.FseCTables, "matchlength_ctable")) = .{},

    /// Selects the encoding type and builds the table for one code table on
    /// both sides, compares them, and makes the new tables the previous.
    fn table(
        self: *SequencesRun,
        kind: CodeKind,
        codes: []const u8,
        port_state: anytype,
        upstream_state: anytype,
    ) !void {
        var count = [_]u32{0} ** (zi.max_seq + 1);
        for (codes) |code| count[code] += 1;
        var max: u32 = kind.max;
        while (count[max] == 0) max -= 1;
        const most_frequent = std.mem.max(u32, count[0 .. max + 1]);
        const policy: compress_sequences.DefaultPolicy =
            if (kind.default_max == zi.default_max_off and max > zi.default_max_off)
                .disallowed
            else
                .allowed;

        var port_repeat: zstd.internal.fse.Repeat = @fromBackingInt(port_state.repeat_mode);
        const port_type = compress_sequences.selectEncodingType(
            &port_repeat,
            &count,
            max,
            most_frequent,
            codes.len,
            kind.fse_log,
            &port_state.prev,
            kind.default_norm,
            kind.default_norm_log,
            policy,
            self.strategy,
        );
        var upstream_repeat: c_int = @intCast(upstream_state.repeat_mode);
        const upstream_type = ZSTD_selectEncodingType(
            &upstream_repeat,
            &count,
            max,
            most_frequent,
            codes.len,
            kind.fse_log,
            &upstream_state.prev,
            kind.default_norm.ptr,
            kind.default_norm_log,
            @backingInt(policy),
            @intCast(@backingInt(self.strategy)),
        );
        try testing.expectEqual(upstream_type, @as(c_int, @backingInt(port_type)));
        try testing.expectEqual(upstream_repeat, @as(c_int, @intCast(@backingInt(port_repeat))));
        port_state.repeat_mode = @backingInt(port_repeat);
        upstream_state.repeat_mode = @intCast(upstream_repeat);

        const CTable = @TypeOf(port_state.prev);
        // A header has at most 512 bytes; the small capacities fail it.
        for ([_]usize{ 600, 3, 0 }) |capacity| {
            var port_dst: [600]u8 = undefined;
            var upstream_dst: [600]u8 = undefined;
            var port_count = count;
            var upstream_count = count;
            var port_next: CTable = std.mem.zeroes(CTable);
            var upstream_next: CTable = std.mem.zeroes(CTable);
            const port = portResult(compress_sequences.buildCTable(
                port_dst[0..capacity],
                &port_next,
                kind.fse_log,
                port_type,
                &port_count,
                max,
                codes,
                kind.default_norm,
                kind.default_norm_log,
                kind.default_max,
                &port_state.prev,
                std.mem.sliceAsBytes(self.port_workspace),
            ));
            const upstream = common.Result.of(ZSTD_buildCTable(
                &upstream_dst,
                capacity,
                &upstream_next,
                kind.fse_log,
                upstream_type,
                &upstream_count,
                max,
                codes.ptr,
                codes.len,
                kind.default_norm.ptr,
                kind.default_norm_log,
                kind.default_max,
                &upstream_state.prev,
                @sizeOf(CTable),
                self.upstream_workspace.ptr,
                self.upstream_workspace.len * 8,
            ));
            try testing.expectEqual(upstream, port);
            try testing.expectEqualSlices(u32, &upstream_count, &port_count);
            switch (upstream) {
                .size => |size| {
                    try testing.expectEqualSlices(u8, upstream_dst[0..size], port_dst[0..size]);
                    try testing.expectEqualSlices(u32, &upstream_next, &port_next);
                    if (capacity == 600) {
                        port_state.prev = port_next;
                        upstream_state.prev = upstream_next;
                    }
                },
                .error_code => try testing.expect(capacity < 600),
            }
        }
    }

    /// Runs the sequences section's steps for `block` on both sides.
    fn step(self: *SequencesRun, block: Block, dst_port: []u8, dst_upstream: []u8) !usize {
        const nb_seq = block.sequences.len;
        if (nb_seq == 0) return 0;
        const codes = try Codes.init(block);
        defer codes.deinit();
        try self.table(ll_kind, codes.ll, &self.port_ll, &self.upstream_ll);
        try self.table(of_kind, codes.of, &self.port_of, &self.upstream_of);
        try self.table(ml_kind, codes.ml, &self.port_ml, &self.upstream_ml);

        var cases: usize = 3;
        for ([_]bool{ false, true }) |long_offsets| {
            var expected_size: usize = 0;
            // The whole stream, then one byte short of it, then too small to
            // start.
            for (0..3) |attempt| {
                const capacity = switch (attempt) {
                    0 => dst_port.len,
                    1 => expected_size -| 1,
                    else => 8,
                };
                const port = portResult(compress_sequences.encodeSequences(
                    dst_port[0..capacity],
                    &self.port_ml.prev,
                    codes.ml,
                    &self.port_of.prev,
                    codes.of,
                    &self.port_ll.prev,
                    codes.ll,
                    block.sequences,
                    long_offsets,
                    false,
                ));
                const upstream = common.Result.of(ZSTD_encodeSequences(
                    dst_upstream.ptr,
                    capacity,
                    &self.upstream_ml.prev,
                    codes.ml.ptr,
                    &self.upstream_of.prev,
                    codes.of.ptr,
                    &self.upstream_ll.prev,
                    codes.ll.ptr,
                    block.sequences.ptr,
                    nb_seq,
                    @intFromBool(long_offsets),
                    0,
                ));
                try testing.expectEqual(upstream, port);
                switch (upstream) {
                    .size => |size| {
                        try testing.expectEqualSlices(u8, dst_upstream[0..size], dst_port[0..size]);
                        if (attempt == 0) expected_size = size;
                    },
                    .error_code => try testing.expect(attempt != 0),
                }
                cases += 1;
            }
        }
        return cases;
    }
};

test "sequences: encoding types, tables and bit stream against the original's" {
    var list = try inputs();
    defer freeInputs(&list);
    const port_workspace = try gpa.alloc(u64, workspace_u64);
    defer gpa.free(port_workspace);
    const upstream_workspace = try gpa.alloc(u64, workspace_u64);
    defer gpa.free(upstream_workspace);
    const dst_size = params.block_size_max * 2;
    const dst_port = try gpa.alloc(u8, dst_size);
    defer gpa.free(dst_port);
    const dst_upstream = try gpa.alloc(u8, dst_size);
    defer gpa.free(dst_upstream);

    var cases: usize = 0;
    for (1..10) |strat| {
        var run: SequencesRun = .{
            .strategy = @fromBackingInt(@as(u32, @intCast(strat))),
            .port_workspace = port_workspace,
            .upstream_workspace = upstream_workspace,
        };
        // Each input twice, so the second pass starts from the tables of
        // the block before it.
        for (0..2) |_| {
            for (list.items) |input| {
                const block = try Block.init(input);
                defer block.deinit();
                cases += try run.step(block, dst_port, dst_upstream);
            }
        }
    }
    try testing.expect(cases > 1000);
}
