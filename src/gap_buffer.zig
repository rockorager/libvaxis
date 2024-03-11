/// the API in this file is directly inspired by `std.ArrayList`
const std = @import("std");
const debug = std.debug;
const assert = debug.assert;
const mem = std.mem;
const math = std.math;
const testing = std.testing;
const Allocator = mem.Allocator;

/// A contiguous, growable list of items in memory.
/// Well "contiguous", except for the gap in the middle
/// which exists to facilitate in-place insertion and deletion
///
/// This struct internally stores a `std.mem.Allocator` for memory management.
/// To manually specify an allocator with each function call see `GapBufferUnmanaged`.
pub fn GapBuffer(comptime T: type) type {
    return GapBufferAligned(T, null);
}

/// A contiguous, growable list of items in memory.
/// Well "contiguous", except for the gap in the middle
/// which exists to facilitate in-place insertion and deletion
/// This is a wrapper around an array of T values aligned to `alignment`-byte addresses.
/// If the specified alignment is `null`, then `@alignOf(T)` is used.
/// Initialize with `init`.
///
/// This struct internally stores a `std.mem.Allocator` for memory management.
/// To manually specify an allocator with each function call see `GapBufferUnmanaged`.
pub fn GapBufferAligned(comptime T: type, comptime alignment: ?u29) type {
    if (alignment) |a| {
        if (a == @alignOf(T)) {
            return GapBufferAligned(T, null);
        }
    }
    return struct {
        const Self = @This();
        /// Contents of the buffer. This field is intended to be accessed directly.
        ///
        /// Pointers to elements in this list are invalidated by various
        /// functions of this GapBuffer in accordance with the respective documentation.
        /// In many cases, "invalidated" means that the memory
        /// has been passed to this allocator's resize or free function.
        /// however, it could also mean that elements have been moved past the gap.
        ///
        /// The `len` field of this slice is the end point of the first chunk in the gap buffer
        items: Slice,
        /// logically the same point as `items.len`, but available for indexing.
        second_start: usize,
        /// the end of the second chunk in the gap buffer
        capacity: usize,
        allocator: Allocator,

        pub const Slice = if (alignment) |a| ([]align(a) T) else []T;

        pub fn SentinelSlice(comptime s: T) type {
            return if (alignment) |a| ([:s]align(a) T) else [:s]T;
        }

        /// Deinitialize with `deinit` or use `toOwnedSlice`.
        pub fn init(allocator: Allocator) Self {
            return .{
                .items = &.{},
                .second_start = 0,
                .capacity = 0,
                .allocator = allocator,
            };
        }

        /// Convenience function to access the second half of the GapBuffer as a Slice.
        /// NB: appears to be not possible to force the second half into alignment
        pub fn secondHalf(self: Self) []T {
            return self.items.ptr[self.second_start..self.capacity];
        }

        /// Initialize with capacity to hold `num` elements.
        /// The resulting capacity will equal `num` exactly.
        /// Deinitialize with `deinit` or use `toOwnedSlice`.
        pub fn initCapacity(allocator: Allocator, num: usize) Allocator.Error!Self {
            var self = Self.init(allocator);
            try self.ensureTotalCapacityPrecise(num);
            return self;
        }

        /// Release all allocated memory
        pub fn deinit(self: Self) void {
            if (@sizeOf(T) > 0) {
                self.allocator.free(self.allocatedSlice());
            }
        }

        /// GapBuffer takes ownership of the passed in slice. The slice must have been
        /// allocated with `allocator`.
        /// Deinitialize with `deinit` or use `toOwnedSlice`.
        pub fn fromOwnedSlice(allocator: Allocator, slice: Slice) Self {
            return .{
                .items = slice,
                .capacity = slice.len,
                .second_start = slice.len,
                .allocator = allocator,
            };
        }

        /// GapBuffer takes ownership of the passed in slice. The slice must have been
        /// allocated with `allocator`.
        /// Deinitialize with `deinit` or use `toOwnedSlice`.
        pub fn fromOwnedSliceSentinel(allocator: Allocator, comptime sentinel: T, slice: SentinelSlice(sentinel)) Self {
            return .{
                .items = slice,
                .capacity = slice.len + 1,
                .second_start = slice.len + 1,
                .allocator = allocator,
            };
        }

        /// Initializes a GapBufferUnmanaged with the `items` and `capacity` fields
        /// of this GapBuffer. Empties this GapBuffer.
        pub fn moveToUnmanaged(self: *Self) GapBufferAlignedUnmanaged(T, alignment) {
            const allocator = self.allocator;
            const result = .{
                .items = self.items,
                .second_start = self.second_start,
                .capacity = self.capacity,
            };
            self.* = init(allocator);
            return result;
        }

        /// The caller owns the returned memory. Empties this GapBuffer,
        /// Its capacity is cleared, making `deinit()` safe but unneccessary to call.
        pub fn toOwnedSlice(self: *Self) Allocator.Error!Slice {
            const allocator = self.allocator;

            const old_memory = self.allocatedSlice();
            const slice_len = self.realLength();
            // FIXME: there's never a case for calling `resize` since we have stuff at the end, right?
            const new_memory = try allocator.alignedAlloc(T, alignment, slice_len);
            @memcpy(new_memory[0..self.items.len], self.items);
            @memcpy(new_memory[self.items.len..], self.secondHalf());
            @memset(old_memory, undefined);
            self.clearAndFree();
            return new_memory;
        }

        /// The caller owns the returned memory. Empties this GapBuffer.
        pub fn toOwnedSliceSentinel(self: *Self, comptime sentinel: T) Allocator.Error!SentinelSlice(sentinel) {
            const old_memory = self.allocatedSlice();
            // This addition can never overflow because `self.realLength()` can never occupy the whole address space
            const slice_len = self.realLength() + 1;
            const new_memory = try self.allocator.alignedAlloc(T, alignment, slice_len);
            @memcpy(new_memory[0..self.items.len], self.items);
            @memcpy(new_memory[self.items.len..slice_len - 1], self.secondHalf());
            @memset(old_memory, undefined);
            new_memory[slice_len - 1] = sentinel;
            @memset(self.items, undefined);
            self.clearAndFree();
            return new_memory[0 .. new_memory.len - 1 :sentinel];
        }

        /// Creates a copy of this GapBuffer
        pub fn clone(self: Self) Allocator.Error!Self {
            var cloned = try Self.initCapacity(self.allocator, self.capacity);
            cloned.appendSliceBeforeAssumeCapacity(self.items);
            cloned.appendSliceAfterAssumeCapacity(self.secondHalf());
            return cloned;
        }

        /// Computes the total number of valid items in this GapBuffer
        pub fn realLength(self: Self) usize {
            return self.items.len + (self.capacity - self.second_start);
        }

        /// Moves the gap in the buffer
        /// asserts that the new start of the gap (that is, `self.items.len`)
        /// is not greater than `self.realLength()`.
        /// this operation is a copy, so O(n).
        pub fn moveGap(self: *Self, new_start: usize) void {
            if (new_start == self.items.len) return;
            const len = self.realLength();
            assert(new_start <= len);
            if (new_start < self.items.len) {
                const len_moved = self.items.len - new_start;
                // we're moving items _backwards_
                std.mem.copyBackwards(
                    T,
                    self.items.ptr[self.second_start - len_moved .. self.second_start],
                    self.items.ptr[new_start..self.items.len],
                );
                self.items.len = new_start;
                self.second_start -= len_moved;
            } else {
                const len_moved = new_start - self.items.len;
                // we're moving items _forwards_
                std.mem.copyForwards(
                    T,
                    self.items.ptr[self.items.len..new_start],
                    self.items.ptr[self.second_start .. self.second_start + len_moved],
                );
                self.items.len = new_start;
                self.second_start += len_moved;
            }
        }

        /// Insert `item` at index `i`, where the index is interpreted as falling within [0..realLength()].
        /// If `i` is equal to self.items.len, this operation is O(1),
        /// otherwise the gap must be moved.
        /// Invalidates element pointers if the gap is moved.
        /// Invalidates element pointers if additional memory is neede.
        /// Asserts that the index is in bounds.
        pub fn insertAfter(self: *Self, i: usize, item: T) Allocator.Error!void {
            const dst = try self.addManyAtAfter(i, 1);
            dst[0] = item;
        }

        /// Insert `item` at index `i`, where the index is interpreted as falling within [0..realLength()].
        /// If `i` is equal to self.items.len, this operation is O(1),
        /// otherwise the gap must be moved.
        /// Invalidates element pointers if the gap is moved.
        /// Asserts that the index is in bounds.
        /// Asserts that there is enough capacity for the new item.
        pub fn insertAfterAssumeCapacity(self: *Self, i: usize, item: T) void {
            assert(self.realLength() < self.capacity);
            self.moveGap(i);
            self.second_start -= 1;
            self.items.ptr[self.second_start] = item;
        }

        /// Insert `item` at index `i`, where the index is interpreted as falling within [0..realLength()].
        /// If `i` is equal to self.items.len, this operation is O(1),
        /// otherwise the gap must be moved.
        /// Invalidates element pointers if the gap is moved.
        /// Invalidates element pointers if additional memory is neede.
        /// Asserts that the index is in bounds.
        pub fn insertBefore(self: *Self, i: usize, item: T) Allocator.Error!void {
            const dst = try self.addManyAtBefore(i, 1);
            dst[0] = item;
        }

        /// Insert `item` at index `i`, where the index is interpreted as falling within [0..realLength()].
        /// If `i` is equal to self.items.len, this operation is O(1),
        /// otherwise the gap must be moved.
        /// Invalidates element pointers if the gap is moved.
        /// Asserts that the index is in bounds.
        /// Asserts that there is enough capacity for the new item.
        pub fn insertBeforeAssumeCapacity(self: *Self, i: usize, item: T) void {
            assert(self.realLength() < self.capacity);
            self.moveGap(i);
            self.items.ptr[i] = item;
            self.items.len += 1;
        }

        /// Add `count` new elements at position `index`, which have `undefined` values.
        /// Returns a slice pointing to the newly allocated elements,
        /// moving the gap so that the returned slice is after it.
        /// This slice becomes invalidated after various GapBuffer operations.
        /// Invalidates pre-existing pointers to elements at and after `index`.
        /// Invalidates all pre-existing element pointers if capacity must be increased
        /// to accomodate the new elements.
        pub fn addManyAtAfter(self: *Self, index: usize, count: usize) Allocator.Error![]T {
            const new_len = try addOrOom(self.realLength(), count);
            try self.ensureTotalCapacity(new_len);
            return addManyAtAfterAssumeCapacity(self, index, count);
        }

        /// Add `count` new elements at position `index`, which have `undefined` values.
        /// Returns a slice pointing to the newly allocated elements,
        /// moving the gap so that the returned slice is after it.
        /// This slice becomes invalidated after various GapBuffer operations.
        /// Asserts that there is enough capacity for the new elements.
        /// Invalidates pre-existing pointers to elements at and after `index`,
        /// and may move the gap.
        /// Asserts that the index is in bounds or equal to the length.
        pub fn addManyAtAfterAssumeCapacity(self: *Self, index: usize, count: usize) []T {
            const new = self.second_start - count;
            assert(new >= self.items.len);
            self.moveGap(index);
            const new_start = self.second_start - count;
            const res = self.items.ptr[new_start..][0..count];
            @memset(res, undefined);
            self.second_start = new_start;
            return res;
        }

        /// Add `count` new elements at position `index`, which have `undefined` values.
        /// Returns a slice pointing to the newly allocated elements,
        /// moving the gap so that the returned slice is before it.
        /// This slice becomes invalidated after various GapBuffer operations.
        /// Invalidates pre-existing pointers to elements at and after `index`.
        /// Invalidates all pre-existing element pointers if capacity must be increased
        /// to accomodate the new elements.
            pub fn addManyAtBefore(self: *Self, index: usize, count: usize) Allocator.Error![]T {
                try self.ensureUnusedCapacity(count);
            return addManyAtBeforeAssumeCapacity(self, index, count);
        }

        /// Add `count` new elements at position `index`, which have `undefined` values.
        /// Returns a slice pointing to the newly allocated elements,
        /// moving the gap so that the returned slice is before it.
        /// This slice becomes invalidated after various GapBuffer operations.
        /// Asserts that there is enough capacity for the new elements.
        /// Invalidates pre-existing pointers to elements at and after `index`,
        /// and may move the gap.
        /// Asserts that the index is in bounds or equal to the length.
            pub fn addManyAtBeforeAssumeCapacity(self: *Self, index: usize, count: usize) []T {
            assert(self.realLength() + count <= self.capacity);
            self.moveGap(index);
            const res = self.items.ptr[index..][0..count];
            @memset(res, undefined);
            self.items.len = index + count;
            return res;
        }

        /// Insert slice `items` at index `i` by moving the gap to make room.
        /// New items are added after the (new) gap.
        /// This operation is O(N) unless the gap does not move.
        /// Invalidates pre-existing pointers if the gap moves.
        /// Invalidates all pre-existing element pointers if capacity must be increased
        /// to accomodate the new elements.
        /// Asserts that the index is in bounds.
        pub fn insertSliceAfter(
            self: *Self,
            index: usize,
            items: []const T,
        ) Allocator.Error!void {
            const dst = try self.addManyAtAfter(index, items.len);
            @memcpy(dst, items);
        }

        /// Insert slice `items` at index `i` by moving the gap to make room.
        /// New items are added before the (new) gap.
        /// This operation is O(N) unless the gap does not move.
        /// Invalidates pre-existing pointers if the gap moves.
        /// Invalidates all pre-existing element pointers if capacity must be increased
        /// to accomodate the new elements.
        /// Asserts that the index is in bounds.
        pub fn insertSliceBefore(
            self: *Self,
            index: usize,
            items: []const T,
        ) Allocator.Error!void {
            const dst = try self.addManyAtBefore(index, items.len);
            @memcpy(dst, items);
        }

        /// Grows or shrinks the buffer and moves the gap as necessary.
        /// Invalidates element pointers if additional capacity is allocated.
        /// Asserts that the range is in bounds.
        pub fn replaceRangeAfter(self: *Self, start: usize, len: usize, new_items: []const T) Allocator.Error!void {
            var unmanaged = self.moveToUnmanaged();
            defer self.* = unmanaged.toManaged(self.allocator);
            return unmanaged.replaceRangeBefore(self.allocator, start, len, new_items);
        }

        /// Grows or shrinks the buffer and moves the gap as necessary.
        /// Asserts the capacity is enough for additional items.
        pub fn replaceRangeAfterAssumeCapacity(self: *Self, start: usize, len: usize, new_items: []const T) void {
            var unmanaged = self.moveToUnmanaged();
            defer self.* = unmanaged.toManaged(self.allocator);
            return unmanaged.replaceRangeAfterAssumeCapacity(start, len, new_items);
        }

        /// Grows or shrinks the buffer and moves the gap as necessary.
        /// Invalidates element pointers if additional capacity is allocated.
        /// Asserts that the range is in bounds.
        pub fn replaceRangeBefore(self: *Self, start: usize, len: usize, new_items: []const T) Allocator.Error!void {
            var unmanaged = self.moveToUnmanaged();
            defer self.* = unmanaged.toManaged(self.allocator);
            return unmanaged.replaceRangeBefore(self.allocator, start, len, new_items);
        }

        /// Grows or shrinks the buffer and moves the gap as necessary.
        /// Asserts the capacity is enough for additional items.
        pub fn replaceRangeBeforeAssumeCapacity(self: *Self, start: usize, len: usize, new_items: []const T) void {
            var unmanaged = self.moveToUnmanaged();
            defer self.* = unmanaged.toManaged(self.allocator);
            return unmanaged.replaceRangeBeforeAssumeCapacity(start, len, new_items);
        }

        /// Extends the list by 1 element after the gap. Allocates more memory as necessary.
        /// Invalidates element pointers if additional memory is needed.
        pub fn appendAfter(self: *Self, item: T) Allocator.Error!void {
            const new_item_ptr = try self.addOneAfter();
            new_item_ptr.* = item;
        }

        /// Extends the list by 1 element after the gap.
        /// Never invalidates element pointers.
        /// Asserts that the list can hold one additional item.
        pub fn appendAfterAssumeCapacity(self: *Self, item: T) void {
            const new_item_ptr = self.addOneAfterAssumeCapacity();
            new_item_ptr.* = item;
        }

        /// Extends the buffer by 1 element before the gap. Allocates more memory as necessary.
        /// Invalidates element pointers if additional memory is needed.
        pub fn appendBefore(self: *Self, item: T) Allocator.Error!void {
            const new_item_ptr = try self.addOneBefore();
            new_item_ptr.* = item;
        }

        /// Extends the buffer by 1 element before the gap.
        /// Never invalidates element pointers.
        /// Asserts that the list can hold one additional item.
        pub fn appendBeforeAssumeCapacity(self: *Self, item: T) void {
            const new_item_ptr = self.addOneBeforeAssumeCapacity();
            new_item_ptr.* = item;
        }

        /// returns an index suitable for feeding to `self.items.ptr`
        /// provided that i < self.realLength().
        pub fn realIndex(self: Self, i: usize) usize {
            return if (i < self.items.len) i else self.second_start + (i - self.items.len);
        }

        /// Remove the element at index `i`, moving the gap so that it is at index `i`,
        /// and returns the removed element.
        /// Invalidates element pointers after the gap.
        /// This operation is O(N) if the gap is moved.
        /// This preserves item order. Use `swapRemove` if order preservation is not important.
        /// Asserts that the index is in bounds.
        /// Asserts that the list is not empty.
        pub fn orderedRemove(self: *Self, i: usize) T {
            const j = self.realIndex(i);
            const old_item = self.items.ptr[j];
            self.replaceRangeBeforeAssumeCapacity(i, 1, &.{});
            return old_item;
        }

        /// Removes the element at the specified index and returns it.
        /// The empty slot is filled from the end of the gap.
        /// This operation is O(1).
        /// This may not preserve item order. Use `orderedRemove` if you need to preserve order.
        /// Asserts that the list is not empty.
        /// Asserts that the index is in bounds.
        pub fn swapRemoveAfter(self: *Self, i: usize) T {
            if (self.items.len == i) return self.popAfter();
            const old_item = self.getAt(i);
            self.getAtPtr(i).* = self.popAfter();
            return old_item;
        }

        /// Removes the element at the specified index and returns it.
        /// The empty slot is filled from the beginning of the gap.
        /// This operation is O(1).
        /// This may not preserve item order. Use `orderedRemove` if you need to preserve order.
        /// Asserts that the buffer is not empty.
        /// Asserts that the index is in bounds.
        pub fn swapRemoveBefore(self: *Self, i: usize) T {
            if (self.items.len - 1 == i) return self.popBefore();

            const old_item = self.getAt(i);
            self.getAtPtr(i).* = self.popBefore();
            return old_item;
        }

        /// Append the slice of items to the buffer after the gap. Allocates more
        /// memory as necessary.
        /// Invalidates element pointers if additional memory is needed.
        pub fn appendSliceAfter(self: *Self, items: []const T) Allocator.Error!void {
            try self.ensureUnusedCapacity(items.len);
            self.appendSliceAfterAssumeCapacity(items);
        }

        /// Append the slice of items to the buffer after the gap.
        /// Never invalidates element pointers.
        /// Asserts that the list can hold the additional items.
        pub fn appendSliceAfterAssumeCapacity(self: *Self, items: []const T) void {
            const old_start = self.second_start;
            const new_start = old_start - items.len;
            assert(new_start >= self.items.len);
            self.second_start = new_start;
            @memcpy(self.items.ptr[new_start..][0..items.len], items);
        }

        /// Append an unaligned slice of items to the buffer after the gap. Allocates more
        /// memory as necessary. Only call this function if calling
        /// `appendSliceAfter` instead would be a compile error.
        /// Invalidates element pointers if additional memory is needed.
        pub fn appendUnalignedSliceAfter(self: *Self, items: []align(1) const T) Allocator.Error!void {
            try self.ensureUnusedCapacity(items.len);
            self.appendUnalignedSliceAfterAssumeCapacity(items);
        }

        /// Append the slice of items to the buffer after the gap.
        /// Never invalidates element pointers.
        /// This function is only needed when calling
        /// `appendSliceAfterAssumeCapacity` instead would be a compile error due to the
        /// alignment of the `items` parameter.
        /// Asserts that the list can hold the additional items.
        pub fn appendUnalignedSliceAfterAssumeCapacity(self: *Self, items: []align(1) const T) void {
            const old_start = self.second_start;
            const new_start = old_start - items.len;
            assert(new_start >= self.items.len);
            self.second_start = new_start;
            @memcpy(self.items.ptr[new_start..][0..items.len], items);
        }

        /// Append the slice of items to the buffer before the gap. Allocates more
        /// memory as necessary.
        /// Invalidates element pointers if additional memory is needed.
        pub fn appendSliceBefore(self: *Self, items: []const T) Allocator.Error!void {
            try self.ensureUnusedCapacity(items.len);
            self.appendSliceBeforeAssumeCapacity(items);
        }

        /// Append the slice of items to the buffer before the gap.
        /// Never invalidates element pointers.
        /// Asserts that the list can hold the additional items.
        pub fn appendSliceBeforeAssumeCapacity(self: *Self, items: []const T) void {
            const old_len = self.items.len;
            const new_len = old_len + items.len;
            assert(new_len <= self.second_start);
            self.items.len = new_len;
            @memcpy(self.items[old_len..][0..items.len], items);
        }

        /// Append an unaligned slice of items to the buffer before the gap. Allocates more
        /// memory as necessary. Only call this function if calling
        /// `appendSliceBefore` instead would be a compile error.
        /// Invalidates element pointers if additional memory is needed.
        pub fn appendUnalignedSliceBefore(self: *Self, items: []align(1) const T) Allocator.Error!void {
            try self.ensureUnusedCapacity(items.len);
            self.appendUnalignedSliceBeforeAssumeCapacity(items);
        }

        /// Append the slice of items to the buffer before the gap.
        /// Never invalidates element pointers.
        /// This function is only needed when calling
        /// `appendSliceBeforeAssumeCapacity` instead would be a compile error due to the
        /// alignment of the `items` parameter.
        /// Asserts that the list can hold the additional items.
        pub fn appendUnalignedSliceBeforeAssumeCapacity(self: *Self, items: []align(1) const T) void {
            const old_len = self.items.len;
            const new_len = old_len + items.len;
            assert(new_len <= self.second_start);
            self.items.len = new_len;
            @memcpy(self.items[old_len..][0..items.len], items);
        }

        pub const AfterWriter = if (T != u8)
            @compileError("The Writer interface is only defined for GapBuffer(u8) " ++
                "but the given type is GapBuffer(" ++ @typeName(T) ++ ")")
        else
            std.io.GenericWriter(*Self, Allocator.Error, appendWriteAfter);

        /// Initializes a Writer which will append to the list.
        pub fn afterWriter(self: *Self) AfterWriter {
            return .{ .context = self };
        }

        pub const BeforeWriter = if (T != u8)
            @compileError("The Writer interface is only defined for GapBuffer(u8) " ++
                "but the given type is GapBuffer(" ++ @typeName(T) ++ ")")
        else
            std.io.GenericWriter(*Self, Allocator.Error, appendWriteBefore);

        /// Initializes a Writer which will append to the list.
        pub fn beforeWriter(self: *Self) BeforeWriter {
            return .{ .context = self };
        }

        /// Same as `appendSliceAfter` except it returns the number of bytes written, which is always the same
        /// as `m.len`. The purpose of this function existing is to match `std.io.Writer` API.
        /// Invalidates element pointers if additional memory is needed.
        fn appendWriteAfter(self: *Self, m: []const u8) Allocator.Error!usize {
            try self.appendUnalignedSliceAfter(m);
            return m.len;
        }

        /// Same as `appendSliceBefore` except it returns the number of bytes written, which is always the same
        /// as `m.len`. The purpose of this function existing is to match `std.io.Writer` API.
        /// Invalidates element pointers if additional memory is needed.
        fn appendWriteBefore(self: *Self, m: []const u8) Allocator.Error!usize {
            try self.appendUnalignedSliceBefore(m);
            return m.len;
        }

        /// Append a value to the buffer `n` times after the gap.
        /// Allocates more memory as necessary.
        /// Invalidates element pointers if additional memory is needed.
        /// The function is inline so that a comptime-known `value` parameter will
        /// have a more optimal memset codegen in case it has a repeated byte pattern.
        pub inline fn appendAfterNTimes(self: *Self, value: T, n: usize) Allocator.Error!void {
            const old_len = self.realLength();
            try self.resizeAfter(try addOrOom(old_len, n));
            @memset(self.items.ptr[self.second_start .. self.second_start + n], value);
        }

        /// Append a value to the buffer `n` times after the gap.
        /// Never invalidates element pointers.
        /// The function is inline so that a comptime-known `value` parameter will
        /// have a more optimal memset codegen in case it has a repeated byte pattern.
        /// Asserts that the list can hold the additional items.
        pub inline fn appendAfterNTimesAssumeCapacity(self: *Self, value: T, n: usize) void {
            const new_len = self.realLength() + n;
            assert(new_len <= self.capacity);
            @memset(self.items.ptr[self.second_start - n .. self.second_start], value);
            self.second_start -= n;
        }

        /// Append a value to the buffer `n` times before the gap.
        /// Allocates more memory as necessary.
        /// Invalidates element pointers if additional memory is needed.
        /// The function is inline so that a comptime-known `value` parameter will
        /// have a more optimal memset codegen in case it has a repeated byte pattern.
        pub inline fn appendBeforeNTimes(self: *Self, value: T, n: usize) Allocator.Error!void {
            const old_len = self.realLength();
            try self.resizeBefore(try addOrOom(old_len, n));
            @memset(self.items[old_len..self.items.len], value);
        }

        /// Append a value to the buffer `n` times before the gap.
        /// Never invalidates element pointers.
        /// The function is inline so that a comptime-known `value` parameter will
        /// have a more optimal memset codegen in case it has a repeated byte pattern.
        /// Asserts that the list can hold the additional items.
        pub inline fn appendBeforeNTimesAssumeCapacity(self: *Self, value: T, n: usize) void {
            const new_len = self.realLength() + n;
            assert(new_len <= self.capacity);
            @memset(self.items.ptr[self.items.len..new_len], value);
            self.items.len = new_len;
        }

        /// Adjusts the list length to `new_len`.
        /// Additional elements have unspecified values and are placed after the gap.
        /// Invalidates element pointers if additional memory is needed.
        pub fn resizeAfter(self: *Self, new_len: usize) Allocator.Error!void {
            const n = new_len - self.realLength();
            try self.ensureTotalCapacity(new_len);
            self.second_start -= n;
        }

        /// Adjusts the list length to `new_len`.
        /// Additional elements have unspecified values and are placed before the gap.
        /// Invalidates element pointers if additional memory is needed.
        pub fn resizeBefore(self: *Self, new_len: usize) Allocator.Error!void {
            const n = new_len - self.realLength();
            try self.ensureTotalCapacity(new_len);
            self.items.len += n;
        }

        /// Reduce allocated capacity to `new_len`.
        /// May invalidate element pointers.
        /// Asserts that the new length is less than or equal to the previous length.
        /// if elements are dropped as a result, they are dropped from after the gap.
        /// asserts that there are enough items after the gap to acommodate this.
        pub fn shrinkAndFreeAfter(self: *Self, new_len: usize) void {
            var unmanaged = self.moveToUnmanaged();
            unmanaged.shrinkAndFreeAfter(self.allocator, new_len);
            self.* = unmanaged.toManaged(self.allocator);
        }

        /// Reduce allocated capacity to `new_len`.
        /// May invalidate element pointers.
        /// Asserts that the new length is less than or equal to the previous length.
        /// if elements are dropped as a result, they are dropped from before the gap.
        /// asserts that there are enough items before the gap to acommodate this.
        pub fn shrinkAndFreeBefore(self: *Self, new_len: usize) void {
            var unmanaged = self.moveToUnmanaged();
            unmanaged.shrinkAndFreeBefore(self.allocator, new_len);
            self.* = unmanaged.toManaged(self.allocator);
        }

        /// Reduce `self.realLength()` to `new_len` by "removing" before the gap.
        /// Invalidates element pointers for the elements `items[new_len..]`.
        /// Asserts that the new length is less than or equal to the previous length.
        pub fn shrinkAfterRetainingCapacity(self: *Self, new_len: usize) void {
            assert(new_len <= self.realLength());
            const shrink_amount = self.realLength() - new_len;
            assert(self.second_start + shrink_amount <= self.capacity);
            self.second_start += shrink_amount;
        }

        /// Reduce `self.realLength()` to `new_len` by "removing" before the gap.
        /// Invalidates element pointers for the elements `items[new_len..]`.
        /// Asserts that the new length is less than or equal to the previous length.
        pub fn shrinkBeforeRetainingCapacity(self: *Self, new_len: usize) void {
            assert(new_len <= self.realLength());
            const shrink_amount = self.realLength() - new_len;
            assert(self.items.len >= shrink_amount);
            self.items.len -= shrink_amount;
        }

        /// Invalidates all element pointers.
        pub fn clearRetainingCapacity(self: *Self) void {
            self.items.len = 0;
            self.second_start = self.capacity;
        }

        /// Invalidates all element pointers.
        pub fn clearAndFree(self: *Self) void {
            self.allocator.free(self.allocatedSlice());
            self.items.len = 0;
            self.second_start = 0;
            self.capacity = 0;
        }

        /// If the current capacity is less than `new_capacity`, this function will
        /// modify the buffer so that it can hold at least `new_capacity` items.
        /// Invalidates element pointers if additional memory is needed.
        pub fn ensureTotalCapacity(self: *Self, new_capacity: usize) Allocator.Error!void {
            if (@sizeOf(T) == 0) {
                const diff = self.capacity - self.second_start;
                self.capacity = math.maxInt(usize);
                self.second_start = self.capacity - diff;
                return;
            }

            if (self.capacity >= new_capacity) return;

            const better_capacity = growCapacity(self.capacity, new_capacity);
            return self.ensureTotalCapacityPrecise(better_capacity);
        }

        /// If the capacity is less than `new_capacity`, this function will
        /// modify the buffer so that it can hold exactly `new_capacity` items.
        /// Invalidates element pointers if additional memory is needed.
        pub fn ensureTotalCapacityPrecise(self: *Self, new_capacity: usize) Allocator.Error!void {
            if (@sizeOf(T) == 0) {
                const diff = self.capacity - self.second_start;
                self.capacity = math.maxInt(usize);
                self.second_start = self.capacity - diff;
                return;
            }

            if (self.capacity >= new_capacity) return;

            // Here we avoid copying allocated but unused bytes by
            // attempting a resize in place, and falling back to allocating
            // a new buffer and doing our own copy. With a realloc() call,
            // the allocator implementation would pointlessly copy our
            // extra capacity.
            const old_memory = self.allocatedSlice();
            const second_half = self.secondHalf();
            if (self.allocator.resize(old_memory, new_capacity)) {
                self.capacity = new_capacity;
                self.second_start = new_capacity - second_half.len;
                mem.copyBackwards(T, self.items.ptr[self.second_start..][0..second_half.len], second_half);
            } else {
                const new_memory = try self.allocator.alignedAlloc(T, alignment, new_capacity);
                @memcpy(new_memory[0..self.items.len], self.items);
                @memcpy(new_memory[new_capacity - second_half.len .. new_capacity], second_half);
                self.allocator.free(old_memory);
                self.items.ptr = new_memory.ptr;
                self.second_start = new_memory.len - second_half.len;
                self.capacity = new_memory.len;
            }
        }

        /// Modify the buffer so that it can hold at least `additional_count` **more** items.
        /// Invalidates element pointers if additional memory is needed.
        pub fn ensureUnusedCapacity(self: *Self, additional_count: usize) Allocator.Error!void {
            return self.ensureTotalCapacity(try addOrOom(self.realLength(), additional_count));
        }

        /// Increase length by 1, returning pointer to the new item, which is after the gap.
        /// The returned pointer becomes invalid when the list resized.
        pub fn addOneAfter(self: *Self) Allocator.Error!*T {
            // This can never overflow because `self.items` can never occupy the whole address space
            const newlen = self.realLength() + 1;
            try self.ensureTotalCapacity(newlen);
            return self.addOneAfterAssumeCapacity();
        }

        /// Increase length by 1, returning pointer to the new item, which is after the gap.
        /// The returned pointer becomes invalid when the list is resized.
        /// Never invalidates element pointers.
        /// Asserts that the list can hold one additional item.
        pub fn addOneAfterAssumeCapacity(self: *Self) *T {
            assert(self.realLength() < self.capacity);
            self.second_start -= 1;
            return &self.items.ptr[self.second_start];
        }

        /// Increase length by 1, returning pointer to the new item, which is before the gap.
        /// The returned pointer becomes invalid when the list resized.
        pub fn addOneBefore(self: *Self) Allocator.Error!*T {
            // This can never overflow because `self.items` can never occupy the whole address space
            const newlen = self.realLength() + 1;
            try self.ensureTotalCapacity(newlen);
            return self.addOneBeforeAssumeCapacity();
        }

        /// Increase length by 1, returning pointer to the new item, which is before the gap.
        /// The returned pointer becomes invalid when the list is resized.
        /// Never invalidates element pointers.
        /// Asserts that the list can hold one additional item.
        pub fn addOneBeforeAssumeCapacity(self: *Self) *T {
            assert(self.realLength() < self.capacity);
            self.items.len += 1;
            return &self.items[self.items.len - 1];
        }

        /// Resize the buffer, adding `n` new elements, which have undefined values.
        /// New items are added after the gap.
        /// The return value is a slice pointing to the newly allocated elements.
        /// Resizes list if `self.capacity` is not large enough.
        pub fn addManyAsArrayAfter(self: *Self, comptime n: usize) Allocator.Error!*[n]T {
            try self.resizeAfter(try addOrOom(self.realLength(), n));
            return self.items.ptr[self.second_start..][0..n];
        }

        /// Resize the buffer, adding `n` new elements, which have `undefined` values.
        /// New items are added after the gap.
        /// The return value is a slice pointing to the newly allocated elements.
        /// Never invalidates element pointers.
        /// The returned pointer becomes invalid when the buffer is resized.
        /// Asserts that the buffer can hold the additional items.
        pub fn addManyAsArrayAfterAssumeCapacity(self: *Self, comptime n: usize) *[n]T {
            assert(self.items.len + n <= self.second_start);
            self.second_start -= n;
            return self.items.ptr[self.second_start..][0..n];
        }

        /// Resize the buffer, adding `n` new elements, which have undefined values.
        /// New items are added before the gap.
        /// The return value is a slice pointing to the newly allocated elements.
        /// Resizes list if `self.capacity` is not large enough.
        pub fn addManyAsArrayBefore(self: *Self, comptime n: usize) Allocator.Error!*[n]T {
            const prev_len = self.realLength();
            try self.resizeBefore(try addOrOom(prev_len, n));
            return self.items[prev_len..][0..n];
        }

        /// Resize the buffer, adding `n` new elements, which have undefined values.
        /// New items are added before the gap.
        /// The return value is a slice pointing to the newly allocated elements.
        /// Never invalidates element pointers.
        /// The returned pointer becomes invalid when the buffer is resized.
        /// Asserts that the buffer can hold the additional items.
        pub fn addManyAsArrayBeforeAssumeCapacity(self: *Self, comptime n: usize) *[n]T {
            assert(self.items.len + n <= self.second_start);
            const prev_len = self.items.len;
            self.items.len += n;
            return self.items[prev_len..][0..n];
        }

        /// Resize the buffer, adding `n` new elements, which have undefined values.
        /// New items are added after the gap.
        /// The return value is a slice pointing to the newly allocated elements.
        /// Resizes list if `self.capacity` is not large enough.
        pub fn addManyAsSliceAfter(self: *Self, n: usize) Allocator.Error![]T {
            try self.resizeAfter(try addOrOom(self.realLength(), n));
            return self.items.ptr[self.second_start..][0..n];
        }

        /// Resize the buffer, adding `n` new elements, which have `undefined` values.
        /// New items are added after the gap.
        /// The return value is a slice pointing to the newly allocated elements.
        /// Never invalidates element pointers.
        /// The returned pointer becomes invalid when the buffer is resized.
        /// Asserts that the buffer can hold the additional items.
        pub fn addManyAsSliceAfterAssumeCapacity(self: *Self, n: usize) []T {
            assert(self.items.len + n <= self.second_start);
            self.second_start -= n;
            return self.items.ptr[self.second_start..][0..n];
        }

        /// Resize the buffer, adding `n` new elements, which have undefined values.
        /// New items are added before the gap.
        /// The return value is a slice pointing to the newly allocated elements.
        /// Resizes list if `self.capacity` is not large enough.
        pub fn addManyAsSliceBefore(self: *Self, n: usize) Allocator.Error![]T {
            const prev_len = self.realLength();
            try self.resizeBefore(try addOrOom(prev_len, n));
            return self.items[prev_len..][0..n];
        }

        /// Resize the buffer, adding `n` new elements, which have undefined values.
        /// New items are added before the gap.
        /// The return value is a slice pointing to the newly allocated elements.
        /// Never invalidates element pointers.
        /// The returned pointer becomes invalid when the buffer is resized.
        /// Asserts that the buffer can hold the additional items.
        pub fn addManyAsSliceBeforeAssumeCapacity(self: *Self, n: usize) []T {
            assert(self.items.len + n <= self.second_start);
            const prev_len = self.items.len;
            self.items.len += n;
            return self.items[prev_len..][0..n];
        }

        /// Remove and return the first element after the gap.
        /// Asserts that there is one.
        pub fn popAfter(self: *Self) T {
            assert(self.second_start < self.capacity);
            const val = self.items.ptr[self.second_start];
            self.second_start += 1;
            return val;
        }

        /// Remove and return the first element after the gap
        /// or return `null` if there is none.
        pub fn popAfterOrNull(self: *Self) ?T {
            if (self.second_start == self.capacity) return null;
            return self.popAfter();
        }

        /// Remove and return the last element from before the gap.
        /// Asserts that there is one.
        pub fn popBefore(self: *Self) T {
            const val = self.items[self.items.len - 1];
            self.items.len -= 1;
            return val;
        }

        /// Remove and return the last element from before the gap
        /// or return `null` if there is none.
        pub fn popBeforeOrNull(self: *Self) ?T {
            if (self.items.len == 0) return null;
            return self.popBefore();
        }

        /// Returns a slice of the entire capacity, including the gap,
        /// whose contents are undefined (if not precisely `undefined`).
        pub fn allocatedSlice(self: Self) Slice {
            return self.items.ptr[0..self.capacity];
        }

        /// Returns the element at the specified index
        pub fn getAt(self: Self, index: usize) T {
            return self.items.ptr[self.realIndex(index)];
        }

        /// Returns a pointer to the element at the specified index
        /// will be invalidated if the gap moves
        pub fn getAtPtr(self: Self, index: usize) *T {
            return &self.items.ptr[self.realIndex(index)];
        }

        /// Returns the first element after the gap.
        /// Asserts that there is one.
        pub fn getAfter(self: Self) T {
            return self.items.ptr[self.second_start];
        }

        /// Returns the first element after the gap, or `null` if there is none.
        pub fn getAfterOrNull(self: Self) ?T {
            if (self.second_start == self.capacity) return null;
            return self.getAfter();
        }

        /// Returns the last element before the gap.
        /// Asserts that there is one.
        pub fn getBefore(self: Self) T {
            const val = self.items[self.items.len - 1];
            return val;
        }

        /// Returns the last element before the gap, or `null` if there is none.
        pub fn getBeforeOrNull(self: Self) ?T {
            if (self.items.len == 0) return null;
            return self.getBefore();
        }
    };
}

