const std = @import("std");
const Thread = std.Thread;
const Mutex = Thread.Mutex;
const Condition = Thread.Condition;
const mem = std.mem;

const deque = @import("zig-deque");

pub fn ChannelUnmanaged(comptime T: type) type {
    return struct {
        const Self = @This();
        const Deque = deque.Deque(T);

        mutex: Mutex,
        queue: Deque,
        condition: Condition,
        waiters: usize,

        pub fn init(allocator: mem.Allocator) !*Self {
            const self = Self{
                .mutex = Mutex{},
                .condition = Condition{},
                .queue = try Deque.init(allocator),
                .waiters = 0,
            };
            const ptr = try allocator.create(Self);
            ptr.* = self;
            return ptr;
        }

        pub fn send(self: *Self, item: T) void {
            self.mutex.lock();
            self.queue.pushBack(item);
            if (self.waiters > 0) {
                self.condition.signal();
            }
            self.mutex.unlock();
        }

        pub fn receive(self: *Self) T {
            self.mutex.lock();
            while (true) {
                if (self.queue.len() > 0) {
                    const res = self.queue.popFront().?;
                    return res;
                } else {
                    self.waiters += 1;
                    self.condition.wait(self.mutex);
                    self.waiters -= 1;
                }
            }
        }

        // precondition: make sure all senders and receivers are done
        pub fn deinit(self: *Self) void {
            const allocator = self.queue.allocator;
            self.queue.deinit();
            allocator.destroy(self);
        }
    };
}

test "simple" {
    const Channel = ChannelUnmanaged(i32);
    const channel = try Channel.init(std.testing.allocator);
    defer channel.deinit();
}
