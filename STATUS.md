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

## Resume notes

Builds: one at a time, `timeout 3000 systemd-run --user --scope -q -p MemoryMax=6G
zig build <step> -j3`, never while the scratchpad's `bench.running` exists.
`zig build check` compiles everything; `zig build test -Dcorpus=false` skips the
corpus runs.

Work in progress is on branches, one per area, each in a worktree under
`~/Projects/zig-zstd.wt/`: `port/entropy` (bitstream, hist, FSE, Huffman),
`port/core` (shared types, workspace, levels, fast, dfast, literals,
sequences, the per-block oracle driver), `port/lazy`, `port/opt`, `port/ldm`,
and `port/frame` (zstd_compress.c up to the one-shot frame path, the
superblock and the pre-splitter). They merge into `main` as each passes its
tests. Still to start: the streaming half of zstd_compress.c (CDict, CStream,
`compressStream2`, `compress2`, the sequence API), then zstdmt.

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

## Frame and one-shot compression

| original | zig-zstd | state |
| --- | --- | --- |
| `ZSTD_compress` | `compress` | not started |
| `ZSTD_compressBound`, `ZSTD_COMPRESSBOUND` | `compressBound` | not started |
| `ZSTD_compressCCtx` | `CCtx.compressCCtx` | not started |
| `ZSTD_compress2` | `CCtx.compress2` | not started |
| `ZSTD_compress_advanced` | `CCtx.compressAdvanced` | not started |
| `ZSTD_writeSkippableFrame` | `writeSkippableFrame` | not started |
| `ZSTD_minCLevel`, `ZSTD_maxCLevel`, `ZSTD_defaultCLevel` | same | not started |
| `ZSTD_versionNumber`, `ZSTD_versionString` | `params.version_number`, `params.version_string` | not started |
| `ZSTD_isError`, `ZSTD_getErrorCode`, `ZSTD_getErrorName` | `Error`, `errorCode` | not started |
| frame header: magic, window descriptor, content size, dictionary id, single segment | in `compress.zig` | not started |
| checksum (XXH64) | `std.hash.XxHash64` | not started |
| raw, RLE and compressed blocks; last-block flag | in `compress.zig` | not started |
| `ZSTD_f_zstd1_magicless` | `Format.zstd1_magicless` | not started |

## Levels and strategies