/// A GapBuffer, but the allocator is passed as a parameter to the relevant functions
/// rather than stored in the struct itself. The same allocator must be used throughout
/// the entire lifetime of a GapBufferUnmanaged. Initialize directly or with
/// `initCapacity` and deinitialize with `deinit` or `toOwnedSlice`.
pub fn GapBufferUnmanaged(comptime T: type) type {
    return GapBufferAlignedUnmanaged(T, null);
}

/// A contiguous, growable list of items in memory.
/// Well "contiguous", except for the gap in the middle
/// which exists to facilitate in-place insertion and deletion
/// This is a wrapper around an array of T values aligned to `alignment`-byte addresses.
/// If the specified alignment is `null`, then `@alignOf(T)` is used.
///
/// Functions that potentially allocate (or free) memory accept an `Allocator` parameter.
/// Initialize directly or with `initCapacity`, and deinitialize with `deinit`
/// or use `toOwnedSlice`.
pub fn GapBufferAlignedUnmanaged(comptime T: type, comptime alignment: ?u29) type {
    if (alignment) |a| {
        if (a == @alignOf(T)) {
            return GapBufferAlignedUnmanaged(T, null);
        }
    }
    return struct {
        const Self = @This();
        /// Contents of the buffer. This field is intended to be accessed
        /// directly.
        ///
        /// Pointers to elements in this slice are invalidated by various
        /// functions of this ArrayList in accordance with the respective documentation
        /// In many cases, "invalidated" means that the memory
        /// has been passed to this allocator's resize or free function.
        /// however, it could also mean that elements have been moved past the gap.
        ///
        /// The `len` field of this slice is the end point of the first chunk in the gap buffer
        items: Slice = &[_]T{},
        /// logically the same point as `items.len`, but available for indexing.
        second_start: usize = 0,
        /// the end of the second chunk in the gap buffer
        capacity: usize = 0,

        pub const Slice = if (alignment) |a| ([]align(a) T) else []T;

        pub fn SentinelSlice(comptime s: T) type {
            return if (alignment) |a| ([:s]align(a) T) else [:s]T;
        }

        /// Convenience function to access the second half of the GapBuffer as a Slice.
        /// NB: it appears to not be possible to force the second half into alignment
        pub fn secondHalf(self: Self) []T {
            return self.items.ptr[self.second_start..self.capacity];
        }

        /// Initialize with capacity to hold `num` elements.
        /// The resulting capacity will equal `num` exactly.
        /// Deinitialize with `deinit` or use `toOwnedSlice`.
        pub fn initCapacity(allocator: Allocator, num: usize) Allocator.Error!Self {
            var self = Self{};
            try self.ensureTotalCapacityPrecise(allocator, num);
            return self;
        }

        /// Initialize with externally-managed memory. The buffer determines the
        /// capacity, and the length is set to zero.
        /// When initialized this way, all functions that accept an Allocator
        /// argument cause illegal behavior.
        pub fn initBuffer(buffer: Slice) Self {
            return .{
                .items = buffer[0..0],
                .capacity = buffer.len,
                .second_start = buffer.len,
            };
        }

        /// Release all allocated memory.
        pub fn deinit(self: *Self, allocator: Allocator) void {
            allocator.free(self.allocatedSlice());
            self.* = undefined;
        }

        /// Convert this list into an analogous memory-managed one.
        /// The returned list has ownership of the underlying memory.
        pub fn toManaged(self: *Self, allocator: Allocator) GapBufferAligned(T, alignment) {
            return .{
                .items = self.items,
                .capacity = self.capacity,
                .second_start = self.second_start,
                .allocator = allocator,
            };
        }

        /// ArrayListUnmanaged takes ownership of the passed in slice. The slice must have been
        /// allocated with `allocator`.
        /// Deinitialize with `deinit` or use `toOwnedSlice`.
        pub fn fromOwnedSlice(slice: Slice) Self {
            return Self{
                .items = slice,
                .capacity = slice.len,
            };
        }

        /// ArrayListUnmanaged takes ownership of the passed in slice. The slice must have been
        /// allocated with `allocator`.
        /// Deinitialize with `deinit` or use `toOwnedSlice`.
        pub fn fromOwnedSliceSentinel(comptime sentinel: T, slice: [:sentinel]T) Self {
            return Self{
                .items = slice,
                .capacity = slice.len + 1,
            };
        }

        /// The caller owns the returned memory. Empties this GapBuffer.
        /// Its capacity is cleared, making deinit() safe but unnecessary to call.
        pub fn toOwnedSlice(self: *Self, allocator: Allocator) Allocator.Error!Slice {
            const old_memory = self.allocatedSlice();
            const slice_len = self.realLength();
            // FIXME: there's never a case for calling `resize` since we have stuff at the end, right?
            const new_memory = try allocator.alignedAlloc(T, alignment, slice_len);
            @memcpy(new_memory[0..self.items.len], self.items);
            @memcpy(new_memory[self.items.len..], self.secondHalf());
            @memset(old_memory, undefined);
            self.clearAndFree(allocator);
            return new_memory;
        }

        /// The caller owns the returned memory. GapBuffer becomes empty.
        pub fn toOwnedSliceSentinel(self: *Self, allocator: Allocator, comptime sentinel: T) Allocator.Error!SentinelSlice(sentinel) {
            // This addition can never overflow because `self.realLength()` can never occupy the whole address space
                try self.ensureTotalCapacityPrecise(allocator, self.realLength() + 1);
            self.moveGap(self.realLength());
            self.appendAfterAssumeCapacity(sentinel);
            const result = try self.toOwnedSlice(allocator);
            return result[0 .. result.len - 1 :sentinel];
        }

        /// Creates a copy of this GapBuffer
        pub fn clone(self: Self, allocator: Allocator) Allocator.Error!Self {
            var cloned = try Self.initCapacity(allocator, self.capacity);
            cloned.appendSliceBeforeAssumeCapacity(self.items);
            cloned.appendSliceAfterAssumeCapacity(self.secondHalf());
            return cloned;
        }

        /// Computes the total number of valid items in this GapBuffer
        pub fn realLength(self: Self) usize {
            return self.items.len + (self.capacity - self.second_start);
        }

        /// Moves the gap in the buffer
        /// asserts that the new start of the gap (that is, `self.items.len`)
        /// is not greater than `self.realLength()`.
        /// this operation is a copy, so O(n).
        pub fn moveGap(self: *Self, new_start: usize) void {
            if (new_start == self.items.len) return;
            const len = self.realLength();
            assert(new_start <= len);
            if (new_start < self.items.len) {
                const len_moved = self.items.len - new_start;
                // we're moving items _backwards_
                std.mem.copyBackwards(
                    T,
                    self.items.ptr[self.second_start - len_moved .. self.second_start],
                    self.items.ptr[new_start..self.items.len],
                );
                self.items.len = new_start;
                self.second_start -= len_moved;
            } else {
                const len_moved = new_start - self.items.len;
                // we're moving items _forwards_
                std.mem.copyForwards(
                    T,
                    self.items.ptr[self.items.len..new_start],
                    self.items.ptr[self.second_start .. self.second_start + len_moved],
                );
                self.items.len = new_start;
                self.second_start += len_moved;
            }
        }

        /// Insert `item` at index `i`, where the index is interpreted as falling within [0..realLength()].
        /// If `i` is equal to self.items.len, this operation is O(1),
        /// otherwise the gap must be moved.
        /// Invalidates element pointers if the gap is moved.
        /// Invalidates element pointers if additional memory is neede.
        /// Asserts that the index is in bounds.
        pub fn insertAfter(self: *Self, allocator: Allocator, i: usize, item: T) Allocator.Error!void {
            const dst = try self.addManyAtAfter(allocator, i, 1);
            dst[0] = item;
        }

        /// Insert `item` at index `i`, where the index is interpreted as falling within [0..realLength()].
        /// If `i` is equal to self.items.len, this operation is O(1),
        /// otherwise the gap must be moved.
        /// Invalidates element pointers if the gap is moved.
        /// Asserts that the index is in bounds.
        /// Asserts that there is enough capacity for the new item.
        pub fn insertAfterAssumeCapacity(self: *Self, i: usize, item: T) void {
            assert(self.realLength() < self.capacity);
            self.moveGap(i);
            self.second_start -= 1;
            self.items.ptr[self.second_start] = item;
        }

        /// Insert `item` at index `i`, where the index is interpreted as falling within [0..realLength()].
        /// If `i` is equal to self.items.len, this operation is O(1),
        /// otherwise the gap must be moved.
        /// Invalidates element pointers if the gap is moved.
        /// Invalidates element pointers if additional memory is neede.
        /// Asserts that the index is in bounds.
        pub fn insertBefore(self: *Self, allocator: Allocator, i: usize, item: T) Allocator.Error!void {
            const dst = try self.addManyAtBefore(allocator, i, 1);
            dst[0] = item;
        }

        /// Insert `item` at index `i`, where the index is interpreted as falling within [0..realLength()].
        /// If `i` is equal to self.items.len, this operation is O(1),
        /// otherwise the gap must be moved.
        /// Invalidates element pointers if the gap is moved.
        /// Asserts that the index is in bounds.
        /// Asserts that there is enough capacity for the new item.
        pub fn insertBeforeAssumeCapacity(self: *Self, i: usize, item: T) void {
            assert(self.realLength() < self.capacity);
            self.moveGap(i);
            self.items.ptr[i] = item;
            self.items.len += 1;
        }

        /// Add `count` new elements at position `index`, which have `undefined` values.
        /// Returns a slice pointing to the newly allocated elements,
        /// moving the gap so that the returned slice is after it.
        /// This slice becomes invalidated after various GapBuffer operations.
        /// Invalidates pre-existing pointers to elements at and after `index`.
        /// Invalidates all pre-existing element pointers if capacity must be increased
        /// to accomodate the new elements.
        pub fn addManyAtAfter(self: *Self, allocator: Allocator, index: usize, count: usize) Allocator.Error![]T {
            const new_len = try addOrOom(self.realLength(), count);
            try self.ensureTotalCapacity(allocator, new_len);
            return addManyAtAfterAssumeCapacity(self, index, count);
        }

        /// Add `count` new elements at position `index`, which have `undefined` values.
        /// Returns a slice pointing to the newly allocated elements,
        /// moving the gap so that the returned slice is after it.
        /// This slice becomes invalidated after various GapBuffer operations.
        /// Asserts that there is enough capacity for the new elements.
        /// Invalidates pre-existing pointers to elements at and after `index`,
        /// and may move the gap.
        /// Asserts that the index is in bounds or equal to the length.
        pub fn addManyAtAfterAssumeCapacity(self: *Self, index: usize, count: usize) []T {
            const new_start = self.second_start - count;
            assert(new_start >= self.items.len);
            self.moveGap(index);
            const res = self.items.ptr[self.second_start - count ..][0..count];
            @memset(res, undefined);
            self.second_start -= count;
            return res;
        }

        /// Add `count` new elements at position `index`, which have `undefined` values.
        /// Returns a slice pointing to the newly allocated elements,
        /// moving the gap so that the returned slice is before it.
        /// This slice becomes invalidated after various GapBuffer operations.
        /// Invalidates pre-existing pointers to elements at and after `index`.
        /// Invalidates all pre-existing element pointers if capacity must be increased
        /// to accomodate the new elements.
            pub fn addManyAtBefore(self: *Self, allocator: Allocator, index: usize, count: usize) Allocator.Error![]T {
                try self.ensureUnusedCapacity(allocator, count);
            return addManyAtBeforeAssumeCapacity(self, index, count);
        }

        /// Add `count` new elements at position `index`, which have `undefined` values.
        /// Returns a slice pointing to the newly allocated elements,
        /// moving the gap so that the returned slice is before it.
        /// This slice becomes invalidated after various GapBuffer operations.
        /// Asserts that there is enough capacity for the new elements.
        /// Invalidates pre-existing pointers to elements at and after `index`,
        /// and may move the gap.
        /// Asserts that the index is in bounds or equal to the length.
        pub fn addManyAtBeforeAssumeCapacity(self: *Self, index: usize, count: usize) []T {
            assert(self.realLength() + count <= self.capacity);
            self.moveGap(index);
            const res = self.items.ptr[index..][0..count];
            @memset(res, undefined);
            self.items.len = index + count;
            return res;
        }

        /// Insert slice `items` at index `i` by moving the gap to make room.
        /// New items are added after the (new) gap.
        /// This operation is O(N) unless the gap does not move.
        /// Invalidates pre-existing pointers if the gap moves.
        /// Invalidates all pre-existing element pointers if capacity must be increased
        /// to accomodate the new elements.
        /// Asserts that the index is in bounds.
        pub fn insertSliceAfter(
            self: *Self,
            allocator: Allocator,
            index: usize,
            items: []const T,
        ) Allocator.Error!void {
            const dst = try self.addManyAtAfter(allocator, index, items.len);
            @memcpy(dst, items);
        }

        /// Insert slice `items` at index `i` by moving the gap to make room.
        /// New items are added before the (new) gap.
        /// This operation is O(N) unless the gap does not move.
        /// Invalidates pre-existing pointers if the gap moves.
        /// Invalidates all pre-existing element pointers if capacity must be increased
        /// to accomodate the new elements.
        /// Asserts that the index is in bounds.
        pub fn insertSliceBefore(
            self: *Self,
            allocator: Allocator,
            index: usize,
            items: []const T,
        ) Allocator.Error!void {
            const dst = try self.addManyAtBefore(allocator, index, items.len);
            @memcpy(dst, items);
        }

        /// Grows or shrinks the list as necessary.
        /// Invalidates element pointers if additional capacity is allocated.
        /// Asserts that the range is in bounds.
        /// Moves the gap so that new_items is placed after it.
        pub fn replaceRangeAfter(
            self: *Self,
            allocator: Allocator,
            start: usize,
            len: usize,
            new_items: []const T,
        ) Allocator.Error!void {
            self.moveGap(start);
            const after_range = self.second_start + len;
            const range = self.items.ptr[self.second_start..after_range];
            if (range.len < new_items.len) {
                const first = new_items[0 .. new_items.len - range.len];
                const rest = new_items[new_items.len - range.len ..];
                @memcpy(range, rest);
                try self.insertSliceAfter(allocator, start, first);
            } else {
                self.replaceRangeAfterAssumeCapacity(start, len, new_items);
            }
        }

        /// Grows or shrinks the list as necessary.
        /// Asserts the capacity is enough for additional items.
        /// Moves the gap so that new_items is placed after it.
        pub fn replaceRangeAfterAssumeCapacity(self: *Self, start: usize, len: usize, new_items: []const T) void {
            self.moveGap(start);
            const after_range = self.second_start + len;
            const range = self.items.ptr[self.second_start..after_range];

            if (range.len == new_items.len)
                @memcpy(range[0..new_items.len], new_items)
            else if (range.len < new_items.len) {
                const first = new_items[0 .. new_items.len - range.len];
                const rest = new_items[new_items.len - range.len ..];
                @memcpy(range, rest);
                const dst = self.addManyAtAfterAssumeCapacity(start, first.len);
                @memcpy(dst, first);
            } else {
                const extra = range.len - new_items.len;
                @memcpy(range[extra..][0..new_items.len], new_items);
                @memset(range[0..extra], undefined);
                self.second_start += extra;
            }
        }

        /// Grows or shrinks the list as necessary.
        /// Invalidates element pointers if additional capacity is allocated.
        /// Asserts that the range is in bounds.
        /// Moves the gap so that new_items is placed before it.
        pub fn replaceRangeBefore(
            self: *Self,
            allocator: Allocator,
            start: usize,
            len: usize,
            new_items: []const T,
        ) Allocator.Error!void {
            const after_range = start + len;
            self.moveGap(after_range);
            const range = self.items[start..after_range];
            if (range.len < new_items.len) {
                const first = new_items[0..range.len];
                const rest = new_items[range.len..];
                @memcpy(range[0..first.len], first);
                try self.insertSliceBefore(allocator, after_range, rest);
            } else {
                self.replaceRangeBeforeAssumeCapacity(start, len, new_items);
            }
        }

        /// Grows or shrinks the list as necessary.
        /// Asserts the capacity is enough for additional items.
        /// Moves the gap so that new_items is placed before it.
        pub fn replaceRangeBeforeAssumeCapacity(self: *Self, start: usize, len: usize, new_items: []const T) void {
            const after_range = start + len;
            self.moveGap(after_range);
            const range = self.items[start..after_range];

            if (range.len == new_items.len)
                @memcpy(range[0..new_items.len], new_items)
            else if (range.len < new_items.len) {
                const first = new_items[0..range.len];
                const rest = new_items[range.len..];
                @memcpy(range[0..first.len], first);
                const dst = self.addManyAtBeforeAssumeCapacity(after_range, rest.len);
                @memcpy(dst, rest);
            } else {
                const extra = range.len - new_items.len;
                @memcpy(range[0..new_items.len], new_items);
                std.mem.copyForwards(
                    T,
                    self.items[after_range - extra ..],
                    self.items[after_range..],
                );
                @memset(self.items[self.items.len - extra ..], undefined);
                self.items.len -= extra;
            }
        }

        /// Extends the list by 1 element after the gap. Allocates more memory as necessary.
        /// Invalidates element pointers if additional memory is needed.
        pub fn appendAfter(self: *Self, allocator: Allocator, item: T) Allocator.Error!void {
            const new_item_ptr = try self.addOneAfter(allocator);
            new_item_ptr.* = item;
        }

        /// Extends the list by 1 element after the gap.
        /// Never invalidates element pointers.
        /// Asserts that the list can hold one additional item.
        pub fn appendAfterAssumeCapacity(self: *Self, item: T) void {
            const new_item_ptr = self.addOneAfterAssumeCapacity();
            new_item_ptr.* = item;
        }

        /// Extends the buffer by 1 element before the gap. Allocates more memory as necessary.
        /// Invalidates element pointers if additional memory is needed.
        pub fn appendBefore(self: *Self, allocator: Allocator, item: T) Allocator.Error!void {
            const new_item_ptr = try self.addOneBefore(allocator);
            new_item_ptr.* = item;
        }

        /// Extends the buffer by 1 element before the gap.
        /// Never invalidates element pointers.
        /// Asserts that the list can hold one additional item.
        pub fn appendBeforeAssumeCapacity(self: *Self, item: T) void {
            const new_item_ptr = self.addOneBeforeAssumeCapacity();
            new_item_ptr.* = item;
        }

        /// returns an index suitable for feeding to `self.items.ptr`
        /// provided that i < self.realLength().
        pub fn realIndex(self: Self, i: usize) usize {
            return if (i < self.items.len) i else self.second_start + (i - self.items.len);
        }

        /// Remove the element at index `i`, moving the gap so that it is at index `i`,
        /// and returns the removed element.
        /// Invalidates element pointers after the gap.
        /// This operation is O(N) if the gap is moved.
        /// This preserves item order. Use `swapRemove` if order preservation is not important.
        /// Asserts that the index is in bounds.
        /// Asserts that the list is not empty.
        pub fn orderedRemove(self: *Self, i: usize) T {
            const j = self.realIndex(i);
            const old_item = self.items.ptr[j];
            self.replaceRangeBeforeAssumeCapacity(i, 1, &.{});
            return old_item;
        }

        /// Removes the element at the specified index and returns it.
        /// The empty slot is filled from the end of the gap.
        /// This operation is O(1).
        /// This may not preserve item order. Use `orderedRemove` if you need to preserve order.
        /// Asserts that the list is not empty.
        /// Asserts that the index is in bounds.
        pub fn swapRemoveAfter(self: *Self, i: usize) T {
            if (self.items.len == i) return self.popAfter();
            const old_item = self.getAt(i);
            self.getAtPtr(i).* = self.popAfter();
            return old_item;
        }

        /// Removes the element at the specified index and returns it.
        /// The empty slot is filled from the beginning of the gap.
        /// This operation is O(1).
        /// This may not preserve item order. Use `orderedRemove` if you need to preserve order.
        /// Asserts that the buffer is not empty.
        /// Asserts that the index is in bounds.
        pub fn swapRemoveBefore(self: *Self, i: usize) T {
            if (self.items.len - 1 == i) return self.popBefore();

            const old_item = self.getAt(i);
            self.getAtPtr(i).* = self.popBefore();
            return old_item;
        }

        /// Append the slice of items to the buffer after the gap. Allocates more
        /// memory as necessary.
        /// Invalidates element pointers if additional memory is needed.
        pub fn appendSliceAfter(self: *Self, allocator: Allocator, items: []const T) Allocator.Error!void {
            try self.ensureUnusedCapacity(allocator, items.len);
            self.appendSliceAfterAssumeCapacity(items);
        }

        /// Append the slice of items to the buffer after the gap.
        /// Never invalidates element pointers.
        /// Asserts that the list can hold the additional items.
        pub fn appendSliceAfterAssumeCapacity(self: *Self, items: []const T) void {
            const old_start = self.second_start;
            const new_start = old_start - items.len;
            assert(new_start >= self.items.len);
            self.second_start = new_start;
            @memcpy(self.items.ptr[new_start..][0..items.len], items);
        }

        /// Append an unaligned slice of items to the buffer after the gap. Allocates more
        /// memory as necessary. Only call this function if calling
        /// `appendSliceAfter` instead would be a compile error.
        /// Invalidates element pointers if additional memory is needed.
        pub fn appendUnalignedSliceAfter(self: *Self, allocator: Allocator, items: []align(1) const T) Allocator.Error!void {
            try self.ensureUnusedCapacity(allocator, items.len);
            self.appendUnalignedSliceAfterAssumeCapacity(items);
        }

        /// Append the slice of items to the buffer after the gap.
        /// Never invalidates element pointers.
        /// This function is only needed when calling
        /// `appendSliceAfterAssumeCapacity` instead would be a compile error due to the
        /// alignment of the `items` parameter.
        /// Asserts that the list can hold the additional items.
        pub fn appendUnalignedSliceAfterAssumeCapacity(self: *Self, items: []align(1) const T) void {
            const old_start = self.second_start;
            const new_start = old_start - items.len;
            assert(new_start >= self.items.len);
            self.second_start = new_start;
            @memcpy(self.items.ptr[new_start..][0..items.len], items);
        }

        /// Append the slice of items to the buffer before the gap. Allocates more
        /// memory as necessary.
        /// Invalidates element pointers if additional memory is needed.
        pub fn appendSliceBefore(self: *Self, allocator: Allocator, items: []const T) Allocator.Error!void {
            try self.ensureUnusedCapacity(allocator, items.len);
            self.appendSliceBeforeAssumeCapacity(items);
        }

        /// Append the slice of items to the buffer before the gap.
        /// Never invalidates element pointers.
        /// Asserts that the list can hold the additional items.
        pub fn appendSliceBeforeAssumeCapacity(self: *Self, items: []const T) void {
            const old_len = self.items.len;
            const new_len = old_len + items.len;
            assert(new_len <= self.second_start);
            self.items.len = new_len;
            @memcpy(self.items[old_len..][0..items.len], items);
        }

        /// Append an unaligned slice of items to the buffer before the gap. Allocates more
        /// memory as necessary. Only call this function if calling
        /// `appendSliceBefore` instead would be a compile error.
        /// Invalidates element pointers if additional memory is needed.
        pub fn appendUnalignedSliceBefore(self: *Self, allocator: Allocator, items: []align(1) const T) Allocator.Error!void {
            try self.ensureUnusedCapacity(allocator, items.len);
            self.appendUnalignedSliceBeforeAssumeCapacity(items);
        }

        /// Append the slice of items to the buffer before the gap.
        /// Never invalidates element pointers.
        /// This function is only needed when calling
        /// `appendSliceBeforeAssumeCapacity` instead would be a compile error due to the
        /// alignment of the `items` parameter.
        /// Asserts that the list can hold the additional items.
        pub fn appendUnalignedSliceBeforeAssumeCapacity(self: *Self, items: []align(1) const T) void {
            const old_len = self.items.len;
            const new_len = old_len + items.len;
            assert(new_len <= self.second_start);
            self.items.len = new_len;
            @memcpy(self.items[old_len..][0..items.len], items);
        }

        pub const WriterContext = struct {
            self: *Self,
            allocator: Allocator,
        };

        pub const AfterWriter = if (T != u8)
            @compileError("The Writer interface is only defined for GapBuffer(u8) " ++
                "but the given type is GapBuffer(" ++ @typeName(T) ++ ")")
        else
            std.io.GenericWriter(WriterContext, Allocator.Error, appendWriteAfter);

        /// Initializes a Writer which will append to the list.
        pub fn afterWriter(self: *Self, allocator: Allocator) AfterWriter {
            return .{ .context = .{ .self = self, .allocator = allocator } };
        }

        pub const BeforeWriter = if (T != u8)
            @compileError("The Writer interface is only defined for GapBuffer(u8) " ++
                "but the given type is GapBuffer(" ++ @typeName(T) ++ ")")
        else
            std.io.GenericWriter(WriterContext, Allocator.Error, appendWriteBefore);

        /// Initializes a Writer which will append to the list.
        pub fn beforeWriter(self: *Self, allocator: Allocator) BeforeWriter {
            return .{ .context = .{ .self = self, .allocator = allocator } };
        }

        /// Same as `appendSliceAfter` except it returns the number of bytes written, which is always the same
        /// as `m.len`. The purpose of this function existing is to match `std.io.Writer` API.
        /// Invalidates element pointers if additional memory is needed.
        fn appendWriteAfter(context: WriterContext, m: []const u8) Allocator.Error!usize {
            try context.self.appendUnalignedSliceAfter(context.allocator, m);
            return m.len;
        }

        /// Same as `appendSliceBefore` except it returns the number of bytes written, which is always the same
        /// as `m.len`. The purpose of this function existing is to match `std.io.Writer` API.
        /// Invalidates element pointers if additional memory is needed.
        fn appendWriteBefore(context: WriterContext, m: []const u8) Allocator.Error!usize {
            try context.self.appendUnalignedSliceBefore(context.allocator, m);
            return m.len;
        }

        pub const FixedAfterWriter = if (T != u8)
            @compileError("The Writer interface is only defined for ArrayList(u8) " ++
                "but the given type is ArrayList(" ++ @typeName(T) ++ ")")
        else
            std.io.Writer(*Self, Allocator.Error, appendWriteFixedAfter);

        /// Initializes a Writer which will append to the list but will return
        /// `error.OutOfMemory` rather than increasing capacity.
        pub fn fixedAfterWriter(self: *Self) FixedAfterWriter {
            return .{ .context = self };
        }

        /// The purpose of this function existing is to match `std.io.Writer` API.
        fn appendWriteFixedAfter(self: *Self, m: []const u8) error{OutOfMemory}!usize {
            const available_capacity = self.second_start - self.items.len;
            if (m.len > available_capacity)
                return error.OutOfMemory;

            self.appendUnalignedSliceAfterAssumeCapacity(m);
            return m.len;
        }

        pub const FixedBeforeWriter = if (T != u8)
            @compileError("The Writer interface is only defined for ArrayList(u8) " ++
                "but the given type is ArrayList(" ++ @typeName(T) ++ ")")
        else
            std.io.Writer(*Self, Allocator.Error, appendWriteFixedBefore);

        /// Initializes a Writer which will append to the list but will return
        /// `error.OutOfMemory` rather than increasing capacity.
        pub fn fixedBeforeWriter(self: *Self) FixedBeforeWriter {
            return .{ .context = self };
        }

        /// The purpose of this function existing is to match `std.io.Writer` API.
        fn appendWriteFixedBefore(self: *Self, m: []const u8) error{OutOfMemory}!usize {
            const available_capacity = self.capacity - self.items.len;
            if (m.len > available_capacity)
                return error.OutOfMemory;

            self.appendUnalignedSliceBeforeAssumeCapacity(m);
            return m.len;
        }

        /// Append a value to the buffer `n` times after the gap.
        /// Allocates more memory as necessary.
        /// Invalidates element pointers if additional memory is needed.
        /// The function is inline so that a comptime-known `value` parameter will
        /// have a more optimal memset codegen in case it has a repeated byte pattern.
        pub inline fn appendAfterNTimes(self: *Self, allocator: Allocator, value: T, n: usize) Allocator.Error!void {
            const old_len = self.realLength();
            try self.resizeAfter(allocator, try addOrOom(old_len, n));
            @memset(self.items.ptr[self.second_start .. self.second_start + n], value);
        }

        /// Append a value to the buffer `n` times after the gap.
        /// Never invalidates element pointers.
        /// The function is inline so that a comptime-known `value` parameter will
        /// have a more optimal memset codegen in case it has a repeated byte pattern.
        /// Asserts that the list can hold the additional items.
        pub inline fn appendAfterNTimesAssumeCapacity(self: *Self, value: T, n: usize) void {
            const new_len = self.realLength() + n;
            assert(new_len <= self.capacity);
            @memset(self.items.ptr[self.second_start - n .. self.second_start], value);
            self.second_start -= n;
        }

        /// Append a value to the buffer `n` times before the gap.
        /// Allocates more memory as necessary.
        /// Invalidates element pointers if additional memory is needed.
        /// The function is inline so that a comptime-known `value` parameter will
        /// have a more optimal memset codegen in case it has a repeated byte pattern.
        pub inline fn appendBeforeNTimes(self: *Self, allocator: Allocator, value: T, n: usize) Allocator.Error!void {
            const old_len = self.realLength();
            try self.resizeBefore(allocator, try addOrOom(old_len, n));
            @memset(self.items[old_len..self.items.len], value);
        }

        /// Append a value to the buffer `n` times before the gap.
        /// Never invalidates element pointers.
        /// The function is inline so that a comptime-known `value` parameter will
        /// have a more optimal memset codegen in case it has a repeated byte pattern.
        /// Asserts that the list can hold the additional items.
        pub inline fn appendBeforeNTimesAssumeCapacity(self: *Self, value: T, n: usize) void {
            const new_len = self.realLength() + n;
            assert(new_len <= self.capacity);
            @memset(self.items.ptr[self.items.len..new_len], value);
            self.items.len = new_len;
        }

        /// Adjusts the list length to `new_len`.
        /// Additional elements have unspecified values and are placed after the gap.
        /// Invalidates element pointers if additional memory is needed.
        pub fn resizeAfter(self: *Self, allocator: Allocator, new_len: usize) Allocator.Error!void {
            try self.ensureTotalCapacity(allocator, new_len);
            const n = new_len - self.realLength();
            self.second_start -= n;
        }

        /// Adjusts the list length to `new_len`.
        /// Additional elements have unspecified values and are placed before the gap.
        /// Invalidates element pointers if additional memory is needed.
        pub fn resizeBefore(self: *Self, allocator: Allocator, new_len: usize) Allocator.Error!void {
            try self.ensureTotalCapacity(allocator, new_len);
            const n = new_len - self.realLength();
            self.items.len += n;
        }

        /// Reduce allocated capacity to `new_len`.
        /// May invalidate element pointers.
        /// Asserts that the new length is less than or equal to the previous length.
        /// if elements are dropped as a result, they are dropped from after the gap.
        /// asserts that there are enough items after the gap to acommodate this.
        pub fn shrinkAndFreeAfter(self: *Self, allocator: Allocator, new_len: usize) void {
            assert(new_len <= self.realLength());

            if (@sizeOf(T) == 0) {
                self.items.len = new_len;
                return;
            }

            const lost = self.realLength() - new_len;
            assert(self.second_start + lost <= self.capacity);
            self.second_start += lost;
            const old_memory = self.allocatedSlice();
            const second_half = self.secondHalf();
            mem.copyForwards(
                T,
                self.items.ptr[self.items.len..][0..second_half.len],
                second_half,
            );

            if (allocator.resize(old_memory, new_len)) {
                // leave the "gap" (which is empty) where it is
                self.capacity = new_len;
                self.second_start = self.items.len;
                return;
            }

            const new_memory = allocator.alignedAlloc(T, alignment, new_len) catch |e| switch (e) {
                error.OutOfMemory => {
                    // No problem, capacity is still correct then.
                    self.items.len = new_len;
                    // since we reduced the "gap" to size zero,
                    // we must act as though we moved it to the end.
                    self.second_start = self.capacity;
                    return;
                },
            };

            @memcpy(new_memory, self.items.ptr[0..new_len]);
            allocator.free(old_memory);
            // leave the "gap" (which is empty) where it is
            const len = self.items.len;
            self.items = new_memory[0..len];
            self.capacity = new_memory.len;
            self.second_start = len;
        }

        /// Reduce allocated capacity to `new_len`.
        /// May invalidate element pointers.
        /// Asserts that the new length is less than or equal to the previous length.
        /// if elements are dropped as a result, they are dropped from before the gap.
        /// asserts that there are enough items before the gap to acommodate this.
        pub fn shrinkAndFreeBefore(self: *Self, allocator: Allocator, new_len: usize) void {
            assert(new_len <= self.realLength());

            if (@sizeOf(T) == 0) {
                self.items.len = new_len;
                return;
            }

            const lost = self.realLength() - new_len;
            assert(self.items.len >= lost);
            self.items.len -= lost;
            const old_memory = self.allocatedSlice();
            const second_half = self.secondHalf();
            mem.copyForwards(
                T,
                self.items.ptr[self.items.len..][0..second_half.len],
                second_half,
            );

            if (allocator.resize(old_memory, new_len)) {
                // leave the "gap" (which is empty) where it is
                self.capacity = new_len;
                self.second_start = self.items.len;
                return;
            }

            const new_memory = allocator.alignedAlloc(T, alignment, new_len) catch |e| switch (e) {
                error.OutOfMemory => {
                    // No problem, capacity is still correct then.
                    self.items.len = new_len;
                    // since we reduced the "gap" to size zero,
                    // we must act as though we moved it to the end.
                    self.second_start = self.capacity;
                    return;
                },
            };

            @memcpy(new_memory, self.items.ptr[0..new_len]);
            allocator.free(old_memory);
            // leave the "gap" (which is empty) where it is
            const len = self.items.len;
            self.items = new_memory[0..len];
            self.capacity = new_memory.len;
            self.second_start = len;
        }

        /// Reduce `self.realLength()` to `new_len` by "removing" before the gap.
        /// Invalidates element pointers for the elements `items[new_len..]`.
        /// Asserts that the new length is less than or equal to the previous length.
        pub fn shrinkAfterRetainingCapacity(self: *Self, new_len: usize) void {
            assert(new_len <= self.realLength());
            const shrink_amount = self.realLength() - new_len;
            assert(self.second_start + shrink_amount <= self.capacity);
            self.second_start += shrink_amount;
        }

        /// Reduce `self.realLength()` to `new_len` by "removing" before the gap.
        /// Invalidates element pointers for the elements `items[new_len..]`.
        /// Asserts that the new length is less than or equal to the previous length.
        pub fn shrinkBeforeRetainingCapacity(self: *Self, new_len: usize) void {
            assert(new_len <= self.realLength());
            const shrink_amount = self.realLength() - new_len;
            assert(self.items.len >= shrink_amount);
            self.items.len -= shrink_amount;
        }

        /// Invalidates all element pointers.
        pub fn clearRetainingCapacity(self: *Self) void {
            self.items.len = 0;
            self.second_start = self.capacity;
        }

        /// Invalidates all element pointers.
        pub fn clearAndFree(self: *Self, allocator: Allocator) void {
            allocator.free(self.allocatedSlice());
            self.items.len = 0;
            self.second_start = 0;
            self.capacity = 0;
        }

        /// If the current capacity is less than `new_capacity`, this function will
        /// modify the buffer so that it can hold at least `new_capacity` items.
        /// Invalidates element pointers if additional memory is needed.
        pub fn ensureTotalCapacity(self: *Self, allocator: Allocator, new_capacity: usize) Allocator.Error!void {
            if (@sizeOf(T) == 0) {
                const diff = self.capacity - self.second_start;
                self.capacity = math.maxInt(usize);
                self.second_start = self.capacity - diff;
                return;
            }

            if (self.capacity >= new_capacity) return;

            const better_capacity = growCapacity(self.capacity, new_capacity);
            return self.ensureTotalCapacityPrecise(allocator, better_capacity);
        }

        /// If the capacity is less than `new_capacity`, this function will
        /// modify the buffer so that it can hold exactly `new_capacity` items.
        /// Invalidates element pointers if additional memory is needed.
        pub fn ensureTotalCapacityPrecise(self: *Self, allocator: Allocator, new_capacity: usize) Allocator.Error!void {
            if (@sizeOf(T) == 0) {
                const diff = self.capacity - self.second_start;
                self.capacity = math.maxInt(usize);
                self.second_start = self.capacity - diff;
                return;
            }

            if (self.capacity >= new_capacity) return;

            // Here we avoid copying allocated but unused bytes by
            // attempting a resize in place, and falling back to allocating
            // a new buffer and doing our own copy. With a realloc() call,
            // the allocator implementation would pointlessly copy our
            // extra capacity.
            const old_memory = self.allocatedSlice();
            const second_half = self.secondHalf();
            if (allocator.resize(old_memory, new_capacity)) {
                self.capacity = new_capacity;
                self.second_start = new_capacity - second_half.len;
                mem.copyBackwards(T, self.items.ptr[self.second_start..][0..second_half.len], second_half);
            } else {
                const new_memory = try allocator.alignedAlloc(T, alignment, new_capacity);
                @memcpy(new_memory[0..self.items.len], self.items);
                @memcpy(new_memory[new_capacity - second_half.len .. new_capacity], second_half);
                allocator.free(old_memory);
                self.items.ptr = new_memory.ptr;
                self.second_start = new_memory.len - second_half.len;
                self.capacity = new_memory.len;
            }
        }

        /// Modify the buffer so that it can hold at least `additional_count` **more** items.
        /// Invalidates element pointers if additional memory is needed.
        pub fn ensureUnusedCapacity(self: *Self, allocator: Allocator, additional_count: usize) Allocator.Error!void {
            return self.ensureTotalCapacity(allocator, try addOrOom(self.realLength(), additional_count));
        }

        /// Increase length by 1, returning pointer to the new item, which is after the gap.
        /// The returned pointer becomes invalid when the list resized.
        pub fn addOneAfter(self: *Self, allocator: Allocator) Allocator.Error!*T {
            // This can never overflow because `self.items` can never occupy the whole address space
            const newlen = self.realLength() + 1;
            try self.ensureTotalCapacity(allocator, newlen);
            return self.addOneAfterAssumeCapacity();
        }

        /// Increase length by 1, returning pointer to the new item, which is after the gap.
        /// The returned pointer becomes invalid when the list is resized.
        /// Never invalidates element pointers.
        /// Asserts that the list can hold one additional item.
        pub fn addOneAfterAssumeCapacity(self: *Self) *T {
            assert(self.realLength() < self.capacity);
            self.second_start -= 1;
            return &self.items.ptr[self.second_start];
        }

        /// Increase length by 1, returning pointer to the new item, which is before the gap.
        /// The returned pointer becomes invalid when the list resized.
        pub fn addOneBefore(self: *Self, allocator: Allocator) Allocator.Error!*T {
            // This can never overflow because `self.items` can never occupy the whole address space
            const newlen = self.realLength() + 1;
            try self.ensureTotalCapacity(allocator, newlen);
            return self.addOneBeforeAssumeCapacity();
        }

        /// Increase length by 1, returning pointer to the new item, which is before the gap.
        /// The returned pointer becomes invalid when the list is resized.
        /// Never invalidates element pointers.
        /// Asserts that the list can hold one additional item.
        pub fn addOneBeforeAssumeCapacity(self: *Self) *T {
            assert(self.realLength() < self.capacity);
            self.items.len += 1;
            return &self.items[self.items.len - 1];
        }

        /// Resize the buffer, adding `n` new elements, which have undefined values.
        /// New items are added after the gap.
        /// The return value is a slice pointing to the newly allocated elements.
        /// Resizes list if `self.capacity` is not large enough.
        pub fn addManyAsArrayAfter(self: *Self, allocator: Allocator, comptime n: usize) Allocator.Error!*[n]T {
            try self.resizeAfter(allocator, try addOrOom(self.realLength(), n));
            return self.items.ptr[self.second_start..][0..n];
        }

        /// Resize the buffer, adding `n` new elements, which have `undefined` values.
        /// New items are added after the gap.
        /// The return value is a slice pointing to the newly allocated elements.
        /// Never invalidates element pointers.
        /// The returned pointer becomes invalid when the buffer is resized.
        /// Asserts that the buffer can hold the additional items.
        pub fn addManyAsArrayAfterAssumeCapacity(self: *Self, comptime n: usize) *[n]T {
            assert(self.items.len + n <= self.second_start);
            self.second_start -= n;
            return self.items.ptr[self.second_start..][0..n];
        }

        /// Resize the buffer, adding `n` new elements, which have undefined values.
        /// New items are added before the gap.
        /// The return value is a slice pointing to the newly allocated elements.
        /// Resizes list if `self.capacity` is not large enough.
        pub fn addManyAsArrayBefore(self: *Self, allocator: Allocator, comptime n: usize) Allocator.Error!*[n]T {
            const prev_len = self.realLength();
            try self.resizeBefore(allocator, try addOrOom(prev_len, n));
            return self.items[prev_len..][0..n];
        }

        /// Resize the buffer, adding `n` new elements, which have undefined values.
        /// New items are added before the gap.
        /// The return value is a slice pointing to the newly allocated elements.
        /// Never invalidates element pointers.
        /// The returned pointer becomes invalid when the buffer is resized.
        /// Asserts that the buffer can hold the additional items.
        pub fn addManyAsArrayBeforeAssumeCapacity(self: *Self, comptime n: usize) *[n]T {
            assert(self.items.len + n <= self.second_start);
            const prev_len = self.items.len;
            self.items.len += n;
            return self.items[prev_len..][0..n];
        }

        /// Resize the buffer, adding `n` new elements, which have undefined values.
        /// New items are added after the gap.
        /// The return value is a slice pointing to the newly allocated elements.
        /// Resizes list if `self.capacity` is not large enough.
        pub fn addManyAsSliceAfter(self: *Self, allocator: Allocator, n: usize) Allocator.Error![]T {
            try self.resizeAfter(allocator, try addOrOom(self.realLength(), n));
            return self.items.ptr[self.second_start - n .. self.second_start];
        }

        /// Resize the buffer, adding `n` new elements, which have `undefined` values.
        /// New items are added after the gap.
        /// The return value is a slice pointing to the newly allocated elements.
        /// Never invalidates element pointers.
        /// The returned pointer becomes invalid when the buffer is resized.
        /// Asserts that the buffer can hold the additional items.
        pub fn addManyAsSliceAfterAssumeCapacity(self: *Self, n: usize) []T {
            assert(self.items.len + n <= self.second_start);
            self.second_start -= n;
            return self.items.ptr[self.second_start..][0..n];
        }

        /// Resize the buffer, adding `n` new elements, which have undefined values.
        /// New items are added before the gap.
        /// The return value is a slice pointing to the newly allocated elements.
        /// Resizes list if `self.capacity` is not large enough.
        pub fn addManyAsSliceBefore(self: *Self, allocator: Allocator, n: usize) Allocator.Error![]T {
            const prev_len = self.realLength();
            try self.resizeBefore(allocator, try addOrOom(prev_len, n));
            return self.items[prev_len..][0..n];
        }

        /// Resize the buffer, adding `n` new elements, which have undefined values.
        /// New items are added before the gap.
        /// The return value is a slice pointing to the newly allocated elements.
        /// Never invalidates element pointers.
        /// The returned pointer becomes invalid when the buffer is resized.
        /// Asserts that the buffer can hold the additional items.
        pub fn addManyAsSliceBeforeAssumeCapacity(self: *Self, n: usize) []T {
            assert(self.items.len + n <= self.second_start);
            const prev_len = self.items.len;
            self.items.len += n;
            return self.items[prev_len..][0..n];
        }
        /// Remove and return the first element after the gap.
        /// Asserts that there is one.
        pub fn popAfter(self: *Self) T {
            assert(self.second_start < self.capacity);
            const val = self.items.ptr[self.second_start];
            self.second_start += 1;
            return val;
        }

        /// Remove and return the first element after the gap
        /// or return `null` if there is none.
        pub fn popAfterOrNull(self: *Self) ?T {
            if (self.second_start == self.capacity) return null;
            return self.popAfter();
        }

        /// Remove and return the last element from before the gap.
        /// Asserts that there is one.
        pub fn popBefore(self: *Self) T {
            const val = self.items[self.items.len - 1];
            self.items.len -= 1;
            return val;
        }

        /// Remove and return the last element from before the gap
        /// or return `null` if there is none.
        pub fn popBeforeOrnull(self: *Self) ?T {
            if (self.items.len == 0) return null;
            return self.popBefore();
        }

        /// Returns a slice of the entire capacity, including the gap,
        /// whose contents are undefined (if not precisely `undefined`).
        pub fn allocatedSlice(self: Self) Slice {
            return self.items.ptr[0..self.capacity];
        }

        /// Returns the element at the specified index
        pub fn getAt(self: Self, index: usize) T {
            return self.items.ptr[self.realIndex(index)];
        }

        /// Returns a pointer to the element at the specified index
        /// will be invalidated if the gap moves
        pub fn getAtPtr(self: Self, index: usize) *T {
            return &self.items.ptr[self.realIndex(index)];
        }

        /// Returns the first element after the gap.
        /// Asserts that there is one.
        pub fn getAfter(self: Self) T {
            return self.items.ptr[self.second_start];
        }

        /// Returns the first element after the gap, or `null` if there is none.
        pub fn getAfterOrNull(self: Self) ?T {
            if (self.second_start == self.capacity) return null;
            return self.getAfter();
        }

        /// Returns the last element before the gap.
        /// Asserts that there is one.
        pub fn getBefore(self: Self) T {
            const val = self.items[self.items.len - 1];
            return val;
        }

        /// Returns the last element before the gap, or `null` if there is none.
        pub fn getBeforeOrNull(self: Self) ?T {
            if (self.items.len == 0) return null;
            return self.getBefore();
        }
    };
}

