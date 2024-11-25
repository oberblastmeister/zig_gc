const std = @import("std");
const builtin = @import("builtin");
const mem = std.mem;
const Allocator = mem.Allocator;
const debug = std.debug;
const assert = debug.assert;
const print = debug.print;
const deque = @import("zig-deque");
const utils = @import("utils.zig");

const GcConfig = @import("GcConfig.zig");
const object = @import("object.zig");
const Header = object.Header;
const Object = object.Object;
const InfoTable = object.InfoTable;
const RecordInfoTable = object.InfoTable;
const shadow_stack = @import("shadow_stack.zig");
const types = @import("types.zig");

// pub const block_size: usize =
//     if (builtin.mode == .Debug) 8 * 1024 else 32 * 1024;
pub const block_size: usize = 32 * 1024;
pub const words_per_block: usize = block_size / @sizeOf(usize);
pub const line_size: usize = 128;
pub const words_per_line: usize = line_size / @sizeOf(usize);
pub const lines_per_block: usize = block_size / line_size;
pub const data_lines_offset: usize = 3;
pub const data_words_offset: usize = data_lines_offset * words_per_line;
pub const data_lines_per_block: usize = lines_per_block - data_lines_offset;
pub const data_words_per_block: usize = data_lines_per_block * words_per_line;
pub const max_small_object_size: usize = line_size;
pub const max_medium_object_size: usize = line_size;

const LineFlags = packed struct(u8) {
    is_marked: bool = false,
    rest: u7 = 0,
};

const Line = [words_per_line]usize;

const Range = struct {
    start: usize,
    end: usize,

    const Self = @This();

    fn len(self: Self) usize {
        assert(self.start <= self.end);
        return self.end - self.start;
    }
};

fn wordSizeOf(comptime T: type) usize {
    return @sizeOf(T) / @sizeOf(usize);
}

fn lineRangeToWord(line_range: Range) Range {
    return .{ .start = line_range.start * words_per_line, .end = line_range.end * words_per_line };
}

fn isMediumSize(size: usize) bool {
    return size > words_per_line;
}

// This is the header for a block.
const Block = struct {
    const LineMap = [data_lines_per_block]LineFlags;

    comptime {
        assert(@sizeOf(LineMap) <= 2 * @sizeOf(Line));
    }

    const Meta = struct {
        // the current hole that we are bumping into
        bump: Range = .{ .start = 0, .end = data_words_per_block },
        is_marked: bool = false,
    };

    comptime {
        assert(@sizeOf(Meta) <= @sizeOf(Line));
        assert(@alignOf(Meta) <= @alignOf(Line));
    }

    const Data = [lines_per_block]Line;

    // reserve the first line for the blockmeta
    // reseve the second and third line for the line flags
    ptr: *align(block_size) Data,

    const Self = @This();

    fn reset(self: Self) void {
        self.getMeta().* = .{};
        @memset(self.getLineMap(), .{});
    }

    fn getLines(self: Self) []Line {
        return self.ptr[data_lines_offset..];
    }

    fn getMeta(self: Self) *Meta {
        return @ptrCast(&self.ptr[0]);
    }

    fn getLineMap(self: Self) *LineMap {
        return @ptrCast(&self.ptr[1]);
    }

    fn getMemory(self: Self) []usize {
        const ptr: *[words_per_block]usize = @ptrCast(self.ptr);
        return ptr[data_words_offset..];
    }

    // start is a valid line index
    fn findNextUnmarkedLine(self: Self, start: usize) ?usize {
        const lines = self.getLines();
        var cursor = start;
        // if we see a marked line, then the line right after that is also implicitly marked
        // this is the conservative marking of lines
        // So we add two instead of one
        while (cursor < lines.len and self.getLineMap()[cursor].is_marked) : (cursor += 2) {}
        if (cursor >= lines.len) {
            return null;
        } else {
            return cursor;
        }
    }

    // start is a valid line index
    fn findNextHoleOfLines(self: Self, start: usize) ?Range {
        const lines = self.getLines();
        const next = self.findNextUnmarkedLine(start) orelse return null;
        var cursor = next;
        while (cursor < lines.len and !self.getLineMap()[cursor].is_marked) : (cursor += 1) {}
        return .{ .start = next, .end = cursor };
    }

    // start must be at the start of a line
    fn findNextHole(self: Self, start: usize) ?Range {
        assert(start % words_per_line == 0);
        const line_range = self.findNextHoleOfLines(start / words_per_line) orelse return null;
        return lineRangeToWord(line_range);
    }

    inline fn bumpRegion(self: Self) []usize {
        return self.getMemory()[self.getMeta().bump.start..self.getMeta().bump.end];
    }

    const SuitableHoleError = error{ NoHoleFound, NoSuitableHoleFound };

    fn findSuitableHole(self: Self, start: usize, size: usize) SuitableHoleError!Range {
        var hole = self.findNextHole(start) orelse return .NoHoleFound;
        while (hole.len() < size) {
            hole = self.findNextHole(hole.end) orelse return .NoSuitableHoleFound;
        }
        return hole;
    }

    inline fn allocFast(self: Self, size: usize) []usize {
        assert(self.getMeta().bump.start + size <= self.getMeta().bump.end);
        const bump = self.bumpRegion();
        const res = bump[0..size];
        self.getMeta().bump.start += size;
        return res;
    }

    fn allocSlow(self: Self, size: usize) SuitableHoleError![]usize {
        const hole = try self.findSuitableHole(self.getMeta().bump.end, size);
        self.getMeta().bump = hole;
        return self.allocFast(size);
    }

    // allocate an amount of words
    fn alloc(self: Self, size: usize) SuitableHoleError![]usize {
        const bump = self.bumpRegion();
        if (size <= bump.len) {
            return self.allocFast(size);
        } else {
            // @branchHint(.unlikely);
            return try self.allocSlow(size);
        }
    }

    fn allocSmall(self: Self, size: usize) ?[]usize {
        assert(size <= words_per_line);

        const bump = self.bumpRegion();
        if (size <= bump.len) {
            return self.allocFast(size);
        } else {
            // the next hole is guaranteed to be big enough becuase small objects are always smaller than a line
            const hole = self.findNextHole(self.getMeta().bump.end) orelse {
                return null;
            };
            self.getMeta().bump = hole;
            return self.allocFast(size);
        }
    }

    fn fromObject(obj: Object) Block {
        const ptr = @intFromPtr(obj);
        return .{ .ptr = @ptrFromInt(mem.alignBackward(usize, ptr, block_size)) };
    }

    fn objectLineIndex(self: Self, obj: Object) usize {
        return (@intFromPtr(obj) - @intFromPtr(self.ptr)) / line_size - data_lines_offset;
    }
};

