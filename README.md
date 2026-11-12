# zig-zstd

Ported from zstd 1.5.7 (`f8745da`), the compressor · Zig 0.17.0 · [status](STATUS.md)

This port is not affiliated with or reviewed by the original authors. Its
code was written with AI assistance for Farhollow Games, and is only machine
verified. See [the tests](doc/TESTING.md) and [parity with the original](doc/parity.md).

## What it is

A Zig port of the compressor of Zstandard (zstd), the compression library by
Yann Collet and Meta. It makes zstd frames at every level, one-shot or
streamed, with dictionaries and on several threads, and gives the frames the
original gives. Decompression is left to Zig's standard library
(`std.compress.zstd`). It is pure Zig, with no dependencies beyond the
standard library, and links no libc. The original is listed under
[References](#references).

## Features

- Levels from -131072 to 22, and every strategy: fast, dfast, greedy, lazy,
  lazy2 (with the row-based match finder), btlazy2, btopt, btultra and
  btultra2.
- Long distance matching, superblocks and the block pre-splitter.
- One-shot, buffer-less and streaming compression (`compressStream2` with
  continue, flush and end, and stable buffers).
- Dictionaries (raw content or full), prefixes and `CDict`s, loaded by copy
  or by reference.
- The sequence API: `generateSequences`, `compressSequences`,
  `compressSequencesAndLiterals` and external sequence producers.
- Multithreaded compression on `std.Thread`, with a shared thread pool.
- Every compression parameter of `zstd.h`, with the original's bounds, and
  static contexts over a caller's buffer.
- Memory comes from an `std.mem.Allocator`.

## Install

```sh
zig fetch --save git+https://github.com/farhollowgames/zig-zstd#main
```

There is no release yet; this fetches `main`. The package needs Zig 0.17.0.

In `build.zig`:

```zig
const zstd = b.dependency("zstd", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("zstd", zstd.module("zstd"));
```

### Build options

The original's compile-time switches are build options, passed where the
dependency is declared, such as `.multithread = false`:

| option | original | effect |
| --- | --- | --- |
| `multithread` | `ZSTD_MULTITHREAD` | `false` builds without workers, as the original without the switch; on by default |
| `intrinsics` | the original's SIMD paths | `false` takes the original's scalar paths in place of its SIMD ones; on by default |

## Use

Compress a buffer at the default level:

```zig
const std = @import("std");
const zstd = @import("zstd");

pub fn pack(gpa: std.mem.Allocator, data: []const u8) ![]u8 {
    const out = try gpa.alloc(u8, try zstd.compressBound(data.len));
    errdefer gpa.free(out);
    const len = try zstd.compress(gpa, out, data, zstd.defaultCLevel());
    return gpa.realloc(out, len);
}
```

The API follows the original's, function for function, without the `ZSTD_`
prefix (`ZSTD_compress2` is `CCtx.compress2`). [`STATUS.md`](STATUS.md) maps
every function and parameter of the original to its counterpart,
[`doc/porting.md`](doc/porting.md) says how the code maps to the original's,
and the doc comments in [`src/`](src) describe each one.

## Differences from the original

The reasons are in [`doc/parity.md`](doc/parity.md).

*Additions*:

- None: the port has the original's compression features, and no more.

*Changes to expect*:

- Functions return `Error!usize` or a value, in place of size codes that can be errors.
- An `std.mem.Allocator` in place of `ZSTD_customMem`; `generateSequences` takes one for its scratch frame.
- Workers need an `std.Io`, through `CCtx.setIo` or a thread pool given with `refThreadPool`.
- A static context refuses what would make the original allocate, and `initStatic` returns null over a workspace too small.
- Broken caller promises, such as malformed sequences, panic in a safe build where the original's release build carries on.

## Left out

The parts of the original that are left out, each with its reason, are
listed in [`STATUS.md`](STATUS.md#left-out-approved-by-the-author). In
short:

- Dictionary training (`ZDICT_*`); the tests use the original's trainer to
  make dictionaries.
- Decompression and the frame readers on its side: Zig's std decompresses
  zstd.
- `ZSTD_customMem`: a `std.mem.Allocator` takes its place.
- Run-time BMI2 dispatch, the switches that leave strategies out for binary
  size, tracing hooks, debug output and sanitizer annotations, and C build
  configuration.
- `ZSTD_C_PREDICT`, an experimental, disabled path, and switches fixed in
  the original (`ZSTD_RESIZE_SEQPOOL`).

## Tests

`zig build test` runs 312 tests: 58 unit tests and 127 oracle tests, run
twice, once with both sides on their SIMD paths and once with both on their
scalar paths. The oracle tests run the original and the port on the same
inputs (upstream's test files, the Silesia and Canterbury corpora, hand-made
edge cases and seeded fuzzing) and compare every frame byte for byte and
every returned value, and decode every frame back through std's decoder and
the original's.

- [`doc/TESTING.md`](doc/TESTING.md): how the tests compare the port with
  the original, and what this repository's tests cover.
- [`doc/parity.md`](doc/parity.md): where the port differs from the
  original, and why.

## Speed

Port time against original time, one core, one-shot compression of the
Silesia corpus:

| feature | time, port / original | port vs original |
| --- | ---: | ---: |
| level -1, whole files | 1.006 | 0.6% slower |
| levels 1 and 2, whole files | 1.011 and 1.012 | 1.1% and 1.2% slower |
| level 3 (the default), whole files | 0.993 | 0.7% faster |
| levels 5 to 9, 2 MiB of each file | 0.994 to 1.010 | 0.6% faster to 1.0% slower |
| level 19, 2 MiB of each file | 0.961 | 3.9% faster |
| level 22, 2 MiB of each file | 0.968 | 3.2% faster |

Levels 1 and 2 are the slowest rows of the full table. The compressed sizes
are the same at every level, since the frames are. Rows move by about 1 to
1.5 points between runs; levels 19 and 22 came out faster than in the
previous table because the run did, not because their code changed. The
functions that run the inner loops are aligned to 4 KiB pages, tuned on this
one Zen 5 machine, which adds about 216 to 225 KB of padding to a binary in
every mode but ReleaseSmall.

AMD Ryzen 9 9950X3D, one core, Linux, Zig 0.17.0 ReleaseFast against the
original at `-O3` with upstream's shared-library flags, both for `znver5`;
the median of five runs (three from level 16); transparent huge pages off
for the benchmark.

- [`doc/BENCHMARKS.md`](doc/BENCHMARKS.md): every level, the flags on both
  sides, the biases and the command.

## Licence

BSD licence, one of the original's two ([`LICENSE`](LICENSE)). zig-zstd is
an altered version of zstd's compressor: the code is rewritten in Zig, with
its own interface. The original's licence and its notice, "Copyright (c)
Meta Platforms, Inc. and affiliates. All rights reserved.", are kept in
`LICENSE` as they are, beside "Copyright (c) 2026 Farhollow Games".

## References

- [zstd](https://github.com/facebook/zstd), the original, by
  [Yann Collet](https://github.com/Cyan4973), Meta and the zstd
  contributors, tag `v1.5.7` (`f8745da`), copied into `reference/` for the
  tests and the benchmark only.
- [RFC 8878](https://www.rfc-editor.org/rfc/rfc8878), the Zstandard
  compression format.
- The test corpora: [Silesia](https://sun.aei.polsl.pl/~sdeor/index.php?page=silesia)
  and [Canterbury](https://corpus.canterbury.ac.nz/).

Made by Farhollow Games for the Loomwork Engine.
