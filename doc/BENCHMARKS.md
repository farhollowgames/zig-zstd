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

The numbers below are one machine's, after the third performance pass, with
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
| level -5, whole files | 211.9 | 103031581 | 103031581 | 2.057 | 1051.7 | 1055.5 | 0.202 (0.201-0.202) | 0.201 (0.201-0.202) | 0.996, within noise |
| level -1, whole files | 211.9 | 86932028 | 86932028 | 2.438 | 849.4 | 844.2 | 0.250 (0.249-0.250) | 0.251 (0.250-0.251) | 1.006, 0.6% slower |
| level 1, whole files | 211.9 | 73229468 | 73229468 | 2.894 | 772.6 | 764.4 | 0.274 (0.274-0.274) | 0.277 (0.277-0.278) | 1.011, 1.1% slower |
| level 2, whole files | 211.9 | 69332724 | 69332724 | 3.057 | 643.1 | 635.4 | 0.330 (0.329-0.330) | 0.334 (0.333-0.334) | 1.012, 1.2% slower |
| level 3, whole files | 211.9 | 66137723 | 66137723 | 3.205 | 443.4 | 446.5 | 0.478 (0.477-0.479) | 0.475 (0.473-0.475) | 0.993, 0.7% faster |
| level 4, sample | 25.2 | 10054481 | 10054481 | 2.503 | 355.0 | 357.0 | 0.071 (0.070-0.071) | 0.070 (0.070-0.071) | 0.994, within noise |
| level 5, sample | 25.2 | 9822898 | 9822898 | 2.562 | 218.8 | 220.1 | 0.115 (0.115-0.115) | 0.114 (0.114-0.115) | 0.994, 0.6% faster |
| level 6, sample | 25.2 | 9678815 | 9678815 | 2.600 | 161.6 | 160.1 | 0.156 (0.155-0.157) | 0.157 (0.157-0.157) | 1.010, 1.0% slower |
| level 7, sample | 25.2 | 9579758 | 9579758 | 2.627 | 142.1 | 141.8 | 0.177 (0.177-0.177) | 0.177 (0.177-0.178) | 1.002, within noise |
| level 8, sample | 25.2 | 9530411 | 9530411 | 2.641 | 112.7 | 112.7 | 0.223 (0.223-0.224) | 0.223 (0.223-0.224) | 1.000, within noise |
| level 9, sample | 25.2 | 9513116 | 9513116 | 2.645 | 111.8 | 111.4 | 0.225 (0.224-0.226) | 0.226 (0.224-0.227) | 1.004, within noise |
| level 10, sample | 25.2 | 9448410 | 9448410 | 2.663 | 80.5 | 83.4 | 0.313 (0.311-0.313) | 0.302 (0.300-0.305) | 0.965, 3.5% faster |
| level 11, sample | 25.2 | 9404022 | 9404022 | 2.676 | 58.2 | 58.1 | 0.433 (0.432-0.436) | 0.433 (0.431-0.434) | 1.001, within noise |
| level 12, sample | 25.2 | 9404022 | 9404022 | 2.676 | 58.2 | 58.0 | 0.433 (0.431-0.438) | 0.434 (0.431-0.435) | 1.003, within noise |
| level 13, sample | 25.2 | 9365115 | 9365115 | 2.687 | 30.0 | 30.9 | 0.838 (0.833-0.848) | 0.816 (0.806-0.819) | 0.973, 2.7% faster |
| level 14, sample | 25.2 | 9328665 | 9328665 | 2.698 | 25.4 | 25.9 | 0.992 (0.987-0.998) | 0.970 (0.961-0.974) | 0.978, 2.2% faster |
| level 15, sample | 25.2 | 9322403 | 9322403 | 2.699 | 23.6 | 24.1 | 1.066 (1.064-1.086) | 1.042 (1.033-1.046) | 0.978, 2.2% faster |
| level 16, sample | 25.2 | 9080439 | 9080439 | 2.771 | 14.2 | 14.6 | 1.777 (1.768-1.781) | 1.727 (1.715-1.728) | 0.972, 2.8% faster |
| level 17, sample | 25.2 | 9021590 | 9021590 | 2.790 | 12.2 | 12.5 | 2.055 (2.054-2.058) | 2.007 (2.001-2.008) | 0.977, 2.3% faster |
| level 18, sample | 25.2 | 8953450 | 8953450 | 2.811 | 9.7 | 10.0 | 2.605 (2.602-2.614) | 2.514 (2.511-2.518) | 0.965, 3.5% faster |
| level 19, sample | 25.2 | 8933881 | 8933881 | 2.817 | 8.1 | 8.5 | 3.098 (3.091-3.105) | 2.977 (2.972-3.055) | 0.961, 3.9% faster |
| level 20, sample | 25.2 | 8933881 | 8933881 | 2.817 | 8.1 | 8.4 | 3.103 (3.099-3.105) | 2.993 (2.979-2.994) | 0.964, 3.6% faster |
| level 21, sample | 25.2 | 8932529 | 8932529 | 2.817 | 7.5 | 7.8 | 3.360 (3.359-3.377) | 3.241 (3.241-3.251) | 0.965, 3.5% faster |
| level 22, sample | 25.2 | 8931771 | 8931771 | 2.818 | 6.9 | 7.1 | 3.639 (3.634-3.664) | 3.523 (3.501-3.524) | 0.968, 3.2% faster |
| level 3, whole files, 4 workers | 211.9 | 66216521 | 66216521 | 3.201 | 421.9 | 424.0 | 0.502 (0.500-0.505) | 0.500 (0.498-0.500) | 0.995, within noise |
| level 19, sample, 4 workers | 25.2 | 8934361 | 8934361 | 2.817 | 7.9 | 8.2 | 3.195 (3.194-3.202) | 3.070 (3.063-3.075) | 0.961, 3.9% faster |

