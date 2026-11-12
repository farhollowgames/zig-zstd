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
- **The AVX2 sequence conversion.** The original's `convertSequences` takes
  its AVX2 path whenever `__AVX2__` is defined, even with
  `ZSTD_NO_INTRINSICS`; the port takes its vector path only with the
  `intrinsics` build option and AVX2. The results are the same except for
  lengths of 2^31 and over.
- **Build switches.** `ZSTD_MULTITHREAD` is the `multithread` build option,
  and `ZSTD_NO_INTRINSICS` the `intrinsics` option turned off. The port
  compiles for the target's CPU features, where the original can dispatch on
  BMI2 at run time; the output does not depend on it.