comptime {
    assert(@alignOf(Block) <= @alignOf(usize));
}

const BlockArrayList = std.ArrayList(Block);
const BlockQueue = deque.Deque(Block);

const Immix = @This();

pub const Stats = struct {
    collections: usize = 0,
};

const WorkList = std.ArrayList(Object);

stack: shadow_stack.Stack = .{},
heap: []align(block_size) usize,
offset: usize = 0,
unavailable: BlockArrayList,
unavailable_copy: BlockArrayList,
free: BlockArrayList,
recyclable: BlockQueue,
recyclable_copy: BlockQueue,
// used so that we have enough space for evacuation
headroom: BlockArrayList,
allocator: Allocator,
worklist: WorkList,
stats: Stats = .{},
// if obj.isMarked() == mark_bit, then obj is marked
mark_bit: bool = false,

pub const heap_size = 32 * 1024 * 1024;
pub const heap_word_size = heap_size / @sizeOf(usize);

// a chunk is a bunch of blocks, like what GHC calls a megablock, except our chunk is way larger than a megablock
pub fn allocChunk() ![]align(block_size) u8 {
    const blocks_per_chunk = heap_size * 2 / block_size;
    // const blocks_per_chunk = 2048;
    const chunk = try std.heap.page_allocator.alloc(u8, blocks_per_chunk * block_size);
    const chunk_val = @intFromPtr(chunk.ptr);
    const aligned_chunk: [*]align(block_size) u8 = @ptrFromInt(mem.alignForward(usize, chunk_val, block_size));
    const off = utils.ptrSub(aligned_chunk, chunk.ptr);
    const aligned_chunk_len = chunk.len - off;
    return aligned_chunk[0..aligned_chunk_len];
}

pub fn init(allocator: Allocator) !Immix {
    const recyclable = try BlockQueue.init(allocator);
    errdefer recyclable.deinit();

    const recyclable_copy = try BlockQueue.init(allocator);
    errdefer recyclable_copy.deinit();

    const chunk = try allocChunk();
    const heap = utils.castSlice(u8, usize, chunk[0..heap_size]);
    errdefer std.heap.page_allocator.free(heap);
    @memset(heap, 0);

    const unavailable = BlockArrayList.init(allocator);
    const unavailable_copy = BlockArrayList.init(allocator);
    const headroom = BlockArrayList.init(allocator);
    const free = BlockArrayList.init(allocator);
    const worklist = WorkList.init(allocator);
    return .{
        .heap = @alignCast(heap),
        .free = free,
        .unavailable = unavailable,
        .unavailable_copy = unavailable_copy,
        .recyclable = recyclable,
        .recyclable_copy = recyclable_copy,
        .headroom = headroom,
        .allocator = allocator,
        .worklist = worklist,
    };
}

