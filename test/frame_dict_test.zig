//! Oracle tests of compression with dictionaries: raw content, full
//! dictionaries from the trainer and the original's test files, loaded by
//! copy and by reference, as prefixes, digested into a `CDict` and attached,
//! copied or reloaded. The original decodes every frame with the same
//! dictionary; std's decoder takes none.

const std = @import("std");
const zstd = @import("zstd");
const c = @import("upstream");
const common = @import("common.zig");
const frame = @import("frame_test.zig");
const test_options = @import("test_options");

const params = zstd.params;
const gpa = common.gpa;
const testing = std.testing;
const Pair = frame.Pair;
const expectSameResult = frame.expectSameResult;

/// The dictionaries the tests use, and inputs that resemble them. Freed by
/// `deinit`.
const Dicts = struct {
    corpus: []u8,
    raw: []u8,
    trained: []u8,
    small_trained: []u8,
    golden: []u8,
    zero_weight: []u8,

    fn init() !Dicts {
        const corpus = try common.generated(2 << 20, 0.6, 0.3, 71);
        errdefer gpa.free(corpus);
        const raw = try gpa.dupe(u8, corpus[0..60_000]);
        errdefer gpa.free(raw);
        const trained = try train(corpus, 110 * 1024);
        errdefer gpa.free(trained);
        const small_trained = try train(corpus, 4096);
        errdefer gpa.free(small_trained);
        const golden = try common.readFile(
            test_options.reference,
            "tests/golden-dictionaries/http-dict-missing-symbols",
        );
        errdefer gpa.free(golden);
        const zero_weight = try common.readFile(
            test_options.reference,
            "tests/dict-files/zero-weight-dict",
        );
        return .{
            .corpus = corpus,
            .raw = raw,
            .trained = trained,
            .small_trained = small_trained,
            .golden = golden,
            .zero_weight = zero_weight,
        };
    }

    fn deinit(d: Dicts) void {
        gpa.free(d.corpus);
        gpa.free(d.raw);
        gpa.free(d.trained);
        gpa.free(d.small_trained);
        gpa.free(d.golden);
        gpa.free(d.zero_weight);
    }

    /// Every dictionary, with whether it is raw content.
    fn all(d: Dicts) [5]struct { bytes: []const u8, raw: bool } {
        return .{
            .{ .bytes = d.raw, .raw = true },
            .{ .bytes = d.trained, .raw = false },
            .{ .bytes = d.small_trained, .raw = false },
            .{ .bytes = d.golden, .raw = false },
            .{ .bytes = d.zero_weight, .raw = false },
        };
    }

    /// Inputs of several sizes from the corpus, past the dictionaries'
    /// samples.
    fn input(d: Dicts, size: usize) []const u8 {
        return d.corpus[d.corpus.len - size ..];
    }
};

/// A dictionary of `capacity` bytes trained on 1 KiB samples of `corpus`.
fn train(corpus: []const u8, capacity: usize) ![]u8 {
    const nb_samples = 1000;
    var sizes: [nb_samples]usize = @splat(1024);
    const dict = try gpa.alloc(u8, capacity);
    errdefer gpa.free(dict);
    const code = c.ZDICT_trainFromBuffer(dict.ptr, dict.len, corpus.ptr, &sizes, nb_samples);
    if (c.ZDICT_isError(code) != 0) return error.TrainingFailed;
    return gpa.realloc(dict, code);
}

const input_sizes = [_]usize{ 0, 1, 100, 1000, 20_000, 200_000, 1 << 20 };

/// Checks a frame made with `dict` decodes back through the original.
fn expectDecodes(out: []const u8, src: []const u8, dict: ?[]const u8) !void {
    try common.expectUpstreamDecodes(out, src, dict);
}

test "compressUsingDict: every dictionary at a level of each strategy" {
    const d = try Dicts.init();
    defer d.deinit();
    const pair = try Pair.init();
    defer pair.deinit();
    const expected = try frame.boundBuffer(1 << 20);
    defer gpa.free(expected);
    const dst = try frame.boundBuffer(1 << 20);
    defer gpa.free(dst);
    for (d.all()) |dict| {
        for (frame.strategy_levels ++ [_]i32{ -131072, 2, 4, 9, 12 }) |level| {
            for (input_sizes) |size| {
                const src = d.input(size);
                const code = c.ZSTD_compress_usingDict(
                    pair.upstream,
                    expected.ptr,
                    expected.len,
                    src.ptr,
                    src.len,
                    dict.bytes.ptr,
                    dict.bytes.len,
                    level,
                );
                const result = pair.port.compressUsingDict(dst, src, dict.bytes, level);
                expectSameResult(code, result) catch |err| {
                    std.debug.print(
                        "dict {d} bytes, level {d}, {d} bytes\n",
                        .{ dict.bytes.len, level, size },
                    );
                    return err;
                };
                const n = result catch continue;
                common.expectSameFrame(expected[0..code], dst[0..n]) catch |err| {
                    std.debug.print(
                        "dict {d} bytes, level {d}, {d} bytes\n",
                        .{ dict.bytes.len, level, size },
                    );
                    return err;
                };
                try expectDecodes(dst[0..n], src, dict.bytes);
            }
        }
    }
}

