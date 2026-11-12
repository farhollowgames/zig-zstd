# Benchmarks

`zig build bench` times the port in ReleaseFast against the original built
from `reference/` at -O3, for the same target, on the Silesia corpus. Each row
is one-shot compression (`compress2`) of the input frame by frame, with one
reused context per side. Both sides must produce the same frames; the
benchmark compares every frame of its warm-up run and says so on a row where
they differ. No row differed.

The numbers below are one machine's, at one point of the port: before the
performance pass, and before the streaming half is merged (so the
multithreaded rows are skipped). They are measurements, not a verdict.

- machine: AMD Ryzen 9 9950X3D 16-Core Processor, 32 logical CPUs
- Zig 0.17.0, target x86_64-linux-gnu, CPU model znver5
- port: ReleaseFast, for that target
- original: zstd 1.5.7 from reference/, same target: -O3 -std=c99 -DXXH_NAMESPACE=ZSTD_ -DZSTD_MULTITHREAD -DZSTD_LEGACY_SUPPORT=0 -fno-sanitize=undefined, plus huf_decompress_amd64.S on x86_64
- command: zig build bench -- --markdown
- corpus: Silesia, 12 files, 211.9 MB; the whole-file rows take all of it as 12 frames, the sample rows 25.2 MB as 12 frames
- method: one `compress2` a frame, a reused context per side; an untimed warm-up of each side, then the median of 5 timed runs (3 from level 16), the sides taking turns; MB are 1e6 input bytes, the verdict is the time saved or added as a share of the original's