pub fn deinit(self: *Immix) void {
    std.heap.page_allocator.free(self.heap);
    self.unavailable.deinit();
    self.unavailable_copy.deinit();
    self.recyclable.deinit();
    self.recyclable_copy.deinit();
    self.free.deinit();
    self.headroom.deinit();
    self.worklist.deinit();
}

pub fn writeBarrier(self: *Immix, obj: Object, field: *Object, ptr: Object) void {
    _ = self;
    _ = obj;
    _ = field;
    _ = ptr;
}

pub fn readBarrier(self: *Immix, obj: Object, field: *Object) void {
    _ = self;
    _ = obj;
    _ = field;
}

// postcondition: blocks are reset
fn allocBlock(self: *Immix) ?Block {
    if (self.free.items.len > 0) {
        const block = self.free.pop();
        block.reset();
        return block;
    }

    if (self.offset + wordSizeOf(Block.Data) <= self.heap.len) {
        const ptr: *align(block_size) Block.Data = @ptrCast(@alignCast(self.heap[self.offset..].ptr));
        const block = Block{ .ptr = ptr };
        block.reset();
        self.offset += wordSizeOf(Block.Data);
        return block;
    } else {
        return null;
    }
}

// fn allocInRecyclable(self: *Immix, size: usize) ?[*]usize {
//     assert(size <= data_words_per_block);

//     // const block = self.recyclable.get
//     while (true) {
//         if (self.recyclable.get(0)) {

//         } else {

//         }
//     }
// }
fn allocFree(self: *Immix, size: usize) ?[*]usize {
    const block = self.allocBlock() orelse return null;
    assert(std.meta.eql(block.getMeta().*, Block.Meta{}));
    const res = block.allocFast(size);
    self.recyclable.pushBack(block) catch unreachable;
    return res.ptr;
}

fn allocMedium(self: *Immix, size: usize) ?[*]usize {
    assert(isMediumSize(size));

    if (self.recyclable.len() == 0) {
        return self.allocFree(size);
    }

    // first try to bump
    const first_block = self.recyclable.get(0).?.*;
    if (first_block.getMeta().bump.start + size <= first_block.getMeta().bump.end) {
        return first_block.allocFast(size).ptr;
    }

    // can't bump, so find another hole or trigger overflow
    while (self.recyclable.get(0)) |it| {
        const block = it.*;
        if (block.findNextHole(block.getMeta().bump.end)) |hole| {
            if (hole.len() >= size) {
                block.getMeta().bump = hole;
                return block.allocFast(size).ptr;
            } else {
                // overflow allocation
                return self.allocFree(size);
            }
        } else {
            _ = self.recyclable.popFront().?;
            self.unavailable.append(block) catch unreachable;
        }
    }

    // all the blocks had no available lines
    return self.allocFree(size);
}

fn allocSmall(self: *Immix, size: usize) ?[*]usize {
    assert(size <= words_per_line);

    while (self.recyclable.get(0)) |it| {
        const block = it.*;
        if (block.allocSmall(size)) |res| {
            return res.ptr;
        } else {
            _ = self.recyclable.popFront().?;
            self.unavailable.append(block) catch unreachable;
        }
    }

    return self.allocFree(size);
}

fn allocNoCollect(self: *Immix, size: usize) ?[*]usize {
    assert(size <= data_words_per_block);

    if (isMediumSize(size)) {
        // unlikely
        return self.allocMedium(size);
    } else {
        return self.allocSmall(size);
    }
}

pub fn allocObject(self: *Immix, info_table: *const InfoTable, size: usize) Object {
    // TODO: implement large object space
    if (size > data_words_per_block) {
        debug.panic("Cannot allocate more than {} bytes!", .{data_words_per_block});
    }

    const ptr = init: {
        if (self.allocNoCollect(size)) |ptr| {
            break :init ptr;
        } else {
            self.collect();
            if (self.allocNoCollect(size)) |ptr| {
                break :init ptr;
            } else {
                std.debug.panic("Out of memory!", .{});
            }
        }
    };

    const obj: Object = @ptrCast(ptr);
    obj._info_table = @constCast(@ptrCast(info_table));
    obj.setMarked(!self.mark_bit);
    obj.setSizeClass(if (isMediumSize(size)) .medium else .small);
    std.debug.assert(@intFromPtr(obj) >= 0x100);
    return obj;
}

pub fn allocRecord(self: *Immix, info_table: *const InfoTable) Object {
    const record_info = &info_table.record;
    return self.allocObject(info_table, record_info.size);
}

