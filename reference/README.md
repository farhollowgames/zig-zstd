# The pinned original

Zstandard 1.5.7: tag `v1.5.7` of https://github.com/facebook/zstd, commit
`f8745da6ff1ad1e7bab384bd1f9d742439278e99`.

These files are copied from that commit unchanged, for the oracle tests and the
benchmark only; the zig-zstd package does not include them.

- `lib/`: the whole library directory.
- `LICENSE`, `COPYING`: upstream's two licences (BSD and GPLv2).
- `tests/golden-compression`, `tests/golden-dictionaries`, `tests/dict-files`:
  upstream's test inputs.
- `programs/datagen.c`, `datagen.h`, `lorem.c`, `lorem.h`, `platform.h`:
  upstream's generator of compressible test data.