test "loadDictionary: by copy, by reference, each content type, each attach mode" {
    const d = try Dicts.init();
    defer d.deinit();
    for (d.all()) |dict| {
        for ([_]i32{ -5, 1, 3, 6, 13, 19 }) |level| {
            for (0..3) |method| {
                for (std.enums.values(params.DictContentType)) |content_type| {
                    for (0..4) |attach| {
                        const pair = try Pair.init();
                        defer pair.deinit();
                        try pair.set(.compression_level, level);
                        try pair.set(.force_attach_dict, @intCast(attach));
                        switch (method) {
                            0 => try expectSameResult(
                                c.ZSTD_CCtx_loadDictionary(
                                    pair.upstream,
                                    dict.bytes.ptr,
                                    dict.bytes.len,
                                ),
                                pair.port.loadDictionary(dict.bytes),
                            ),
                            1 => try expectSameResult(
                                c.ZSTD_CCtx_loadDictionary_byReference(
                                    pair.upstream,
                                    dict.bytes.ptr,
                                    dict.bytes.len,
                                ),
                                pair.port.loadDictionaryByReference(dict.bytes),
                            ),
                            else => try expectSameResult(
                                c.ZSTD_CCtx_loadDictionary_advanced(
                                    pair.upstream,
                                    dict.bytes.ptr,
                                    dict.bytes.len,
                                    1,
                                    @backingInt(content_type),
                                ),
                                pair.port.loadDictionaryAdvanced(dict.bytes, .by_ref, content_type),
                            ),
                        }
                        // Two frames each: the dictionary stays for the next.
                        for ([_]usize{ 1000, 200_000, 50 }) |size| {
                            const src = d.input(size);
                            const out = pair.compress2Frame(
                                src,
                                c.ZSTD_compressBound(size),
                            ) catch |err| {
                                std.debug.print(
                                    "dict {d}, level {d}, method {d}, {t}, attach {d}, {d} bytes\n",
                                    .{ dict.bytes.len, level, method, content_type, attach, size },
                                );
                                return err;
                            } orelse continue;
                            defer gpa.free(out);
                            const as_dict = content_type != .raw_content or dict.raw;
                            if (as_dict) try expectDecodes(out, src, dict.bytes);
                        }
                        if (method != 0) break;
                    }
                    if (method != 2) break;
                }
            }
        }
    }
}

test "refPrefix: raw prefixes, one frame each" {
    const d = try Dicts.init();
    defer d.deinit();
    const pair = try Pair.init();
    defer pair.deinit();
    for (frame.strategy_levels) |level| {
        try pair.set(.compression_level, level);
        for ([_]usize{ 0, 8, 1000, 60_000 }) |prefix_size| {
            for (std.enums.values(params.DictContentType)) |content_type| {
                const prefix = d.raw[0..prefix_size];
                try expectSameResult(
                    c.ZSTD_CCtx_refPrefix_advanced(
                        pair.upstream,
                        prefix.ptr,
                        prefix.len,
                        @backingInt(content_type),
                    ),
                    pair.port.refPrefixAdvanced(prefix, content_type),
                );
                const src = d.input(100_000);
                if (try pair.compress2Frame(src, c.ZSTD_compressBound(src.len))) |out| {
                    defer gpa.free(out);
                    if (content_type != .full_dict) try expectDecodes(out, src, prefix);
                }
                // The prefix is gone for the next frame.
                _ = try pair.compress2(d.input(5000), c.ZSTD_compressBound(5000));
            }
        }
    }
}