pub fn collect(self: *Immix) void {
    self.stats.collections += 1;

    self.unmarkBlocks();
    self.markAll();
    self.sweep();

    // flip the mark bit so we don't have to clear the mark bits that we set during markAll
    self.mark_bit = !self.mark_bit;
}

pub fn objectWordSize(ref: Object) usize {
    return types.objectSize(ref);
}

pub fn objectWordSlice(ref: Object) []usize {
    const ptr: [*]usize = @ptrCast(ref);
    return ptr[0..objectWordSize(ref)];
}

fn isMarked(self: *Immix, obj: Object) bool {
    return obj.isMarked() == self.mark_bit;
}

fn unmarkBlocks(self: *Immix) void {
    var it = self.recyclable.iterator();
    while (it.next()) |t| {
        const block = t.*;
        self.unmarkBlock(block);
    }

    for (self.unavailable.items) |block| {
        self.unmarkBlock(block);
    }

    if (builtin.mode == .Debug) {
        for (self.free.items) |block| {
            assert(!block.getMeta().is_marked);
            for (0.., block.getLines()) |i, line| {
                _ = line;
                assert(!block.getLineMap()[i].is_marked);
            }
        }
    }
}

fn unmarkBlock(self: *Immix, block: Block) void {
    _ = self;

    block.getMeta().is_marked = false;
    // unmark each line
    for (0.., block.getLines()) |i, line| {
        _ = line;
        block.getLineMap()[i].is_marked = false;
    }
}

pub fn markAll(self: *Immix) void {
    var frame = self.stack.node;
    while (frame) |ps| {
        for (ps.pointers) |it| {
            if (it) |field| {
                const obj = field.*;
                if (!self.isMarked(obj)) {
                    self.markObject(obj);
                }
            }
        }
        frame = ps.next;
    }
    while (self.worklist.items.len > 0) {
        const obj = self.worklist.pop();
        if (!self.isMarked(obj)) {
            self.markObject(obj);
        }
    }
    self.worklist.clearRetainingCapacity();
}

pub fn markObject(self: *Immix, obj: Object) void {
    assert(!self.isMarked(obj));
    types.processFields(@ptrCast(self), obj, struct {
        pub fn F(gc: *anyopaque, field: *Object) void {
            const this: *Immix = @ptrCast(@alignCast(gc));
            const slot = this.worklist.addOne() catch unreachable;
            slot.* = field.*;
        }
    }.F);
    obj.flipMarked();
    const block = Block.fromObject(obj);
    block.getMeta().is_marked = true;
    const line_index = block.objectLineIndex(obj);
    if (obj.getSizeClass() == .small) {
        block.getLineMap()[line_index].is_marked = true;
    } else {
        assert(obj.getSizeClass() == .medium);
        const size = types.objectSize(obj);
        const lines = (size - 1) / words_per_line + 1;
        for (line_index..(line_index + lines + 1)) |li| {
            block.getLineMap()[li].is_marked = true;
        }
        // since the medium object could start in the middle of a line and create one extra line, we need to mark the extra line
        // but that is handled with the implicitly marked line
    }
}

pub fn sweep(self: *Immix) void {
    var it = self.recyclable.iterator();
    while (it.next()) |t| {
        const block = t.*;
        self.sweep_block(block);
    }

    for (self.unavailable.items) |block| {
        self.sweep_block(block);
    }

    // swap the lists of blocks

    // the deque library does not have a clearRetainingCapacity method
    // so we just access the the internal fields
    self.recyclable.head = 0;
    self.recyclable.tail = 0;
    self.unavailable.clearRetainingCapacity();
    mem.swap(BlockQueue, &self.recyclable, &self.recyclable_copy);
    mem.swap(BlockArrayList, &self.unavailable, &self.unavailable_copy);
}

pub fn sweep_block(self: *Immix, block: Block) void {
    if (block.getMeta().is_marked) {
        const res = self.sweep_lines(block);
        const available_lines = data_lines_per_block - res.marked_lines;
        assert(res.marked_lines != 0);
        if (available_lines > 0) {
            self.recyclable_copy.pushBack(block) catch unreachable;
        } else {
            self.unavailable_copy.append(block) catch unreachable;
        }
    } else {
        self.free.append(block) catch unreachable;
    }
}

pub fn sweep_lines(self: *Immix, block: Block) struct {
    // IMPORTANT: this does not count implicitly marked lines
    marked_lines: usize,
} {
    _ = self;
    assert(block.getMeta().is_marked);
    var marked_lines: usize = 0;
    for (0.., block.getLines()) |i, *line| {
        _ = line;
        const flags = block.getLineMap()[i];
        if (flags.is_marked) {
            marked_lines += 1;
        }
    }
    return .{ .marked_lines = marked_lines };
}