/// Called when memory growth is necessary. Returns a capacity larger than minimum
/// that grows super-linearly.
fn growCapacity(current: usize, minimum: usize) usize {
    var new = current;
    while (true) {
        new +|= new / 2 + 8;
        if (new >= minimum)
            return new;
    }
}

/// Integer addition returning `error.OutOfMemory` on overflow
fn addOrOom(a: usize, b: usize) error{OutOfMemory}!usize {
    const res, const overflow = @addWithOverflow(a, b);
    if (overflow != 0) return error.OutOfMemory;
    return res;
}

test "init" {
    {
        var buffer = GapBuffer(i32).init(testing.allocator);
        defer buffer.deinit();

        try testing.expect(buffer.items.len == 0);
        try testing.expect(buffer.capacity == 0);
        try testing.expect(buffer.second_start == 0);
    }

    {
        const buffer = GapBufferUnmanaged(i32){};

        try testing.expect(buffer.items.len == 0);
        try testing.expect(buffer.capacity == 0);
        try testing.expect(buffer.second_start == 0);
    }
}

test "initCapacity" {
    const a = testing.allocator;
    {
        var buffer = try GapBuffer(i8).initCapacity(a, 200);
        defer buffer.deinit();
        try testing.expect(buffer.items.len == 0);
        try testing.expect(buffer.capacity >= 200);
        try testing.expect(buffer.second_start >= 200);
    }
    {
        var buffer = try GapBufferUnmanaged(i8).initCapacity(a, 200);
        defer buffer.deinit(a);
        try testing.expect(buffer.items.len == 0);
        try testing.expect(buffer.capacity >= 200);
        try testing.expect(buffer.second_start >= 200);
    }
}

