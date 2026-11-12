//! The compression workspace, from the original's zstd_cwksp.h: one buffer
//! that holds all of a context's or dictionary's internal structures, so
//! that it takes one allocation, or none when the caller provides the buffer.
//!
//! Layout:
//!
//!     [objects][tables ->] free space [<- buffers][<- aligned][<- init once]
//!
//! - Objects: fixed-size structures reserved once, at the first
//!   initialisation (the entropy workspace, the two block states, a
//!   dictionary's content), aligned on pointers. They are reused for every
//!   compression.
//! - Tables: the match finders' u32 tables (hash tables, chain tables, binary
//!   trees), sized by the parameters and aligned on 64 bytes. Every value in
//!   them is below the window's current index, so they can be reused without
//!   clearing while the workspace keeps that bound (`table_valid_end`).
//! - Init once: 64-byte aligned buffers zeroed the first time they are
//!   reserved; later reservations may see earlier compressions' data.
//! - Aligned: 64-byte aligned buffers that are written before they are read.
//! - Buffers: unaligned buffers that are written before they are read.
//!
//! Reservations go in phase order: objects, then init once, aligned and
//! buffers, with tables at any time after the objects. A reservation out of
//! order fails.

const std = @import("std");

const Error = @import("../error.zig").Error;
const zstd_internal = @import("../common/zstd_internal.zig");

const assert = std.debug.assert;

/// Tables and aligned buffers are aligned on 64 bytes.
pub const alignment_bytes = 64;

pub const AllocPhase = enum(u32) {
    objects,
    aligned_init_once,
    aligned,
    buffers,
};

/// Whether the workspace is the caller's buffer, never freed by the
/// workspace, or allocated by it.
pub const StaticAlloc = enum(u32) {
    dynamic_alloc,
    static_alloc,
};

/// `ZSTD_cwksp_align`: `size` rounded up to `alignment`, a power of two.
pub fn alignSize(size: usize, alignment: usize) usize {
    assert(std.math.isPowerOfTwo(alignment));
    const mask = alignment - 1;
    return (size + mask) & ~mask;
}

/// `ZSTD_cwksp_alloc_size`: the space an object or buffer of `size` bytes
/// takes in the workspace. Tables take exactly their size; aligned buffers
/// take `aligned64AllocSize`.
pub fn allocSize(size: usize) usize {
    return size;
}

/// `ZSTD_cwksp_aligned_alloc_size`.
pub fn alignedAllocSize(size: usize, alignment: usize) usize {
    return allocSize(alignSize(size, alignment));
}

/// `ZSTD_cwksp_aligned64_alloc_size`: the space an aligned buffer of `size`
/// bytes takes, a multiple of 64 bytes.
pub fn aligned64AllocSize(size: usize) usize {
    return alignedAllocSize(size, alignment_bytes);
}

/// `ZSTD_cwksp_slack_space_required`: the space the workspace may lose to
/// alignment, at the start of the tables and the end of the buffers.
pub fn slackSpaceRequired() usize {
    return alignment_bytes * 2;
}

/// `ZSTD_cwksp_bytes_to_align_ptr`: the bytes from `ptr` to the next
/// multiple of `align_bytes`, a power of two.
pub fn bytesToAlignPtr(ptr: [*]const u8, align_bytes: usize) usize {
    assert(std.math.isPowerOfTwo(align_bytes));
    const align_bytes_mask = align_bytes - 1;
    const bytes = (align_bytes - (@intFromPtr(ptr) & align_bytes_mask)) & align_bytes_mask;
    assert(bytes < align_bytes);
    return bytes;
}

/// Where an empty workspace's pointers point, as the original's are null.
var no_buffer: [0]u8 align(alignment_bytes) = .{};

