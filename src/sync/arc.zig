const std = @import("std");
const mem = std.mem;

const AtomicUsize = std.atomic.Value(usize);

pub fn noop(comptime T: type) fn (value: *T) void {
    const Id = struct {
        fn f(value: *T) void {
            _ = value; // autofix
        }
    };
    return Id.f;
}

pub fn ArcUnmanaged(comptime T: type, deinitInner: fn (value: *T) void) type {
    return struct {
        const Self = @This();

        count: AtomicUsize,
        value: T,

        pub fn init(value: T, allocator: mem.Allocator) !*Self {
            const ptr = try allocator.create(Self);
            const arc = Self{ .count = AtomicUsize.init(1), .value = value };
            ptr.* = arc;
            return ptr;
        }

        pub fn ref(self: *Self) void {
            _ = self.count.fetchAdd(1, .monotonic);
        }

        pub fn unref(self: *Self, allocator: mem.Allocator) void {
            if (self.count.fetchSub(1, .release) == 1) {
                _ = self.count.load(.acquire);
                deinitInner(&self.value);
                allocator.destroy(self);
            }
        }
    };
}

test "arc init" {
    const Arc = ArcUnmanaged(u32, noop(u32));
    const arc = try Arc.init(42, std.testing.allocator);
    arc.ref();
    arc.unref(std.testing.allocator);
    arc.unref(std.testing.allocator);
}
