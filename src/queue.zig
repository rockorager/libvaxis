const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const atomic = std.atomic;

// Zig 0.16 removed std.Thread.Mutex / std.Thread.Condition; the
// std.Io.* replacements demand an Io on every lock/wait, which
// would force every Queue caller in the vaxis tree to plumb Io.
// Use libc pthread primitives instead — same wake semantics, no
// Io dependency in the type.
//
// POSIX-only for now. Windows support needs CRITICAL_SECTION +
// CONDITION_VARIABLE; the hook is straightforward but not wired up
// in this fork. Fail loudly at compile time instead of link time so
// the constraint is obvious.
comptime {
    if (builtin.os.tag == .windows) {
        @compileError(
            "vaxis queue.zig: Windows support dropped during the Zig 0.16 " ++
                "port. Restore SRWLOCK / CONDITION_VARIABLE shims before " ++
                "building for Windows.",
        );
    }
}

/// Thread safe. Fixed size. Blocking push and pop.
pub fn Queue(
    comptime T: type,
    comptime size: usize,
) type {
    return struct {
        buf: [size]T = undefined,

        read_index: usize = 0,
        write_index: usize = 0,

        mutex: std.c.pthread_mutex_t = .{},
        not_full: std.c.pthread_cond_t = .{},
        not_empty: std.c.pthread_cond_t = .{},

        const Self = @This();

        fn mLock(self: *Self) void {
            _ = std.c.pthread_mutex_lock(&self.mutex);
        }
        fn mUnlock(self: *Self) void {
            _ = std.c.pthread_mutex_unlock(&self.mutex);
        }
        fn condWait(self: *Self, cond: *std.c.pthread_cond_t) void {
            _ = std.c.pthread_cond_wait(cond, &self.mutex);
        }
        fn condSignal(cond: *std.c.pthread_cond_t) void {
            _ = std.c.pthread_cond_signal(cond);
        }

        /// Pop an item from the queue. Blocks until an item is available.
        pub fn pop(self: *Self) T {
            self.mLock();
            defer self.mUnlock();
            while (self.isEmptyLH()) self.condWait(&self.not_empty);
            std.debug.assert(!self.isEmptyLH());
            return self.popAndSignalLH();
        }

        /// Push an item into the queue. Blocks until an item has been
        /// put in the queue.
        pub fn push(self: *Self, item: T) void {
            self.mLock();
            defer self.mUnlock();
            while (self.isFullLH()) self.condWait(&self.not_full);
            std.debug.assert(!self.isFullLH());
            self.pushAndSignalLH(item);
        }

        /// Push an item into the queue. Returns true when the item
        /// was successfully placed in the queue, false if the queue
        /// was full.
        pub fn tryPush(self: *Self, item: T) bool {
            self.mLock();
            defer self.mUnlock();
            if (self.isFullLH()) return false;
            self.pushAndSignalLH(item);
            return true;
        }

        /// Pop an item from the queue. Returns null when no item is
        /// available.
        pub fn tryPop(self: *Self) ?T {
            self.mLock();
            defer self.mUnlock();
            if (self.isEmptyLH()) return null;
            return self.popAndSignalLH();
        }

        /// Poll the queue. This call blocks until events are in the queue
        pub fn poll(self: *Self) void {
            self.mLock();
            defer self.mUnlock();
            while (self.isEmptyLH()) self.condWait(&self.not_empty);
            std.debug.assert(!self.isEmptyLH());
        }

        pub fn lock(self: *Self) void {
            self.mLock();
        }

        pub fn unlock(self: *Self) void {
            self.mUnlock();
        }

        /// Used to efficiently drain the queue while the lock is externally held
        pub fn drain(self: *Self) ?T {
            if (self.isEmptyLH()) return null;
            const was_full = self.isFullLH();
            const item = self.popLH();
            if (was_full) condSignal(&self.not_full);
            return item;
        }

        fn isEmptyLH(self: Self) bool {
            return self.write_index == self.read_index;
        }

        fn isFullLH(self: Self) bool {
            return self.mask2(self.write_index + self.buf.len) ==
                self.read_index;
        }

        /// Returns `true` if the queue is empty and `false` otherwise.
        pub fn isEmpty(self: *Self) bool {
            self.mLock();
            defer self.mUnlock();
            return self.isEmptyLH();
        }

        /// Returns `true` if the queue is full and `false` otherwise.
        pub fn isFull(self: *Self) bool {
            self.mLock();
            defer self.mUnlock();
            return self.isFullLH();
        }

        /// Returns the length
        fn len(self: Self) usize {
            const wrap_offset = 2 * self.buf.len *
                @intFromBool(self.write_index < self.read_index);
            const adjusted_write_index = self.write_index + wrap_offset;
            return adjusted_write_index - self.read_index;
        }

        /// Returns `index` modulo the length of the backing slice.
        fn mask(self: Self, index: usize) usize {
            return index % self.buf.len;
        }

        /// Returns `index` modulo twice the length of the backing slice.
        fn mask2(self: Self, index: usize) usize {
            return index % (2 * self.buf.len);
        }

        fn pushAndSignalLH(self: *Self, item: T) void {
            const was_empty = self.isEmptyLH();
            self.buf[self.mask(self.write_index)] = item;
            self.write_index = self.mask2(self.write_index + 1);
            if (was_empty) condSignal(&self.not_empty);
        }

        fn popAndSignalLH(self: *Self) T {
            const was_full = self.isFullLH();
            const result = self.popLH();
            if (was_full) condSignal(&self.not_full);
            return result;
        }

        fn popLH(self: *Self) T {
            const result = self.buf[self.mask(self.read_index)];
            self.read_index = self.mask2(self.read_index + 1);
            return result;
        }
    };
}