/// `ZSTD_cwksp`. An empty workspace (`.{}`) has no buffer. Every pointer it hands out is into its buffer, valid until
/// the reservation's phase is cleared (`clearTables` for tables, `clear` for
/// all but objects) or the workspace is freed or moved.
pub const Cwksp = struct {
    workspace: [*]u8 = &no_buffer,
    workspace_end: [*]u8 = &no_buffer,

    object_end: [*]u8 = &no_buffer,
    table_end: [*]u8 = &no_buffer,
    table_valid_end: [*]u8 = &no_buffer,
    alloc_start: [*]u8 = &no_buffer,
    init_once_start: [*]u8 = &no_buffer,

    alloc_failed: bool = false,
    workspace_oversized_duration: i32 = 0,
    phase: AllocPhase = .objects,
    is_static: StaticAlloc = .dynamic_alloc,

    fn assertInternalConsistency(ws: *const Cwksp) void {
        assert(@intFromPtr(ws.workspace) <= @intFromPtr(ws.object_end));
        assert(@intFromPtr(ws.object_end) <= @intFromPtr(ws.table_end));
        assert(@intFromPtr(ws.object_end) <= @intFromPtr(ws.table_valid_end));
        assert(@intFromPtr(ws.table_end) <= @intFromPtr(ws.alloc_start));
        assert(@intFromPtr(ws.table_valid_end) <= @intFromPtr(ws.alloc_start));
        assert(@intFromPtr(ws.alloc_start) <= @intFromPtr(ws.workspace_end));
        assert(@intFromPtr(ws.init_once_start) <= @intFromPtr(ws.initialAllocStart()));
        assert(@intFromPtr(ws.workspace) <= @intFromPtr(ws.init_once_start));
    }

    /// `ZSTD_cwksp_initialAllocStart`: where reservations from the end
    /// start, the end aligned down to 64 bytes.
    pub fn initialAllocStart(ws: *const Cwksp) [*]u8 {
        const end = @intFromPtr(ws.workspace_end);
        return ws.workspace_end - (end % alignment_bytes);
    }

    /// `ZSTD_cwksp_reserve_internal_buffer_space`: takes `bytes` from the end
    /// part of the workspace.
    fn reserveInternalBufferSpace(ws: *Cwksp, bytes: usize) ?[*]u8 {
        ws.assertInternalConsistency();
        const alloc_addr = @intFromPtr(ws.alloc_start) -% bytes;
        if (bytes > @intFromPtr(ws.alloc_start) or alloc_addr < @intFromPtr(ws.table_end)) {
            ws.alloc_failed = true;
            return null;
        }
        const alloc = ws.alloc_start - bytes;
        // Space over the valid tables voids their bound on values.
        if (@intFromPtr(alloc) < @intFromPtr(ws.table_valid_end)) ws.table_valid_end = alloc;
        ws.alloc_start = alloc;
        return alloc;
    }

    /// `ZSTD_cwksp_internal_advance_phase`: moves on to `phase`, aligning the
    /// start of the tables when leaving the objects.
    fn internalAdvancePhase(ws: *Cwksp, phase: AllocPhase) Error!void {
        assert(@backingInt(phase) >= @backingInt(ws.phase));
        if (@backingInt(phase) > @backingInt(ws.phase)) {
            if (@backingInt(ws.phase) < @backingInt(AllocPhase.aligned_init_once) and
                @backingInt(phase) >= @backingInt(AllocPhase.aligned_init_once))
            {
                ws.table_valid_end = ws.object_end;
                ws.init_once_start = ws.initialAllocStart();

                // Align the start of the tables on 64 bytes, with 0 to 63 bytes.
                const bytes_to_align = bytesToAlignPtr(ws.object_end, alignment_bytes);
                if (@intFromPtr(ws.object_end) + bytes_to_align > @intFromPtr(ws.workspace_end)) {
                    return error.MemoryAllocation;
                }
                const object_end = ws.object_end + bytes_to_align;
                ws.object_end = object_end;
                ws.table_end = object_end;
                if (@intFromPtr(ws.table_valid_end) < @intFromPtr(ws.table_end)) {
                    ws.table_valid_end = ws.table_end;
                }
            }
            ws.phase = phase;
            ws.assertInternalConsistency();
        }
    }

    /// `ZSTD_cwksp_owns_buffer`: whether `ptr` is in the workspace.
    pub fn ownsBuffer(ws: *const Cwksp, ptr: ?*const anyopaque) bool {
        const p = ptr orelse return false;
        return @intFromPtr(ws.workspace) <= @intFromPtr(p) and
            @intFromPtr(p) < @intFromPtr(ws.workspace_end);
    }

    fn reserveInternal(ws: *Cwksp, bytes: usize, phase: AllocPhase) ?[*]u8 {
        ws.internalAdvancePhase(phase) catch return null;
        if (bytes == 0) return null;
        return ws.reserveInternalBufferSpace(bytes);
    }

    /// `ZSTD_cwksp_reserve_buffer`: unaligned memory, written before read.
    pub fn reserveBuffer(ws: *Cwksp, bytes: usize) ?[*]u8 {
        return ws.reserveInternal(bytes, .buffers);
    }

    /// `ZSTD_cwksp_reserve_aligned_init_once`: memory sized and aligned on 64
    /// bytes, zeroed the first time this space is reserved, and possibly
    /// holding an earlier compression's data after that. For algorithms that
    /// may read memory they have not written; they must stay correct, and
    /// must not leak the old data, whatever it holds.
    pub fn reserveAlignedInitOnce(ws: *Cwksp, bytes: usize) ?[*]align(alignment_bytes) u8 {
        const aligned_bytes = alignSize(bytes, alignment_bytes);
        const ptr = ws.reserveInternal(aligned_bytes, .aligned_init_once) orelse return null;
        assert(@intFromPtr(ptr) & (alignment_bytes - 1) == 0);
        if (@intFromPtr(ptr) < @intFromPtr(ws.init_once_start)) {
            // The memory after this reservation is the end of the workspace
            // or an earlier init-once reservation, already zeroed, so zeroing
            // up to `init_once_start` is enough.
            const zeroed = @min(@intFromPtr(ws.init_once_start) - @intFromPtr(ptr), aligned_bytes);
            @memset(ptr[0..zeroed], 0);
            ws.init_once_start = ptr;
        }
        return @alignCast(ptr);
    }

    /// `ZSTD_cwksp_reserve_aligned64`: memory sized and aligned on 64 bytes.
    pub fn reserveAligned64(ws: *Cwksp, bytes: usize) ?[*]align(alignment_bytes) u8 {
        const ptr = ws.reserveInternal(alignSize(bytes, alignment_bytes), .aligned) orelse
            return null;
        assert(@intFromPtr(ptr) & (alignment_bytes - 1) == 0);
        return @alignCast(ptr);
    }

    /// `ZSTD_cwksp_reserve_table`: a table aligned on 64 bytes, whose values
    /// stay bounded so it can be reused without clearing. `bytes` is a
    /// multiple of 64. Returns a pointer even for 0 bytes.
    pub fn reserveTable(ws: *Cwksp, bytes: usize) ?[*]align(alignment_bytes) u8 {
        const phase: AllocPhase = .aligned_init_once;
        // Tables start once the objects are done.
        if (@backingInt(ws.phase) < @backingInt(phase)) {
            ws.internalAdvancePhase(phase) catch return null;
        }
        const alloc = ws.table_end;
        assert(bytes & (@sizeOf(u32) - 1) == 0);
        ws.assertInternalConsistency();
        if (bytes > @intFromPtr(ws.alloc_start) - @intFromPtr(alloc)) {
            ws.alloc_failed = true;
            return null;
        }
        ws.table_end = alloc + bytes;

        assert(bytes & (alignment_bytes - 1) == 0);
        assert(@intFromPtr(alloc) & (alignment_bytes - 1) == 0);
        return @alignCast(alloc);
    }

    /// `ZSTD_cwksp_reserve_object`: an object aligned on pointers. Only at
    /// the workspace's first initialisation.
    pub fn reserveObject(ws: *Cwksp, bytes: usize) ?[*]align(@alignOf(*anyopaque)) u8 {
        const rounded_bytes = alignSize(bytes, @sizeOf(*anyopaque));
        const alloc = ws.object_end;
        assert(@intFromPtr(alloc) % @alignOf(*anyopaque) == 0);
        assert(bytes % @alignOf(*anyopaque) == 0);
        ws.assertInternalConsistency();
        // Objects come first: no phase moves back to them.
        if (ws.phase != .objects or
            @intFromPtr(alloc) + rounded_bytes > @intFromPtr(ws.workspace_end))
        {
            ws.alloc_failed = true;
            return null;
        }
        const end = alloc + rounded_bytes;
        ws.object_end = end;
        ws.table_end = end;
        ws.table_valid_end = end;
        return @alignCast(alloc);
    }

    /// `ZSTD_cwksp_reserve_object_aligned`: an object aligned on `alignment`,
    /// a power of two.
    pub fn reserveObjectAligned(ws: *Cwksp, byte_size: usize, alignment: usize) ?[*]u8 {
        const mask = alignment - 1;
        const surplus = if (alignment > @sizeOf(*anyopaque)) alignment - @sizeOf(*anyopaque) else 0;
        const start = ws.reserveObject(byte_size + surplus) orelse return null;
        if (surplus == 0) return start;
        assert(std.math.isPowerOfTwo(alignment));
        return @ptrFromInt((@intFromPtr(start) + surplus) & ~mask);
    }

    /// `ZSTD_cwksp_mark_tables_dirty`: the tables' values are no longer bounded.
    pub fn markTablesDirty(ws: *Cwksp) void {
        assert(@intFromPtr(ws.table_valid_end) >= @intFromPtr(ws.object_end));
        assert(@intFromPtr(ws.table_valid_end) <= @intFromPtr(ws.alloc_start));
        ws.table_valid_end = ws.object_end;
        ws.assertInternalConsistency();
    }

    /// `ZSTD_cwksp_mark_tables_clean`: the reserved tables' values are bounded.
    pub fn markTablesClean(ws: *Cwksp) void {
        assert(@intFromPtr(ws.table_valid_end) >= @intFromPtr(ws.object_end));
        assert(@intFromPtr(ws.table_valid_end) <= @intFromPtr(ws.alloc_start));
        if (@intFromPtr(ws.table_valid_end) < @intFromPtr(ws.table_end)) {
            ws.table_valid_end = ws.table_end;
        }
        ws.assertInternalConsistency();
    }

    /// `ZSTD_cwksp_clean_tables`: zeroes the part of the tables not known to
    /// be bounded.
    pub fn cleanTables(ws: *Cwksp) void {
        assert(@intFromPtr(ws.table_valid_end) >= @intFromPtr(ws.object_end));
        assert(@intFromPtr(ws.table_valid_end) <= @intFromPtr(ws.alloc_start));
        if (@intFromPtr(ws.table_valid_end) < @intFromPtr(ws.table_end)) {
            const size = @intFromPtr(ws.table_end) - @intFromPtr(ws.table_valid_end);
            @memset(ws.table_valid_end[0..size], 0);
        }
        ws.markTablesClean();
    }

    /// `ZSTD_cwksp_clear_tables`: frees the tables; other reservations stay.
    pub fn clearTables(ws: *Cwksp) void {
        ws.table_end = ws.object_end;
        ws.assertInternalConsistency();
    }

    /// `ZSTD_cwksp_clear`: frees everything but the objects.
    pub fn clear(ws: *Cwksp) void {
        ws.table_end = ws.object_end;
        ws.alloc_start = ws.initialAllocStart();
        ws.alloc_failed = false;
        if (@backingInt(ws.phase) > @backingInt(AllocPhase.aligned_init_once)) {
            ws.phase = .aligned_init_once;
        }
        ws.assertInternalConsistency();
    }

    /// `ZSTD_cwksp_sizeof`.
    pub fn sizeof(ws: *const Cwksp) usize {
        return @intFromPtr(ws.workspace_end) - @intFromPtr(ws.workspace);
    }

    /// `ZSTD_cwksp_used`.
    pub fn used(ws: *const Cwksp) usize {
        return (@intFromPtr(ws.table_end) - @intFromPtr(ws.workspace)) +
            (@intFromPtr(ws.workspace_end) - @intFromPtr(ws.alloc_start));
    }

    /// `ZSTD_cwksp_init`: the workspace takes `buffer`, aligned on pointers,
    /// forgetting any buffer it had (which the caller frees). A static
    /// workspace is never freed by `free`.
    pub fn init(ws: *Cwksp, buffer: []u8, is_static: StaticAlloc) void {
        assert(@intFromPtr(buffer.ptr) & (@sizeOf(*anyopaque) - 1) == 0);
        ws.workspace = buffer.ptr;
        ws.workspace_end = buffer.ptr + buffer.len;
        ws.object_end = ws.workspace;
        ws.table_valid_end = ws.object_end;
        ws.init_once_start = ws.initialAllocStart();
        ws.phase = .objects;
        ws.is_static = is_static;
        ws.clear();
        ws.workspace_oversized_duration = 0;
        ws.assertInternalConsistency();
    }

    /// `ZSTD_cwksp_create`: allocates a workspace of `size` bytes with `gpa`.
    pub fn create(ws: *Cwksp, size: usize, gpa: std.mem.Allocator) Error!void {
        const buffer = gpa.alignedAlloc(u8, .of(*anyopaque), size) catch
            return error.MemoryAllocation;
        ws.init(buffer, .dynamic_alloc);
    }

    /// `ZSTD_cwksp_free`: frees the buffer with `gpa`, which must be the
    /// allocator that created it, and leaves the workspace empty.
    pub fn free(ws: *Cwksp, gpa: std.mem.Allocator) void {
        const ptr = ws.workspace;
        const size = ws.sizeof();
        ws.* = .{};
        if (size != 0) {
            const buffer: []align(@alignOf(*anyopaque)) u8 = @alignCast(ptr[0..size]);
            gpa.free(buffer);
        }
    }

    /// `ZSTD_cwksp_move`: hands the buffer from `src` to `dst`; `src` must be
    /// initialised again before use.
    pub fn move(dst: *Cwksp, src: *Cwksp) void {
        dst.* = src.*;
        src.* = .{};
    }

    /// `ZSTD_cwksp_reserve_failed`: whether a reservation failed since the
    /// last `clear`.
    pub fn reserveFailed(ws: *const Cwksp) bool {
        return ws.alloc_failed;
    }

    /// `ZSTD_cwksp_estimated_space_within_bounds`: whether `estimated_space`
    /// is the space used, give or take the alignment slack.
    pub fn estimatedSpaceWithinBounds(ws: *const Cwksp, estimated_space: usize) bool {
        // Alignment can lose space between the objects and the tables, and
        // between the tables and the buffers.
        return estimated_space - slackSpaceRequired() <= ws.used() and
            ws.used() <= estimated_space;
    }

    /// `ZSTD_cwksp_available_space`.
    pub fn availableSpace(ws: *const Cwksp) usize {
        return @intFromPtr(ws.alloc_start) - @intFromPtr(ws.table_end);
    }

    /// `ZSTD_cwksp_check_available`.
    pub fn checkAvailable(ws: *const Cwksp, additional_needed_space: usize) bool {
        return ws.availableSpace() >= additional_needed_space;
    }

    /// `ZSTD_cwksp_check_too_large`: whether the free space is several times
    /// what is needed.
    pub fn checkTooLarge(ws: *const Cwksp, additional_needed_space: usize) bool {
        return ws.checkAvailable(additional_needed_space * zstd_internal.workspace_too_large_factor);
    }

    /// `ZSTD_cwksp_check_wasteful`: too large for too many calls in a row.
    pub fn checkWasteful(ws: *const Cwksp, additional_needed_space: usize) bool {
        return ws.checkTooLarge(additional_needed_space) and
            ws.workspace_oversized_duration > zstd_internal.workspace_too_large_max_duration;
    }

    /// `ZSTD_cwksp_bump_oversized_duration`.
    pub fn bumpOversizedDuration(ws: *Cwksp, additional_needed_space: usize) void {
        if (ws.checkTooLarge(additional_needed_space)) {
            ws.workspace_oversized_duration += 1;
        } else {
            ws.workspace_oversized_duration = 0;
        }
    }
};

