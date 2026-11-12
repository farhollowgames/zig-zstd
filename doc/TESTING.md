# Testing

The sections up to "In this repository" are the same in every Farhollow
Games port of a C or C++ library to Zig. The last section says how this
repository applies them.

## Oracle tests

The original is pinned to one upstream commit and kept in `reference/` (or
fetched as a lazy dependency), byte for byte as upstream has it. It is built
only for the tests and the benchmark, and is never part of the package.

An oracle test runs the original and the port on the same inputs and
compares the results. Where the original is exact, the test compares every
output byte and every returned value, not a summary such as a hash or one
field of the result. The inputs are:

- the original's own test data and demo assets, where it has them;
- hand-made edge cases: empty input, one element, the largest size, and
  degenerate cases;
- seeded random inputs (see Fuzzing).

`STATUS.md` lists every public function, option and mode of the original,
and names the tests that check each one. Code coverage is not the measure:
a feature counts as checked when a test compares it, not when a line is
reached.

## What "the same output" means

- Bytes and integers are equal.
- Floats are compared by their bit patterns, so `-0.0` differs from `0.0`,
  and a NaN matches only a NaN with the same bits.
- Where the original's output depends on how it is compiled (fused
  multiply-add, fast-math, signed overflow), the reference is built with
  flags that fix one result, and the port computes that result. The last
  section names the flags.
- Where a port deliberately computes differently from the original, a
  written design gives the units, scales, overflow bounds and tolerances.
  The port is then checked against an exact port within those tolerances,
  and against itself exactly.

## Fuzzing

Each fuzz test draws its inputs from a seeded generator and runs at least
1,000 cases. The seeds are recorded in the tests, so every run checks the
same inputs. A failure prints its seed, and the configuration where there is
one, so that it can be repeated. Where a repository has the option,
`zig build test -Dfuzz-seed=N` changes every fuzz test's seed, to explore
other inputs.

## Malformed input

Decoders and parsers are given truncated, corrupted and random bytes, and
must give the original's result: the same output, the same error, or the
same rejection. Where the port asserts a condition that the original
reports as an error code, or that the original does not check, `STATUS.md`
says so. Where a repository has contract tests, a program breaks one
contract per run, and the test expects the abort and its message in the safe
build modes.

## Determinism

The same inputs give the same output on every run. Where the library splits
work over threads, the tests compare the output on 1, 2 and more threads
with the output of one.

## Build modes

`zig build test` runs the tests in ReleaseSafe unless
`-Dtest-optimize=<mode>` says otherwise. ReleaseSafe keeps every assert and
integer overflow check on and runs the slow cases in reasonable time. The
last section says which modes have been run.

## Review

After a port passes its oracle tests, a separate AI agent profiles it
against the original and tunes the hot paths; each change is kept only if
the oracle tests still pass and the benchmark shows a gain. Another AI agent
then tries to break the claims: features left untested, comparisons that
check too little, fuzzing too narrow, benchmarks that favour the port,
undefined behaviour, integer overflow, and references that can outlive what
they point to. Each confirmed finding is fixed with a test that failed
before the fix. No person has yet reviewed the code or the tests.


## In this repository

### The original

zstd 1.5.7, tag `v1.5.7`, commit `f8745da6ff1ad1e7bab384bd1f9d742439278e99`,
is copied into `reference/` unchanged (see `reference/README.md`): the whole
`lib/` directory, upstream's licences, its test inputs
(`tests/golden-compression`, `tests/golden-dictionaries`, `tests/dict-files`)
and its generator of compressible data (`programs/datagen.c`). The tests and
the benchmark build it with Zig's C compiler; a package that depends on
zig-zstd never builds or fetches it.

### What is compared

- Every frame the port makes is compared with the original's, byte for
  byte, and decoded back to its input through std's decoder
  (`std.compress.zstd`) and the original's.
- Below the frame, the block compressors of every strategy run on one block
  after the same setup on both sides, and every stored sequence, literal,
  repeat offset and table entry is compared, with the match state the next
  block starts from (the optimal parser's statistics and prices, the
  window, and the hash and tree tables).
- The entropy coders (histograms, FSE, Huffman, the bit stream writer, the
  table header readers) are compared output byte by output byte, table entry
  by table entry, with every returned value and error code.