/// Streams `src` on both sides with `.flush` and then `.end`, so the size
/// stays unknown, and compares every result and the frames. Returns the
/// port's frame; the caller frees it.
fn flushedStreamFrame(pair: Pair, src: []const u8) ![]u8 {
    const capacity = c.ZSTD_compressBound(src.len) + 64;
    const expected = try gpa.alloc(u8, capacity);
    defer gpa.free(expected);
    const actual = try gpa.alloc(u8, capacity);
    errdefer gpa.free(actual);
    var upstream_out: c.ZSTD_outBuffer = .{ .dst = expected.ptr, .size = capacity, .pos = 0 };
    var upstream_in: c.ZSTD_inBuffer = .{ .src = src.ptr, .size = src.len, .pos = 0 };
    var port_out: zstd.OutBuffer = .{ .dst = actual };
    var port_in: zstd.InBuffer = .{ .src = src };
    for ([_]zstd.EndDirective{ .flush, .end }) |op| {
        const code = c.ZSTD_compressStream2(
            pair.upstream,
            &upstream_out,
            &upstream_in,
            @backingInt(op),
        );
        try expectSameResult(code, pair.port.compressStream2(&port_out, &port_in, op));
        try testing.expectEqual(upstream_in.pos, port_in.pos);
        try testing.expectEqual(upstream_out.pos, port_out.pos);
    }
    try common.expectSameFrame(expected[0..upstream_out.pos], actual[0..port_out.pos]);
    return gpa.realloc(actual, port_out.pos);
}

// A prefix of 2 GiB with a window log of 31 puts the dictionary's end at
// index 2^31 + 2, so the dictionary's end plus the window size wraps in u32,
// as it does in the original, and the dictionary goes at the first block.
// The prefix is a read-only mapping of zero pages, so it takes almost no
// memory.
test "refPrefix: a 2 GiB prefix with window log 31" {
    if (@sizeOf(usize) < 8) return error.SkipZigTest;
    const prefix = try std.posix.mmap(
        null,
        1 << 31,
        .{ .READ = true },
        .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
        -1,
        0,
    );
    defer std.posix.munmap(prefix);
    const src = try common.generated(200_000, 0.5, 0.3, 31);
    defer gpa.free(src);
    const pair = try Pair.init();
    defer pair.deinit();
    try pair.set(.window_log, 31);
    try pair.set(.strategy, 1);
    try pair.set(.hash_log, 16);
    try pair.set(.chain_log, 16);
    // A stable input, so neither side buffers a 2 GiB window.
    try pair.set(.stable_in_buffer, 1);
    try expectSameResult(
        c.ZSTD_CCtx_refPrefix(pair.upstream, prefix.ptr, prefix.len),
        pair.port.refPrefix(prefix),
    );
    const out = try flushedStreamFrame(pair, src);
    defer gpa.free(out);
    try expectDecodes(out, src, prefix);
}

/// A digested dictionary of each side.
const CDictPair = struct {
    port: *const zstd.CDict,
    upstream: *const c.ZSTD_CDict,
    port_workspace: ?[]align(64) u8 = null,
    upstream_workspace: ?[]align(64) u8 = null,

    fn deinit(pair: CDictPair) void {
        if (pair.port_workspace) |ws| {
            gpa.free(ws);
            gpa.free(pair.upstream_workspace.?);
            return;
        }
        @constCast(pair.port).destroy();
        _ = c.ZSTD_freeCDict(@constCast(pair.upstream));
    }

    fn expectSame(pair: CDictPair) !void {
        try testing.expectEqual(
            c.ZSTD_getDictID_fromCDict(pair.upstream),
            zstd.CDict.getDictId(pair.port),
        );
        try testing.expectEqual(c.ZSTD_sizeof_CDict(pair.upstream), zstd.CDict.sizeof(pair.port));
    }
};

/// The ways of making a `CDict` the tests cover.
const CDictKind = enum { create, by_reference, advanced_copy, advanced_ref, advanced2, static };

