const std = @import("std");
const assert = std.debug.assert;

pub fn Pool(comptime T: type) type {
    return struct {
        pub const Iterator = struct {
            items: []T,
            iter: std.DynamicBitSetUnmanaged.Iterator(.{
                .kind = .set,
                .direction = .forward,
            }),

            pub fn next(self: *Iterator) ?T {
                const index = self.iter.next() orelse return null;
                return self.items[index];
            }

            pub fn next_ptr(self: *Iterator) ?*T {
                const index = self.iter.next() orelse return null;
                return &self.items[index];
            }

            pub fn next_index(self: *Iterator) ?usize {
                return self.iter.next();
            }
        };

        const Self = @This();
        allocator: std.mem.Allocator,
        // Buffer for the Pool.
        items: []T,
        dirty: std.DynamicBitSetUnmanaged,

        /// Initalizes our items buffer as undefined.
        pub fn init(allocator: std.mem.Allocator, size: usize) !Self {
            return .{
                .allocator = allocator,
                .items = try allocator.alloc(T, size),
                .dirty = try std.DynamicBitSetUnmanaged.initEmpty(allocator, size),
            };
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.items);
            self.dirty.deinit(self.allocator);
        }

        /// Deinitalizes our items buffer with a passed in hook.
        pub fn deinit_with_hook(
            self: *Self,
            args: anytype,
            deinit_hook: ?*const fn (buffer: []T, args: @TypeOf(args)) void,
        ) void {
            if (deinit_hook) |hook| {
                @call(.auto, hook, .{ self.items, args });
            }

            self.allocator.free(self.items);
            self.dirty.deinit(self.allocator);
        }

        pub fn get(self: *const Self, index: usize) T {
            assert(index < self.items.len);
            return self.items[index];
        }

        pub fn get_ptr(self: *const Self, index: usize) *T {
            assert(index < self.items.len);
            return &self.items[index];
        }

        /// Is this empty?
        pub fn empty(self: *const Self) bool {
            return self.dirty.count() == 0;
        }

        /// Is this full?
        pub fn full(self: *const Self) bool {
            return self.dirty.count() == self.list.len;
        }

        /// Returns the number of clean (or available) slots.
        pub fn clean(self: *const Self) usize {
            return self.items.len - self.dirty.count();
        }

        /// Linearly probes for an available slot in the pool.
        /// If dynamic, this *might* grow the Pool.
        ///
        /// Returns the index into the Pool.
        pub fn borrow(self: *Self) !usize {
            var iter = self.dirty.iterator(.{ .kind = .unset });
            const index = iter.next() orelse return error.Full;
            self.dirty.set(index);
            return index;
        }

        /// Linearly probes for an available slot in the pool.
        /// Uses a provided hint value as the starting index.
        /// This will never grow the Pool.
        ///
        /// Returns the index into the Pool.
        pub fn borrow_hint(self: *Self, hint: usize) !usize {
            const length = self.items.len;
            for (0..length) |i| {
                const index = @mod(hint + i, length);
                if (!self.dirty.isSet(index)) {
                    self.dirty.set(index);
                    return index;
                }
            }

            return error.Full;
        }

        /// Attempts to borrow at the given index.
        /// Asserts that it is an available slot.
        /// This will never grow the Pool.
        pub fn borrow_assume_unset(self: *Self, index: usize) usize {
            assert(!self.dirty.isSet(index));
            self.dirty.set(index);
            return index;
        }

        /// Releases the item with the given index back to the Pool.
        /// Asserts that the given index was borrowed.
        pub fn release(self: *Self, index: usize) void {
            assert(self.dirty.isSet(index));
            self.dirty.unset(index);
        }

        /// Returns an iterator over the taken values in the Pool.
        pub fn iterator(self: *const Self) Iterator {
            const iter = self.dirty.iterator(.{});
            return .{ .iter = iter, .items = self.items };
        }
    };
}

const testing = std.testing;

test "Pool: Initalization (integer)" {
    var byte_pool = try Pool(u8).init(testing.allocator, 1024);
    defer byte_pool.deinit();

    for (0..1024) |i| {
        const index = try byte_pool.borrow_hint(i);
        const byte_ptr = byte_pool.get_ptr(index);
        byte_ptr.* = 2;
    }

    for (byte_pool.items) |item| {
        try testing.expectEqual(item, 2);
    }
}

test "Pool: Initalization & Deinit (ArrayList)" {
    var list_pool = try Pool(std.ArrayList(u8)).init(testing.allocator, 256);
    defer list_pool.deinit();

    for (list_pool.items, 0..) |*item, i| {
        item.* = std.ArrayList(u8).init(testing.allocator);
        try item.appendNTimes(0, i);
    }

    for (list_pool.items, 0..) |item, i| {
        try testing.expectEqual(item.items.len, i);
    }

    for (list_pool.items) |item| {
        item.deinit();
    }
}

test "Pool: BufferPool ([][]u8)" {
    var buffer_pool = try Pool([1024]u8).init(testing.allocator, 1024);
    defer buffer_pool.deinit();

    for (buffer_pool.items) |*item| {
        std.mem.copyForwards(u8, item, "ABCDEF");
    }

    for (buffer_pool.items) |item| {
        try testing.expectEqualStrings("ABCDEF", item[0..6]);
    }
}

test "Pool: Borrowing" {
    var byte_pool = try Pool(u8).init(testing.allocator, 1024);
    defer byte_pool.deinit();

    for (0..byte_pool.items.len) |_| {
        _ = try byte_pool.borrow();
    }

    // Expect a Full.
    try testing.expectError(error.Full, byte_pool.borrow());

    for (0..byte_pool.items.len) |i| {
        byte_pool.release(i);
    }
}

test "Pool: Borrowing Hint" {
    var byte_pool = try Pool(u8).init(testing.allocator, 1024);
    defer byte_pool.deinit();

    for (0..byte_pool.items.len) |i| {
        _ = try byte_pool.borrow_hint(i);
    }

    for (0..byte_pool.items.len) |i| {
        byte_pool.release(i);
    }
}

test "Pool: Borrowing Unset" {
    var byte_pool = try Pool(u8).init(testing.allocator, 1024);
    defer byte_pool.deinit();

    for (0..byte_pool.items.len) |i| {
        _ = byte_pool.borrow_assume_unset(i);
    }

    for (0..byte_pool.items.len) |i| {
        byte_pool.release(i);
    }
}

test "Pool Iterator" {
    var int_pool = try Pool(usize).init(testing.allocator, 1024);
    defer int_pool.deinit();

    for (0..(1024 / 2)) |_| {
        const borrowed = try int_pool.borrow();
        const item_ptr = int_pool.get_ptr(borrowed);
        item_ptr.* = borrowed;
    }

    var iter = int_pool.iterator();
    while (iter.next()) |item| {
        try testing.expect(int_pool.dirty.isSet(item));
        int_pool.release(item);
    }

    try testing.expect(int_pool.empty());
}
