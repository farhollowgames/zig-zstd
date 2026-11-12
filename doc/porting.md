# How the code maps to the original

zig-zstd translates zstd 1.5.7's compressor (`reference/lib`) file by file and
function by function, so that each piece can be read beside its original and
produces the same bytes. These are the rules every file follows.

## Files

| original | port |
| --- | --- |
| `common/zstd_internal.h` | `src/common/zstd_internal.zig` (constants and code tables) |
| `common/fse.h`, `common/huf.h` | `src/common/fse.zig`, `src/common/huf.zig` (constants, table sizes) |
| `common/bitstream.h` (writer) | `src/common/bitstream.zig` |
| `common/entropy_common.c` | `src/common/entropy_common.zig` (`FSE_readNCount`, `HUF_readStats`, for dictionaries) |
| `common/error_private.h`, `zstd_errors.h` | `src/error.zig` |
| `common/xxhash.h` | `std.hash.XxHash64` |
| `common/pool.c`, `threading.c` | `src/common/pool.zig` |
| `compress/hist.c` | `src/compress/hist.zig` |
| `compress/fse_compress.c` | `src/compress/fse_compress.zig` |
| `compress/huf_compress.c` | `src/compress/huf_compress.zig` |
| `compress/zstd_compress_internal.h` | `src/compress/compress_internal.zig` |
| `compress/zstd_cwksp.h` | `src/compress/cwksp.zig` |
| `compress/clevels.h` | `src/compress/clevels.zig` |
| `compress/zstd_compress_literals.c` | `src/compress/compress_literals.zig` |
| `compress/zstd_compress_sequences.c` | `src/compress/compress_sequences.zig` |
| `compress/zstd_compress_superblock.c` | `src/compress/compress_superblock.zig` |
| `compress/zstd_preSplit.c` | `src/compress/pre_split.zig` |
| `compress/zstd_fast.c` | `src/compress/fast.zig` |
| `compress/zstd_double_fast.c` | `src/compress/double_fast.zig` |
| `compress/zstd_lazy.c` | `src/compress/lazy.zig` |
| `compress/zstd_opt.c` | `src/compress/opt.zig` |
| `compress/zstd_ldm.c`, `zstd_ldm_geartab.h` | `src/compress/ldm.zig` |
| `compress/zstd_compress.c` | `src/compress/compress.zig` |
| `compress/zstdmt_compress.c` | `src/compress/zstdmt.zig` |
| `zstd.h` (compression types) | `src/params.zig` |
| `zstd.h` (compression functions) | `src/zstd.zig`, the public root |

## Names

- Functions keep the original's name without its library prefix, in
  camelCase: `ZSTD_compressBlock_fast` is `compressBlockFast`,
  `HUF_compress4X_usingCTable` is `compress4XUsingCTable`, `FSE_normalizeCount`
  is `normalizeCount`. The namespace (the file) stands in for the prefix.
- Types are TitleCase without the prefix and the `_t`: `ZSTD_MatchState_t` is
  `MatchState`, `SeqStore_t` is `SeqStore`.
- Fields and locals are snake_case: `ms->window.dictLimit` is
  `ms.window.dict_limit`, `nextToUpdate` is `next_to_update`.
- Constants from macros are snake_case: `ZSTD_REP_NUM` is `rep_num`,
  `HUF_TABLELOG_MAX` is `huf.table_log_max`.
- Each function's doc comment, or the file's, names the original it translates
  where the name alone does not make it plain.

## Types and arithmetic

- C's widths are kept: `U32` is `u32`, `size_t` is `usize`, `int` is `i32`,
  `ptrdiff_t` is `isize`, `BYTE` is `u8`. An enum keeps the original's values.
- Where the original relies on unsigned wrap-around, the port says so with
  `+%`, `-%` and `*%`, and only there: everywhere else an overflow is a bug
  that the safe build modes catch. Repeat-offset checks such as
  `(U32)((dictLimit - 1) - repIndex) >= 3` are the usual case.
- Signed division says its rounding (`@divTrunc`), as C's `/` truncates.
- Shifts cast their amount (`@intCast` to the shift type); a shift the
  original can make by the full width is written so it cannot overflow.
- Reads and writes of little-endian words are `std.mem.readInt` and
  `std.mem.writeInt` on `ptr[0..4]` or `ptr[0..8]`, with no helper around them.
  `ZSTD_count`, the hashes and `ZSTD_NbCommonBytes` are translated as they are.
- Builtins are the 0.17 ones: `@fromBackingInt` and `@backingInt` for enums
  and packed structs, `@clz`, `@ctz`, `std.math.rotr`.

## Pointers and buffers

- Public functions take slices. Inside, where the original walks raw pointers
  (`ip`, `iend`, `base + matchIndex`), the port keeps `[*]const u8` and `[*]u8`
  many-pointers and the same arithmetic, so the match finders read like the
  original and cost the same. Pointer distances are
  `@intFromPtr(a) - @intFromPtr(b)`.
- `window.base` and `window.dict_base` point before the buffer, as in the
  original: they are only ever offset by an index at or above the window's
  limits. They are stored as `[*]const u8`.
- Every pointer a context holds into a caller's buffer (a referenced
  dictionary, a prefix, a stable input buffer) is valid only until the next
  call that resets the context; each doc comment says so.

## Memory

- The original's `ZSTD_customMem` is a `std.mem.Allocator`. A context made
  with `initStatic` has none and never allocates, as the original's static
  contexts do.
- The workspace (`cwksp`) is translated as it is: one allocation carved into
  objects, tables and buffers in the original's order and alignment, so that
  `estimate*` and `sizeof*` give the original's numbers and a static workspace
  of the original's size works.
- Tables the original zeroes are zeroed; nothing reads memory the original
  would not have initialised.

## Errors

- A function that returns an error code in the original returns
  `Error!usize` (or `Error!void`), with the error named as in `src/error.zig`.
  `RETURN_ERROR_IF(cond, err, ...)` is `if (cond) return error.Err;`, and
  `FORWARD_IF_ERROR` is `try`.
- Where the original inspects an error and carries on (a `dstSize_tooSmall`
  that means "store this block raw"), the port catches that one error by name.
- Return values that are not errors keep their meaning: 0 for "not
  compressible", 1 for "RLE", as in the original.

## SIMD and build switches

- Where the original uses SSE2, AVX2 or NEON, the port uses `@Vector`, behind
  `build_options.intrinsics`; with it off, the port takes the original's scalar
  path. The oracle tests compare each path with the original built the same way.
- Zig 0.17 keeps LLVM's loop vectorizer off, so a loop with a run-time length
  stays scalar. Where upstream's C relies on the C compiler vectorizing a loop
  (match length counting, hashing, histograms), the port writes the vectors
  out with `@Vector`. LLVM still packs explicit vectors, small fixed arrays,
  `inline for` bodies and field-wise operations on small structs, the last
  only when the destination pointer is `noalias`.
- `ZSTD_MULTITHREAD` is `build_options.multithread`.
- Other switches are listed in `STATUS.md`, as ported or left out.

## What is not translated

- `DEBUGLOG`, `RAWLOG` and the statistics code under `DEBUGLEVEL`.
- Asserts that restate the lines around them. Asserts that check a promise
  made elsewhere (a caller's, or another function's state) are kept as
  `std.debug.assert`.
- `ZSTD_TRACE` hooks, sanitizer annotations and prefetch hints that have no
  effect on the output; prefetches in hot loops are `@prefetch`.
- Comments that narrate history or cite issues. Comments that explain the
  algorithm are kept, in plain words.
