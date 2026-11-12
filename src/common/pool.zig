//! The thread pool, from the original's pool.c and the parts of threading.c
//! it uses: a set of threads that take jobs from a bounded queue, in the
//! order they were added. Its threads are `std.Thread`s; its locks are
//! `std.Io`'s, so the pool keeps the `Io` its creator passes in.
//!
//! Without `build_options.multithread`, as the original without
//! `ZSTD_MULTITHREAD`, there are no threads: `create` returns one shared,
//! empty pool and `add` runs each job in the caller's thread.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");

const Io = std.Io;
const assert = std.debug.assert;

/// `POOL_function`: a job, run with the context it was added with.
pub const Function = *const fn (context: ?*anyopaque) void;

/// `POOL_job`.
const Job = struct {
    function: Function,
    context: ?*anyopaque,
};

/// The original's `POOL_ctx`, which its public API calls `ZSTD_threadPool`.
pub const ThreadPool = if (build_options.multithread) ThreadedPool else InlinePool;

/// `ZSTD_createThreadPool`: a pool of `num_threads` threads with no queue
/// beyond them, for contexts to share (`CCtx.refThreadPool`). Null when
/// `num_threads` is 0 or the threads or memory could not be had.
pub fn createThreadPool(gpa: std.mem.Allocator, io: Io, num_threads: usize) ?*ThreadPool {
    return ThreadPool.create(gpa, io, num_threads, 0);
}

/// `ZSTD_freeThreadPool`: stops the threads once the queued jobs are done,
/// then frees the pool. Every context that refers to it must be done with it.
pub fn freeThreadPool(pool: ?*ThreadPool) void {
    if (pool) |p| p.free();
}