test "clone" {
    const a = testing.allocator;
    {
        var buffer = GapBuffer(i32).init(a);
        try buffer.appendBefore(-1);
        try buffer.appendAfter(3);
        try buffer.appendBefore(5);

        const cloned = try buffer.clone();
        defer cloned.deinit();

        try testing.expectEqualSlices(i32, buffer.items, cloned.items);
        try testing.expectEqual(buffer.allocator, cloned.allocator);
        try testing.expect(cloned.capacity >= buffer.capacity);

        buffer.deinit();

        try testing.expectEqual(@as(i32, -1), cloned.items[0]);
        try testing.expectEqual(@as(i32, 5), cloned.items[1]);
        try testing.expectEqual(@as(i32, 3), cloned.items.ptr[cloned.realIndex(2)]);
    }
    {
        var buffer = GapBufferUnmanaged(i32){};
        try buffer.appendBefore(a, -1);
        try buffer.appendAfter(a, 3);
        try buffer.appendBefore(a, 5);

        var cloned = try buffer.clone(a);
        defer cloned.deinit(a);

        try testing.expectEqualSlices(i32, buffer.items, cloned.items);
        try testing.expect(cloned.capacity >= buffer.capacity);

        buffer.deinit(a);

        try testing.expectEqual(@as(i32, -1), cloned.items[0]);
        try testing.expectEqual(@as(i32, 5), cloned.items[1]);
        try testing.expectEqual(@as(i32, 3), cloned.items.ptr[cloned.realIndex(2)]);
    }
}