// --------------------------------------------------------
// Tests
// --------------------------------------------------------

const testing = std.testing;

test "phases in order, alignment, and failure" {
    var ws: Cwksp = .{};
    try ws.create(4096 + 37, testing.allocator);
    defer ws.free(testing.allocator);
    try testing.expectEqual(@as(usize, 4096 + 37), ws.sizeof());

    const object = ws.reserveObject(24).?;
    try testing.expectEqual(@intFromPtr(ws.workspace), @intFromPtr(object));
    const table = ws.reserveTable(256).?;
    try testing.expectEqual(@as(usize, 0), @intFromPtr(table) % alignment_bytes);
    try testing.expect(@intFromPtr(table) >= @intFromPtr(object) + 24);
    // Objects are over once a table is reserved.
    try testing.expect(ws.reserveObject(8) == null);
    try testing.expect(ws.reserveFailed());
    ws.clear();
    try testing.expect(!ws.reserveFailed());

    const init_once = ws.reserveAlignedInitOnce(100).?;
    try testing.expectEqual(@as(usize, 0), @intFromPtr(init_once) % alignment_bytes);
    for (init_once[0..128]) |byte| try testing.expectEqual(@as(u8, 0), byte);
    const aligned = ws.reserveAligned64(10).?;
    try testing.expectEqual(@intFromPtr(init_once) - 64, @intFromPtr(aligned));
    const buffer = ws.reserveBuffer(7).?;
    try testing.expectEqual(@intFromPtr(aligned) - 7, @intFromPtr(buffer));
    // An empty reservation gives null, and is not a failure.
    try testing.expect(ws.reserveBuffer(0) == null);
    try testing.expect(!ws.reserveFailed());
    const used_before = ws.used();
    try testing.expect(ws.reserveBuffer(1 << 20) == null);
    try testing.expect(ws.reserveFailed());
    try testing.expectEqual(used_before, ws.used());
    try testing.expectEqual(ws.availableSpace(), @intFromPtr(ws.alloc_start) - @intFromPtr(ws.table_end));
}