| original | zig-zstd | state |
| --- | --- | --- |
| levels 1 to 22, the default level (3), level 0 | `clevels.zig` | oracle-tested (the table, against `ZSTD_getCParams`) |
| negative levels (`ZSTD_minCLevel` = -131072) | `fast` with target length | oracle-tested per block (the table rows, and `fast` with target lengths up to 100) |
| `ZSTD_fast` (`zstd_fast.c`), with dictMatchState and extDict | `fast.zig` | oracle-tested per block (frames wait for `compress.zig`) |
| `ZSTD_dfast` (`zstd_double_fast.c`) | `double_fast.zig` | oracle-tested per block (frames wait for `compress.zig`) |
| `ZSTD_greedy`, `ZSTD_lazy`, `ZSTD_lazy2` (hash chain) | `lazy.zig` | not started |
| the row-based match finder (`useRowMatchFinder`), SSE2 and NEON tag compare | `lazy.zig`, `@Vector` | not started |
| `ZSTD_btlazy2` (binary tree) | `lazy.zig` | not started |
| dedicated dictionary search (`enableDedicatedDictSearch`) | `lazy.zig` | not started |
| `ZSTD_btopt`, `ZSTD_btultra`, `ZSTD_btultra2` (`zstd_opt.c`), with dictMatchState and extDict, btultra2's two passes over the first block | `opt.zig` | oracle-tested per block (`test/opt_test.zig`); frame-level tests wait for the frame path |
| the optimal parser's price model: dictionary entropy tables, fixed prices for tiny blocks, literal compression off, statistics across blocks | `opt.zig` | oracle-tested per block |
| long distance match candidates in the optimal parser (`ZSTD_optLdm_*`) | `opt.zig` | oracle-tested per block, on hand-made candidates; with `ldm.zig`'s once it lands |
| long-distance matching (`zstd_ldm.c`) | `ldm.zig` | not started |
| `ZSTD_getCParams`, `ZSTD_getParams`, `ZSTD_checkCParams`, `ZSTD_adjustCParams` | same | not started |

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
| `ZSTD_c_compressionLevel` | `.compression_level` | not started |
| `ZSTD_c_windowLog`, `hashLog`, `chainLog`, `searchLog`, `minMatch`, `targetLength`, `strategy` | same names | not started |
| `ZSTD_c_targetCBlockSize` (superblocks, `zstd_compress_superblock.c`) | `.target_cblock_size` | not started |
| `ZSTD_c_enableLongDistanceMatching`, `ldmHashLog`, `ldmMinMatch`, `ldmBucketSizeLog`, `ldmHashRateLog` | same names | not started |
| `ZSTD_c_contentSizeFlag`, `checksumFlag`, `dictIDFlag` | same names | not started |
| `ZSTD_c_nbWorkers`, `jobSize`, `overlapLog`, `rsyncable` | same names | not started |
| `ZSTD_c_format` | `.format` | not started |
| `ZSTD_c_forceMaxWindow`, `forceAttachDict` | same names | not started |
| `ZSTD_c_literalCompressionMode` | `.literal_compression_mode` | not started |
| `ZSTD_c_srcSizeHint` | `.src_size_hint` | not started |
| `ZSTD_c_enableDedicatedDictSearch` | same | not started |
| `ZSTD_c_stableInBuffer`, `stableOutBuffer` | same | not started |
| `ZSTD_c_blockDelimiters`, `validateSequences` | same | not started |
| `ZSTD_c_blockSplitterLevel`, `splitAfterSequences` (post-split, `ZSTD_compressBlock_splitBlock`) and the pre-splitter (`zstd_preSplit.c`) | same, `pre_split.zig` | not started |
| `ZSTD_c_useRowMatchFinder` | same | not started |
| `ZSTD_c_deterministicRefPrefix` | same | not started |
| `ZSTD_c_prefetchCDictTables` | same | not started |
| `ZSTD_c_enableSeqProducerFallback` | same | not started |
| `ZSTD_c_maxBlockSize` | same | not started |
| `ZSTD_c_repcodeResolution` (`searchForExternalRepcodes`) | same | not started |
| `ZSTD_cParam_getBounds` | `cParamGetBounds` | not started |
| `ZSTD_CCtx_getParameter`, `ZSTD_CCtxParams_getParameter` | same | not started |
| `ZSTD_CCtx_setCParams`, `setFParams`, `setParams` | same | not started |
| `ZSTD_createCCtxParams`, `freeCCtxParams`, `CCtxParams_reset`, `_init`, `_init_advanced` | `CCtxParams` | not started |
| `ZSTD_CCtx_setParametersUsingCCtxParams` | same | not started |
| `ZSTD_CCtx_setPledgedSrcSize` | same | not started |
| `ZSTD_CCtx_reset` (session, parameters, both) | `CCtx.reset` | not started |

## Contexts and memory

| original | zig-zstd | state |
| --- | --- | --- |
| `ZSTD_createCCtx`, `ZSTD_freeCCtx`, `ZSTD_createCCtx_advanced` (custom allocator) | `CCtx.create(gpa)`, `CCtx.destroy` | not started |
| `ZSTD_initStaticCCtx`, `ZSTD_initStaticCStream`, `ZSTD_initStaticCDict` | `initStatic` | not started |
| context reuse: tables kept between frames, workspace resize and shrink rules | `cwksp.zig` | ported (the workspace; its use waits for `compress.zig`) |
| `ZSTD_sizeof_CCtx`, `ZSTD_sizeof_CStream`, `ZSTD_sizeof_CDict` | same | not started |
| `ZSTD_estimateCCtxSize*`, `ZSTD_estimateCStreamSize*`, `ZSTD_estimateCDictSize*` | same | not started |
| `ZSTD_copyCCtx` | same | not started |