- Streaming is driven call by call on both sides with the same input
  chunks, output windows and directives; after every call the results, the
  input and output positions and the frame progression must be the same.
- Long distance matching compares the raw sequences, the whole hash table,
  the bucket offsets and the window after every step.
- Parameters: their bounds, setting and reading them, contexts reused and
  reset, and the size estimates, which static contexts are then built with.

Two limits of std's decoder (Zig 0.17.0) shape the round trips:
- it panics when asked to verify a checksum, so the tests decode through std
  without checksum verification and through the original with it;
- it takes no dictionaries, so frames made with a dictionary or a prefix
  decode through the original only.

### Tests and counts

`zig build test` runs 298 tests in about 28 minutes on the machine in
[`BENCHMARKS.md`](BENCHMARKS.md): 58 unit tests in `src/`, and 120 oracle
tests run twice, as `oracle` (the port's `@Vector` paths against the
original's SIMD paths) and as `oracle-scalar` (both sides on their scalar
paths). `-Dcorpus=false` skips the corpus tests, and `-Doracle-scalar=false`
the second run.

| file | what it covers |
| --- | --- |
| `test/entropy_test.zig` | histograms, FSE, Huffman, the bit stream, the table readers |
| `test/literals_sequences_test.zig` | the literals section and each step of the sequences section, on real blocks |
| `test/core_test.zig` | the parameter table, and the fast and double-fast block compressors |
| `test/lazy_test.zig` | greedy, lazy and lazy2 over the hash chain and the row matcher, and btlazy2, with and without dictionaries |
| `test/opt_test.zig` | btopt, btultra and btultra2 over one or more blocks |
| `test/ldm_test.zig` | long distance matching |
| `test/frame_test.zig` | one-shot and buffer-less frames, and choosing and checking parameters |
| `test/frame_params_test.zig` | every advanced parameter, reused and reset contexts, static contexts |
| `test/frame_dict_test.zig` | dictionaries, prefixes and `CDict`s, attached, copied or reloaded |
| `test/frame_sequences_test.zig` | `generateSequences`, `mergeBlockDelimiters`, external sequence producers |
| `test/compress_sequences_test.zig` | `compressSequences` and `compressSequencesAndLiterals` |
| `test/stream_test.zig` | `compressStream2` and the streaming functions around it |
| `test/mt_test.zig` | multithreaded compression |
| `test/corpus_test.zig` | the corpora below |

### Inputs

- Upstream's test files and the data its generator makes.
- The Canterbury corpus (its canterbury, artificial and large sets) at
  levels -5 and -1 and every positive level; the first 4 MiB of every
  Silesia file at -5 and every positive level, and each whole Silesia file
  at levels 1, 3 and 19, one-shot and streamed. Both corpora are lazy
  dependencies, fetched only for the tests and the benchmark.
- `test/data/`: a BC7 texture from zig-bcn, encoded mesh streams from
  zig-meshoptimizer and a Loomwork snapshot pack, each at every level
  (`test/data/README.md` says how each was made).
- Hand-made edge cases, among them one-byte output windows and invalid
  sequences, which must fail with the original's errors.

### Fuzzing

Each fuzz test runs `-Dfuzz-cases` cases, 1,000 by default.
`-Dfuzz-seed=N` is added to every fuzz test's first seed. Fuzzed inputs
cover the entropy coders' inputs, the block compressors, parameter sets,
streaming calls, long distance matching and caller sequences.

### Malformed input

A compressor reads no encoded input except the caller's dictionaries and
sequences. Invalid sequences must give the original's errors. Malformed
sequences and dictionaries that break the original's own asserts panic in
a safe build, as [`parity.md`](parity.md) says; the tests stay clear of the
two cases where the original then reads out of bounds.

### Determinism

The multithreaded tests drive the port and the original with 1, 2, 3, 4
and 8 workers. Every frame must be the original's on every run, whatever the
threads' timing, and so must the sizes after the start of a frame, the
frame progression whenever no job is in progress, and the errors.

### Build modes

The recorded run of 298 tests is the default, ReleaseSafe.

### State

The oracle tests pass. The performance pass, the skeptic's review and the
fixes are still under way, and [`STATUS.md`](../STATUS.md) lists the open
points they start from.