const testing = std.testing;
const cfg = Thread.SpawnConfig{ .allocator = testing.allocator };
test "Queue: simple push / pop" {
    var queue: Queue(u8, 16) = .{};
    queue.push(1);
    queue.push(2);
    const pop = queue.pop();
    try testing.expectEqual(1, pop);
    try testing.expectEqual(2, queue.pop());
}

const Thread = std.Thread;
fn testPushPop(q: *Queue(u8, 2)) !void {
    q.push(3);
    try testing.expectEqual(2, q.pop());
}

test "Fill, wait to push, pop once in another thread" {
    var queue: Queue(u8, 2) = .{};
    queue.push(1);
    queue.push(2);
    const t = try Thread.spawn(cfg, testPushPop, .{&queue});
    try testing.expectEqual(false, queue.tryPush(3));
    try testing.expectEqual(1, queue.pop());
    t.join();
    try testing.expectEqual(3, queue.pop());
    try testing.expectEqual(null, queue.tryPop());
}

fn testPush(q: *Queue(u8, 2)) void {
    q.push(0);
    q.push(1);
    q.push(2);
    q.push(3);
    q.push(4);
}

test "Try to pop, fill from another thread" {
    var queue: Queue(u8, 2) = .{};
    const thread = try Thread.spawn(cfg, testPush, .{&queue});
    for (0..5) |idx| {
        try testing.expectEqual(@as(u8, @intCast(idx)), queue.pop());
    }
    thread.join();
}

fn sleepyPop(q: *Queue(u8, 2), state: *atomic.Value(u8)) !void {
    // First we wait for the queue to be full.
    while (state.load(.acquire) < 1)
        try Thread.yield();

    // Then we spuriously wake it up, because that's a thing that can
    // happen.
    q.not_full.signal();
    q.not_empty.signal();

    // Then give the other thread a good chance of waking up. It's not
    // clear that yield guarantees the other thread will be scheduled,
    // so we'll throw a sleep in here just to be sure. The queue is
    // still full and the push in the other thread is still blocked
    // waiting for space.
    try Thread.yield();
    std.Thread.sleep(10 * std.time.ns_per_ms);
    // Finally, let that other thread go.
    try std.testing.expectEqual(1, q.pop());

    // Wait for the other thread to signal it's ready for second push
    while (state.load(.acquire) < 2)
        try Thread.yield();
    // But we want to ensure that there's a second push waiting, so
    // here's another sleep.
    std.Thread.sleep(10 * std.time.ns_per_ms);

    // Another spurious wake...
    q.not_full.signal();
    q.not_empty.signal();
    // And another chance for the other thread to see that it's
    // spurious and go back to sleep.
    try Thread.yield();
    std.Thread.sleep(10 * std.time.ns_per_ms);

    // Pop that thing and we're done.
    try std.testing.expectEqual(2, q.pop());
}