test "basic" {
    const a = testing.allocator;
    {
        var buffer = GapBuffer(i32).init(a);
        defer buffer.deinit();

        {
            var i: usize = 0;
            while (i < 10) : (i += 1) {
                buffer.appendBefore(@as(i32, @intCast(i + 1))) catch unreachable;
            }
        }

        {
            var i: usize = 0;
            while (i < 10) : (i += 1) {
                try testing.expect(buffer.items[i] == @as(i32, @intCast(i + 1)));
            }
        }

        for (buffer.items, 0..) |v, i| {
            try testing.expect(v == @as(i32, @intCast(i + 1)));
        }

        try testing.expect(buffer.popBefore() == 10);
        try testing.expect(buffer.items.len == 9);

        buffer.appendSliceAfter(&[_]i32{ 1, 2, 3 }) catch unreachable;
        try testing.expect(buffer.items.len == 9);
        try testing.expect(buffer.realLength() == 12);
        try testing.expect(buffer.popAfter() == 1);
        try testing.expect(buffer.popAfter() == 2);
        try testing.expect(buffer.popAfter() == 3);
        try testing.expect(buffer.items.len == 9);

        var unaligned: [3]i32 align(1) = [_]i32{ 4, 5, 6 };
        buffer.appendUnalignedSliceBefore(&unaligned) catch unreachable;
        try testing.expect(buffer.items.len == 12);
        try testing.expect(buffer.popBefore() == 6);
        try testing.expect(buffer.popBefore() == 5);
        try testing.expect(buffer.popBefore() == 4);
        try testing.expect(buffer.items.len == 9);

        buffer.appendSliceBefore(&[_]i32{}) catch unreachable;
        try testing.expect(buffer.items.len == 9);

        // can only set on indices < self.items.len
        buffer.items[7] = 33;
        buffer.items[8] = 42;

        try testing.expect(buffer.popBefore() == 42);
        try testing.expect(buffer.popBefore() == 33);
    }
    {
        var buffer = GapBufferUnmanaged(i32){};
        defer buffer.deinit(a);

        {
            var i: usize = 0;
            while (i < 10) : (i += 1) {
                buffer.appendAfter(a, @as(i32, @intCast(i + 1))) catch unreachable;
            }
        }

        {
            var i: usize = 0;
            while (i < 10) : (i += 1) {
                const j = buffer.realIndex(i);
                try testing.expect(buffer.items.ptr[j] == @as(i32, @intCast(10 - i)));
            }
        }

        for (buffer.secondHalf(), 0..) |v, i| {
            try testing.expect(v == @as(i32, @intCast(10 - i)));
        }

        try testing.expect(buffer.popAfter() == 10);
        try testing.expect(buffer.secondHalf().len == 9);

        buffer.appendSliceBefore(a, &[_]i32{ 1, 2, 3 }) catch unreachable;
        try testing.expect(buffer.realLength() == 12);
        try testing.expect(buffer.popBefore() == 3);
        try testing.expect(buffer.popBefore() == 2);
        try testing.expect(buffer.popBefore() == 1);
        try testing.expect(buffer.realLength() == 9);

        var unaligned: [3]i32 align(1) = [_]i32{ 4, 5, 6 };
        buffer.appendUnalignedSliceBefore(a, &unaligned) catch unreachable;
        try testing.expect(buffer.realLength() == 12);
        try testing.expect(buffer.popBefore() == 6);
        try testing.expect(buffer.popBefore() == 5);
        try testing.expect(buffer.popBefore() == 4);
        try testing.expect(buffer.realLength() == 9);

        buffer.appendSliceAfter(a, &[_]i32{}) catch unreachable;
        try testing.expect(buffer.realLength() == 9);

        // can only set on indices < second_half.len
        const second_half = buffer.secondHalf();
        second_half[1] = 33;
        second_half[0] = 42;

        try testing.expect(buffer.popAfter() == 42);
        try testing.expect(buffer.popAfter() == 33);
    }
}

