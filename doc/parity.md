# Differences from the original

zig-zstd translates zstd 1.5.7's compressor function by function and gives
the original's frames. [`STATUS.md`](../STATUS.md) lists every function,
parameter and build switch of the original with its counterpart and its
state, and [`porting.md`](porting.md) the rules the translation follows. This
file gives the reasons for each difference a caller can see. The review of
the port is not finished, so this list can still change.

## Additions

None. The port has the original's compression features, and no more.
Decompression is left to Zig's standard library (`std.compress.zstd`).

## Changes to expect

- **Errors.** A function that returns a size or an error code in the
  original returns `Error!usize` (or `Error!void`), with the error named as
  in `src/error.zig`. Values that are not errors keep their meaning, such as
  0 for "not compressible".
- **Memory.** `ZSTD_customMem` is a `std.mem.Allocator`. A context made with
  `initStatic` has none and never allocates, as the original's static
  contexts do. `CCtx.generateSequences` takes an allocator for its scratch
  frame, which the original mallocs.
- **Static contexts.** Where the original mallocs even for a static
  context, the port refuses with `error.MemoryAllocation`: compressing with
  a dictionary loaded by reference (the original digests it into a `CDict`),
  and making the multithreaded context. `initStatic` over a workspace a few
  bytes larger than the context returns null; the original's space check
  wraps there, and it returns a context that crashes on first use.
- **Unchecked writes.** Where the original goes on past a failure the port
  returns the error: `copyCCtx` when resetting the copy fails (the original
  then copies into tables it has not reserved).
- **Workers.** Workers need an `std.Io`: `CCtx.setIo`, or the one of a pool
  given with `refThreadPool`. A context with workers and neither refuses
  with `error.ParameterCombinationUnsupported`.
- **Asserts.** The port keeps the original's asserts on promises made by the
  caller, and they panic in Debug and ReleaseSafe where the original's
  release build carries on: malformed caller sequences (in
  `convertBlockSequences`, `get1BlockSummary`, `offsetToOffbase` and
  `storeSeqOnly`), a hand-made dictionary whose Huffman codes are longer
  than 11 bits or whose FSE costs reach 10 when the optimal parser prices
  from it (undefined behaviour in the original in the Huffman case), and a
  stable-input promise broken before a frame starts, where the original's
  next frame reads out of bounds.
- **Size estimates.** With long distance matching on and `ldmMinMatch`
  unset, `estimateCCtxSizeUsingCCtxParams` and
  `estimateCStreamSizeUsingCCtxParams` divide by zero, as the original's do:
  the original dies with SIGFPE, the port panics in a safe build.
- **Tables past a 32-bit address space.** On a 32-bit target, a hash log of
  30 (a 4 GiB table) or a long distance hash log of 29 or 30 with long
  distance matching on wraps the original's size_t table size to 0, and the
  largest tables together wrap its sums. The estimates return the same
  wrapped values as the original's. Compressing, the port refuses such
  tables with `error.MemoryAllocation`. Where only the sum wraps, the
  original's workspace check refuses them too, unless its pointer sum wraps
  at the top of the address space. Where a table's own size wraps, the
  original reserves no room for it and writes past its workspace.
- **The AVX2 sequence conversion.** The original's `convertSequences` takes
  its AVX2 path whenever `__AVX2__` is defined, even with
  `ZSTD_NO_INTRINSICS`; the port takes its vector path only with the
  `intrinsics` build option and AVX2. The results are the same except for
  lengths of 2^31 and over.
- **Build switches.** `ZSTD_MULTITHREAD` is the `multithread` build option,
  and `ZSTD_NO_INTRINSICS` the `intrinsics` option turned off. The port
  compiles for the target's CPU features, where the original can dispatch on
  BMI2 at run time; the output does not depend on it.

## Left out

The author approved leaving these out of the port:

- **Dictionary training** (`ZDICT_*`: `zdict.c`, `cover.c`, `fastcover.c`,
  `divsufsort.c`). The tests use the original's trainer to make dictionaries.
- **Decompression and the frame readers** (`ZSTD_decompress*`, `ZSTD_DCtx*`,
  `ZSTD_DStream*`, `ZSTD_DDict*`, the legacy formats, `ZSTD_isFrame`,
  `ZSTD_isSkippableFrame`, `ZSTD_readSkippableFrame`, `ZSTD_getFrameContentSize`,
  `ZSTD_findFrameCompressedSize`). Zig's std decompresses zstd.
- **`ZSTD_customMem`**, a struct of allocation callbacks. A `std.mem.Allocator`
  takes its place.
- **BMI2 run-time dispatch** (`DYNAMIC_BMI2`, `STATIC_BMI2`). The port is built
  for the target's CPU features, and the output does not depend on BMI2.
- **Build switches for C builds**: the `ZSTD_EXCLUDE_*_BLOCK_COMPRESSOR`
  switches (binary size only), `ZSTD_COMPRESS_HEAPMODE`, tracing (`ZSTD_TRACE`,
  `ZSTD_HAVE_WEAK_SYMBOLS`), debug and sanitizer switches (`DEBUGLEVEL`,
  `ZSTD_ADDRESS_SANITIZER`, `ZSTD_MEMORY_SANITIZER`, `ZSTD_DATAFLOW_SANITIZER`),
  and the C build-configuration macros (`ZSTD_STRIP_ERROR_STRINGS`,
  `ZSTD_LIB_MINIFY`, `ZSTD_LINUX_KERNEL`, `ZSTD_DEPS_*`, `XXH_*`).
- **`ZSTD_C_PREDICT`** (an experimental, disabled path in `zstd_opt.c`), the
  fuzzing build mode (`FUZZING_BUILD_MODE_UNSAFE_FOR_PRODUCTION`) and
  `ZSTD_RESIZE_SEQPOOL` (fixed to 0 in the original).