const ThreadedPool = struct {
    gpa: std.mem.Allocator,
    io: Io,
    /// The thread handles: `threads[0..thread_capacity]` are running.
    threads: []std.Thread,
    thread_capacity: usize,
    /// The number of threads that may run jobs at once, at most
    /// `thread_capacity`; the others wait.
    thread_limit: usize,

    /// The queue, a ring buffer with one slot more than the queue size, so
    /// that full and empty differ.
    queue: []Job,
    queue_head: usize,
    queue_tail: usize,
    /// The number of threads running a job.
    num_threads_busy: usize,
    queue_empty: bool,

    /// Guards every field above but `gpa`, `io` and the queue's length.
    queue_mutex: Io.Mutex,
    /// Signaled when a job leaves the queue or ends: pushers wait on it for
    /// room, and `joinJobs` for the end.
    queue_push_cond: Io.Condition,
    /// Signaled when a job enters the queue or the limit changes.
    queue_pop_cond: Io.Condition,
    shutdown: bool,

    /// `POOL_create_advanced`: a pool of `num_threads` threads and a queue
    /// of `queue_size` jobs waiting. With a queue size of 0, `add` waits
    /// for a free thread. Null when `num_threads` is 0 or the threads or
    /// memory could not be had.
    pub fn create(
        gpa: std.mem.Allocator,
        io: Io,
        num_threads: usize,
        queue_size: usize,
    ) ?*ThreadedPool {
        if (num_threads == 0) return null;
        const ctx = gpa.create(ThreadedPool) catch return null;
        ctx.* = .{
            .gpa = gpa,
            .io = io,
            .threads = &.{},
            .thread_capacity = 0,
            .thread_limit = 0,
            .queue = &.{},
            .queue_head = 0,
            .queue_tail = 0,
            .num_threads_busy = 0,
            .queue_empty = true,
            .queue_mutex = .init,
            .queue_push_cond = .init,
            .queue_pop_cond = .init,
            .shutdown = false,
        };
        ctx.queue = gpa.alloc(Job, queue_size + 1) catch {
            ctx.free();
            return null;
        };
        ctx.threads = gpa.alloc(std.Thread, num_threads) catch {
            ctx.free();
            return null;
        };
        for (ctx.threads, 0..) |*thread, i| {
            thread.* = std.Thread.spawn(.{}, poolThread, .{ctx}) catch {
                ctx.free();
                return null;
            };
            // Counted at once, so that a failure later joins it.
            ctx.thread_capacity = i + 1;
        }
        ctx.queue_mutex.lockUncancelable(io);
        ctx.thread_limit = num_threads;
        ctx.queue_mutex.unlock(io);
        return ctx;
    }

    /// `POOL_thread`: waits for jobs and runs them, until the pool shuts
    /// down.
    fn poolThread(ctx: *ThreadedPool) void {
        const io = ctx.io;
        while (true) {
            ctx.queue_mutex.lockUncancelable(io);
            while (ctx.queue_empty or ctx.num_threads_busy >= ctx.thread_limit) {
                if (ctx.shutdown) {
                    // A queue left with jobs above the thread limit still
                    // has enough threads running to finish it.
                    ctx.queue_mutex.unlock(io);
                    return;
                }
                ctx.queue_pop_cond.waitUncancelable(io, &ctx.queue_mutex);
            }
            const job = ctx.queue[ctx.queue_head];
            ctx.queue_head = (ctx.queue_head + 1) % ctx.queue.len;
            ctx.num_threads_busy += 1;
            ctx.queue_empty = ctx.queue_head == ctx.queue_tail;
            ctx.queue_push_cond.signal(io);
            ctx.queue_mutex.unlock(io);

            job.function(job.context);

            // With a queue size of 0, a pusher waits for this.
            ctx.queue_mutex.lockUncancelable(io);
            ctx.num_threads_busy -= 1;
            ctx.queue_push_cond.signal(io);
            ctx.queue_mutex.unlock(io);
        }
    }

    /// `POOL_join`: shuts the queue down, wakes the threads and joins them.
    /// The jobs still queued run first.
    fn join(ctx: *ThreadedPool) void {
        const io = ctx.io;
        ctx.queue_mutex.lockUncancelable(io);
        ctx.shutdown = true;
        ctx.queue_mutex.unlock(io);
        ctx.queue_push_cond.broadcast(io);
        ctx.queue_pop_cond.broadcast(io);
        for (ctx.threads[0..ctx.thread_capacity]) |thread| thread.join();
    }

    /// `POOL_free`: runs the jobs still queued, stops the threads and frees
    /// the pool.
    pub fn free(ctx: *ThreadedPool) void {
        ctx.join();
        const gpa = ctx.gpa;
        gpa.free(ctx.queue);
        gpa.free(ctx.threads);
        gpa.destroy(ctx);
    }

    /// `POOL_joinJobs`: waits until every job queued so far has ended.
    pub fn joinJobs(ctx: *ThreadedPool) void {
        const io = ctx.io;
        ctx.queue_mutex.lockUncancelable(io);
        while (!ctx.queue_empty or ctx.num_threads_busy > 0) {
            ctx.queue_push_cond.waitUncancelable(io, &ctx.queue_mutex);
        }
        ctx.queue_mutex.unlock(io);
    }

    /// `POOL_sizeof`: the memory the original's pool of this shape takes.
    pub fn sizeof(ctx: ?*const ThreadedPool) usize {
        const p = ctx orelse return 0;
        return @sizeOf(c_layout.PoolCtx) +
            p.queue.len * @sizeOf(c_layout.Job) +
            p.thread_capacity * @sizeOf(c_layout.Thread);
    }

    /// `POOL_resize_internal`; the caller holds the mutex.
    fn resizeInternal(ctx: *ThreadedPool, num_threads: usize) error{ThreadPoolResize}!void {
        if (num_threads <= ctx.thread_capacity) {
            if (num_threads == 0) return error.ThreadPoolResize;
            ctx.thread_limit = num_threads;
            return;
        }
        const threads = ctx.gpa.alloc(std.Thread, num_threads) catch return error.ThreadPoolResize;
        @memcpy(threads[0..ctx.thread_capacity], ctx.threads[0..ctx.thread_capacity]);
        ctx.gpa.free(ctx.threads);
        ctx.threads = threads;
        for (threads[ctx.thread_capacity..], ctx.thread_capacity..) |*thread, i| {
            thread.* = std.Thread.spawn(.{}, poolThread, .{ctx}) catch {
                ctx.thread_capacity = i;
                return error.ThreadPoolResize;
            };
        }
        ctx.thread_capacity = num_threads;
        ctx.thread_limit = num_threads;
    }

    /// `POOL_resize`: changes the number of threads that run jobs; extra
    /// threads are kept, idle. Jobs running or queued are unaffected. Fails
    /// for 0 threads, or when more threads or memory could not be had.
    pub fn resize(ctx: *ThreadedPool, num_threads: usize) error{ThreadPoolResize}!void {
        const io = ctx.io;
        ctx.queue_mutex.lockUncancelable(io);
        defer ctx.queue_mutex.unlock(io);
        defer ctx.queue_pop_cond.broadcast(io);
        return ctx.resizeInternal(num_threads);
    }

    /// `isQueueFull`. With a queue size of 0, the queue is full while every
    /// thread is busy or a job waits.
    fn isQueueFull(ctx: *const ThreadedPool) bool {
        if (ctx.queue.len > 1) {
            return ctx.queue_head == (ctx.queue_tail + 1) % ctx.queue.len;
        }
        return ctx.num_threads_busy == ctx.thread_limit or !ctx.queue_empty;
    }

    /// `POOL_add_internal`; the caller holds the mutex.
    fn addInternal(ctx: *ThreadedPool, function: Function, context: ?*anyopaque) void {
        if (ctx.shutdown) return;
        ctx.queue_empty = false;
        ctx.queue[ctx.queue_tail] = .{ .function = function, .context = context };
        ctx.queue_tail = (ctx.queue_tail + 1) % ctx.queue.len;
        ctx.queue_pop_cond.signal(ctx.io);
    }

    /// `POOL_add`: queues a job, waiting for room. `context` must stay valid
    /// until the job has run.
    pub fn add(ctx: *ThreadedPool, function: Function, context: ?*anyopaque) void {
        const io = ctx.io;
        ctx.queue_mutex.lockUncancelable(io);
        while (ctx.isQueueFull() and !ctx.shutdown) {
            ctx.queue_push_cond.waitUncancelable(io, &ctx.queue_mutex);
        }
        ctx.addInternal(function, context);
        ctx.queue_mutex.unlock(io);
    }

    /// `POOL_tryAdd`: queues a job if there is room, and says whether it did.
    /// `context` must stay valid until the job has run.
    pub fn tryAdd(ctx: *ThreadedPool, function: Function, context: ?*anyopaque) bool {
        const io = ctx.io;
        ctx.queue_mutex.lockUncancelable(io);
        defer ctx.queue_mutex.unlock(io);
        if (ctx.isQueueFull()) return false;
        ctx.addInternal(function, context);
        return true;
    }
};

