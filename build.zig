const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const intrinsics = b.option(
        bool,
        "intrinsics",
        "Use @Vector paths where the original uses SIMD (default true)",
    ) orelse true;
    const multithread = b.option(
        bool,
        "multithread",
        "Build multithreaded compression (default true)",
    ) orelse true;

    const public = b.addModule("zstd", .{
        .root_source_file = b.path("src/zstd.zig"),
        .target = target,
        .optimize = optimize,
    });
    public.addOptions("build_options", buildOptions(b, intrinsics, multithread));

    // Tests default to ReleaseSafe: the corpus runs take minutes in Debug, and
    // ReleaseSafe keeps every assert and overflow check on.
    const test_optimize = b.option(
        std.lang.Optimize,
        "test-optimize",
        "Optimize mode for the tests (default ReleaseSafe)",
    ) orelse .safe;
    const test_filters = b.option(
        []const []const u8,
        "test-filter",
        "Skip tests that do not match any filter",
    ) orelse &.{};
    const fuzz_seed = b.option(
        u64,
        "fuzz-seed",
        "Added to every fuzz test's first seed, for new cases (default 0)",
    ) orelse 0;
    const fuzz_cases = b.option(
        u32,
        "fuzz-cases",
        "Cases per fuzz test (default 1000)",
    ) orelse 1000;
    const corpus = b.option(
        bool,
        "corpus",
        "Run the Silesia and Canterbury corpus tests (default true)",
    ) orelse true;
    const skeptic = b.option(
        bool,
        "skeptic",
        "Run the skeptic tests, which fail until their findings are fixed (default false)",
    ) orelse false;

    const test_step = b.step("test", "Run unit and oracle tests");
    const check_step = b.step("check", "Compile the library and its tests without running them");

    const test_mod = zstdModule(b, target, test_optimize, intrinsics, multithread);
    const unit_tests = b.addTest(.{ .root_module = test_mod, .filters = test_filters });
    test_step.dependOn(&b.addRunArtifact(unit_tests).step);
    check_step.dependOn(&unit_tests.step);

    // Oracle tests: the port against the original built from reference/, on
    // the same inputs, every frame compared byte for byte. The scalar pair
    // checks the port's scalar paths against the original's scalar paths.
    const variants = [_]struct { name: []const u8, port_simd: bool, reference_simd: bool }{
        .{ .name = "oracle", .port_simd = intrinsics, .reference_simd = true },
        .{ .name = "oracle-scalar", .port_simd = false, .reference_simd = false },
    };
    const scalar_only = b.option(
        bool,
        "oracle-scalar",
        "Also run the oracle tests with both sides on their scalar paths (default true)",
    ) orelse true;

    // The original and the corpora are built and fetched only for the
    // oracle tests and the benchmark, and never for a package that depends
    // on this one.
    if (!b.isRoot()) return;
    const silesia = if (corpus) b.lazyDependency("silesia", .{}) else null;
    const canterbury = if (corpus) b.lazyDependency("canterbury", .{}) else null;

    for (variants) |variant| {
        if (!variant.reference_simd and !scalar_only) continue;
        const options = b.addOptions();
        options.addOption(u64, "fuzz_seed", fuzz_seed);
        options.addOption(u32, "fuzz_cases", fuzz_cases);
        options.addOption(bool, "skeptic", skeptic);
        options.addOption(bool, "simd", variant.port_simd);
        options.addOption(bool, "corpus", silesia != null and canterbury != null);
        if (silesia) |dep| options.addOptionPathDirectory("silesia", dep.path("")) else {
            options.addOption([]const u8, "silesia", "");
        }
        if (canterbury) |dep| options.addOptionPathDirectory("canterbury", dep.path("")) else {
            options.addOption([]const u8, "canterbury", "");
        }
        options.addOptionPathDirectory("reference", b.path("reference"));
        options.addOptionPathDirectory("data", b.path("test/data"));

        const port = zstdModule(b, target, test_optimize, variant.port_simd, multithread);
        const oracle = b.addTest(.{
            .name = variant.name,
            .root_module = b.createModule(.{
                .root_source_file = b.path("test/oracle.zig"),
                .target = target,
                .optimize = test_optimize,
                .link_libc = true,
                .imports = &.{
                    .{ .name = "zstd", .module = port },
                    .{ .name = "upstream", .module = upstreamModule(b, target) },
                    .{ .name = "test_options", .module = options.createModule() },
                },
            }),
            .filters = test_filters,
        });
        oracle.root_module.linkLibrary(referenceLibrary(b, target, variant.reference_simd));
        const run = b.addRunArtifact(oracle);
        test_step.dependOn(&run.step);
        check_step.dependOn(&oracle.step);
    }

    addBench(b, target, intrinsics, multithread, silesia);
}

fn zstdModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
    intrinsics: bool,
    multithread: bool,
) *std.Build.Module {
    const module = b.createModule(.{
        .root_source_file = b.path("src/zstd.zig"),
        .target = target,
        .optimize = optimize,
    });
    module.addOptions("build_options", buildOptions(b, intrinsics, multithread));
    return module;
}

/// The original's build switches that the port keeps, as compile-time options.
fn buildOptions(b: *std.Build, intrinsics: bool, multithread: bool) *std.Build.Step.Options {
    const options = b.addOptions();
    options.addOption(bool, "intrinsics", intrinsics);
    options.addOption(bool, "multithread", multithread);
    // ZSTD_WINDOW_OVERFLOW_CORRECT_FREQUENTLY, off as in the original's
    // library build; a test build that turns it on must build the original
    // with it too.
    options.addOption(bool, "overflow_correct_frequently", false);
    return options;
}