test "appendNTimes" {
    const a = testing.allocator;
    {
        var buffer = GapBuffer(i32).init(a);
        defer buffer.deinit();

        try buffer.appendBeforeNTimes(2, 10);
        try testing.expectEqual(@as(usize, 10), buffer.items.len);
        for (buffer.items) |element| {
            try testing.expectEqual(@as(i32, 2), element);
        }
    }
    {
        var buffer = GapBufferUnmanaged(i32){};
        defer buffer.deinit(a);

        try buffer.appendAfterNTimes(a, 2, 10);
        try testing.expectEqual(@as(usize, 10), buffer.secondHalf().len);
        for (buffer.secondHalf()) |element| {
            try testing.expectEqual(@as(i32, 2), element);
        }
    }
}

test "appendNTimes with failing allocator" {
    const a = testing.failing_allocator;
    {
        var buffer = GapBuffer(i32).init(a);
        defer buffer.deinit();
        try testing.expectError(error.OutOfMemory, buffer.appendAfterNTimes(2, 10));
    }
    {
        var buffer = GapBufferUnmanaged(i32){};
        defer buffer.deinit(a);
        try testing.expectError(error.OutOfMemory, buffer.appendBeforeNTimes(a, 2, 10));
    }
}

test "orderedRemove" {
    const a = testing.allocator;
    {
        var buffer = GapBuffer(i32).init(a);
        defer buffer.deinit();

        try buffer.appendBefore(1);
        try buffer.appendBefore(2);
        try buffer.appendBefore(3);
        try buffer.appendBefore(4);
        try buffer.appendBefore(5);
        try buffer.appendBefore(6);
        try buffer.appendAfter(7);

        //remove from middle
        try testing.expectEqual(@as(i32, 4), buffer.orderedRemove(3));
        try testing.expectEqual(@as(i32, 5), buffer.items.ptr[buffer.realIndex(3)]);
        try testing.expectEqual(@as(usize, 6), buffer.realLength());

        //remove from end
        try testing.expectEqual(@as(i32, 7), buffer.orderedRemove(5));
        try testing.expectEqual(@as(usize, 5), buffer.realLength());

        //remove from front
        try testing.expectEqual(@as(i32, 1), buffer.orderedRemove(0));
        try testing.expectEqual(@as(i32, 2), buffer.items.ptr[buffer.realIndex(0)]);
        try testing.expectEqual(@as(usize, 4), buffer.realLength());
    }
    {
        var buffer = GapBufferUnmanaged(i32){};
        defer buffer.deinit(a);

        try buffer.appendBefore(a, 1);
        try buffer.appendBefore(a, 2);
        try buffer.appendBefore(a, 3);
        try buffer.appendBefore(a, 4);
        try buffer.appendBefore(a, 5);
        try buffer.appendBefore(a, 6);
        try buffer.appendAfter(a, 7);

        //remove from middle
        try testing.expectEqual(@as(i32, 4), buffer.orderedRemove(3));
        try testing.expectEqual(@as(i32, 5), buffer.items.ptr[buffer.realIndex(3)]);
        try testing.expectEqual(@as(usize, 6), buffer.realLength());

        //remove from end
        try testing.expectEqual(@as(i32, 7), buffer.orderedRemove(5));
        try testing.expectEqual(@as(usize, 5), buffer.realLength());

        //remove from front
        try testing.expectEqual(@as(i32, 1), buffer.orderedRemove(0));
        try testing.expectEqual(@as(i32, 2), buffer.items.ptr[buffer.realIndex(0)]);
        try testing.expectEqual(@as(usize, 4), buffer.realLength());
    }
    {
        // remove last item
        var buffer = GapBuffer(i32).init(a);
        defer buffer.deinit();
        try buffer.appendBefore(1);
        try testing.expectEqual(@as(i32, 1), buffer.orderedRemove(0));
        try testing.expectEqual(@as(usize, 0), buffer.realLength());
    }
    {
        // remove last item
        var buffer = GapBufferUnmanaged(i32){};
        defer buffer.deinit(a);
        try buffer.appendAfter(a, 1);
        try testing.expectEqual(@as(i32, 1), buffer.orderedRemove(0));
        try testing.expectEqual(@as(usize, 0), buffer.realLength());
    }
}