| row | MB in | original bytes | port bytes | ratio | original MB/s | port MB/s | original s (min-max) | port s (min-max) | port / original |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| level -5, whole files | 211.9 | 103031581 | 103031581 | 2.057 | 869.8 | 896.8 | 0.244 (0.219-0.301) | 0.236 (0.232-0.299) | 0.970, 3.0% faster |
| level -1, whole files | 211.9 | 86932028 | 86932028 | 2.438 | 531.3 | 539.7 | 0.399 (0.308-0.565) | 0.393 (0.358-0.599) | 0.984, 1.6% faster |
| level 1, whole files | 211.9 | 73229468 | 73229468 | 2.894 | 248.9 | 227.0 | 0.851 (0.465-1.330) | 0.934 (0.518-1.347) | 1.097, 9.7% slower |
| level 2, whole files | 211.9 | 69332724 | 69332724 | 3.057 | 238.4 | 238.5 | 0.889 (0.684-1.297) | 0.889 (0.564-1.248) | 1.000, 0.0% faster |
| level 3, whole files | 211.9 | 66137723 | 66137723 | 3.205 | 286.4 | 216.4 | 0.740 (0.730-1.188) | 0.979 (0.809-1.206) | 1.323, 32.3% slower |
| level 4, sample | 25.2 | 10054481 | 10054481 | 2.503 | 281.9 | 229.7 | 0.089 (0.084-0.114) | 0.110 (0.106-0.127) | 1.227, 22.7% slower |
| level 5, sample | 25.2 | 9822898 | 9822898 | 2.562 | 178.1 | 173.6 | 0.141 (0.137-0.153) | 0.145 (0.136-0.155) | 1.026, 2.6% slower |
| level 6, sample | 25.2 | 9678815 | 9678815 | 2.600 | 128.6 | 133.4 | 0.196 (0.177-0.247) | 0.189 (0.181-0.200) | 0.964, 3.6% faster |
| level 7, sample | 25.2 | 9579758 | 9579758 | 2.627 | 117.9 | 112.9 | 0.213 (0.200-0.238) | 0.223 (0.207-0.227) | 1.045, 4.5% slower |
| level 8, sample | 25.2 | 9530411 | 9530411 | 2.641 | 96.9 | 91.5 | 0.260 (0.247-0.263) | 0.275 (0.255-0.283) | 1.059, 5.9% slower |
| level 9, sample | 25.2 | 9513116 | 9513116 | 2.645 | 94.9 | 98.3 | 0.265 (0.239-0.301) | 0.256 (0.249-0.258) | 0.965, 3.5% faster |
| level 10, sample | 25.2 | 9448410 | 9448410 | 2.663 | 67.4 | 71.7 | 0.373 (0.367-0.386) | 0.351 (0.331-0.363) | 0.941, 5.9% faster |
| level 11, sample | 25.2 | 9404022 | 9404022 | 2.676 | 48.7 | 47.8 | 0.517 (0.484-0.536) | 0.527 (0.512-0.560) | 1.019, 1.9% slower |
| level 12, sample | 25.2 | 9404022 | 9404022 | 2.676 | 48.9 | 49.4 | 0.514 (0.504-0.529) | 0.510 (0.489-0.514) | 0.991, 0.9% faster |
| level 13, sample | 25.2 | 9365115 | 9365115 | 2.687 | 23.1 | 23.3 | 1.088 (0.946-1.505) | 1.082 (0.935-1.424) | 0.994, 0.6% faster |
| level 14, sample | 25.2 | 9328665 | 9328665 | 2.698 | 21.5 | 22.5 | 1.171 (1.135-1.218) | 1.118 (1.031-1.169) | 0.955, 4.5% faster |
| level 15, sample | 25.2 | 9322403 | 9322403 | 2.699 | 22.7 | 23.2 | 1.110 (1.066-1.150) | 1.083 (1.054-1.106) | 0.975, 2.5% faster |
| level 16, sample | 25.2 | 9080439 | 9080439 | 2.771 | 13.1 | 13.6 | 1.920 (1.881-1.968) | 1.856 (1.831-1.858) | 0.967, 3.3% faster |
| level 17, sample | 25.2 | 9021590 | 9021590 | 2.790 | 12.3 | 12.4 | 2.044 (1.993-2.150) | 2.022 (1.952-2.121) | 0.989, 1.1% faster |
| level 18, sample | 25.2 | 8953450 | 8953450 | 2.811 | 9.6 | 9.8 | 2.608 (2.599-2.666) | 2.567 (2.529-2.624) | 0.984, 1.6% faster |
| level 19, sample | 25.2 | 8933881 | 8933881 | 2.817 | 8.0 | 8.3 | 3.130 (3.055-3.144) | 3.042 (3.024-3.075) | 0.972, 2.8% faster |
| level 20, sample | 25.2 | 8933881 | 8933881 | 2.817 | 7.7 | 7.7 | 3.284 (3.189-3.347) | 3.256 (3.233-3.336) | 0.991, 0.9% faster |
| level 21, sample | 25.2 | 8932529 | 8932529 | 2.817 | 6.7 | 6.8 | 3.771 (3.626-3.804) | 3.716 (3.524-3.747) | 0.986, 1.4% faster |
| level 22, sample | 25.2 | 8931771 | 8931771 | 2.818 | 6.4 | 6.6 | 3.944 (3.738-4.044) | 3.788 (3.715-3.894) | 0.961, 3.9% faster |
| level 3, whole files, 4 workers | - | - | - | - | - | - | - | - | skipped (not merged) |
| level 19, sample, 4 workers | - | - | - | - | - | - | - | - | skipped (not merged) |

sum of the compressed sizes of every timed run, both sides: 5507881646

## Known biases

- The whole-file rows (levels -5 to 3) spread widely between runs (level 1:
  0.47 s to 1.33 s on the original's side). Their medians move by tens of
  percent between runs of the benchmark; the sample rows are steadier.
- The sample rows take the first 2 MiB of each Silesia file, 25.2 MB in all,
  so a level-22 row runs in minutes, not hours.
- Rows are single-threaded; the machine was otherwise idle apart from other
  sessions' work, which the benchmark cannot see.

## Where the port is slower

- Levels 3 and 4 (`dfast`): 23% to 32% slower. Not yet profiled.
- Level 1 (`fast`): about 10% slower on whole files, inside the noise above;
  5% to 7% slower on samples in quick runs.
- Levels 5, 7, 8 (greedy and lazy with the row matcher): 3% to 6% slower.
