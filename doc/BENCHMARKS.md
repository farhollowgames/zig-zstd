# Benchmarks

`zig build bench` times the port in ReleaseFast against the original built
from `reference/` at -O3, for the same target, on the Silesia corpus. The
original is built as upstream's lib/Makefile builds libzstd.so, with `-fPIC
-fvisibility=hidden`, so its calls into its own functions bind directly. Each
row is one-shot compression (`compress2`) of the input frame by frame, with
one reused context per side. Both sides must produce the same frames; the
benchmark compares every frame of its warm-up run and says so on a row where
they differ. No row differed.

The levels up to 3 compress every whole file, 211.9 MB as 12 frames (the rows
named "whole files"). The levels from 4 compress a sample, the first 2 MiB of
each file, 25.2 MB as 12 frames (the rows named "sample"), so a level-22 row
runs in minutes, not hours. The last column is the port's time over the
original's, then the time saved or added as a share of the original's; it
says "within noise" instead when the two sides' min-max spreads overlap.

The numbers below are one machine's, after the second performance pass, with
the whole run pinned to one core and transparent huge pages off for the
benchmark's process (see below). They are measurements, not a verdict.

- machine: AMD Ryzen 9 9950X3D 16-Core Processor, 32 logical CPUs, the run pinned to one (`taskset -c 6`)
- Zig 0.17.0, target x86_64-linux-gnu, CPU model znver5
- port: ReleaseFast, for that target
- original: zstd 1.5.7 from reference/, same target: -O3 -std=c99 -DXXH_NAMESPACE=ZSTD_ -DZSTD_MULTITHREAD -DZSTD_LEGACY_SUPPORT=0 -fno-sanitize=undefined -fPIC -fvisibility=hidden, plus huf_decompress_amd64.S on x86_64, as a shared library on glibc
- memory: transparent huge pages off for the process; the port allocates first
- command: zig build bench -- --markdown
- corpus: Silesia, 12 files, 211.9 MB; the whole-file rows take all of it as 12 frames, the sample rows 25.2 MB as 12 frames
- method: one `compress2` a frame, a reused context per side; an untimed warm-up of each side, then the median of 5 timed runs (3 from level 16), the sides taking turns; MB are 1e6 input bytes, the verdict is the time saved or added as a share of the original's, or within noise when the two sides' min-max spreads overlap

| row | MB in | original bytes | port bytes | ratio | original MB/s | port MB/s | original s (min-max) | port s (min-max) | port / original |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| level -5, whole files | 211.9 | 103031581 | 103031581 | 2.057 | 1062.3 | 1068.3 | 0.200 (0.199-0.200) | 0.198 (0.198-0.199) | 0.994, within noise |
| level -1, whole files | 211.9 | 86932028 | 86932028 | 2.438 | 856.0 | 859.3 | 0.248 (0.247-0.248) | 0.247 (0.246-0.247) | 0.996, 0.4% faster |
| level 1, whole files | 211.9 | 73229468 | 73229468 | 2.894 | 775.4 | 759.1 | 0.273 (0.273-0.273) | 0.279 (0.279-0.279) | 1.021, 2.1% slower |
| level 2, whole files | 211.9 | 69332724 | 69332724 | 3.057 | 648.9 | 643.8 | 0.327 (0.326-0.327) | 0.329 (0.328-0.330) | 1.008, 0.8% slower |
| level 3, whole files | 211.9 | 66137723 | 66137723 | 3.205 | 448.3 | 452.6 | 0.473 (0.473-0.473) | 0.468 (0.468-0.469) | 0.990, 1.0% faster |
| level 4, sample | 25.2 | 10054481 | 10054481 | 2.503 | 357.2 | 361.8 | 0.070 (0.070-0.070) | 0.070 (0.069-0.070) | 0.987, 1.3% faster |
| level 5, sample | 25.2 | 9822898 | 9822898 | 2.562 | 220.2 | 217.1 | 0.114 (0.114-0.115) | 0.116 (0.116-0.116) | 1.015, 1.5% slower |
| level 6, sample | 25.2 | 9678815 | 9678815 | 2.600 | 162.0 | 157.8 | 0.155 (0.155-0.155) | 0.159 (0.159-0.160) | 1.027, 2.7% slower |
| level 7, sample | 25.2 | 9579758 | 9579758 | 2.627 | 143.1 | 138.7 | 0.176 (0.176-0.176) | 0.181 (0.181-0.182) | 1.031, 3.1% slower |
| level 8, sample | 25.2 | 9530411 | 9530411 | 2.641 | 114.3 | 110.4 | 0.220 (0.220-0.221) | 0.228 (0.228-0.228) | 1.036, 3.6% slower |
| level 9, sample | 25.2 | 9513116 | 9513116 | 2.645 | 113.1 | 109.5 | 0.223 (0.222-0.223) | 0.230 (0.229-0.231) | 1.033, 3.3% slower |
| level 10, sample | 25.2 | 9448410 | 9448410 | 2.663 | 81.3 | 84.2 | 0.310 (0.309-0.310) | 0.299 (0.298-0.299) | 0.965, 3.5% faster |
| level 11, sample | 25.2 | 9404022 | 9404022 | 2.676 | 58.7 | 58.3 | 0.429 (0.429-0.432) | 0.432 (0.431-0.436) | 1.006, within noise |
| level 12, sample | 25.2 | 9404022 | 9404022 | 2.676 | 58.6 | 58.3 | 0.430 (0.427-0.446) | 0.432 (0.431-0.434) | 1.006, within noise |
| level 13, sample | 25.2 | 9365115 | 9365115 | 2.687 | 30.6 | 31.1 | 0.823 (0.823-0.832) | 0.810 (0.808-0.816) | 0.984, 1.6% faster |
| level 14, sample | 25.2 | 9328665 | 9328665 | 2.698 | 25.6 | 26.1 | 0.981 (0.980-0.988) | 0.963 (0.956-0.965) | 0.982, 1.8% faster |
| level 15, sample | 25.2 | 9322403 | 9322403 | 2.699 | 23.7 | 24.3 | 1.062 (1.054-1.065) | 1.036 (1.030-1.051) | 0.976, 2.4% faster |
| level 16, sample | 25.2 | 9080439 | 9080439 | 2.771 | 14.3 | 14.7 | 1.761 (1.756-1.765) | 1.713 (1.706-1.717) | 0.973, 2.7% faster |
| level 17, sample | 25.2 | 9021590 | 9021590 | 2.790 | 12.4 | 12.7 | 2.025 (2.024-2.047) | 1.989 (1.981-1.990) | 0.982, 1.8% faster |
| level 18, sample | 25.2 | 8953450 | 8953450 | 2.811 | 9.7 | 10.0 | 2.585 (2.584-2.592) | 2.511 (2.500-2.512) | 0.972, 2.8% faster |
| level 19, sample | 25.2 | 8933881 | 8933881 | 2.817 | 8.2 | 8.4 | 3.083 (3.080-3.090) | 3.001 (2.993-3.035) | 0.973, 2.7% faster |
| level 20, sample | 25.2 | 8933881 | 8933881 | 2.817 | 8.2 | 8.4 | 3.077 (3.076-3.081) | 2.994 (2.986-3.000) | 0.973, 2.7% faster |
| level 21, sample | 25.2 | 8932529 | 8932529 | 2.817 | 7.6 | 7.7 | 3.325 (3.319-3.340) | 3.261 (3.222-3.261) | 0.981, 1.9% faster |
| level 22, sample | 25.2 | 8931771 | 8931771 | 2.818 | 7.2 | 7.3 | 3.506 (3.490-3.622) | 3.444 (3.439-3.491) | 0.982, within noise |
| level 3, whole files, 4 workers | 211.9 | 66216521 | 66216521 | 3.201 | 438.7 | 442.5 | 0.483 (0.481-0.484) | 0.479 (0.477-0.484) | 0.992, within noise |
| level 19, sample, 4 workers | 25.2 | 8934361 | 8934361 | 2.817 | 8.2 | 8.4 | 3.080 (3.079-3.086) | 2.995 (2.980-3.023) | 0.972, 2.8% faster |

sum of the compressed sizes of every timed run, both sides: 6223653022

The two rows with 4 workers ran their workers on the same one core, so they
time the cost of the workers more than their gain. The same build on five
cores (`taskset -c 6-10`, `--levels 3,19`), which waited only for core 6 and
its sibling to be idle, so other work may have shared the other four:

- level 3, whole files, 4 workers: 1.002, within noise (the port 0.284 s
  (0.283-0.332), the original 0.284 s (0.278-0.296))
- level 19, sample, 4 workers: 1.060, within noise (the port 3.819 s
  (3.208-5.154), the original 3.604 s (3.478-3.891))

## Transparent huge pages

The benchmark turns transparent huge pages off for its own process
(`prctl(PR_SET_THP_DISABLE)`), so both sides' tables are on 4 KiB pages.
Machines in the field usually have them on: for every process with the
setting `always`, as this one has, or with `madvise` only where a program
asks, which leaves malloc's memory on 4 KiB pages as here. With them on for
the benchmark, whether a side's hash tables land on a 2 MiB huge page turns
on where malloc places its context, which follows the order the two sides
allocate in, so the order decided rows. In a run during the performance
pass, at level 4 with the port allocating first, a profile of L1 TLB misses
had 21242 samples in the port against 2517 in the original, and the port
came out 3.8% slower; with the original allocating first, it came out 4.0%
faster. With huge pages off, the misses split evenly (51% in the port at
levels 3 and 4), and the order moves no row. `--huge-pages` leaves them as
the system has them, and `--original-first` lets the original allocate
first. Levels 3 and 4 with the build above, huge pages on, each order:

- huge pages on, the port allocating first: level 3, whole files, 0.993
  (0.7% faster; the port 0.452 s (0.451-0.453), the original 0.455 s
  (0.454-0.455)); level 4, sample, 1.031 (3.1% slower; the port 0.068 s
  (0.068-0.068), the original 0.066 s (0.066-0.066))
- huge pages on, the original allocating first: level 3, whole files, 0.989
  (1.1% faster; the port 0.451 s (0.450-0.451), the original 0.455 s
  (0.455-0.456)); level 4, sample, 0.937 (6.3% faster; the port 0.065 s
  (0.065-0.065), the original 0.070 s (0.069-0.070))
- huge pages off, run just after: level 3, whole files, 1.000 (within noise;
  the port 0.476 s (0.471-0.477), the original 0.476 s (0.472-0.477)); level
  4, sample, 1.003 (within noise; the port 0.071 s (0.070-0.071), the
  original 0.070 s (0.070-0.071))

## Known biases

- The run takes a lock that keeps this project's builds off the machine, and
  waited until its core and that core's sibling were idle, but other
  sessions' work ran on other cores, sharing the L3 cache and memory
  bandwidth, which the benchmark cannot see.
- Rows move by up to 3% with where the code sits alone. The port's code is
  linked into the benchmark, so a change to the benchmark's own code moves
  the port's functions. A build with the same port code as here, 1360 bytes
  earlier in the binary (16 bytes off its place in a 64-byte cache line),
  measured in two pinned passes level 1 at 1.001 and 0.999 (here 1.021),
  levels 5 to 8 at 0.994 to 1.018 (here 1.015 to 1.036), levels -5 and -1 at
  1.004 to 1.012 (here 0.994 and 0.996), and levels 2 to 4 as here. The
  original is a shared library and stays put. In cycle profiles of the two
  builds, with the same instruction counts, the port's fast block compressor
  took 3.6% more cycles here at level 1, and at level 8 its row search 2.3%
  and its lazy2 loop 14% more, while the original's block compressor and row
  search took within 1% of the same in both.
- The original's calls into the C library go through the PLT, as in a
  distribution's libzstd.so. The port's calls to memcpy, memmove and memset go
  to Zig's own, in compiler_rt.

## Where the port is slower

- Level 1 (fast): 2.1% slower. Levels 5 to 9 (greedy, lazy and lazy2 with
  the row matcher): 1.5% to 3.6% slower. Level 2 (fast): 0.8% slower.
- At these levels the port runs as many instructions as the original or
  fewer (`instructions:u` over a whole level: 0.95 times the original's at
  level 1, 0.96 at level 2, 0.99 to 1.00 at levels 5 to 8), so the gap is
  in the cycles each instruction takes, and it moves with where the code
  sits (see the known biases above): in another build of the same port
  code, level 1 measured 1.001 and 0.999, and levels 5 to 8 0.994 to
  1.018.