test "swapRemove" {
    const a = testing.allocator;
    {
        var buffer = GapBuffer(i32).init(a);
        defer buffer.deinit();

        try buffer.appendAfter(1);
        try buffer.appendAfter(2);
        try buffer.appendAfter(3);
        try buffer.appendAfter(4);
        try buffer.appendAfter(5);
        try buffer.appendAfter(6);
        try buffer.appendBefore(7);

        //remove from middle
        try testing.expectEqual(4, buffer.swapRemoveBefore(3));
        try testing.expectEqual(7, buffer.getAt(2));
        try testing.expectEqual(6, buffer.realLength());

        //remove from end
        try testing.expectEqual(1, buffer.swapRemoveAfter(5));
        try testing.expectEqual(5, buffer.realLength());

        //remove from front
        try testing.expectEqual(5, buffer.swapRemoveAfter(0));
        try testing.expectEqual(7, buffer.getAt(0));
        try testing.expect(buffer.realLength() == 4);
    }
    {
        var buffer = GapBufferUnmanaged(i32){};
        defer buffer.deinit(a);

        try buffer.appendBefore(a, 1);
        try buffer.appendBefore(a, 2);
        try buffer.appendBefore(a, 3);
        try buffer.appendBefore(a, 4);
        try buffer.appendBefore(a, 5);
        try buffer.appendBefore(a, 6);
        try buffer.appendAfter(a, 7);

        //remove from middle
        try testing.expect(buffer.swapRemoveAfter(3) == 4);
        try testing.expect(buffer.getAt(3) == 7);
        try testing.expect(buffer.realLength() == 6);

        //remove from end
        try testing.expect(buffer.swapRemoveBefore(5) == 6);
        try testing.expect(buffer.realLength() == 5);

        //remove from front
        try testing.expect(buffer.swapRemoveBefore(0) == 1);
        try testing.expectEqual(5, buffer.getAt(0));
        try testing.expect(buffer.realLength() == 4);
    }
}

test "insert" {
    const a = testing.allocator;
    {
        var buffer = GapBuffer(i32).init(a);
        defer buffer.deinit();

        try buffer.insertAfter(0, 1);
        try buffer.appendBefore(2);
        try buffer.insertBefore(2, 3);
        try buffer.insertAfter(0, 5);
        try testing.expect(buffer.getAt(0) == 5);
        try testing.expect(buffer.getAt(1) == 2);
        try testing.expect(buffer.getAt(2) == 1);

        try testing.expectEqual(3, buffer.getAt(3));
    }
    {
        var buffer = GapBufferUnmanaged(i32){};
        defer buffer.deinit(a);

        try buffer.insertBefore(a, 0, 1);
        try buffer.appendAfter(a, 2);
        try buffer.insertBefore(a, 2, 3);
        try buffer.insertAfter(a, 0, 5);
        try testing.expect(buffer.getAt(0) == 5);
        try testing.expect(buffer.getAt(1) == 1);
        try testing.expect(buffer.getAt(2) == 2);
        try testing.expect(buffer.getAt(3) == 3);
    }
}

test "insertSlice" {
    const a = testing.allocator;
    {
        var buffer = GapBuffer(i32).init(a);
        defer buffer.deinit();

        try buffer.appendBefore(1);
        try buffer.appendBefore(2);
        try buffer.appendAfter(3);
        try buffer.appendAfter(4);
        try buffer.insertSliceAfter(1, &[_]i32{ 9, 8 });
        try testing.expect(buffer.getAt(0) == 1);
        try testing.expect(buffer.getAt(1) == 9);
        try testing.expect(buffer.getAt(2) == 8);
        try testing.expect(buffer.getAt(3) == 2);
        try testing.expect(buffer.getAt(4) == 4);
        try testing.expect(buffer.getAt(5) == 3);

        const items = [_]i32{69};
        try buffer.insertSliceBefore(0, items[0..0]);
        try testing.expect(buffer.realLength() == 6);
        try testing.expect(buffer.getAt(0) == 1);
    }
    {
        var buffer = GapBufferUnmanaged(i32){};
        defer buffer.deinit(a);

        try buffer.appendBefore(a, 1);
        try buffer.appendBefore(a, 2);
        try buffer.appendAfter(a, 3);
        try buffer.appendAfter(a, 4);
        try buffer.insertSliceBefore(a, 1, &[_]i32{ 9, 8 });
        try testing.expect(buffer.getAt(0) == 1);
        try testing.expect(buffer.getAt(1) == 9);
        try testing.expect(buffer.getAt(2) == 8);
        try testing.expect(buffer.getAt(3) == 2);
        try testing.expect(buffer.getAt(4) == 4);
        try testing.expect(buffer.getAt(5) == 3);

        const items = [_]i32{69};
        try buffer.insertSliceAfter(a, 0, items[0..0]);
        try testing.expect(buffer.realLength() == 6);
        try testing.expect(buffer.getAt(0) == 1);
    }
}

test "replaceRange" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const init = [_]i32{ 1, 2, 3, 4, 5 };
    const new = [_]i32{ 0, 0, 0 };

    const result_zero = [_]i32{ 1, 0, 0, 0, 2, 3, 4, 5 };
    const result_eq = [_]i32{ 1, 0, 0, 0, 5 };
    const result_le = [_]i32{ 1, 0, 0, 0, 4, 5 };
    const result_gt = [_]i32{ 1, 0, 0, 0 };

    {
        var buffer_zero = GapBuffer(i32).init(a);
        var buffer_eq = GapBuffer(i32).init(a);
        var buffer_lt = GapBuffer(i32).init(a);
        var buffer_gt = GapBuffer(i32).init(a);

        try buffer_zero.appendSliceBefore(&init);
        try buffer_eq.appendSliceAfter(&init);
        try buffer_lt.appendSliceBefore(&init);
        try buffer_gt.appendSliceAfter(&init);

        try buffer_zero.replaceRangeBefore(1, 0, &new);
        try buffer_eq.replaceRangeAfter(1, 3, &new);
        try buffer_lt.replaceRangeBefore(1, 2, &new);

        // after_range > new_items.len in function body
        try testing.expect(1 + 4 > new.len);
        try buffer_gt.replaceRangeBefore(1, 4, &new);

        try testing.expectEqualSlices(i32, try buffer_zero.toOwnedSlice(), &result_zero);
        try testing.expectEqualSlices(i32, try buffer_eq.toOwnedSlice(), &result_eq);
        try testing.expectEqualSlices(i32, try buffer_lt.toOwnedSlice(), &result_le);
        try testing.expectEqualSlices(i32, try buffer_gt.toOwnedSlice(), &result_gt);
    }
    {
        var buffer_zero = GapBufferUnmanaged(i32){};
        var buffer_eq = GapBufferUnmanaged(i32){};
        var buffer_lt = GapBufferUnmanaged(i32){};
        var buffer_gt = GapBufferUnmanaged(i32){};

        try buffer_zero.appendSliceBefore(a, &init);
        try buffer_eq.appendSliceAfter(a, &init);
        try buffer_lt.appendSliceBefore(a, &init);
        try buffer_gt.appendSliceAfter(a, &init);

        try buffer_zero.replaceRangeBefore(a, 1, 0, &new);
        try buffer_eq.replaceRangeAfter(a, 1, 3, &new);
        try buffer_lt.replaceRangeBefore(a, 1, 2, &new);

        // after_range > new_items.len in function body
        try testing.expect(1 + 4 > new.len);
        try buffer_gt.replaceRangeAfter(a, 1, 4, &new);

        try testing.expectEqualSlices(i32, try buffer_zero.toOwnedSlice(a), &result_zero);
        try testing.expectEqualSlices(i32, try buffer_eq.toOwnedSlice(a), &result_eq);
        try testing.expectEqualSlices(i32, try buffer_lt.toOwnedSlice(a), &result_le);
        try testing.expectEqualSlices(i32, try buffer_gt.toOwnedSlice(a), &result_gt);
    }

    {
        var buffer_zero = GapBuffer(i32).init(a);
        var buffer_eq = GapBuffer(i32).init(a);
        var buffer_lt = GapBuffer(i32).init(a);
        var buffer_gt = GapBuffer(i32).init(a);

        try buffer_zero.appendSliceBefore(&init);
        try buffer_eq.appendSliceAfter(&init);
        try buffer_lt.appendSliceBefore(&init);
        try buffer_gt.appendSliceAfter(&init);

        buffer_zero.replaceRangeBeforeAssumeCapacity(1, 0, &new);
        buffer_eq.replaceRangeAfterAssumeCapacity(1, 3, &new);
        buffer_lt.replaceRangeBeforeAssumeCapacity(1, 2, &new);

        // after_range > new_items.len in function body
        try testing.expect(1 + 4 > new.len);
        buffer_gt.replaceRangeAfterAssumeCapacity(1, 4, &new);

        try testing.expectEqualSlices(i32, try buffer_zero.toOwnedSlice(), &result_zero);
        try testing.expectEqualSlices(i32, try buffer_eq.toOwnedSlice(), &result_eq);
        try testing.expectEqualSlices(i32, try buffer_lt.toOwnedSlice(), &result_le);
        try testing.expectEqualSlices(i32, try buffer_gt.toOwnedSlice(), &result_gt);
    }
    {
        var buffer_zero = GapBufferUnmanaged(i32){};
        var buffer_eq = GapBufferUnmanaged(i32){};
        var buffer_lt = GapBufferUnmanaged(i32){};
        var buffer_gt = GapBufferUnmanaged(i32){};

        try buffer_zero.appendSliceBefore(a, &init);
        try buffer_eq.appendSliceAfter(a, &init);
        try buffer_lt.appendSliceBefore(a, &init);
        try buffer_gt.appendSliceAfter(a, &init);

        buffer_zero.replaceRangeBeforeAssumeCapacity(1, 0, &new);
        buffer_eq.replaceRangeAfterAssumeCapacity(1, 3, &new);
        buffer_lt.replaceRangeBeforeAssumeCapacity(1, 2, &new);

        // after_range > new_items.len in function body
        try testing.expect(1 + 4 > new.len);
        buffer_gt.replaceRangeAfterAssumeCapacity(1, 4, &new);

        try testing.expectEqualSlices(i32, try buffer_zero.toOwnedSlice(a), &result_zero);
        try testing.expectEqualSlices(i32, try buffer_eq.toOwnedSlice(a), &result_eq);
        try testing.expectEqualSlices(i32, try buffer_lt.toOwnedSlice(a), &result_le);
        try testing.expectEqualSlices(i32, try buffer_gt.toOwnedSlice(a), &result_gt);
    }
}

