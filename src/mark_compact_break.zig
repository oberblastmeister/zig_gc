const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const debug = std.debug;
const assert = debug.assert;

const GcConfig = @import("GcConfig.zig");
const object = @import("object.zig");
const Header = object.Header;
const Object = object.Object;
const InfoTable = object.InfoTable;
const RecordInfoTable = object.InfoTable;
const shadow_stack = @import("shadow_stack.zig");
const types = @import("types.zig");

pub const heap_size = 32 * 1024 * 1024;

pub const Self = @This();

const ForwardingMap = std.AutoHashMap(u32, u32);
const WorkList = std.ArrayList(Object);

pub const Stats = struct {
    collections: usize = 0,
};

stack: shadow_stack.Stack,
heap: []usize,
free: usize,
backing_allocator: mem.Allocator,
forwarding_map: ForwardingMap,
worklist: WorkList,
stats: Stats,
firstUsedChunkSize: usize,

pub fn objectWordSize(ref: Object) usize {
    const marked = ref.isMarked();
    ref.setMarked(false);
    const res = types.objectSize(ref);
    ref.setMarked(marked);
    return res;
}

pub fn objectWordSlice(ref: Object) []usize {
    const ptr: [*]usize = @ptrCast(ref);
    return ptr[0..objectWordSize(ref)];
}

pub fn init(backing_allocator: mem.Allocator) !Self {
    const heap = try std.heap.page_allocator.alloc(usize, heap_size / @sizeOf(usize));
    @memset(heap, 0);
    return .{
        .stack = .{},
        .heap = heap,
        .free = 0,
        .backing_allocator = backing_allocator,
        .forwarding_map = ForwardingMap.init(backing_allocator),
        .worklist = WorkList.init(backing_allocator),
        .stats = .{},
        .firstUsedChunk = undefined,
    };
}

pub fn deinit(self: *Self) void {
    self.forwarding_map.deinit();
    self.worklist.deinit();
    std.heap.page_allocator.free(self.heap);
}

pub fn writeBarrier(self: *Self, obj: Object, field: *Object, ptr: Object) void {
    _ = self;
    _ = obj;
    _ = field;
    _ = ptr;
}

pub fn readBarrier(self: *Self, obj: Object, field: *Object) void {
    _ = self;
    _ = obj;
    _ = field;
}

pub fn allocRaw_(self: *Self, size: usize) ?[*]usize {
    const res = self.free;
    const new_free = self.free + size;
    if (new_free >= self.heap.len) {
        return null;
    }
    self.free = new_free;
    return self.heap[res..][0..size].ptr;
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
    const record_info = &info_table.record;
    const ptr = self.allocRaw(record_info.size);
    const header_ptr: Object = @ptrCast(ptr);
    header_ptr._info_table = @constCast(info_table);
    return header_ptr;
}

pub fn collect(self: *Self) void {
    self.stats.collections += 1;

    self.markAll();
    self.compact();
}

pub fn markAll(self: *Self) void {
    var frame = self.stack.node;
    while (frame) |ps| {
        for (ps.pointers) |it| {
            if (it) |field| {
                const obj = field.*;
                // debug.assert(!obj.isMarked());
                if (!obj.isMarked()) {
                    self.markObject(obj);
                }
            }
        }
        frame = ps.next;
    }
    while (self.worklist.items.len > 0) {
        const obj = self.worklist.pop();
        if (!obj.isMarked()) {
            self.markObject(obj);
        }
    }
    self.worklist.clearRetainingCapacity();
}

pub fn markObject(self: *Self, obj: Object) void {
    debug.assert(!obj.isMarked());
    types.processFields(@ptrCast(self), obj, struct {
        pub fn F(gc: *anyopaque, field: *Object) void {
            const this: *Self = @ptrCast(@alignCast(gc));
            const slot = this.worklist.addOne() catch unreachable;
            slot.* = field.*;
        }
    }.F);
    obj.setMarked(true);
}

pub fn compact(self: *Self) void {
    const new_free = self.computeLocations();
    self.updateReferences();
    self.relocate();
    self.free = new_free;
}

pub fn getForwardOffset(self: *Self, from: usize) usize {
    return @intCast(self.forwarding_map.get(@intCast(from)).?);
}

pub fn getForward(self: *Self, from: Object) Object {
    const heap: [*]usize = @ptrCast(self.heap.ptr);
    const ptr: [*]usize = @ptrCast(from);
    const off = (@intFromPtr(ptr) - @intFromPtr(heap)) / @sizeOf(usize);
    const to = self.getForwardOffset(off);
    const res = heap + to;
    return @ptrCast(res);
}

pub fn setForward(self: *Self, from: usize, to: usize) void {
    self.forwarding_map.put(@intCast(from), @intCast(to)) catch unreachable;
}

pub fn getObject(self: *Self, index: usize) Object {
    return @ptrCast(&self.heap[index]);
}

const BreakTableItem = struct {
    from: u32,
    to: u32,
};

comptime {
    assert(@sizeOf(BreakTableItem) == @sizeOf(usize));
}

pub fn computeLocations(self: *Self) usize {
    var scan: usize = 0;
    var free: usize = 0;
    const end = self.free;
    while (scan < end) {
        const obj = self.getObject(scan);
        const obj_size = objectWordSize(obj);
        if (obj.isMarked()) {
            self.setForward(scan, free);
            free += obj_size;
        }
        scan += obj_size;
    }
    return free;
}

pub fn computeLocationsBreak(self: *Self) usize {
    var cur: usize = 0;
    const end = self.free;

    while (cur < end) : (cur += objectWordSize(self.getObject(cur))) {}
}

pub fn updateReferences(self: *Self) void {
    var frame = self.stack.node;
    while (frame) |ps| {
        for (ps.pointers) |it| {
            if (it) |field| {
                field.* = self.getForward(field.*);
            }
        }
        frame = ps.next;
    }

    var scan: usize = 0;
    const end = self.free;
    while (scan < end) {
        const obj = self.getObject(scan);
        const obj_size = objectWordSize(obj);
        if (obj.isMarked()) {
            obj.setMarked(false);
            types.processFields(@ptrCast(self), obj, struct {
                pub fn F(gc: *anyopaque, field: *Object) void {
                    field.* = @as(*Self, @ptrCast(@alignCast(gc))).getForward(field.*);
                }
            }.F);
            obj.setMarked(true);
        }
        scan += obj_size;
    }
}

pub fn relocate(self: *Self) void {
    var scan: usize = 0;
    const end = self.free;
    while (scan < end) {
        const obj = self.getObject(scan);
        const obj_size = objectWordSize(obj);
        if (obj.isMarked()) {
            const dest = self.getForwardOffset(scan);
            mem.copyForwards(usize, self.heap[dest..][0..obj_size], objectWordSlice(obj));
            self.getObject(dest).setMarked(false);
        }
        scan += obj_size;
    }
    self.forwarding_map.clearRetainingCapacity();
}