/// `zig build bench`: the port in ReleaseFast against the original at -O3,
/// both for `target`. Arguments after `--` go to the benchmark; the binary
/// is also installed as zig-out/bin/bench, for profiling.
fn addBench(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    intrinsics: bool,
    multithread: bool,
    silesia: ?*std.Build.Dependency,
) void {
    const bench_step = b.step("bench", "Time the port against the original (ReleaseFast)");
    const options = b.addOptions();
    if (silesia) |dep| options.addOptionPathDirectory("silesia", dep.path("")) else {
        options.addOption([]const u8, "silesia", "");
    }
    const bench = b.addExecutable(.{
        .name = "bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/bench.zig"),
            .target = target,
            .optimize = .fast,
            .link_libc = true,
            .imports = &.{
                .{ .name = "zstd", .module = zstdModule(b, target, .fast, intrinsics, multithread) },
                .{ .name = "upstream", .module = upstreamModule(b, target) },
                .{ .name = "bench_options", .module = options.createModule() },
            },
        }),
    });
    bench.root_module.linkLibrary(referenceLibrary(b, target, true));
    const run = b.addRunArtifact(bench);
    run.addPassthruArgs();
    bench_step.dependOn(&run.step);
    bench_step.dependOn(&b.addInstallArtifact(bench, .{}).step);
}

fn upstreamModule(b: *std.Build, target: std.Build.ResolvedTarget) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.path("test/upstream.zig"),
        .target = target,
    });
}

const reference_sources = [_][]const u8{
    "lib/common/debug.c",
    "lib/common/entropy_common.c",
    "lib/common/error_private.c",
    "lib/common/fse_decompress.c",
    "lib/common/pool.c",
    "lib/common/threading.c",
    "lib/common/xxhash.c",
    "lib/common/zstd_common.c",
    "lib/compress/fse_compress.c",
    "lib/compress/hist.c",
    "lib/compress/huf_compress.c",
    "lib/compress/zstd_compress.c",
    "lib/compress/zstd_compress_literals.c",
    "lib/compress/zstd_compress_sequences.c",
    "lib/compress/zstd_compress_superblock.c",
    "lib/compress/zstd_double_fast.c",
    "lib/compress/zstd_fast.c",
    "lib/compress/zstd_lazy.c",
    "lib/compress/zstd_ldm.c",
    "lib/compress/zstd_opt.c",
    "lib/compress/zstd_preSplit.c",
    "lib/compress/zstdmt_compress.c",
    "lib/decompress/huf_decompress.c",
    "lib/decompress/zstd_ddict.c",
    "lib/decompress/zstd_decompress.c",
    "lib/decompress/zstd_decompress_block.c",
    // The dictionary trainer only makes dictionaries for the tests.
    "lib/dictBuilder/cover.c",
    "lib/dictBuilder/divsufsort.c",
    "lib/dictBuilder/fastcover.c",
    "lib/dictBuilder/zdict.c",
    // The original's generator of compressible test data.
    "programs/datagen.c",
    "programs/lorem.c",
};

/// The flags of upstream's own library build (lib/libzstd.mk), at -O3:
/// Zig builds C in ReleaseFast at -O2, and a later -O3 overrides it.
const reference_flags = [_][]const u8{
    "-O3",
    "-std=c99",
    "-DXXH_NAMESPACE=ZSTD_",
    "-DZSTD_MULTITHREAD",
    "-DZSTD_LEGACY_SUPPORT=0",
    "-fno-sanitize=undefined",
};

const reference_scalar_flags = reference_flags ++ [_][]const u8{
    "-DZSTD_NO_INTRINSICS",
    "-DDYNAMIC_BMI2=0",
    "-DZSTD_DISABLE_ASM",
};

/// The original library from reference/, as a shared library on glibc, so
/// its calls into the C library bind to the system's, as in a normal build
/// of it, rather than to compiler_rt's versions. `simd` false builds it
/// with its scalar paths only.
fn referenceLibrary(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    simd: bool,
) *std.Build.Step.Compile {
    const glibc = target.result.isGnuLibC();
    const library = b.addLibrary(.{
        .name = if (simd) "zstd_reference" else "zstd_reference_scalar",
        .linkage = if (glibc) .dynamic else .static,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = .fast,
            .link_libc = true,
        }),
    });
    if (glibc) library.bundle_compiler_rt = false;
    library.root_module.addCSourceFiles(.{
        .root = b.path("reference"),
        .files = &reference_sources,
        .flags = if (simd) &reference_flags else &reference_scalar_flags,
    });
    if (simd and target.result.cpu.arch == .x86_64) {
        library.root_module.addAssemblyFile(b.path("reference/lib/decompress/huf_decompress_amd64.S"));
    }
    library.root_module.addCSourceFile(.{
        .file = b.path("test/reference.c"),
        .flags = if (simd) &reference_flags else &reference_scalar_flags,
    });
    library.root_module.addIncludePath(b.path("reference/lib"));
    library.root_module.addIncludePath(b.path("reference/lib/common"));
    library.root_module.addIncludePath(b.path("reference/programs"));
    return library;
}