const Item = struct {
    integer: i32,
    sub_items: GapBuffer(Item),
};

const ItemUnmanaged = struct {
    integer: i32,
    sub_items: GapBufferUnmanaged(ItemUnmanaged),
};

test "GapBuffer(T) of struct T" {
    const a = std.testing.allocator;
    {
        var root = Item{ .integer = 1, .sub_items = GapBuffer(Item).init(a) };
        defer root.sub_items.deinit();
        try root.sub_items.appendBefore(Item{ .integer = 42, .sub_items = GapBuffer(Item).init(a) });
        try testing.expect(root.sub_items.getAt(0).integer == 42);
    }
    {
        var root = ItemUnmanaged{ .integer = 1, .sub_items = GapBufferUnmanaged(ItemUnmanaged){} };
        defer root.sub_items.deinit(a);
        try root.sub_items.appendAfter(a, ItemUnmanaged{ .integer = 42, .sub_items = GapBufferUnmanaged(ItemUnmanaged){} });
        try testing.expect(root.sub_items.getAt(0).integer == 42);
    }
}

test "GapBuffer(u8) implements writer" {
    const a = testing.allocator;

    {
        var buffer = GapBuffer(u8).init(a);
        defer buffer.deinit();

        const x: i32 = 42;
        const y: i32 = 1234;
        try buffer.beforeWriter().print("x: {}\ny: {}\n", .{ x, y });

        try testing.expectEqualSlices(u8, "x: 42\ny: 1234\n", buffer.items);
    }
    {
        var buffer = GapBufferAligned(u8, 2).init(a);
        defer buffer.deinit();

        const writer = buffer.afterWriter();

        try writer.writeAll("efg");
        try writer.writeAll("d");
        try writer.writeAll("bc");
        try writer.writeAll("a");

        try testing.expectEqualSlices(u8, buffer.secondHalf(), "abcdefg");
    }
}

test "GapBufferUnmanaged(u8) implements writer" {
    const a = testing.allocator;

    {
        var buffer: GapBufferUnmanaged(u8) = .{};
        defer buffer.deinit(a);

        const x: i32 = 42;
        const y: i32 = 1234;
        try buffer.beforeWriter(a).print("x: {}\ny: {}\n", .{ x, y });

        try testing.expectEqualSlices(u8, "x: 42\ny: 1234\n", buffer.items);
    }
    {
        var buffer: GapBufferAlignedUnmanaged(u8, 2) = .{};
        defer buffer.deinit(a);

        const writer = buffer.beforeWriter(a);
        try writer.writeAll("a");
        try writer.writeAll("bc");
        try writer.writeAll("d");
        try writer.writeAll("efg");

        try testing.expectEqualSlices(u8, buffer.items, "abcdefg");
    }
}

test "shrink still sets length when resizing is disabled" {
    var failing_allocator = testing.FailingAllocator.init(testing.allocator, .{ .resize_fail_index = 0 });
    const a = failing_allocator.allocator();

    {
        var buffer = GapBuffer(i32).init(a);
        defer buffer.deinit();

        try buffer.appendBefore(1);
        try buffer.appendAfter(2);
        try buffer.appendBefore(3);

        buffer.shrinkAndFreeBefore(1);
        try testing.expect(buffer.realLength() == 1);
    }
    {
        var buffer = GapBufferUnmanaged(i32){};
        defer buffer.deinit(a);

        try buffer.appendBefore(a, 1);
        try buffer.appendAfter(a, 2);
        try buffer.appendBefore(a, 3);

        buffer.shrinkAndFreeBefore(a, 1);
        try testing.expect(buffer.realLength() == 1);
    }
}

test "shrinkAndFree with a copy" {
    var failing_allocator = testing.FailingAllocator.init(testing.allocator, .{ .resize_fail_index = 0 });
    const a = failing_allocator.allocator();

    var buffer = GapBuffer(i32).init(a);
    defer buffer.deinit();

    try buffer.appendAfterNTimes(3, 16);
    buffer.shrinkAndFreeAfter(4);
    try testing.expect(mem.eql(i32, buffer.secondHalf(), &.{ 3, 3, 3, 3 }));
}

test "addManyAsArray" {
    const a = std.testing.allocator;
    {
        var buffer = GapBuffer(u8).init(a);

        (try buffer.addManyAsArrayAfter(4)).* = "aoeu".*;
        try buffer.ensureTotalCapacity(8);
        buffer.addManyAsArrayBeforeAssumeCapacity(4).* = "asdf".*;

        const got = try buffer.toOwnedSlice();
        defer a.free(got);
        try testing.expectEqualSlices(u8, "asdfaoeu", got);
    }
    {
        var buffer = GapBufferUnmanaged(u8){};

        (try buffer.addManyAsArrayAfter(a, 4)).* = "aoeu".*;
        try buffer.ensureTotalCapacity(a, 8);
        buffer.addManyAsArrayBeforeAssumeCapacity(4).* = "asdf".*;

        const got = try buffer.toOwnedSlice(a);
        defer a.free(got);
        try testing.expectEqualSlices(u8, "asdfaoeu", got);
    }
}

test "growing memory preserves contents" {
    // Shrink the buffer after every insertion to ensure that a memory growth
    // will be triggered in the next operation.
    const a = std.testing.allocator;
    {
        var buffer = GapBuffer(u8).init(a);
        defer buffer.deinit();

        (try buffer.addManyAsArrayBefore(4)).* = "abcd".*;
        buffer.shrinkAndFreeAfter(4);

        try buffer.appendSliceBefore("efgh");
        try testing.expectEqualSlices(u8, buffer.items, "abcdefgh");
        buffer.shrinkAndFreeBefore(8);

        try buffer.insertSliceAfter(4, "ijkl");
        try testing.expectEqualSlices(u8, buffer.items, "abcd");
        try testing.expectEqualSlices(u8, buffer.secondHalf(), "ijklefgh");
    }
    {
        var buffer = GapBufferUnmanaged(u8){};
        defer buffer.deinit(a);

        (try buffer.addManyAsArrayAfter(a, 4)).* = "abcd".*;
        buffer.shrinkAndFreeBefore(a, 4);

        try buffer.appendSliceBefore(a, "efgh");
        try testing.expectEqualSlices(u8, "efgh", buffer.items);
        try testing.expectEqualSlices(u8, "abcd", buffer.secondHalf());
        buffer.shrinkAndFreeAfter(a, 8);

        try buffer.insertSliceBefore(a, 4, "ijkl");
        try testing.expectEqualSlices(u8, "efghijkl", buffer.items);
        try testing.expectEqualSlices(u8, "abcd", buffer.secondHalf());
    }
}

test "fromOwnedSlice" {
    const a = testing.allocator;
    {
        var orig_buffer = GapBuffer(u8).init(a);
        defer orig_buffer.deinit();
        try orig_buffer.appendSliceBefore("foobar");

        const slice = try orig_buffer.toOwnedSlice();
        var buffer = GapBuffer(u8).fromOwnedSlice(a, slice);
        defer buffer.deinit();
        try testing.expectEqualStrings(buffer.items, "foobar");
    }
    {
        var buffer = GapBuffer(u8).init(a);
        defer buffer.deinit();
        try buffer.appendSliceAfter("foobar");

        const slice = try buffer.toOwnedSlice();
        var unmanaged = GapBufferUnmanaged(u8).fromOwnedSlice(slice);
        defer unmanaged.deinit(a);
        try testing.expectEqualStrings(unmanaged.items, "foobar");
    }
}

test "fromOwnedSliceSentinel" {
    const a = testing.allocator;
    {
        var orig_buffer = GapBuffer(u8).init(a);
        defer orig_buffer.deinit();
        try orig_buffer.appendSliceAfter("foobar");

        const sentinel_slice = try orig_buffer.toOwnedSliceSentinel(0);
        var buffer = GapBuffer(u8).fromOwnedSliceSentinel(a, 0, sentinel_slice);
        defer buffer.deinit();
        try testing.expectEqualStrings(buffer.items, "foobar");
    }
    {
        var buffer = GapBuffer(u8).init(a);
        defer buffer.deinit();
        try buffer.appendSliceBefore("foobar");

        const sentinel_slice = try buffer.toOwnedSliceSentinel(0);
        var unmanaged = GapBufferUnmanaged(u8).fromOwnedSliceSentinel(0, sentinel_slice);
        defer unmanaged.deinit(a);
        try testing.expectEqualStrings(unmanaged.items, "foobar");
    }
}

test "toOwnedSliceSentinel" {
    const a = testing.allocator;
    {
        var buffer = GapBuffer(u8).init(a);
        defer buffer.deinit();

        try buffer.appendSliceBefore("foobar");

        const result = try buffer.toOwnedSliceSentinel(0);
        defer a.free(result);
        try testing.expectEqualStrings(result, mem.sliceTo(result.ptr, 0));
    }
    {
        var buffer = GapBufferUnmanaged(u8){};
        defer buffer.deinit(a);

        try buffer.appendSliceAfter(a, "foobar");

        const result = try buffer.toOwnedSliceSentinel(a, 0);
        defer a.free(result);
        try testing.expectEqualStrings(result, mem.sliceTo(result.ptr, 0));
    }
}

test "accepts unaligned slices" {
    const a = testing.allocator;
    {
        var buffer = GapBufferAligned(u8, 8).init(a);

        try buffer.appendSliceBefore(&.{ 0, 1, 2, 3 });
        try buffer.insertSliceBefore(2, &.{ 4, 5, 6, 7 });
        try buffer.replaceRangeBefore(1, 3, &.{ 8, 9 });

        const got = try buffer.toOwnedSlice();
        defer a.free(got);
        try testing.expectEqualSlices(u8, &.{ 0, 8, 9, 6, 7, 2, 3 }, got);
    }
    {
        var buffer = GapBufferAlignedUnmanaged(u8, 8){};

        try buffer.appendSliceAfter(a, &.{ 0, 1, 2, 3 });
        try buffer.insertSliceAfter(a, 2, &.{ 4, 5, 6, 7 });
        try buffer.replaceRangeAfter(a, 1, 3, &.{ 8, 9 });

        const got = try buffer.toOwnedSlice(a);
        defer a.free(got);
        try testing.expectEqualSlices(u8, &.{ 0, 8, 9, 6, 7, 2, 3 }, got);
    }
}

test "GapBuffer(u0)" {
    // An GapBuffer on zero-sized types should not need to allocate
    const a = testing.failing_allocator;

    var buffer = GapBuffer(u0).init(a);
    defer buffer.deinit();

    try buffer.appendBefore(0);
    try buffer.appendAfter(0);
    try buffer.appendBefore(0);
    try testing.expectEqual(buffer.realLength(), 3);

    var count: usize = 0;
    for (0..buffer.realLength()) |i| {
        const x = buffer.getAt(i);
        try testing.expectEqual(x, 0);
        count += 1;
    }
    try testing.expectEqual(count, 3);
}

test "GapBuffer(?u32).popOrNull()" {
    const a = testing.allocator;

    var buffer = GapBuffer(?u32).init(a);
    defer buffer.deinit();

    try buffer.appendBefore(null);
    try buffer.appendBefore(1);
    try buffer.appendBefore(2);
    try testing.expectEqual(buffer.items.len, 3);

    try testing.expect(buffer.popBeforeOrNull().? == @as(u32, 2));
    try testing.expect(buffer.popBeforeOrNull().? == @as(u32, 1));
    try testing.expect(buffer.popBeforeOrNull().? == null);
    try testing.expect(buffer.popBeforeOrNull() == null);
}

test "GapBuffer(u32).getLast()" {
    const a = testing.allocator;

    var buffer = GapBuffer(u32).init(a);
    defer buffer.deinit();

    try buffer.appendAfter(2);
    const const_buffer = buffer;
    try testing.expectEqual(const_buffer.getAfter(), 2);
}

test "GapBuffer(u32).getLastOrNull()" {
    const a = testing.allocator;

    var buffer = GapBuffer(u32).init(a);
    defer buffer.deinit();

    try testing.expectEqual(buffer.getAfterOrNull(), null);

    try buffer.appendAfter(2);
    const const_buffer = buffer;
    try testing.expectEqual(const_buffer.getAfterOrNull().?, 2);
}

test "return OutOfMemory when capacity would exceed maximum usize integer value" {
    const a = testing.allocator;
    const new_item: u32 = 42;
    const items = &.{ 42, 43 };

    {
        var buffer: GapBufferUnmanaged(u32) = .{
            .items = undefined,
            .capacity = math.maxInt(usize) - 1,
            .second_start = math.maxInt(usize) - 1,
        };
        buffer.items.len = math.maxInt(usize) - 1;

        try testing.expectError(error.OutOfMemory, buffer.appendSliceBefore(a, items));
        try testing.expectError(error.OutOfMemory, buffer.appendAfterNTimes(a, new_item, 2));
        try testing.expectError(error.OutOfMemory, buffer.appendUnalignedSliceAfter(a, &.{ new_item, new_item }));
        try testing.expectError(error.OutOfMemory, buffer.addManyAtBefore(a, 0, 2));
        try testing.expectError(error.OutOfMemory, buffer.addManyAsArrayAfter(a, 2));
        try testing.expectError(error.OutOfMemory, buffer.addManyAsSliceBefore(a, 2));
        try testing.expectError(error.OutOfMemory, buffer.insertSliceBefore(a, 0, items));
        try testing.expectError(error.OutOfMemory, buffer.ensureUnusedCapacity(a, 2));
    }

    {
        var buffer: GapBuffer(u32) = .{
            .items = undefined,
            .capacity = math.maxInt(usize) - 1,
            .second_start = math.maxInt(usize) - 1,
            .allocator = a,
        };
        buffer.items.len = math.maxInt(usize) - 1;

        try testing.expectError(error.OutOfMemory, buffer.appendSliceAfter(items));
        try testing.expectError(error.OutOfMemory, buffer.appendBeforeNTimes(new_item, 2));
        try testing.expectError(error.OutOfMemory, buffer.appendUnalignedSliceBefore(&.{ new_item, new_item }));
        try testing.expectError(error.OutOfMemory, buffer.addManyAtAfter(0, 2));
        try testing.expectError(error.OutOfMemory, buffer.addManyAsArrayBefore(2));
        try testing.expectError(error.OutOfMemory, buffer.addManyAsSliceAfter(2));
        try testing.expectError(error.OutOfMemory, buffer.insertSliceBefore(0, items));
        try testing.expectError(error.OutOfMemory, buffer.ensureUnusedCapacity(2));
    }
}