test "Fill, block, fill, block" {
    // Fill the queue, block while trying to write another item, have
    // a background thread unblock us, then block while trying to
    // write yet another thing. Have the background thread unblock
    // that too (after some time) then drain the queue. This test
    // fails if the while loop in `push` is turned into an `if`.

    var queue: Queue(u8, 2) = .{};
    var state = atomic.Value(u8).init(0);
    const thread = try Thread.spawn(cfg, sleepyPop, .{ &queue, &state });
    queue.push(1);
    queue.push(2);
    state.store(1, .release);
    const now = std.time.milliTimestamp();
    queue.push(3); // This one should block.
    const then = std.time.milliTimestamp();

    // Just to make sure the sleeps are yielding to this thread, make
    // sure it took at least 5ms to do the push.
    try std.testing.expect(then - now > 5);

    state.store(2, .release);
    // This should block again, waiting for the other thread.
    queue.push(4);

    // And once that push has gone through, the other thread's done.
    thread.join();
    try std.testing.expectEqual(3, queue.pop());
    try std.testing.expectEqual(4, queue.pop());
}

fn sleepyPush(q: *Queue(u8, 1), state: *atomic.Value(u8)) !void {
    // Try to ensure the other thread has already started trying to pop.
    try Thread.yield();
    std.Thread.sleep(10 * std.time.ns_per_ms);

    // Spurious wake
    q.not_full.signal();
    q.not_empty.signal();

    try Thread.yield();
    std.Thread.sleep(10 * std.time.ns_per_ms);

    // Stick something in the queue so it can be popped.
    q.push(1);
    // Ensure it's been popped.
    while (state.load(.acquire) < 1)
        try Thread.yield();
    // Give the other thread time to block again.
    try Thread.yield();
    std.Thread.sleep(10 * std.time.ns_per_ms);

    // Spurious wake
    q.not_full.signal();
    q.not_empty.signal();

    q.push(2);
}

test "Drain, block, drain, block" {
    // This is like fill/block/fill/block, but on the pop end. This
    // test should fail if the `while` loop in `pop` is turned into an
    // `if`.

    var queue: Queue(u8, 1) = .{};
    var state = atomic.Value(u8).init(0);
    const thread = try Thread.spawn(cfg, sleepyPush, .{ &queue, &state });
    try std.testing.expectEqual(1, queue.pop());
    state.store(1, .release);
    try std.testing.expectEqual(2, queue.pop());
    thread.join();
}

fn readerThread(q: *Queue(u8, 1)) !void {
    try testing.expectEqual(1, q.pop());
}

test "2 readers" {
    // 2 threads read, one thread writes
    var queue: Queue(u8, 1) = .{};
    const t1 = try Thread.spawn(cfg, readerThread, .{&queue});
    const t2 = try Thread.spawn(cfg, readerThread, .{&queue});
    try Thread.yield();
    std.Thread.sleep(10 * std.time.ns_per_ms);
    queue.push(1);
    queue.push(1);
    t1.join();
    t2.join();
}

fn writerThread(q: *Queue(u8, 1)) !void {
    q.push(1);
}

test "2 writers" {
    var queue: Queue(u8, 1) = .{};
    const t1 = try Thread.spawn(cfg, writerThread, .{&queue});
    const t2 = try Thread.spawn(cfg, writerThread, .{&queue});

    try testing.expectEqual(1, queue.pop());
    try testing.expectEqual(1, queue.pop());
    t1.join();
    t2.join();
}
