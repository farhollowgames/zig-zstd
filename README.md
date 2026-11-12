# zig-zstd

Tracks zstd 1.5.7 (the compressor) · Zig 0.17 · [status](STATUS.md)

## What it is

A Zig port of the compressor of Zstandard (zstd), the compression library by
Yann Collet and Meta. It makes zstd frames at every level, one-shot or
streamed, with dictionaries and on several threads, and gives the frames the
original gives. Decompression is left to Zig's standard library
(`std.compress.zstd`). The original is listed under
[Licence and references](#licence-and-references).

This port is not affiliated with or reviewed by the original authors. Its
code was written with AI assistance for Farhollow Games, and is only machine
verified. See [the tests](doc/TESTING.md) and [parity with the original](doc/parity.md).

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
- Pure Zig, with no libc. Memory comes from an `std.mem.Allocator`.

## Install

```sh
zig fetch --save git+https://github.com/farhollowgames/zig-zstd#main
```

There is no release yet; this fetches `main`.

In `build.zig`:

```zig
const zstd = b.dependency("zstd", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("zstd", zstd.module("zstd"));
```

Two build options are passed where the dependency is declared:
`.multithread = false` builds without workers, as the original without
`ZSTD_MULTITHREAD`, and `.intrinsics = false` takes the original's scalar
paths in place of its SIMD ones.

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

## Not included

The parts of the original that are left out, each with its reason, are listed in
[`STATUS.md`](STATUS.md), under "Left out".

## Testing and benchmarks

`zig build test` runs 306 tests: 58 unit tests and 124 oracle tests, run twice,
once with both sides on their SIMD paths and once with both on their scalar
paths. The oracle tests run the original and the port on the same inputs
(upstream's test files, the Silesia and Canterbury corpora, hand-made edge
cases and seeded fuzzing) and compare every frame byte for byte and every
returned value, and decode every frame back through std's decoder and the
original's.

Port time against original time, one-shot compression of the Silesia corpus,
pinned to one core:

| feature | port vs original |
| --- | ---: |
| level -1, whole files | 0.4% faster |
| level 1, whole files | 2% slower |
| level 3 (the default), whole files | 1% faster |
| levels 5 to 9, 2 MiB of each file | 2% to 4% slower |
| level 19, 2 MiB of each file | 3% faster |
| level 22, 2 MiB of each file | within noise |

AMD Ryzen 9 9950X3D, Zig 0.17.0 ReleaseFast against the original at `-O3`
with upstream's shared-library flags, both for `znver5`; the median of five
runs (three from level 16), with transparent huge pages off for the benchmark.
The compressed sizes are the same at every level, since the frames are.

- [`doc/TESTING.md`](doc/TESTING.md): how the tests compare the port with
  the original, and what this repository's tests cover.
- [`doc/BENCHMARKS.md`](doc/BENCHMARKS.md): ratios and full tables: every
  level, the flags on both sides, the biases and the command.

## Licence and references

zig-zstd is licensed under the BSD licence, one of the original's two
([`LICENSE`](LICENSE)), Copyright (c) 2026 Farhollow Games. The original's
licence and its notice, "Copyright (c) Meta Platforms, Inc. and affiliates.
All rights reserved.", are kept in `LICENSE` as they are.

- [zstd](https://github.com/facebook/zstd), the original, by
  [Yann Collet](https://github.com/Cyan4973), Meta and the zstd
  contributors, tag `v1.5.7` (`f8745da`), copied into `reference/` for the tests and
  the benchmark only.
- [RFC 8878](https://www.rfc-editor.org/rfc/rfc8878), the Zstandard
  compression format.
- The test corpora: [Silesia](https://sun.aei.polsl.pl/~sdeor/index.php?page=silesia)
  and [Canterbury](https://corpus.canterbury.ac.nz/).

Made by Farhollow Games for the Loomwork Engine.
