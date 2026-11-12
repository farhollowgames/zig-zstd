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

**Tests.** `zig build test` (corpus on): 298 of 298 pass in 28 minutes (58 unit, 120
`oracle`, 120 `oracle-scalar`); `-Dcorpus=false` skips Silesia and Canterbury. Each fuzz
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
methodology are done (the step 4 report is above). The run stopped at the end of the
author's session on 11 November, during step 5.

**Where things are.**
- `main`: the whole port, 298 of 298 tests passing with the corpora (`zig build test`,
  28 minutes) and the benchmark tables in `doc/BENCHMARKS.md` (from before step 5).
- `review/perf-and-skeptic`: `main` plus step 5's first change, `cc86709`: the
  double-fast finder's range test on the long candidate is a conditional move on x86-64,
  as upstream's inline-asm `ZSTD_selectAddr` is. Level 4 takes 11% less time; levels 3
  and 1 are unchanged. The oracle tests pass on both builds.
- `port/*`: the merged porting branches, kept for history.

**The second performance pass** (`review/perf-2`, worktree `zig-zstd.wt/perf2`), as of
03:40 on 12 November:
- Profiling works: `perf record -e cycles:u` (user-mode events pass `perf_event_paranoid`
  2; only kernel events are blocked). In a profile of the bench, `bench` is the port and
  `libzstd_reference.so` the original, so `perf report --sort dso,sym` compares them
  function by function. Sample with `-c 1000000`; pin with `taskset -c 6` under the lock.
  Instruction counts (`instructions:u`) do not depend on load, so instruction profiles
  can run without the lock; cycle profiles need it.
- Level 3 before this pass: the dfast block compressor took 40.9% of the cycles against
  the original's 37.6%, and ran 32% more instructions (37.8% of all instructions against
  28.6%). The inner search loops cost the same; the match path (count, storeSeq, table
  inserts, repeat offsets) cost about 30% more. The entropy stages are even.
- Kept: the repeat offsets swap through a temporary (fast and dfast, every dictionary
  mode) and the Huffman sort swaps nodes the same way. `std.mem.swap` in Zig 0.17 swaps
  byte by byte, which split the offsets into bytes for the whole function. Level 3 1.078
  to 1.031, level 4 1.098 to 1.058 (pinned, 5 runs); level 1 unchanged at 1.058. The
  fast, dfast, Huffman and compressCCtx oracle tests pass (49 of 49).
- Kept: the dfast noDict loop is one labeled switch whose `continue`s name their targets.
  The search loop left with the next step as a value, and the dispatch on it compiled to
  jump tables (23 indirect jumps) with the live values on the stack. Level 3 1.038 to
  1.006 and 0.999 (two passes), level 4 1.057 to 1.041.
- Kept: the bench turns transparent huge pages off for its process; `--huge-pages` leaves
  them as the system has them and `--original-first` lets the original allocate first.
  With them on, which side's tables got huge pages followed where malloc placed each
  context: level 4 went from 1.038 to 0.960 when the original allocated first, and a
  rebuilt original moved its own levels 5 to 8 by 6%. With them off the order changes
  nothing and the L1 TLB misses split evenly between the sides.
- Kept: the bench's original is upstream's shared library build (`benchReferenceLibrary`
  in build.zig, -fPIC -fvisibility=hidden); the tests keep theirs. The original's times
  did not move (within 0.5%). Every ratio from then on is against it with huge pages
  off: level 1 1.04, level 3 1.015, levels 4 to 8 0.99 to 1.01. Time only while core 6
  and its sibling 22 are idle: other sessions' test runs share the machine, and a busy
  sibling inflates a run by half.
- Kept: `seqToCodes` keeps the three code tables in locals, as the original does: a code
  byte stored through the store's pointers made the loop read them again after every byte.
  Levels -5 to 3 0.5% to 1.2% faster (level 2 1.020 to 1.008); from level 4 within the
  passes' spread.
- Kept: fast's repeat-offset test makes both comparisons with `&`, as the original's, with
  no branch between them. Measured in the final state with and without it, level 1 goes
  from 1.021 to 1.000 and levels -1 to 3 gain 0.5% to 1.6%. Added on its own after
  `seqToCodes` it measured slower: changes of 1% to 2% are the size of the swings between
  builds, so the last four changes are each measured in the final state.
- Kept: `getLowerBits` masks with `bzhi` on BMI2 targets built with intrinsics, as
  `BIT_getLowerBits` does. In the final state, every level but 4 0.1% to 2.4% faster
  with it, level 4 0.6% and 1.0% slower.
