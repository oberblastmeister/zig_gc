const std = @import("std");

const GcConfig = @import("GcConfig.zig");
const object = @import("object.zig");
const Object = *Header;
const Header = object.Header;
const InfoTable = object.InfoTable;
const RecordInfoTable = object.InfoTable;
const types = @import("types.zig");
const types_constructors = @import("types_constructors.zig");
const shadow_stack = @import("shadow_stack.zig");

// config provides:
//  fn objectSize(object: *Header) usize,
//  fn processFields(comptime GC: type, gc: *GC, ref: *Header, comptime processField: fn (gc: *GC, **Header) void) void,
//
pub fn MakeGC(comptime config: type) type {
    return struct {
        pub fn objectWordSize(ref: Object) usize {
            return config.objectSize(ref);
        }

        pub fn objectWordSlice(ref: Object) []usize {
            const ptr: [*]usize = @ptrCast(ref);
            return ptr[0..objectWordSize(ref)];
        }

        pub const heap_size = 4096 * 1024;

        const Self = @This();

        stack: shadow_stack.Stack,
        to_space: [*]usize,
        from_space: [*]usize,
        extent: usize,
        top: [*]usize,
        free: [*]usize,
        scan: [*]usize,

        pub fn init() !Self {
            const heap = try std.heap.page_allocator.alloc(usize, heap_size / @sizeOf(usize));
            @memset(heap, 0);
            const heap_start = heap.ptr;
            const to_space = heap_start;
            const extent = heap.len / 2;
            const top = to_space + extent;
            return .{
                .stack = .{ .node = null },
                .to_space = to_space,
                .from_space = top,
                .extent = extent,
                .top = top,
                .free = to_space,
                .scan = undefined,
            };
        }

        pub fn allocRaw_(self: *Self, size: usize) ?[*]usize {
            const res = self.free;
            const new_free = self.free + size;
            if (@intFromPtr(new_free) > @intFromPtr(self.top)) {
                return null;
            }
            self.free = new_free;
            return res;
        }

        pub fn allocRaw(self: *Self, size: usize) [*]usize {
            const ptr = init: {
                if (self.allocRaw_(size)) |ptr| {
                    break :init ptr;
                } else {
                    self.collect();
                    if (self.allocRaw_(size)) |ptr| {
                        break :init ptr;
                    } else {
                        std.debug.panic("Out of memory!", .{});
                    }
                }
            };
            return ptr;
        }

        pub fn allocRecord(self: *Self, info_table: *const InfoTable) Object {
            const ptr = self.allocRaw(info_table.record.size);
            const header_ptr: Object = @ptrCast(ptr);
            header_ptr.info_table = info_table;
            return header_ptr;
        }

        pub fn flip(self: *Self) void {
            std.mem.swap([*]usize, &self.from_space, &self.to_space);
            self.top = self.to_space + self.extent;
            self.free = self.to_space;
        }

        fn isWorklistEmpty(self: *Self) bool {
            return self.scan == self.free;
        }

        fn initWorklist(self: *Self) void {
            self.scan = self.free;
        }

        fn removeWorklist(self: *Self) Object {
            const ref: Object = @ptrCast(self.scan);
            self.scan += config.objectSize(ref);
            return ref;
        }

        pub fn collect(self: *Self) void {
            self.flip();
            self.initWorklist();
            var node = self.stack.node;
            while (node) |ps| {
                for (ps.pointers) |field| {
                    if (field) |it| {
                        self.processField(it);
                    }
                }
                node = ps.prev;
            }
            while (!self.isWorklistEmpty()) {
                const ref = self.removeWorklist();
                self.processObject(ref);
            }
        }

        pub fn processObject(self: *Self, ref: Object) void {
            config.processFields(Self, self, ref, processField);
        }

        pub fn processField(self: *Self, field: *Object) void {
            const from_ref = field.*;
            field.* = self.forward(from_ref);
        }

        pub fn forward(self: *Self, from_ref: Object) Object {
            const to_ref = from_ref.getForwardingAddress();
            if (to_ref) |res| {
                return res;
            } else {
                return self.copy(from_ref);
            }
        }

        pub fn copy(self: *Self, from_ref: Object) Object {
            const to_ref = self.free;
            self.free += objectWordSize(from_ref);
            @memcpy(to_ref, objectWordSlice(from_ref));
            from_ref.setForwardingAddress(@ptrCast(to_ref));
            return @ptrCast(to_ref);
        }
    };
}
