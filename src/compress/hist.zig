//! Histograms of byte values, from the original's hist.c.

const std = @import("std");
const assert = std.debug.assert;
const Error = @import("../error.zig").Error;

/// The workspace `countWksp` and `countFastWksp` take, in `u32` units.
pub const wksp_size_u32 = 1024;
pub const wksp_size = wksp_size_u32 * @sizeOf(u32);

/// Below this size, `countFastWksp` counts in one table.
const parallel_threshold = 1500;

/// `HIST_add`: adds the bytes of `src` to `counts`, which must cover them.
pub fn add(counts: []u32, src: []const u8) void {
    for (src) |byte| counts[byte] += 1;
}

/// `HIST_count_simple`: counts the bytes of `src` into
/// `counts[0..max_symbol_value_ptr.* + 1]`, and lowers `max_symbol_value_ptr`
/// to the largest byte present (0 for an empty `src`). Every byte must be at
/// most `max_symbol_value_ptr.*`. Returns the largest count.
pub fn countSimple(counts: []u32, max_symbol_value_ptr: *u32, src: []const u8) u32 {
    var max_symbol_value = max_symbol_value_ptr.*;
    @memset(counts[0 .. max_symbol_value + 1], 0);
    if (src.len == 0) {
        max_symbol_value_ptr.* = 0;
        return 0;
    }
    for (src) |byte| {
        assert(byte <= max_symbol_value);
        counts[byte] += 1;
    }
    while (counts[max_symbol_value] == 0) max_symbol_value -= 1;
    max_symbol_value_ptr.* = max_symbol_value;

    var largest_count: u32 = 0;
    for (counts[0 .. max_symbol_value + 1]) |c| largest_count = @max(largest_count, c);
    return largest_count;
}

const CheckInput = enum { trust_input, check_max_symbol_value };

/// `HIST_count_parallel_wksp`: counts into four tables, so that runs of one
/// byte do not wait on the same counter, then adds them up. With
/// `check_max_symbol_value`, a byte above `max_symbol_value_ptr.*` is an
/// error; otherwise `max_symbol_value_ptr` becomes the largest byte present.
fn countParallelWksp(
    counts: []u32,
    max_symbol_value_ptr: *u32,
    src: []const u8,
    check: CheckInput,
    workspace: *[wksp_size_u32]u32,
) Error!usize {
    assert(max_symbol_value_ptr.* <= 255);
    const count_size = max_symbol_value_ptr.* + 1;
    if (src.len == 0) {
        @memset(counts[0..count_size], 0);
        max_symbol_value_ptr.* = 0;
        return 0;
    }
    @memset(workspace, 0);
    const counting1 = workspace[0..256];
    const counting2 = workspace[256..512];
    const counting3 = workspace[512..768];
    const counting4 = workspace[768..1024];

    // The sum is all that is kept, so which table a byte lands in does not
    // matter: eight bytes at a time, two to each table.
    var ip: usize = 0;
    while (src.len - ip >= 16) : (ip += 16) {
        inline for (.{ 0, 8 }) |half| {
            const word = std.mem.readInt(u64, src[ip + half ..][0..8], .little);
            counting1[@as(u8, @truncate(word))] += 1;
            counting2[@as(u8, @truncate(word >> 8))] += 1;
            counting3[@as(u8, @truncate(word >> 16))] += 1;
            counting4[@as(u8, @truncate(word >> 24))] += 1;
            counting1[@as(u8, @truncate(word >> 32))] += 1;
            counting2[@as(u8, @truncate(word >> 40))] += 1;
            counting3[@as(u8, @truncate(word >> 48))] += 1;
            counting4[@as(u8, @truncate(word >> 56))] += 1;
        }
    }
    for (src[ip..]) |byte| counting1[byte] += 1;

    const lanes = 16;
    const Lanes = @Vector(lanes, u32);
    var max_vector: Lanes = @splat(0);
    var s: usize = 0;
    while (s < 256) : (s += lanes) {
        const sum = @as(Lanes, counting1[s..][0..lanes].*) +
            @as(Lanes, counting2[s..][0..lanes].*) +
            @as(Lanes, counting3[s..][0..lanes].*) +
            @as(Lanes, counting4[s..][0..lanes].*);
        counting1[s..][0..lanes].* = sum;
        max_vector = @max(max_vector, sum);
    }
    const max: u32 = @reduce(.Max, max_vector);

    var max_symbol_value: u32 = 255;
    while (counting1[max_symbol_value] == 0) max_symbol_value -= 1;
    if (check == .check_max_symbol_value and max_symbol_value > max_symbol_value_ptr.*) {
        return error.MaxSymbolValueTooSmall;
    }
    max_symbol_value_ptr.* = max_symbol_value;
    // `counts` may overlap the workspace.
    @memmove(counts[0..count_size], counting1[0..count_size]);
    return max;
}

