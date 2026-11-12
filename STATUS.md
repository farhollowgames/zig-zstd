# Port status

Every public compression function, parameter, mode and build switch of zstd
1.5.7 (`reference/lib/zstd.h`, `zdict.h`, the library's build macros), with
its state:

- **not started**: nothing in zig-zstd yet;
- **ported**: translated, with no test against the original;
- **oracle-tested**: the original runs on the same inputs in `zig build test`,
  and every frame byte and returned value matches;
- **benchmarked**: oracle-tested, and timed against the original by
  `zig build bench` (see `doc/BENCHMARKS.md`);
- **reviewed**: through the performance pass, the skeptic and the fixes.

The original is pinned in `reference/` (see `reference/README.md`): tag
`v1.5.7`, commit `f8745da6ff1ad1e7bab384bd1f9d742439278e99`. `doc/porting.md`
says how the code maps to it.

## Step 4 report (11 November 2026)

**Done.** zstd 1.5.7 pinned in `reference/` (v1.5.7, f8745da6). Every feature in this file
that is not left out is ported and merged on `main`: the entropy coders, every strategy
(fast, dfast, greedy, lazy, lazy2 with the row matcher, btlazy2, btopt, btultra,
btultra2), long-distance matching, the superblock and the pre-splitter, one-shot,
buffer-less and streaming compression (`compressStream2` with continue, flush and end,
stable buffers), dictionaries, prefixes and CDicts, the sequence API and the external
sequence producer, and multithreading on `std.Thread` with its pool.

**Tests.** `zig build test` (corpus on): 306 of 306 pass in 25 minutes (58 unit, 124
`oracle`, 124 `oracle-scalar`); `-Dcorpus=false` skips Silesia and Canterbury. Each fuzz
test runs 1,000 cases. Frames are compared byte for byte with the original's, and every
frame decodes through std's decoder and the original's.

**Speed and ratio** (Silesia, one thread, `zig build bench`, before the performance pass;
`doc/BENCHMARKS.md`). Ratios are equal at every level, since the frames are equal.

| levels | port against the original |
| --- | --- |
| -5, -1 | 2% to 3% faster |
| 1 | 10% slower (whole files, noisy) |
| 2 | equal |
| 3, 4 (dfast) | 32% and 23% slower |
| 5 to 12 | 6% faster to 6% slower |
| 13 to 22 | 1% to 5% faster |
| 19 | 2.8% faster (8.3 against 8.0 MB/s, ratio 2.817) |

**Left out, approved by the author (11 November):** the list at the end of this file (dictionary
training, decompression and frame readers, `ZSTD_customMem`, BMI2 dispatch, the strategy
exclusion switches, `ZSTD_COMPRESS_HEAPMODE`, tracing, debug and sanitizer switches, C
build configuration, `ZSTD_C_PREDICT`, the fuzzing mode, `ZSTD_RESIZE_SEQPOOL`).

**For the author.** std's decoder panics when asked to verify a checksum, and takes no
dictionaries (details below). `test/data/snapshot.bin` is a snapshot pack, not B+ tree
pages. Open points for the review are listed below.

## Resume notes

Builds: one at a time, `timeout 3000 systemd-run --user --scope -q -p MemoryMax=6G
zig build <step> -j3`, never while the scratchpad's `bench.running` exists.
`zig build check` compiles everything; `zig build test -Dcorpus=false` skips the
corpus runs.

All porting branches (`port/*`) are merged into `main` and pushed. Steps 1 to 4 of the
methodology are done (the step 4 report is above), and README.md, `doc/TESTING.md` and
`doc/parity.md` are on `main`. The left-out list is approved by the author.

**Where things are.**
- `main`: the whole port, 298 of 298 tests passing with the corpora (`zig build test`,
  28 minutes), the docs, and the benchmark tables in `doc/BENCHMARKS.md` (from before
  step 5).
- `review/perf-and-skeptic`: `main` plus step 5's first change, `cc86709` (the
  double-fast finder's range test on the long candidate is a conditional move on x86-64,
  as upstream's inline-asm `ZSTD_selectAddr` is; level 4 takes 11% less time), and the
  first skeptic's probes in `test/skeptic_test.zig` behind `-Dskeptic` (all passing). A
  second skeptic adds failing tests there, one per finding, named `skeptic: ...`.
- The second skeptic (11 and 12 November), its tests behind `-Dskeptic`:
  - `skeptic: a 2 GiB prefix with window log 31 overflows the dictionary's validity
    check` panics with an integer overflow: `Window.checkDictValidity` and
    `Window.enforceMaxDist` (`compress_internal.zig`) add the window size to the
    dictionary's end in u32 with `+`, where the original's sums wrap. Any dictionary,
    prefix or CDict whose end index reaches 2^31 with window log 31 gets there; the
    dictMatchState assert in `double_fast.zig` (`dict_limit + (1 << window_log)`) is the
    same sum. **Fixed** in `46975b9`: the sums wrap (`+%`); no other u32 index sum in
    the window, the LDM or the finders has the pattern. The test is now `refPrefix: a
    2 GiB prefix with window log 31` in the normal suite (a read-only mapping of zero
    pages: a few MB, a few milliseconds).
  - `skeptic: a thread pool replaced by refThreadPool still runs the context's workers`
    fails: the multithreaded context keeps the pool and the `Io` it was made with, so
    the docs of `refThreadPool`, of the `pool` field and of `CCtx` in `zstd.zig` ("until
    they are replaced") promise what neither the port nor the original does. **Fixed**
    in `30528a0`: the docs say valid until the context is destroyed, and `multithreading:
    a pool set after the first frame with workers is not used` checks that both sides
    keep the first pool (the original's through `reference_mtFactory`).
  - Docs: `copyCCtx` does not say that the copy refers to what the source's window
    refers to (a `compressBeginUsingDict` dictionary, a CDict's content) until its frame
    ends, and `zstd.zig`'s list of references misses it. **Fixed** in `1e9973b`, with
    the docs of the `CDict` and local dictionary fields, which said a session reset
    ends them.
  - `test/mt_test.zig`'s `Observed` compares `sizeof_after_init` with workers, which
    differs between two runs of the original itself (9,167,360 against 7,337,440 in
    `zstdmt: a context reused, resized, abandoned mid-frame, on a shared pool`): drop it
    with workers. **Fixed** in `dfc7422`: the size is not compared after an abandoned
    frame, the one case whose pools depend on timing; `common.generated(0, ...)` is
    guarded in the same commit.
  - `-Doverflow-correct-frequently` (build.zig) builds both sides with
    `ZSTD_WINDOW_OVERFLOW_CORRECT_FREQUENTLY`, so the main window's overflow correction
    (`reduceIndex`, never reached by the normal suite) runs: 33 of 34 frame, stream,
    dictionary, worker and LDM tests pass at 150 fuzz cases; the 34th is the flake above.
    After the fixes the whole suite passes with it: 300 of 306 at 150 cases (the 6
    corpus runs skipped).
  - Debug (`-Dtest-optimize=Debug`, 40 fuzz cases): entropy, fast, dfast, lazy, opt and
    LDM, 50 of 50; frame, dictionaries, streams, sequences and workers, 54 of
    55 before the run was stopped in the 55th (`CDict: every way to make one ...`, still
    running after 18 minutes); in Debug the 2 GiB prefix test panics at
    `compress_internal.zig:545` (`checkDictValidity`).
  - 32-bit (`-Dtarget=x86-linux-musl`, run natively): the port does not compile.
    `compress_internal.zig:1100` and `compress_literals.zig:77` shift a `usize` by a
    `u6`, and `fse_compress.zig:589` and `:598` mix `isize` with `u32`, which fit only
    on 64-bit targets; the tests take a 64-bit `usize` too (`1 << 40` output windows in
    `stream_test.zig` and `mt_test.zig`, a 64-bit constant at `lazy_test.zig:428`).
    Nothing builds or tests a 32-bit target, though `params.zig` keeps the 32-bit limits.
    **Partly fixed** in `af1aa14`: `zig build check -Dtarget=x86-linux-musl` compiles,
    and `test -Dtarget=x86-linux-musl -Dcorpus=false` runs natively here (22 minutes):
    58 of 58 unit tests, and 116 of 124 oracle tests in each binary (4 skipped, the
    64-bit-only ones). Left, stopped at the time box:
    - **`p - window.base` without wrap-around** (55 sites: `fast.zig` 23,
      `double_fast.zig` 14, `compress_internal.zig` 7, `compress.zig` 5, `ldm.zig` 3,
      `opt.zig` 2, `lazy.zig` 1). A reused context keeps its indexes across frames, so
      `base` sits that far before the next input; with an input at a low address
      (`compressCCtx: edge cases`, a constant in `.rodata`), `base` wraps below 0 and
      `@intCast(@intFromPtr(p) - @intFromPtr(base))` panics (`buildSeqStore`,
      `compress.zig:3101`), where the original's pointer difference cast to U32 wraps.
      Fix: `@truncate(... -% ...)`, as the window functions already do; most sites are
      in the match finders, so after the perf pass merges.
    - **Tables past the address space**: a hash or chain log of 30 (4 GiB of u32) is in
      bounds on 32-bit, and the original's size_t sums wrap to a workspace too small for
      its tables; the port's estimate panics with an integer overflow
      (`estimateCCtxSizeUsingCCtxParamsInternal`, from `setParameter, getParameter:
      every parameter over its bounds`). Upstream's own limit; the test should skip
      those values on 32-bit, once what the original returns there is known.
    - `initStatic: workspaces of the estimated size, and one byte less` fails an
      `expect` with no output (likely a workspace of the level-22 estimate that a
      32-bit process cannot allocate twice); not yet looked into.
    - `compressStream2: fuzzed calls ...` (seed 984, case 479) gave the same raw value
      on both sides, 2^32 - 113, in the original's error range; the harness now takes
      that as the same, but why the hint wraps on 32-bit only is not yet known.
  - The benchmark: the original is a shared library built without upstream's own
    `-fvisibility=hidden` (`reference/lib/Makefile:147`), so 460 call sites into its
    own functions (`HIST_countFast_wksp`, `FSE_buildCTable_wksp`, `HUF_buildCTable_wksp`,
    `ZSTD_selectBlockCompressor`, ...) go through the PLT, unlike upstream's own `.so` or
    `.a`; likely small, not measured. The verdicts are medians with no noise floor: the
    -5 and -1 rows' "faster" (3.0%, 1.6%) sit inside min-max spreads of 28% to 64% of
    their medians.
  - Coverage: the fuzzers cap the window log at 25, hash and chain logs at 24, the LDM
    hash log at 22 and its rate at 9 (`frame_params_test.zig:165`), on inputs of at most
    400 KB from one generated buffer, and dictionaries stay at or below 110 KB; no test
    sets a window log above 25, which is where the overflow above lives. `oracle-scalar`
    runs other port code only in the row matcher's tag compare and the sequence
    conversion. **Fixed** in `7cc99a7`: fresh contexts reach window log 27, hash and
    chain logs 26, long distance hash log 27 and every rate, inputs reach 3 MiB and
    dictionaries (all four ways in) 20 MiB; about a minute per binary, at most 310 MB.
    The Canterbury corpus already runs at every positive level, so at every strategy.
  - Probes that found nothing: pledged sizes near 2^64 with dictionaries, CDicts,
    prefixes and workers; LDM hash logs 25 to 27, bucket log 8, minimum matches 4 to
    4096, rates 0 to 25, window logs 27 to 31; size hints near 2^31 with dictionaries;
    `max_block_size` 1024 with superblocks; CDicts of 16 MiB less 3 bytes to 20 MiB,
    past the short cache's limit, at levels -5 to 4 with every attach mode; eight
    workers with long distance matching on 512 KiB jobs, streamed in small pieces with
    flushes and small output windows, six runs of each; an input of 3.5 GiB and 8 MiB
    at levels 1, 5 and 13, through indexes past 2^31 and the overflow correction at its
    real threshold (3500 MiB).
- `review/perf-2` (worktree `zig-zstd.wt/perf2`): the second perf pass, made from
  `review/perf-and-skeptic`. Its target is no level slower than upstream, level 3 and 4
  first. Each kept change is one commit with its pinned-core gain in the message; its
  notes on what was tried are in the section below as they land.
- `port/*`: the merged porting branches, kept for history.

**To resume.**
1. Step 7 on `review/perf-and-skeptic`: the window sums, the pool docs, the copy
   docs, the test harness and the fuzz ranges are fixed, and 32-bit partly (marked
   above). The full suite with the corpora passes (306 of 306), as do `-Dskeptic` and
   `-Doverflow-correct-frequently` (counts in `doc/TESTING.md`). Left: the 32-bit
   points above, after the perf pass merges (they touch the match finders).
2. Merge `review/perf-2` into `review/perf-and-skeptic`; run the full suite with the
   corpora; set `port_multithread_merged = true` in bench/bench.zig if the perf pass has
   not; run the full benchmark pinned to one core and replace the tables in
   `doc/BENCHMARKS.md` and the README headline rows ("N% faster/slower").
3. Step 8 after the author's review: merge into `main`, version and tag.

Builds and timing: `perf` is blocked by `perf_event_paranoid` on this machine, so a
profile needs the author to lower it. Time with the build lock held and pinned to one
core, for example `flock <lock> taskset -c 6 ./zig-out/bin/bench --levels 3,4 --runs 5`.

Pushing: `main` and the review branch go to
`git@github.com:farhollowgames/zig-zstd.git`, fast-forward only.

## For the author

- std's decoder (`std.compress.zstd.Decompress`, Zig 0.17.0) cannot verify
  checksums: with `.verify_checksum = true`, any frame with a checksum and a
  non-empty block panics with "TODO all those bytes written needed to go
  through the hasher too" (Decompress.zig:373). The smallest input that shows
  it is one byte compressed with `ZSTD_c_checksumFlag` = 1. The tests decode
  through std without checksum verification and through the original with it.
- Loomwork's snapshots hold table rows as column chunks, not B+ tree pages,
  so `test/data/snapshot.bin` (a real snapshot pack from the mmo example's
  server) stands in for "B+ tree pages from a snapshot".
- std's decoder takes no dictionaries, so frames made with a dictionary or a
  prefix round-trip through the original's decoder only.

## Open points for review

- The optimal parser keeps upstream's asserts that a dictionary's Huffman
  codes are at most 11 bits and its FSE costs under 10 when it prices from
  the dictionary's tables. A hand-made dictionary that breaks them panics in a
  safe build, where upstream's release build carries on (the Huffman case is
  undefined behaviour in C). Dictionaries from the trainer satisfy both.
- `BlockTest.create` (test-only) panics on an empty block; compression never
  runs a block compressor on one.
- With long distance matching on and `ldmMinMatch` unset,
  `ZSTD_estimateCCtxSize_usingCCtxParams` and `ZSTD_estimateCStreamSize_usingCCtxParams`
  divide by zero: the original dies with SIGFPE, the port panics in a safe
  build. The estimates skip `ZSTD_ldm_adjustParameters`, which fills it in.
- An `ldmHashRateLog` over the window log makes the original's long distance
  hash log its maximum, 30: an 8 GiB table, even for an empty input. The
  port does the same.
- `initStatic` over a workspace a few bytes larger than the context: the
  original's space check wraps, and it returns a context without its block
  states, which crashes on first use. The port returns null.
- A static context cannot compress with a dictionary loaded by reference:
  `ZSTD_initLocalDict` digests it into a `CDict`, which the original mallocs
  even for a static context, and the port refuses with
  `error.MemoryAllocation` (both refuse a copy at load time).
- `CCtx.generateSequences` takes an allocator for its scratch frame, where the
  original mallocs it.
- Workers need an `std.Io`: `CCtx.setIo`, or the one of a pool given with
  `refThreadPool`. A context with workers and neither refuses with
  `error.ParameterCombinationUnsupported`. A static context cannot make its
  multithreaded context (`error.MemoryAllocation`); the original mallocs it.
- `ZSTD_CCtx_reset` leaves the count of stable input not yet taken: after a
  broken stable-input promise before a frame starts, the original's next frame
  steps back past its input and reads out of bounds. The port's assert on it
  panics in a safe build. Likewise `ZSTD_flushStream` and `ZSTD_endStream`
  before a stable-input frame starts, when the context's last frame (or none)
  buffered its input. The tests stay clear of both.
- `ZSTD_getFrameProgression` asserts at most a block buffered, but buffers a
  block and one byte when the pledged size is exactly a block; the port's
  assert allows the extra byte.
- Malformed caller sequences: the asserts in `convertBlockSequences`,
  `get1BlockSummary`, `offsetToOffbase` and `storeSeqOnly` panic in a safe
  build, where the original's release build carries on.
- The original's `convertSequences` takes its AVX2 path on `__AVX2__`, even
  with `ZSTD_NO_INTRINSICS`; the port takes its vector path only with
  `-Dintrinsics` and AVX2. Results are the same except for lengths of 2^31
  and over.
- `compressSequencesAndLiterals` keeps `litCapacity` and reads only the
  literals given. `compressSequences` ignores a frame header that does not
  fit, as the original does (under 18 bytes of output is undefined there);
  the tests give at least 18.

## Frame and one-shot compression

| original | zig-zstd | state |
| --- | --- | --- |
| `ZSTD_compress` | `compress` | oracle-tested |
| `ZSTD_compressBound`, `ZSTD_COMPRESSBOUND` | `compressBound` | oracle-tested |
| `ZSTD_compressCCtx` | `CCtx.compressCCtx` | oracle-tested |
| `ZSTD_compress2` | `CCtx.compress2` | oracle-tested (through `compressStream2_simpleArgs` with stable buffers, as the original; with 1, 2 and 4 workers, job sizes, overlaps, `rsyncable`, LDM, checksum) |
| `ZSTD_compress_advanced` | `CCtx.compressAdvanced` | oracle-tested |
| `ZSTD_writeSkippableFrame` | `writeSkippableFrame` | oracle-tested |
| `ZSTD_minCLevel`, `ZSTD_maxCLevel`, `ZSTD_defaultCLevel` | same | oracle-tested |
| `ZSTD_versionNumber`, `ZSTD_versionString` | `params.version_number`, `params.version_string` | ported (constants for 1.5.7; the tests check the reference's number) |
| `ZSTD_isError`, `ZSTD_getErrorCode`, `ZSTD_getErrorName` | `Error`, `errorCode` | oracle-tested (every failing result compares its code with the original's; names are Zig's error names) |
| frame header: magic, window descriptor, content size, dictionary id, single segment | in `compress.zig` | oracle-tested |
| checksum (XXH64) | `std.hash.XxHash64` | oracle-tested |
| raw, RLE and compressed blocks; last-block flag | in `compress.zig` | oracle-tested |
| `ZSTD_f_zstd1_magicless` | `Format.zstd1_magicless` | oracle-tested |

## Levels and strategies

| original | zig-zstd | state |
| --- | --- | --- |
| levels 1 to 22, the default level (3), level 0 | `clevels.zig` | oracle-tested (the table, against `ZSTD_getCParams`) |
| negative levels (`ZSTD_minCLevel` = -131072) | `fast` with target length | oracle-tested per block (the table rows, and `fast` with target lengths up to 100) |
| `ZSTD_fast` (`zstd_fast.c`), with dictMatchState and extDict | `fast.zig` | oracle-tested per block and in frames |
| `ZSTD_dfast` (`zstd_double_fast.c`) | `double_fast.zig` | oracle-tested per block and in frames |
| `ZSTD_greedy`, `ZSTD_lazy`, `ZSTD_lazy2` (hash chain) | `lazy.zig` | oracle-tested per block, with dictMatchState and extDict, and in frames |
| the row-based match finder (`useRowMatchFinder`), SSE2 and NEON tag compare | `lazy.zig`, `@Vector` | oracle-tested per block and in frames, SIMD and scalar builds (NEON only by a unit test on x86) |
| `ZSTD_btlazy2` (binary tree) | `lazy.zig` | oracle-tested per block, with extDict, and in frames with dictionaries |
| dedicated dictionary search (`enableDedicatedDictSearch`) | `lazy.zig` | oracle-tested per block and in frames with CDicts |
| `ZSTD_btopt`, `ZSTD_btultra`, `ZSTD_btultra2` (`zstd_opt.c`), with dictMatchState and extDict, btultra2's two passes over the first block | `opt.zig` | oracle-tested per block (`test/opt_test.zig`) and in frames |
| the optimal parser's price model: dictionary entropy tables, fixed prices for tiny blocks, literal compression off, statistics across blocks | `opt.zig` | oracle-tested per block |
| long distance match candidates in the optimal parser (`ZSTD_optLdm_*`) | `opt.zig` | oracle-tested per block, on hand-made candidates; and in frames with `ldm.zig`'s |
| long-distance matching (`zstd_ldm.c`) | `ldm.zig` | oracle-tested below the frame (`test/ldm_test.zig`: gear hash splits, parameter defaults, sequence skipping and splitting, `ZSTD_ldm_generateSequences` over far repeats, dictionaries, full stores and the overflow correction, `ZSTD_ldm_blockCompress`) and in frames, single-threaded and with workers. `ZSTD_ldm_gear_reset` never stores its hash in the original, and the port keeps that |
| `ZSTD_getCParams`, `ZSTD_getParams`, `ZSTD_checkCParams`, `ZSTD_adjustCParams` | same | oracle-tested |

## Entropy coding

| original | zig-zstd | state |
| --- | --- | --- |
| `HIST_count`, `HIST_countFast`, `_wksp` variants | `hist.zig` | oracle-tested |
| FSE: `FSE_optimalTableLog`, `FSE_normalizeCount`, `FSE_writeNCount`, `FSE_buildCTable_wksp`, `FSE_buildCTable_rle`, `FSE_compress_usingCTable` | `fse_compress.zig` | oracle-tested |
| the FSE state encoder of `fse.h` (`FSE_initCState`, `FSE_initCState2`, `FSE_encodeSymbol`, `FSE_flushCState`, `FSE_getMaxNbBits`, `FSE_bitCost`) and the bit stream writer of `bitstream.h` | `fse_compress.zig`, `bitstream.zig` | oracle-tested |
| Huffman: `HUF_optimalTableLog`, `HUF_buildCTable_wksp`, `HUF_writeCTable_wksp`, `HUF_compress1X_repeat`, `HUF_compress4X_repeat`, `HUF_compress1X_usingCTable`, `HUF_compress4X_usingCTable`, `HUF_readCTable`, `HUF_validateCTable` | `huf_compress.zig` | oracle-tested |
| `FSE_readNCount`, `HUF_readStats` (dictionary loading) | `entropy_common.zig` | oracle-tested |
| literals: raw, RLE, Huffman 1 and 4 streams, repeat table | `compress_literals.zig` | oracle-tested (`ZSTD_compressLiterals` on real blocks' literals) |
| sequences: `ZSTD_selectEncodingType`, `ZSTD_buildCTable`, `ZSTD_encodeSequences` | `compress_sequences.zig` | oracle-tested (each function, on real blocks' sequences) |

## Parameters (`ZSTD_CCtx_setParameter`, `ZSTD_CCtxParams_setParameter`)

| original | zig-zstd | state |
| --- | --- | --- |
| `ZSTD_c_compressionLevel` | `.compression_level` | oracle-tested |
| `ZSTD_c_windowLog`, `hashLog`, `chainLog`, `searchLog`, `minMatch`, `targetLength`, `strategy` | same names | oracle-tested |
| `ZSTD_c_targetCBlockSize` (superblocks, `zstd_compress_superblock.c`) | `.target_cblock_size` | oracle-tested |
| `ZSTD_c_enableLongDistanceMatching`, `ldmHashLog`, `ldmMinMatch`, `ldmBucketSizeLog`, `ldmHashRateLog` | same names | oracle-tested |
| `ZSTD_c_contentSizeFlag`, `checksumFlag`, `dictIDFlag` | same names | oracle-tested |
| `ZSTD_c_nbWorkers`, `jobSize`, `overlapLog`, `rsyncable` | same names | oracle-tested (bounds, set and get; frames with 1, 2 and 4 workers through `compress2` and `compressStream2`) |
| `ZSTD_c_format` | `.format` | oracle-tested |
| `ZSTD_c_forceMaxWindow`, `forceAttachDict` | same names | oracle-tested |
| `ZSTD_c_literalCompressionMode` | `.literal_compression_mode` | oracle-tested |
| `ZSTD_c_srcSizeHint` | `.src_size_hint` | oracle-tested |
| `ZSTD_c_enableDedicatedDictSearch` | same | oracle-tested |
| `ZSTD_c_stableInBuffer`, `stableOutBuffer` | same | oracle-tested (set and get; stable buffers in every mix, broken promises refused) |
| `ZSTD_c_blockDelimiters`, `validateSequences` | same | oracle-tested (set and get; `compressSequences` in both formats, with and without validation) |
| `ZSTD_c_blockSplitterLevel`, `splitAfterSequences` (post-split, `ZSTD_compressBlock_splitBlock`) and the pre-splitter (`zstd_preSplit.c`) | same, `pre_split.zig` | oracle-tested |
| `ZSTD_c_useRowMatchFinder` | same | oracle-tested |
| `ZSTD_c_deterministicRefPrefix` | same | oracle-tested |
| `ZSTD_c_prefetchCDictTables` | same | set and get oracle-tested (no effect on the output) |
| `ZSTD_c_enableSeqProducerFallback` | same | oracle-tested |
| `ZSTD_c_maxBlockSize` | same | oracle-tested |
| `ZSTD_c_repcodeResolution` (`searchForExternalRepcodes`) | same | oracle-tested |
| `ZSTD_cParam_getBounds` | `cParamGetBounds` | oracle-tested |
| `ZSTD_CCtx_getParameter`, `ZSTD_CCtxParams_getParameter` | same | oracle-tested |
| `ZSTD_CCtx_setCParams`, `setFParams`, `setParams` | same | oracle-tested |
| `ZSTD_createCCtxParams`, `freeCCtxParams`, `CCtxParams_reset`, `_init`, `_init_advanced` | `CCtxParams` | oracle-tested |
| `ZSTD_CCtx_setParametersUsingCCtxParams` | same | oracle-tested |
| `ZSTD_CCtx_setPledgedSrcSize` | same | oracle-tested |
| `ZSTD_CCtx_reset` (session, parameters, both) | `CCtx.reset` | oracle-tested |

## Contexts and memory

| original | zig-zstd | state |
| --- | --- | --- |
| `ZSTD_createCCtx`, `ZSTD_freeCCtx`, `ZSTD_createCCtx_advanced` (custom allocator) | `CCtx.create(gpa)`, `CCtx.destroy` | oracle-tested |
| `ZSTD_initStaticCCtx`, `ZSTD_initStaticCStream`, `ZSTD_initStaticCDict` | `initStatic` | oracle-tested |
| context reuse: tables kept between frames, workspace resize and shrink rules | `cwksp.zig` | oracle-tested (many frames on one context, changing parameters, resets) |
| `ZSTD_sizeof_CCtx`, `ZSTD_sizeof_CStream`, `ZSTD_sizeof_CDict` | same | oracle-tested |
| `ZSTD_estimateCCtxSize*`, `ZSTD_estimateCStreamSize*`, `ZSTD_estimateCDictSize*` | same | oracle-tested |
| `ZSTD_copyCCtx` | same | oracle-tested |

## Streaming

| original | zig-zstd | state |
| --- | --- | --- |
| `ZSTD_compressStream2` with `ZSTD_e_continue`, `ZSTD_e_flush`, `ZSTD_e_end` | `CCtx.compressStream2` | oracle-tested (`test/stream_test.zig`: every call's result, positions and progression; every level, one-byte windows, fuzzed calls, modes, dictionaries, pledged sizes and frames; workers) |
| `ZSTD_compressStream2_simpleArgs` | `CCtx.compressStream2SimpleArgs` | oracle-tested |
| `ZSTD_createCStream`, `freeCStream`, `CStreamInSize`, `CStreamOutSize` | `CStream` (= `CCtx`), `cStreamInSize`, `cStreamOutSize` | oracle-tested |
| `ZSTD_initCStream`, `_srcSize`, `_usingDict`, `_advanced`, `_usingCDict`, `_usingCDict_advanced`, `ZSTD_resetCStream` | same | oracle-tested |
| `ZSTD_compressStream`, `ZSTD_flushStream`, `ZSTD_endStream` | same | oracle-tested |
| `ZSTD_getFrameProgression`, `ZSTD_toFlushNow` | same | oracle-tested after every single-threaded call; with workers, run but timing-dependent, so not compared |
| buffer-less: `ZSTD_compressBegin*`, `ZSTD_compressContinue`, `ZSTD_compressEnd`, `ZSTD_getBlockSize`, `ZSTD_compressBlock` | same | oracle-tested |

## Dictionaries

| original | zig-zstd | state |
| --- | --- | --- |
| `ZSTD_compress_usingDict` | same | oracle-tested |
| `ZSTD_CCtx_loadDictionary`, `_byReference`, `_advanced` (raw content, full dictionary, auto) | same | oracle-tested |
| `ZSTD_CCtx_refPrefix`, `refPrefix_advanced` | same | oracle-tested |
| `ZSTD_createCDict`, `freeCDict`, `_advanced`, `_advanced2`, `_byReference` | `CDict` | oracle-tested |
| `ZSTD_compress_usingCDict`, `_usingCDict_advanced`, `ZSTD_CCtx_refCDict` | same | oracle-tested |
| attach, copy and load of a CDict (`forceAttachDict`) | in `compress.zig` | oracle-tested |
| entropy tables from a full dictionary (`ZSTD_loadCEntropy`) | in `compress.zig` | oracle-tested |
| `ZSTD_getDictID_fromDict`, `ZSTD_getDictID_fromCDict` | same | `getDictId` of a `CDict` oracle-tested; `ZSTD_getDictID_fromDict` is not ported |

## Sequences

| original | zig-zstd | state |
| --- | --- | --- |
| `ZSTD_sequenceBound`, `ZSTD_generateSequences`, `ZSTD_mergeBlockDelimiters` | same | oracle-tested |
| `ZSTD_compressSequences` (with and without delimiters, validation) | same | oracle-tested (`test/compress_sequences_test.zig`: generated and synthetic sequences, both formats, validation, repeat offsets, invalid sequences, small outputs) |
| `ZSTD_compressSequencesAndLiterals` (AVX2 conversion path) | same | oracle-tested (generated and synthetic sequences, refusals; vector and scalar paths) |
| `ZSTD_registerSequenceProducer`, `ZSTD_CCtxParams_registerSequenceProducer` (external match finders, fallback) | `SequenceProducer` | oracle-tested |

## Multithreading

| original | zig-zstd | state |
| --- | --- | --- |
| `zstdmt_compress.c`: jobs, overlap, job size, `rsyncable`, long distance matching across jobs, checksum, flush, frame progression, `updateCParams_whileCompressing` | `zstdmt.zig` on `std.Thread` and `std.Io` locks | oracle-tested (`test/mt_test.zig`: `ZSTDMT_initCStream_internal` and `ZSTDMT_compressStream_generic` driven as `ZSTD_compressStream2` drives them, every frame equal on every run; and through `compressStream2` and `compress2` in `test/stream_test.zig`) |
| `ZSTD_createThreadPool`, `ZSTD_freeThreadPool`, `ZSTD_CCtx_refThreadPool`; `pool.c` | `pool.createThreadPool`, `pool.freeThreadPool`, `CCtx.refThreadPool`; `pool.ThreadPool` | ported (unit tests in `pool.zig`; oracle-tested as a context's shared pool) |

## Build switches

| original | zig-zstd | state |
| --- | --- | --- |
| `ZSTD_MULTITHREAD` | `-Dmultithread` (`build_options.multithread`) | ported (off: one shared pool runs jobs inline, and no multithreaded context is made) |
| `ZSTD_NO_INTRINSICS`, `ZSTD_ARCH_X86_SSE2`, `ZSTD_ARCH_X86_AVX2`, `ZSTD_ARCH_ARM_NEON` | `-Dintrinsics`, the target's CPU features | oracle-tested (the `oracle` build against the reference with SIMD, `oracle-scalar` with intrinsics off on both sides; NEON only by a unit test on x86) |
| `ZSTD_CLEVEL_DEFAULT` | `params.clevel_default` | oracle-tested (level 0 and the default level against `ZSTD_getCParams`) |
| `ZSTDMT_NBWORKERS_MAX`, `ZSTDMT_JOBSIZE_MIN`, `ZSTDMT_JOBSIZE_MAX` | `nbworkers_max`, `jobsize_min`, `jobsize_max` in `zstdmt.zig` | ported (the original's values; the parameter bounds in `compress.zig` use them) |
| `ZSTD_WINDOW_OVERFLOW_CORRECT_FREQUENTLY` | a build option for the tests | oracle-tested with `-Doverflow-correct-frequently`, which builds both sides with it (`build_options.overflow_correct_frequently`; off in every other build) |

## Left out, approved by the author

| original | reason |
| --- | --- |
| `ZDICT_*`: dictionary training (`zdict.c`, `cover.c`, `fastcover.c`, `divsufsort.c`) | the brief leaves it to the author; the tests use the original's trainer to make dictionaries |
| decompression (`ZSTD_decompress*`, `ZSTD_DCtx*`, `ZSTD_DStream*`, `ZSTD_DDict*`, legacy formats) | Zig's std decompresses zstd; the port adds none |
| `ZSTD_isFrame`, `ZSTD_isSkippableFrame`, `ZSTD_readSkippableFrame`, `ZSTD_getFrameContentSize`, `ZSTD_findFrameCompressedSize` | frame readers, on the decompression side |
| `ZSTD_customMem` as a struct of callbacks | a `std.mem.Allocator` takes its place |
| `DYNAMIC_BMI2`, `STATIC_BMI2` | run-time CPU dispatch; the port compiles for the target's CPU features, and the output does not depend on BMI2 |
| `ZSTD_EXCLUDE_{DFAST,GREEDY,LAZY,LAZY2,BTLAZY2,BTOPT,BTULTRA}_BLOCK_COMPRESSOR` | binary size only; every strategy is compiled |
| `ZSTD_COMPRESS_HEAPMODE` | stack or heap for `ZSTD_compress`'s context; the port always takes the caller's allocator |
| `ZSTD_TRACE`, `ZSTD_HAVE_WEAK_SYMBOLS` | tracing hooks through weak symbols |
| `DEBUGLEVEL`, `DEBUGLOG`, `ZSTD_ADDRESS_SANITIZER`, `ZSTD_MEMORY_SANITIZER`, `ZSTD_DATAFLOW_SANITIZER` | debug output and sanitizer annotations; Zig's safe modes check instead |
| `ZSTD_STRIP_ERROR_STRINGS`, `ZSTD_LIB_MINIFY`, `ZSTD_LINUX_KERNEL`, `ZSTD_DEPS_*`, `XXH_*` | C build configuration |
| `ZSTD_C_PREDICT` | an experimental, disabled path in `zstd_opt.c` |
| `FUZZING_BUILD_MODE_UNSAFE_FOR_PRODUCTION` | changes the superblock's checks and the overflow correction for fuzzers; the second is the build option above |
| `ZSTD_RESIZE_SEQPOOL` | fixed to 0 in the original |
