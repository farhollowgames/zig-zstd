//! The original zstd's C interface, as declared in its zstd.h with
//! ZSTD_STATIC_LINKING_ONLY, for the oracle tests and the benchmark, which
//! link the original built from reference/. C types map to Zig's: `unsigned`
//! is `c_uint`, `int` is `c_int`, `size_t` is `usize`.

pub extern fn ZSTD_versionNumber() c_uint;
pub extern fn ZSTD_compressBound(src_size: usize) usize;
pub extern fn ZSTD_isError(code: usize) c_uint;
pub extern fn ZSTD_compress(
    dst: ?*anyopaque,
    dst_capacity: usize,
    src: ?*const anyopaque,
    src_size: usize,
    level: c_int,
) usize;