sum of the compressed sizes of every timed run, both sides: 6223653022

The two rows with 4 workers ran their workers on the same one core, so they
time the cost of the workers more than their gain. The second performance
pass's build on five
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
first. Levels 3 and 4 with the second performance pass's build, huge pages on,
each order:

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
- Where the code sits moved rows by up to 3% before the third performance
  pass: a loop that straddles a 4 KiB page boundary misses in this CPU's
  instruction cache far more often (in one build the level-1 fast loop
  crossed one and missed 194 million times, against 15 million in a build
  where it did not, for the same instructions). The port's inner-loop
  functions are now page-aligned, and `-Dbench-code-shift=N` moves the
  port's code to test it: at shifts 0, 16 and 1360, each row from -5 to 15
  stayed within 1.2% of itself, most within 0.8% (levels 1 and 2 at 1.007
  to 1.012, levels 5 to 9 at 0.992 to 1.006). The shifts move whole
  functions, not the code inside an aligned one, so this holds for this
  code as compiled here, not for every later change: several hot functions
  are over 4 KiB (the lazy block compressors, the Huffman 1X coder), whose
  loops could straddle a page after a change, and the double-fast
  no-dictionary variant sits 59 bytes under a page. The original is a
  shared library and stays put, with whatever its build gives it: its row
  search at levels 5 to 9 takes misses of the same size in this build.
- Ratios move by about 1 to 1.5 points between runs of the same binary on
  different occasions (level 6 1.002 in one pass and 1.010 in the table
  above, level 4 0.984 and 0.994). The rows from 16 to 22 came out 1 to 1.4
  points faster for the port than in the second pass's table; that pass and
  this one did not change their code, so that move is the run's, not this
  pass's.
- The original's calls into the C library go through the PLT, as in a
  distribution's libzstd.so. The port's calls to memcpy, memmove and memset go
  to Zig's own, in compiler_rt.

## Where the port is slower

- Levels 1 and 2 (fast): 1.1% and 1.2% slower, at every placement tried;
  level -1 0.6% slower. The fast block compressor's variants are
  functions of their own, so that each starts on a page of its own, and
  compiled that way their loop runs about 10% more instructions than
  when they were inlined into one function as the original's are (more
  spills of loop invariants), and the port as a whole about 6% more at
  level 1 (from an instruction profile of the port's side alone). The inlined version was 0.1% faster to
  2.2% slower depending on where it landed.
- Level 6: 1.0% slower in this run; 1.001 to 1.005 at the three
  placements above. Levels 5 and 7 to 9 are even or within noise.
