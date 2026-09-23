const std = @import("std");
const assert = std.debug.assert;
const atomic = std.atomic;

/// Thread safe. Fixed size. Blocking push and pop.
pub fn Queue(
    comptime T: type,
    comptime size: usize,
) type {
    return struct {
        buf: [size]T = undefined,

        read_index: usize = 0,
        write_index: usize = 0,
        closed: ?anyerror = null,

        io: std.Io,
        mutex: std.Io.Mutex = .init,
        // blocks when the buffer is full
        not_full: std.Io.Condition = .init,
        // ...or empty
        not_empty: std.Io.Condition = .init,

        const Self = @This();

        pub fn init(io: std.Io) Self {
            return .{ .io = io };
        }

        /// Reject further writes and wake all waiters. Buffered items remain readable;
        /// once drained, readers receive the first close reason.
        pub fn close(self: *Self, reason: anyerror) void {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            if (self.closed != null) return;
            self.closed = reason;
            self.not_full.broadcast(self.io);
            self.not_empty.broadcast(self.io);
        }

        /// Reopen after the previous producer has stopped. Retains buffered items.
        pub fn reopen(self: *Self) void {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            self.closed = null;
        }

        /// Pop an item from the queue. Blocks until an item is available.
        pub fn pop(self: *Self) !T {
            try self.mutex.lock(self.io);
            defer self.mutex.unlock(self.io);
            while (self.isEmptyLH()) {
                if (self.closed) |err| return err;
                try self.not_empty.wait(self.io, &self.mutex);
            }
            std.debug.assert(!self.isEmptyLH());
            return self.popAndSignalLH();
        }

        /// Push an item into the queue. Blocks until an item has been
        /// put in the queue.
        pub fn push(self: *Self, item: T) !void {
            try self.mutex.lock(self.io);
            defer self.mutex.unlock(self.io);
            while (self.isFullLH()) {
                if (self.closed) |err| return err;
                try self.not_full.wait(self.io, &self.mutex);
            }
            if (self.closed) |err| return err;
            std.debug.assert(!self.isFullLH());
            self.pushAndSignalLH(item);
        }

        /// Push an item into the queue. Returns true when the item
        /// was successfully placed in the queue, false if the queue
        /// was full.
        pub fn tryPush(self: *Self, item: T) !bool {
            try self.mutex.lock(self.io);
            defer self.mutex.unlock(self.io);
            if (self.closed) |err| return err;
            if (self.isFullLH()) return false;
            self.pushAndSignalLH(item);
            return true;
        }

        /// Pop an item from the queue. Returns null when no item is
        /// available.
        pub fn tryPop(self: *Self) !?T {
            try self.mutex.lock(self.io);
            defer self.mutex.unlock(self.io);
            if (self.isEmptyLH()) return if (self.closed) |err| err else null;
            return self.popAndSignalLH();
        }

        /// Poll the queue. This call blocks until events are in the queue
        pub fn poll(self: *Self) !void {
            try self.mutex.lock(self.io);
            defer self.mutex.unlock(self.io);
            while (self.isEmptyLH()) {
                if (self.closed) |err| return err;
                try self.not_empty.wait(self.io, &self.mutex);
            }
            std.debug.assert(!self.isEmptyLH());
        }

        pub fn lock(self: *Self) !void {
            try self.mutex.lock(self.io);
        }

        pub fn unlock(self: *Self) void {
            self.mutex.unlock(self.io);
        }

        /// Used to efficiently drain the queue while the lock is externally held
        pub fn drain(self: *Self) ?T {
            if (self.isEmptyLH()) return null;
            // Preserve queue push wakeups when draining under external lock.
            // If the queue was full before this pop, a producer may be blocked
            // waiting on not_full.
            const was_full = self.isFullLH();
            const item = self.popLH();
            if (was_full) {
                self.not_full.signal(self.io);
            }
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
        pub fn isEmpty(self: *Self) !bool {
            try self.mutex.lock(self.io);
            defer self.mutex.unlock(self.io);
            return self.isEmptyLH();
        }

        /// Returns `true` if the queue is full and `false` otherwise.
        pub fn isFull(self: *Self) !bool {
            try self.mutex.lock(self.io);
            defer self.mutex.unlock(self.io);
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
            if (was_empty) {
                self.not_empty.signal(self.io);
            }
        }

        fn popAndSignalLH(self: *Self) T {
            const was_full = self.isFullLH();
            const result = self.popLH();
            if (was_full) {
                self.not_full.signal(self.io);
            }
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
    const io = std.testing.io;
    var queue: Queue(u8, 16) = .init(io);
    try queue.push(1);
    try queue.push(2);
    const pop = try queue.pop();
    try testing.expectEqual(1, pop);
    try testing.expectEqual(2, try queue.pop());
}

const Thread = std.Thread;
fn testPushPop(q: *Queue(u8, 2)) !void {
    try q.push(3);
    try testing.expectEqual(2, try q.pop());
}

test "Fill, wait to push, pop once in another thread" {
    const io = std.testing.io;
    var queue: Queue(u8, 2) = .init(io);
    try queue.push(1);
    try queue.push(2);
    var t = try io.concurrent(testPushPop, .{&queue});
    try testing.expectEqual(false, try queue.tryPush(3));
    try testing.expectEqual(1, try queue.pop());
    try t.await(io);
    try testing.expectEqual(3, try queue.pop());
    try testing.expectEqual(null, try queue.tryPop());
}

fn testPush(q: *Queue(u8, 2)) !void {
    try q.push(0);
    try q.push(1);
    try q.push(2);
    try q.push(3);
    try q.push(4);
}

test "Try to pop, fill from another thread" {
    const io = std.testing.io;
    var queue: Queue(u8, 2) = .init(io);
    var task = try io.concurrent(testPush, .{&queue});
    defer task.cancel(io) catch {};
    for (0..5) |idx| {
        try testing.expectEqual(@as(u8, @intCast(idx)), try queue.pop());
    }
    try task.await(io);
}

fn sleepyPop(io: std.Io, q: *Queue(u8, 2), state: *atomic.Value(u8)) !void {
    // First we wait for the queue to be full.
    while (state.load(.acquire) < 1)
        try Thread.yield();

    // Then we spuriously wake it up, because that's a thing that can
    // happen.
    q.not_full.signal(io);
    q.not_empty.signal(io);

    // Then give the other thread a good chance of waking up. It's not
    // clear that yield guarantees the other thread will be scheduled,
    // so we'll throw a sleep in here just to be sure. The queue is
    // still full and the push in the other thread is still blocked
    // waiting for space.
    try Thread.yield();
    try io.sleep(.fromMilliseconds(10), .real);
    // Finally, let that other thread go.
    try std.testing.expectEqual(1, q.pop());

    // Wait for the other thread to signal it's ready for second push
    while (state.load(.acquire) < 2)
        try Thread.yield();
    // But we want to ensure that there's a second push waiting, so
    // here's another sleep.
    try io.sleep(.fromMilliseconds(10), .real);

    // Another spurious wake...
    q.not_full.signal(io);
    q.not_empty.signal(io);
    // And another chance for the other thread to see that it's
    // spurious and go back to sleep.
    try Thread.yield();
    try io.sleep(.fromMilliseconds(10), .real);

    // Pop that thing and we're done.
    try std.testing.expectEqual(2, q.pop());
}

test "Fill, block, fill, block" {
    const io = std.testing.io;

    // Fill the queue, block while trying to write another item, have
    // a background thread unblock us, then block while trying to
    // write yet another thing. Have the background thread unblock
    // that too (after some time) then drain the queue. This test
    // fails if the while loop in `push` is turned into an `if`.

    var queue: Queue(u8, 2) = .init(io);
    var state = atomic.Value(u8).init(0);
    var task = try io.concurrent(sleepyPop, .{ io, &queue, &state });
    try queue.push(1);
    try queue.push(2);
    state.store(1, .release);
    const now = std.Io.Timestamp.now(io, .real).toMilliseconds();
    try queue.push(3); // This one should block.
    const then = std.Io.Timestamp.now(io, .real).toMilliseconds();

    // Just to make sure the sleeps are yielding to this thread, make
    // sure it took at least 5ms to do the push.
    try std.testing.expect(then - now > 5);

    state.store(2, .release);
    // This should block again, waiting for the other thread.
    try queue.push(4);

    // And once that push has gone through, the other thread's done.
    try task.await(io);
    try std.testing.expectEqual(3, try queue.pop());
    try std.testing.expectEqual(4, try queue.pop());
}

fn sleepyPush(io: std.Io, q: *Queue(u8, 1), state: *atomic.Value(u8)) !void {
    // Try to ensure the other thread has already started trying to pop.
    try Thread.yield();
    try io.sleep(.fromMilliseconds(10), .real);

    // Spurious wake
    q.not_full.signal(io);
    q.not_empty.signal(io);

    try Thread.yield();
    try io.sleep(.fromMilliseconds(10), .real);

    // Stick something in the queue so it can be popped.
    try q.push(1);
    // Ensure it's been popped.
    while (state.load(.acquire) < 1)
        try Thread.yield();
    // Give the other thread time to block again.
    try Thread.yield();
    try io.sleep(.fromMilliseconds(10), .real);

    // Spurious wake
    q.not_full.signal(io);
    q.not_empty.signal(io);

    try q.push(2);
}

test "Drain, block, drain, block" {
    const io = std.testing.io;

    // This is like fill/block/fill/block, but on the pop end. This
    // test should fail if the `while` loop in `pop` is turned into an
    // `if`.

    var queue: Queue(u8, 1) = .init(io);
    var state = atomic.Value(u8).init(0);
    var task = try io.concurrent(sleepyPush, .{ io, &queue, &state });
    try std.testing.expectEqual(1, queue.pop());
    state.store(1, .release);
    try std.testing.expectEqual(2, queue.pop());
    try task.await(io);
}

fn readerThread(q: *Queue(u8, 1)) !void {
    try testing.expectEqual(1, try q.pop());
}

test "2 readers" {
    const io = std.testing.io;
    // 2 threads read, one thread writes
    var queue: Queue(u8, 1) = .init(io);
    var t1 = try io.concurrent(readerThread, .{&queue});
    defer t1.cancel(io) catch {};
    var t2 = try io.concurrent(readerThread, .{&queue});
    defer t2.cancel(io) catch {};
    try Thread.yield();
    try io.sleep(.fromMilliseconds(10), .real);
    try queue.push(1);
    try queue.push(1);
    try t1.await(io);
    try t2.await(io);
}

fn writerThread(q: *Queue(u8, 1)) !void {
    try q.push(1);
}

test "2 writers" {
    const io = std.testing.io;

    var queue: Queue(u8, 1) = .init(io);
    var t1 = try io.concurrent(writerThread, .{&queue});
    var t2 = try io.concurrent(writerThread, .{&queue});

    try testing.expectEqual(1, try queue.pop());
    try testing.expectEqual(1, try queue.pop());
    try t1.await(io);
    try t2.await(io);
}

test "close preserves buffered items and the first failure" {
    var q: Queue(u8, 2) = .init(testing.io);
    try q.push(17);
    try q.push(29);
    q.close(error.InputOutput);
    q.close(error.Closed);
    try testing.expectError(error.InputOutput, q.push(31));
    try testing.expectError(error.InputOutput, q.tryPush(31));
    try q.poll();
    try testing.expectEqual(17, try q.pop());
    try testing.expectEqual(29, (try q.tryPop()).?);
    try testing.expectError(error.InputOutput, q.pop());
    try testing.expectError(error.InputOutput, q.tryPop());
    try testing.expectError(error.InputOutput, q.poll());
    // A closed queue rejects writes even when it has free capacity.
    try testing.expectError(error.InputOutput, q.push(31));
    try testing.expectError(error.InputOutput, q.tryPush(31));
    q.reopen();
    try testing.expectEqual(null, try q.tryPop());
    try q.push(31);
    try testing.expectEqual(31, try q.pop());
}

test "close wakes all blocked writers and readers" {
    const Waiter = struct {
        ready: std.Io.Event = .unset,

        fn write(self: *@This(), q: *Queue(u8, 1)) !void {
            self.ready.set(q.io);
            try testing.expectError(error.Closed, q.push(99));
        }

        fn read(self: *@This(), q: *Queue(u8, 1)) !void {
            self.ready.set(q.io);
            try testing.expectError(error.Closed, q.pop());
        }

        fn poll(self: *@This(), q: *Queue(u8, 1)) !void {
            self.ready.set(q.io);
            try testing.expectError(error.Closed, q.poll());
        }
    };
    const io = testing.io;
    var full: Queue(u8, 1) = .init(io);
    var empty: Queue(u8, 1) = .init(io);
    try full.push(7);
    var waiters: [4]Waiter = @splat(.{});
    var a = try io.concurrent(Waiter.write, .{ &waiters[0], &full });
    defer a.cancel(io) catch {};
    var b = try io.concurrent(Waiter.write, .{ &waiters[1], &full });
    defer b.cancel(io) catch {};
    var c = try io.concurrent(Waiter.read, .{ &waiters[2], &empty });
    defer c.cancel(io) catch {};
    var d = try io.concurrent(Waiter.poll, .{ &waiters[3], &empty });
    defer d.cancel(io) catch {};
    for (&waiters) |*waiter| try waiter.ready.wait(io);
    try io.sleep(.fromMilliseconds(10), .awake);
    full.close(error.Closed);
    empty.close(error.Closed);
    try a.await(io);
    try b.await(io);
    try c.await(io);
    try d.await(io);
    try testing.expectEqual(7, try full.pop());
}

test {
    std.testing.refAllDecls(@This());
}