/// The workspace as `u32` counters, or `error.Generic` if it is not aligned
/// on 4 bytes, as the original requires.
fn countersOf(workspace: []u8) Error!*[wksp_size_u32]u32 {
    if (@intFromPtr(workspace.ptr) & 3 != 0) return error.Generic;
    if (workspace.len < wksp_size) return error.WorkSpaceTooSmall;
    return @ptrCast(@alignCast(workspace.ptr));
}

/// `HIST_countFast_wksp`: as `countSimple`, faster on large inputs, with a
/// workspace of `wksp_size` bytes aligned on 4. The bytes of `src` are
/// trusted to be at most `max_symbol_value_ptr.*`.
pub fn countFastWksp(
    counts: []u32,
    max_symbol_value_ptr: *u32,
    src: []const u8,
    workspace: []u8,
) Error!usize {
    if (src.len < parallel_threshold) return countSimple(counts, max_symbol_value_ptr, src);
    const counters = try countersOf(workspace);
    return countParallelWksp(counts, max_symbol_value_ptr, src, .trust_input, counters);
}

/// `HIST_count_wksp`: as `countFastWksp`, but a byte above
/// `max_symbol_value_ptr.*` gives `error.MaxSymbolValueTooSmall`.
pub fn countWksp(
    counts: []u32,
    max_symbol_value_ptr: *u32,
    src: []const u8,
    workspace: []u8,
) Error!usize {
    const counters = try countersOf(workspace);
    if (max_symbol_value_ptr.* < 255) {
        return countParallelWksp(
            counts,
            max_symbol_value_ptr,
            src,
            .check_max_symbol_value,
            counters,
        );
    }
    max_symbol_value_ptr.* = 255;
    return countFastWksp(counts, max_symbol_value_ptr, src, workspace);
}

/// `HIST_countFast`: `countFastWksp` with a workspace on the stack.
pub fn countFast(counts: []u32, max_symbol_value_ptr: *u32, src: []const u8) Error!usize {
    var workspace: [wksp_size_u32]u32 = undefined;
    return countFastWksp(counts, max_symbol_value_ptr, src, std.mem.asBytes(&workspace));
}

/// `HIST_count`: `countWksp` with a workspace on the stack.
pub fn count(counts: []u32, max_symbol_value_ptr: *u32, src: []const u8) Error!usize {
    var workspace: [wksp_size_u32]u32 = undefined;
    return countWksp(counts, max_symbol_value_ptr, src, std.mem.asBytes(&workspace));
}

// --------------------------------------------------------
// Tests
// --------------------------------------------------------

const testing = std.testing;

test "the four-table count matches the simple count" {
    var src: [5000]u8 = undefined;
    for (&src, 0..) |*byte, n| byte.* = @truncate(n * 7 + n / 13);
    var simple: [256]u32 = undefined;
    var parallel: [256]u32 = undefined;
    var max_simple: u32 = 255;
    var max_parallel: u32 = 255;
    const largest_simple = countSimple(&simple, &max_simple, &src);
    const largest_parallel = try count(&parallel, &max_parallel, &src);
    try testing.expectEqual(@as(usize, largest_simple), largest_parallel);
    try testing.expectEqual(max_simple, max_parallel);
    try testing.expectEqualSlices(u32, &simple, &parallel);
}

test "a byte above the limit is an error when checked" {
    const src = [_]u8{ 1, 2, 200 };
    var counts: [256]u32 = undefined;
    var max_symbol_value: u32 = 100;
    try testing.expectError(error.MaxSymbolValueTooSmall, count(&counts, &max_symbol_value, &src));
}