/// The pool without threads: every job runs in the caller's thread.
const InlinePool = struct {
    /// The original's `g_poolCtx`: one pool for every caller, which has
    /// nothing to free.
    var shared: InlinePool = .{};

    /// `POOL_create_advanced`: the shared pool, whatever the arguments.
    pub fn create(gpa: std.mem.Allocator, io: Io, num_threads: usize, queue_size: usize) ?*InlinePool {
        _ = gpa;
        _ = io;
        _ = num_threads;
        _ = queue_size;
        return &shared;
    }

    pub fn free(ctx: *InlinePool) void {
        assert(ctx == &shared);
    }

    pub fn joinJobs(ctx: *InlinePool) void {
        assert(ctx == &shared);
    }

    /// The original's `sizeof(POOL_ctx)`, an int, for the shared pool.
    pub fn sizeof(ctx: ?*const InlinePool) usize {
        const p = ctx orelse return 0;
        assert(p == &shared);
        return @sizeOf(c_int);
    }

    pub fn resize(ctx: *InlinePool, num_threads: usize) error{ThreadPoolResize}!void {
        _ = ctx;
        _ = num_threads;
    }

    pub fn add(ctx: *InlinePool, function: Function, context: ?*anyopaque) void {
        _ = ctx;
        function(context);
    }

    pub fn tryAdd(ctx: *InlinePool, function: Function, context: ?*anyopaque) bool {
        _ = ctx;
        function(context);
        return true;
    }
};

