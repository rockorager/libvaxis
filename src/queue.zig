const std = @import("std");
const assert = std.debug.assert;
const atomic = std.atomic;
const Futex = std.Thread.Futex;

const log = std.log.scoped(.queue);

/// Thread safe. Fixed size. Blocking push and pop.
pub fn Queue(
    comptime T: type,
    comptime size: usize,
) type {
    return struct {
        buf: [size]T = undefined,

        read_index: usize = 0,
        write_index: usize = 0,

        mutex: std.Thread.Mutex = .{},
        // blocks when the buffer is full or empty
        futex: atomic.Value(u32) = atomic.Value(u32).init(0),

        const Self = @This();

        pub fn pop(self: *Self) T {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.isEmpty()) {
                // If we don't have any items, we unlock and wait
                self.mutex.unlock();
                Futex.wait(&self.futex, 0);
                // regain our lock
                self.mutex.lock();
            }
            if (self.isFull()) {
                // If we are full, wake up the push
                defer Futex.wake(&self.futex, 1);
            }
            const i = self.read_index;
            self.read_index += 1;
            self.read_index = self.read_index % self.buf.len;
            return self.buf[i];
        }

        pub fn push(self: *Self, item: T) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.isFull()) {
                self.mutex.unlock();
                Futex.wait(&self.futex, 0);
                self.mutex.lock();
            }
            if (self.isEmpty()) {
                defer Futex.wake(&self.futex, 1);
            }
            const i = self.write_index;
            self.write_index += 1;
            self.write_index = self.write_index % self.buf.len;
            self.buf[i] = item;
        }

        /// Returns `true` if the ring buffer is empty and `false` otherwise.
        pub fn isEmpty(self: Self) bool {
            return self.write_index == self.read_index;
        }

        /// Returns `true` if the ring buffer is full and `false` otherwise.
        pub fn isFull(self: Self) bool {
            return self.mask2(self.write_index + self.buf.len) == self.read_index;
        }

        /// Returns the length
        pub fn len(self: Self) usize {
            const wrap_offset = 2 * self.buf.len * @intFromBool(self.write_index < self.read_index);
            const adjusted_write_index = self.write_index + wrap_offset;
            return adjusted_write_index - self.read_index;
        }

        /// Returns `index` modulo the length of the backing slice.
        pub fn mask(self: Self, index: usize) usize {
            return index % self.buf.len;
        }

        /// Returns `index` modulo twice the length of the backing slice.
        pub fn mask2(self: Self, index: usize) usize {
            return index % (2 * self.buf.len);
        }
    };
}

test "Queue: simple push / pop" {
    var queue: Queue(u8, 16) = .{};
    queue.push(1);
    const pop = queue.pop();
    try std.testing.expectEqual(1, pop);
}
