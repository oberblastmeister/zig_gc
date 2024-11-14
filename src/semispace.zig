const std = @import("std");

const GcConfig = @import("GcConfig.zig");
const object = @import("object.zig");
const Header = object.Header;
const InfoTable = object.InfoTable;
const RecordInfoTable = object.InfoTable;
const types = @import("types.zig");
const types_constructors = @import("types_constructors.zig");

const PointerStack = struct {
    const Self = @This();

    next: ?*Self,
    pointers: []?**Header,

    fn init(pointers: []**Header) Self {
        return Self{
            .next = null,
            .pointers = pointers,
        };
    }
};

pub fn MakeGC(comptime config: GcConfig) type {
    return struct {
        pub fn objectWordSize(ref: *Header) usize {
            return config.objectSize(ref);
        }

        pub fn objectWordSlice(ref: *Header) []usize {
            const ptr: [*]usize = @ptrCast(ref);
            return ptr[0..objectWordSize(ref)];
        }

        pub const heap_size = 4096 * 1024;

        const Self = @This();

        pointer_stack: ?*PointerStack,
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
                .pointer_stack = null,
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

        pub fn allocRecord(self: *Self, info_table: *const InfoTable) *Header {
            const record_info = &info_table.body.record;
            const ptr = self.allocRaw(record_info.size);
            const header_ptr: *Header = @ptrCast(ptr);
            header_ptr._info_table = @constCast(info_table);
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

        fn removeWorklist(self: *Self) *Header {
            const ref: *Header = @ptrCast(self.scan);
            self.scan += config.objectSize(ref);
            return ref;
        }

        pub fn collect(self: *Self) void {
            self.flip();
            self.initWorklist();
            var ptr_stack = self.pointer_stack;
            while (ptr_stack) |ps| {
                for (ps.pointers) |field| {
                    if (field) |it| {
                        self.processField(it);
                    }
                }
                ptr_stack = ps.next;
            }
            while (!self.isWorklistEmpty()) {
                const ref = self.removeWorklist();
                self.processObject(ref);
            }
        }

        pub fn processObject(self: *Self, ref: *Header) void {
            config.processFields(@ptrCast(self), ref, processFieldWrapper);
        }

        pub fn processField(self: *Self, field: **Header) void {
            const from_ref = field.*;
            field.* = self.forward(from_ref);
        }

        fn processFieldWrapper(self: *anyopaque, field: **Header) void {
            processField(@ptrCast(@alignCast((self))), field);
        }

        pub fn forward(self: *Self, from_ref: *Header) *Header {
            const to_ref = from_ref.getForwardingAddress();
            if (to_ref) |res| {
                return res;
            } else {
                return self.copy(from_ref);
            }
        }

        pub fn copy(self: *Self, from_ref: *Header) *Header {
            const to_ref = self.free;
            self.free += objectWordSize(from_ref);
            @memcpy(to_ref, objectWordSlice(from_ref));
            from_ref.setForwardingAddress(@ptrCast(to_ref));
            return @ptrCast(to_ref);
        }

        pub fn addPointerStack(self: *Self, ptr_stack: *PointerStack) void {
            ptr_stack.next = self.pointer_stack;
            self.pointer_stack = ptr_stack;
        }
    };
}

pub fn MakeP(comptime GC: type) type {
    return struct {
        pub fn P(comptime N: usize) type {
            return struct {
                pub const Self = @This();

                pointers: [N]?**Header,
                pointer_stack: PointerStack,

                pub fn init(pointers: [N]?**Header) Self {
                    return .{
                        .pointers = pointers,
                        .pointer_stack = undefined,
                    };
                }

                pub fn enter(self: *Self, gc: *GC) void {
                    self.pointer_stack.pointers = &self.pointers;
                    self.pointer_stack.next = gc.pointer_stack;
                    gc.pointer_stack = &self.pointer_stack;
                }

                pub fn exit(self: *Self, gc: *GC) void {
                    _ = self;
                    gc.pointer_stack = gc.pointer_stack.?.next;
                }
            };
        }
    };
}