/// The original's threading structures as a C compiler lays them out for
/// the target, for the sizes `sizeof` reports: pthreads' on POSIX systems,
/// and on Windows the critical sections and condition variables its
/// threading.h maps them to.
pub const c_layout = struct {
    const Ptr = ?*anyopaque;
    const windows = builtin.os.tag == .windows;

    /// `ZSTD_pthread_mutex_t`.
    pub const Mutex = if (windows)
        extern struct { data: [if (@sizeOf(usize) == 8) 40 else 24]u8 align(@alignOf(usize)) }
    else if (std.c.pthread_mutex_t == void)
        extern struct { data: [40]u8 align(@alignOf(usize)) }
    else
        std.c.pthread_mutex_t;

    /// `ZSTD_pthread_cond_t`.
    pub const Cond = if (windows)
        extern struct { ptr: Ptr }
    else if (std.c.pthread_cond_t == void)
        extern struct { data: [48]u8 align(@alignOf(usize)) }
    else
        std.c.pthread_cond_t;

    /// `ZSTD_pthread_t`: a thread id or handle, the size of a pointer.
    pub const Thread = Ptr;

    pub const CustomMem = extern struct { alloc: Ptr, free: Ptr, opaque_ptr: Ptr };

    pub const Job = extern struct { function: Ptr, opaque_ptr: Ptr };

    pub const PoolCtx = extern struct {
        custom_mem: CustomMem,
        threads: Ptr,
        thread_capacity: usize,
        thread_limit: usize,
        queue: Ptr,
        queue_head: usize,
        queue_tail: usize,
        queue_size: usize,
        num_threads_busy: usize,
        queue_empty: c_int,
        queue_mutex: Mutex,
        queue_push_cond: Cond,
        queue_pop_cond: Cond,
        shutdown: c_int,
    };
};

// --------------------------------------------------------
// Tests
// --------------------------------------------------------

const testing = std.testing;

/// A job that waits until the test releases it, counting how many run at
/// once.
const Gate = struct {
    mutex: Io.Mutex = .init,
    cond: Io.Condition = .init,
    open: bool = false,
    running: usize = 0,
    max_running: usize = 0,
    started: usize = 0,
    done: usize = 0,

    fn job(context: ?*anyopaque) void {
        const gate: *Gate = @ptrCast(@alignCast(context.?));
        const io = testing.io;
        gate.mutex.lockUncancelable(io);
        defer gate.mutex.unlock(io);
        gate.started += 1;
        gate.running += 1;
        gate.max_running = @max(gate.max_running, gate.running);
        gate.cond.broadcast(io);
        while (!gate.open) gate.cond.waitUncancelable(io, &gate.mutex);
        gate.running -= 1;
        gate.done += 1;
        gate.cond.broadcast(io);
    }

    fn waitStarted(gate: *Gate, n: usize) void {
        const io = testing.io;
        gate.mutex.lockUncancelable(io);
        defer gate.mutex.unlock(io);
        while (gate.started < n) gate.cond.waitUncancelable(io, &gate.mutex);
    }

    fn release(gate: *Gate) void {
        const io = testing.io;
        gate.mutex.lockUncancelable(io);
        defer gate.mutex.unlock(io);
        gate.open = true;
        gate.cond.broadcast(io);
    }
};

fn countJob(context: ?*anyopaque) void {
    const counter: *std.atomic.Value(usize) = @ptrCast(@alignCast(context.?));
    _ = counter.fetchAdd(1, .monotonic);
}

test "a pool needs a thread" {
    try testing.expect(ThreadPool.create(testing.allocator, testing.io, 0, 4) == null or
        !build_options.multithread);
}

test "every job added runs, and joinJobs waits for them" {
    var counter: std.atomic.Value(usize) = .init(0);
    for ([_]usize{ 0, 1, 7 }) |queue_size| {
        counter.store(0, .monotonic);
        const pool = ThreadPool.create(testing.allocator, testing.io, 4, queue_size).?;
        defer pool.free();
        for (0..200) |_| pool.add(countJob, &counter);
        pool.joinJobs();
        try testing.expectEqual(@as(usize, 200), counter.load(.monotonic));
    }
}

