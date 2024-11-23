const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const debug = std.debug;
const assert = debug.assert;
const deque = @import("zig-deque");

const GcConfig = @import("GcConfig.zig");
const object = @import("object.zig");
const Header = object.Header;
const Object = object.Object;
const InfoTable = object.InfoTable;
const RecordInfoTable = object.InfoTable;
const shadow_stack = @import("shadow_stack.zig");
const types = @import("types.zig");

pub const block_size: usize = 32 * 1024;
pub const line_size: usize = 128;
pub const lines_per_block: usize = block_size / line_size;
pub const max_small_object_size: usize = line_size;
pub const max_medium_object_size: usize = line_size;
pub const words_per_line: usize = line_size / @sizeOf(usize);

const LineFlags = packed struct(u8) {
    is_marked: bool,
    rest: u7,
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

fn lineRangeToWord(line_range: Range) Range {
    return .{ .start = line_range.start * words_per_line, .end = line_range.end * words_per_line };
}

// This is the header for a block.
const Block = struct {
    line_map: [lines_per_block]LineFlags,
    bump: Range,

    const Self = @This();

    fn getLines(self: *Self) *[lines_per_block]Line {
        return @ptrCast(@as([*]Block, @ptrCast(self)) + 1);
    }

    fn getMemory(self: *Self) *[lines_per_block * words_per_line]usize {
        return @ptrCast(self.getLines());
    }

    fn findNextUnmarkedLine(self: *Self, start: usize) ?usize {
        const lines = self.getLines();
        var cursor = start;
        while (cursor < lines.len and self.line_map[cursor].is_marked) : (cursor += 2) {}
        if (cursor >= lines.len) {
            return null;
        } else {
            return cursor;
        }
    }

    fn findNextHoleOfLines(self: *Self, start: usize) ?Range {
        const lines = self.getLines();
        const next = self.findNextUnmarkedLine(start) orelse return null;
        var cursor = next;
        while (cursor < lines.len and !self.line_map[cursor].is_marked) : (cursor += 1) {}
        return .{ .start = next, .end = cursor };
    }

    fn findNextHole(self: *Self, start: usize) ?Range {
        const line_range = self.findNextHoleOfLines(start) orelse return null;
        return lineRangeToWord(line_range);
    }

    inline fn bumpRegion(self: *Self) []usize {
        return self.getMemory()[self.bump.start..self.bump.end];
    }

    fn findSuitableHole(self: *Self, start: usize, size: usize) ?Range {
        var hole = self.findNextHole(start) orelse return null;
        while (hole.len() < size) {
            hole = self.findNextHole(hole.end) orelse return null;
        }
        return hole;
    }

    inline fn allocFast(self: *Self, size: usize) []usize {
        const bump = self.bumpRegion();
        const res = bump[0..size];
        self.bump.start += size;
        return res;
    }

    fn allocSlow(self: *Self, size: usize) ?[]usize {
        const hole = self.findSuitableHole(self.bump.start, size) orelse return null;
        self.bump = hole;
        self.bump.start = hole.start;
        self.bump.end = hole.end;
        return self.allocFast(size);
    }

    // allocate an amount of words
    fn alloc(self: *Self, size: usize) []usize {
        const bump = self.bumpRegion();
        if (size > bump.len) {
            // @branchHint(.unlikely);
            self.allocSlow(size);
        } else {
            return self.allocFast(size);
        }
    }
};

comptime {
    assert(@alignOf(Block) >= @alignOf(usize));
}

const BlockArrayList = std.ArrayList(Block);
const BlockQueue = deque.Deque(Block);

const Immix = @This();

heap: []u8,
unavailable: BlockArrayList,
recyclable: BlockQueue,
// used so that we have enough space for evacuation
headroom: BlockArrayList,

pub const heap_size = 32 * 1024 * 1024;

fn init(allocator: Allocator) !Immix {
    const heap = try std.heap.page_allocator.alloc(usize, heap_size / @sizeOf(usize));
    @memset(heap, 0);
    const unavailable = BlockArrayList.init(allocator);
    const recyclable = try BlockQueue.init(allocator);
    const headroom = BlockArrayList.init(allocator);
    return .{
        .heap = heap,
        .unavailable = unavailable,
        .recyclable = recyclable,
        .headroom = headroom,
    };
}