- Kept: `storeSeq` and `storeSeqOnly` read the literal and sequence pointers once into
  locals and write the sequence whole. In the final state, levels 1 and 6 to 8 1.1% to 3.2%
  faster with it, level -5 0.8% to 2.1% slower, the others within 1.1%.
- Kept: the bench's last column says "within noise" where the two sides' min-max spreads
  overlap.
- Level 1 (fast): the search loop compiles to the same 51 instructions per two positions
  as the original's, and the function runs as many instructions; the gap is in cycles,
  not yet explained. Levels 5 to 8 (row matcher): the port runs no more instructions
  than the original over the whole level; the row search is the same code.
- `encodeSequences` masks with a table load where the original uses BMI2 `bzhi`
  (`BIT_getLowerBits`): 5% to 6% more instructions there, and it is a sixth of the work
  at level 4. Next: `getLowerBits` with `bzhi`, measured at levels 1, 3 and 4; then the
  repeat-offset test as a non-short-circuit `&` in dfast, as the original's.
  `std.mem.copyForwards` in `zstdmt.zig` is a byte loop (the original uses memmove);
  check before the MT rows.
- At the end: set `port_multithread_merged = true` in bench/bench.zig if the MT rows run,
  and replace the table in `doc/BENCHMARKS.md` from one full pinned `--runs 5` run.

**To resume.**
1. Step 5 on `review/perf-2`: continue from the notes above.
2. Step 6, a fresh skeptic agent on the same branch, with the open points below as a
   start: upstream asserts that safe builds turn into panics on caller-supplied
   dictionaries and sequences, the two upstream out-of-bounds reads the stream tests avoid,
   the Io requirement for workers, the static-context deviations.
3. Step 7, fixes with failing-first tests; the full suite and the benchmark again.
4. README.md (layout in the gameplan's `port-readme.md`, with the author's notice wording
   and "N% faster/slower" headline rows), `doc/TESTING.md`, `doc/parity.md`; then step 8.

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
| `ZSTD_versionNumber`, `ZSTD_versionString` | `params.version_number`, `params.version_string` | not started |
| `ZSTD_isError`, `ZSTD_getErrorCode`, `ZSTD_getErrorName` | `Error`, `errorCode` | not started |
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
| `ZSTD_greedy`, `ZSTD_lazy`, `ZSTD_lazy2` (hash chain) | `lazy.zig` | not started |
| the row-based match finder (`useRowMatchFinder`), SSE2 and NEON tag compare | `lazy.zig`, `@Vector` | not started |
| `ZSTD_btlazy2` (binary tree) | `lazy.zig` | not started |
| dedicated dictionary search (`enableDedicatedDictSearch`) | `lazy.zig` | not started |
| `ZSTD_btopt`, `ZSTD_btultra`, `ZSTD_btultra2` (`zstd_opt.c`), with dictMatchState and extDict, btultra2's two passes over the first block | `opt.zig` | oracle-tested per block (`test/opt_test.zig`) and in frames |
| the optimal parser's price model: dictionary entropy tables, fixed prices for tiny blocks, literal compression off, statistics across blocks | `opt.zig` | oracle-tested per block |
| long distance match candidates in the optimal parser (`ZSTD_optLdm_*`) | `opt.zig` | oracle-tested per block, on hand-made candidates; with `ldm.zig`'s once it lands |
| long-distance matching (`zstd_ldm.c`) | `ldm.zig` | not started |
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
| `ZSTD_NO_INTRINSICS`, `ZSTD_ARCH_X86_SSE2`, `ZSTD_ARCH_X86_AVX2`, `ZSTD_ARCH_ARM_NEON` | `-Dintrinsics`, the target's CPU features | not started |
| `ZSTD_CLEVEL_DEFAULT` | `params.clevel_default` | not started |
| `ZSTDMT_NBWORKERS_MAX`, `ZSTDMT_JOBSIZE_MIN`, `ZSTDMT_JOBSIZE_MAX` | `nbworkers_max`, `jobsize_min`, `jobsize_max` in `zstdmt.zig` | ported (the original's values; the parameter bounds in `compress.zig` use them) |
| `ZSTD_WINDOW_OVERFLOW_CORRECT_FREQUENTLY` | a build option for the tests | ported (`build_options.overflow_correct_frequently`, always off: no `-D` flag yet) |

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