test "free runs the jobs still queued" {
    var counter: std.atomic.Value(usize) = .init(0);
    const pool = ThreadPool.create(testing.allocator, testing.io, 2, 16).?;
    for (0..16) |_| pool.add(countJob, &counter);
    pool.free();
    try testing.expectEqual(@as(usize, 16), counter.load(.monotonic));
}

test "tryAdd refuses a job when the queue is full" {
    if (!build_options.multithread) return error.SkipZigTest;
    // No queue: full while the one thread is busy.
    {
        var gate: Gate = .{};
        const pool = ThreadPool.create(testing.allocator, testing.io, 1, 0).?;
        defer pool.free();
        try testing.expect(pool.tryAdd(Gate.job, &gate));
        gate.waitStarted(1);
        try testing.expect(!pool.tryAdd(Gate.job, &gate));
        gate.release();
        pool.joinJobs();
        try testing.expect(pool.tryAdd(Gate.job, &gate));
        pool.joinJobs();
        try testing.expectEqual(@as(usize, 2), gate.done);
    }
    // A queue of 2: full with the thread busy and two jobs waiting.
    {
        var gate: Gate = .{};
        const pool = ThreadPool.create(testing.allocator, testing.io, 1, 2).?;
        defer pool.free();
        try testing.expect(pool.tryAdd(Gate.job, &gate));
        gate.waitStarted(1);
        try testing.expect(pool.tryAdd(Gate.job, &gate));
        try testing.expect(pool.tryAdd(Gate.job, &gate));
        try testing.expect(!pool.tryAdd(Gate.job, &gate));
        gate.release();
        pool.joinJobs();
        try testing.expectEqual(@as(usize, 3), gate.done);
        try testing.expectEqual(@as(usize, 1), gate.max_running);
    }
}

test "resize while busy: more threads start, a lower limit holds back" {
    if (!build_options.multithread) return error.SkipZigTest;
    const pool = ThreadPool.create(testing.allocator, testing.io, 2, 8).?;
    defer pool.free();
    const base = @sizeOf(c_layout.PoolCtx) + 9 * @sizeOf(c_layout.Job);
    try testing.expectEqual(base + 2 * @sizeOf(c_layout.Thread), pool.sizeof());

    var gate: Gate = .{};
    pool.add(Gate.job, &gate);
    pool.add(Gate.job, &gate);
    gate.waitStarted(2);
    try pool.resize(4);
    try testing.expectEqual(base + 4 * @sizeOf(c_layout.Thread), pool.sizeof());
    pool.add(Gate.job, &gate);
    pool.add(Gate.job, &gate);
    gate.waitStarted(4);
    try testing.expectEqual(@as(usize, 4), gate.max_running);
    gate.release();
    pool.joinJobs();
    try testing.expectEqual(@as(usize, 4), gate.done);

    // Down to one: the threads are kept, but only one runs jobs.
    var narrow: Gate = .{};
    try pool.resize(1);
    try testing.expectEqual(base + 4 * @sizeOf(c_layout.Thread), pool.sizeof());
    for (0..5) |_| pool.add(Gate.job, &narrow);
    narrow.waitStarted(1);
    narrow.release();
    pool.joinJobs();
    try testing.expectEqual(@as(usize, 5), narrow.done);
    try testing.expectEqual(@as(usize, 1), narrow.max_running);

    try testing.expectError(error.ThreadPoolResize, pool.resize(0));
}

test "the shared pool of contexts" {
    const pool = createThreadPool(testing.allocator, testing.io, 3).?;
    defer freeThreadPool(pool);
    var counter: std.atomic.Value(usize) = .init(0);
    for (0..10) |_| pool.add(countJob, &counter);
    pool.joinJobs();
    try testing.expectEqual(@as(usize, 10), counter.load(.monotonic));
    freeThreadPool(null);
}