fn makeCDict(
    kind: CDictKind,
    dict: []const u8,
    level: i32,
    held: ?*const zstd.CCtxParams,
    uheld: ?*const c.ZSTD_CCtx_params,
) !?CDictPair {
    const cp = zstd.getCParams(level, params.content_size_unknown, dict.len);
    switch (kind) {
        .create, .by_reference => {
            const upstream = (if (kind == .create)
                c.ZSTD_createCDict(dict.ptr, dict.len, level)
            else
                c.ZSTD_createCDict_byReference(dict.ptr, dict.len, level));
            const port = if (kind == .create)
                zstd.CDict.create(gpa, dict, level)
            else
                zstd.CDict.createByReference(gpa, dict, level);
            try testing.expectEqual(upstream == null, if (port) |_| false else |_| true);
            if (upstream == null) return null;
            return .{ .port = try port, .upstream = upstream.? };
        },
        .advanced_copy, .advanced_ref => {
            const method: params.DictLoadMethod = if (kind == .advanced_copy) .by_copy else .by_ref;
            const upstream = c.ZSTD_createCDict_advanced(
                dict.ptr,
                dict.len,
                @backingInt(method),
                0,
                frame.toC(cp),
                .{},
            );
            const port = zstd.CDict.createAdvanced(gpa, dict, method, .auto, cp);
            try testing.expectEqual(upstream == null, port == null);
            if (port == null) return null;
            return .{ .port = port.?, .upstream = upstream.? };
        },
        .advanced2 => {
            const upstream = c.ZSTD_createCDict_advanced2(dict.ptr, dict.len, 0, 0, uheld.?, .{});
            const port = zstd.CDict.createAdvanced2(gpa, dict, .by_copy, .auto, held.?);
            try testing.expectEqual(upstream == null, if (port) |_| false else |_| true);
            if (upstream == null) return null;
            return .{ .port = try port, .upstream = upstream.? };
        },
        .static => {
            const size = zstd.estimateCDictSizeAdvanced(dict.len, cp, .by_copy);
            const port_workspace = try gpa.alignedAlloc(u8, .@"64", size);
            errdefer gpa.free(port_workspace);
            const upstream_workspace = try gpa.alignedAlloc(u8, .@"64", size);
            errdefer gpa.free(upstream_workspace);
            // One byte less is too small for both.
            try testing.expectEqual(
                c.ZSTD_initStaticCDict(
                    upstream_workspace.ptr,
                    size - 1,
                    dict.ptr,
                    dict.len,
                    0,
                    0,
                    frame.toC(cp),
                ) == null,
                zstd.CDict.initStatic(
                    port_workspace[0 .. size - 1],
                    dict,
                    .by_copy,
                    .auto,
                    cp,
                ) == null,
            );
            const upstream = c.ZSTD_initStaticCDict(
                upstream_workspace.ptr,
                size,
                dict.ptr,
                dict.len,
                0,
                0,
                frame.toC(cp),
            );
            const port = zstd.CDict.initStatic(port_workspace, dict, .by_copy, .auto, cp);
            try testing.expectEqual(upstream == null, port == null);
            if (port == null) {
                gpa.free(port_workspace);
                gpa.free(upstream_workspace);
                return null;
            }
            return .{
                .port = port.?,
                .upstream = upstream.?,
                .port_workspace = port_workspace,
                .upstream_workspace = upstream_workspace,
            };
        },
    }
}

test "CDict: every way to make one, compressUsingCDict and refCDict" {
    const d = try Dicts.init();
    defer d.deinit();
    const expected = try frame.boundBuffer(1 << 20);
    defer gpa.free(expected);
    const dst = try frame.boundBuffer(1 << 20);
    defer gpa.free(dst);
    const held = try zstd.CCtxParams.create(gpa);
    defer held.destroy();
    const uheld = c.ZSTD_createCCtxParams().?;
    defer _ = c.ZSTD_freeCCtxParams(uheld);
    for (d.all()) |dict| {
        for (frame.strategy_levels) |level| {
            for (std.enums.values(CDictKind)) |kind| {
                if (kind == .advanced2) {
                    // The context parameters, with and without the dedicated
                    // dictionary search.
                    _ = c.ZSTD_CCtxParams_init(uheld, level);
                    held.* = zstd.CCtxParams.init(level);
                    held.custom_mem = gpa;
                    if (level >= 5 and level <= 12) {
                        _ = c.ZSTD_CCtxParams_setParameter(uheld, 1005, 1);
                        _ = try held.setParameter(.enable_dedicated_dict_search, 1);
                    }
                }
                const cdicts = try makeCDict(kind, dict.bytes, level, held, uheld) orelse continue;
                defer cdicts.deinit();
                try cdicts.expectSame();
                const pair = try Pair.init();
                defer pair.deinit();
                for (input_sizes) |size| {
                    errdefer std.debug.print(
                        "dict {d} bytes, level {d}, {t}, {d} bytes\n",
                        .{ dict.bytes.len, level, kind, size },
                    );
                    const src = d.input(size);
                    const code = c.ZSTD_compress_usingCDict(
                        pair.upstream,
                        expected.ptr,
                        expected.len,
                        src.ptr,
                        src.len,
                        cdicts.upstream,
                    );
                    const n = try pair.port.compressUsingCDict(dst, src, cdicts.port);
                    try expectSameResult(code, @as(zstd.Error!usize, n));
                    try common.expectSameFrame(expected[0..code], dst[0..n]);
                    try expectDecodes(dst[0..n], src, dict.bytes);
                    // The frame parameters of the advanced variant.
                    const fparams: params.FrameParameters = .{
                        .content_size_flag = size % 2 == 0,
                        .checksum_flag = true,
                        .no_dict_id_flag = size % 3 == 0,
                    };
                    const code2 = c.ZSTD_compress_usingCDict_advanced(
                        pair.upstream,
                        expected.ptr,
                        expected.len,
                        src.ptr,
                        src.len,
                        cdicts.upstream,
                        frame.fparamsToC(fparams),
                    );
                    const n2 = try pair.port.compressUsingCDictAdvanced(
                        dst,
                        src,
                        cdicts.port,
                        fparams,
                    );
                    try expectSameResult(code2, @as(zstd.Error!usize, n2));
                    try common.expectSameFrame(expected[0..code2], dst[0..n2]);
                }
                // Referenced by a context, under each attach mode and level.
                for (0..4) |attach| {
                    for ([_]i32{ level, 1, 19 }) |ctx_level| {
                        try pair.set(.force_attach_dict, @intCast(attach));
                        try pair.set(.compression_level, ctx_level);
                        try expectSameResult(
                            c.ZSTD_CCtx_refCDict(pair.upstream, cdicts.upstream),
                            pair.port.refCDict(cdicts.port),
                        );
                        for ([_]usize{ 100, 200_000, 1 << 20 }) |size| {
                            const src = d.input(size);
                            const made = pair.compress2(
                                src,
                                c.ZSTD_compressBound(size),
                            ) catch |err| {
                                std.debug.print(
                                    "dict {d}, level {d}, {t}, attach {d}, level {d}, {d} bytes\n",
                                    .{ dict.bytes.len, level, kind, attach, ctx_level, size },
                                );
                                return err;
                            };
                            try testing.expect(made);
                        }
                    }
                }
                try expectSameResult(
                    c.ZSTD_CCtx_refCDict(pair.upstream, null),
                    pair.port.refCDict(null),
                );
            }
        }
    }
}