test "tables stay clean until buffers overlap them" {
    var memory: [2048]u8 align(64) = undefined;
    @memset(&memory, 0xEE);
    var ws: Cwksp = .{};
    ws.init(&memory, .static_alloc);
    _ = ws.reserveObject(64).?;
    const table = ws.reserveTable(512).?;
    ws.cleanTables();
    for (table[0..512]) |byte| try testing.expectEqual(@as(u8, 0), byte);
    // A second compression: the tables are still clean.
    table[0] = 1;
    ws.clear();
    _ = ws.reserveTable(512).?;
    ws.cleanTables();
    try testing.expectEqual(@as(u8, 1), table[0]);
    // A buffer over part of the table space voids that part; the next clean
    // zeroes it, and only it.
    table[300] = 7;
    ws.clear();
    _ = ws.reserveBuffer(2048 - 64 - 256).?;
    ws.clear();
    _ = ws.reserveTable(512).?;
    ws.cleanTables();
    try testing.expectEqual(@as(u8, 1), table[0]);
    try testing.expectEqual(@as(u8, 0), table[300]);
    ws.markTablesDirty();
    table[1] = 5;
    ws.cleanTables();
    try testing.expectEqual(@as(u8, 0), table[1]);
}

test "oversized duration" {
    var memory: [4096]u8 align(64) = undefined;
    var ws: Cwksp = .{};
    ws.init(&memory, .static_alloc);
    try testing.expect(ws.checkTooLarge(1000));
    try testing.expect(!ws.checkTooLarge(2000));
    for (0..zstd_internal.workspace_too_large_max_duration + 1) |_| ws.bumpOversizedDuration(1000);
    try testing.expect(ws.checkWasteful(1000));
    ws.bumpOversizedDuration(2000);
    try testing.expect(!ws.checkWasteful(1000));
    try testing.expectEqual(@as(usize, 128), slackSpaceRequired());
    try testing.expectEqual(@as(usize, 128), aligned64AllocSize(65));
}