## Streaming

| original | zig-zstd | state |
| --- | --- | --- |
| `ZSTD_compressStream2` with `ZSTD_e_continue`, `ZSTD_e_flush`, `ZSTD_e_end` | `CCtx.compressStream2` | not started |
| `ZSTD_compressStream2_simpleArgs` | covered by `compressStream2` | not started |
| `ZSTD_createCStream`, `freeCStream`, `CStreamInSize`, `CStreamOutSize` | `CCtx`, same sizes | not started |
| `ZSTD_initCStream`, `_srcSize`, `_usingDict`, `_advanced`, `_usingCDict`, `_usingCDict_advanced`, `ZSTD_resetCStream` | same | not started |
| `ZSTD_compressStream`, `ZSTD_flushStream`, `ZSTD_endStream` | same | not started |
| `ZSTD_getFrameProgression`, `ZSTD_toFlushNow` | same | not started |
| buffer-less: `ZSTD_compressBegin*`, `ZSTD_compressContinue`, `ZSTD_compressEnd`, `ZSTD_getBlockSize`, `ZSTD_compressBlock` | same | not started |

## Dictionaries

| original | zig-zstd | state |
| --- | --- | --- |
| `ZSTD_compress_usingDict` | same | not started |
| `ZSTD_CCtx_loadDictionary`, `_byReference`, `_advanced` (raw content, full dictionary, auto) | same | not started |
| `ZSTD_CCtx_refPrefix`, `refPrefix_advanced` | same | not started |
| `ZSTD_createCDict`, `freeCDict`, `_advanced`, `_advanced2`, `_byReference` | `CDict` | not started |
| `ZSTD_compress_usingCDict`, `_usingCDict_advanced`, `ZSTD_CCtx_refCDict` | same | not started |
| attach, copy and load of a CDict (`forceAttachDict`) | in `compress.zig` | not started |
| entropy tables from a full dictionary (`ZSTD_loadCEntropy`) | in `compress.zig` | not started |
| `ZSTD_getDictID_fromDict`, `ZSTD_getDictID_fromCDict` | same | not started |

## Sequences

| original | zig-zstd | state |
| --- | --- | --- |
| `ZSTD_sequenceBound`, `ZSTD_generateSequences`, `ZSTD_mergeBlockDelimiters` | same | not started |
| `ZSTD_compressSequences` (with and without delimiters, validation) | same | not started |
| `ZSTD_compressSequencesAndLiterals` (AVX2 conversion path) | same | not started |
| `ZSTD_registerSequenceProducer`, `ZSTD_CCtxParams_registerSequenceProducer` (external match finders, fallback) | `SequenceProducer` | not started |

## Multithreading

| original | zig-zstd | state |
| --- | --- | --- |
| `zstdmt_compress.c`: jobs, overlap, job size, `rsyncable`, flush | `zstdmt.zig` on `std.Thread` | not started |
| `ZSTD_createThreadPool`, `ZSTD_freeThreadPool`, `ZSTD_CCtx_refThreadPool` | `ThreadPool` | not started |

## Build switches

| original | zig-zstd | state |
| --- | --- | --- |
| `ZSTD_MULTITHREAD` | `-Dmultithread` (`build_options.multithread`) | not started |
| `ZSTD_NO_INTRINSICS`, `ZSTD_ARCH_X86_SSE2`, `ZSTD_ARCH_X86_AVX2`, `ZSTD_ARCH_ARM_NEON` | `-Dintrinsics`, the target's CPU features | not started |
| `ZSTD_CLEVEL_DEFAULT` | `params.clevel_default` | not started |
| `ZSTDMT_NBWORKERS_MAX`, `ZSTDMT_JOBSIZE_MIN` | constants in `zstdmt.zig` | not started |
| `ZSTD_WINDOW_OVERFLOW_CORRECT_FREQUENTLY` | a build option for the tests | ported (`build_options.overflow_correct_frequently`, always off: no `-D` flag yet) |

## Left out, awaiting the author's approval

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