test "compressBeginUsingDict, compressBeginUsingCDict: buffer-less frames with a dictionary" {
    const d = try Dicts.init();
    defer d.deinit();
    const pair = try Pair.init();
    defer pair.deinit();
    const expected = try frame.boundBuffer(1 << 20);
    defer gpa.free(expected);
    const dst = try frame.boundBuffer(1 << 20);
    defer gpa.free(dst);
    for (d.all()) |dict| {
        for (frame.strategy_levels) |level| {
            const cdict = c.ZSTD_createCDict(dict.bytes.ptr, dict.bytes.len, level) orelse continue;
            defer _ = c.ZSTD_freeCDict(cdict);
            const port_cdict = try zstd.CDict.create(gpa, dict.bytes, level);
            defer port_cdict.destroy();
            for (0..3) |mode| {
                switch (mode) {
                    0 => try expectSameResult(
                        c.ZSTD_compressBegin_usingDict(
                            pair.upstream,
                            dict.bytes.ptr,
                            dict.bytes.len,
                            level,
                        ),
                        pair.port.compressBeginUsingDict(dict.bytes, level),
                    ),
                    1 => try expectSameResult(
                        c.ZSTD_compressBegin_usingCDict(pair.upstream, cdict),
                        pair.port.compressBeginUsingCDict(port_cdict),
                    ),
                    else => try expectSameResult(
                        c.ZSTD_compressBegin_usingCDict_advanced(pair.upstream, cdict, .{
                            .content_size_flag = 1,
                            .checksum_flag = 1,
                            .no_dict_id_flag = 0,
                        }, 300_000),
                        pair.port.compressBeginUsingCDictAdvanced(
                            port_cdict,
                            .{ .checksum_flag = true },
                            300_000,
                        ),
                    ),
                }
                const src = d.input(300_000);
                var out: usize = 0;
                var pos: usize = 0;
                for ([_]usize{ 1, 70_000, 129_000, 99_999 }) |chunk| {
                    const piece = src[pos..][0..chunk];
                    const code = c.ZSTD_compressContinue(
                        pair.upstream,
                        expected[out..].ptr,
                        expected.len - out,
                        piece.ptr,
                        piece.len,
                    );
                    const n = try pair.port.compressContinue(dst[out..], piece);
                    try expectSameResult(code, @as(zstd.Error!usize, n));
                    try common.expectSameFrame(expected[out..][0..code], dst[out..][0..n]);
                    out += n;
                    pos += chunk;
                }
                const code = c.ZSTD_compressEnd(
                    pair.upstream,
                    expected[out..].ptr,
                    expected.len - out,
                    src[pos..].ptr,
                    src.len - pos,
                );
                const n = try pair.port.compressEnd(dst[out..], src[pos..]);
                try common.expectSameFrame(expected[out..][0..code], dst[out..][0..n]);
                out += n;
                try expectDecodes(dst[0..out], src, dict.bytes);
            }
        }
    }
}
