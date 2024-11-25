const std = @import("std");

pub const Tag = enum(usize) { record, array };

pub const RecordInfoTable = struct {
    // number of words that the object takes up
    size: usize,
    pointers_num: usize,
    // the tag of the constructor, used to distinguish constructors for sumtypes
    constructor_tag: usize,
};

pub const InfoTable = union(Tag) {
    const Self = @This();

    record: RecordInfoTable,
    array: void,
};

pub const Object = *Header;

const SizeClass = enum {
    small,
    medium,
};

pub const Header = extern struct {
    const Self = @This();

    const FORWARD_MASK: usize = 0b1;
    const FORWARD_SHIFT: usize = 0;
    const MARK_MASK: usize = 0b10;
    const MARK_SHIFT: usize = 1;
    const BITS_MASK: usize = 0b111;
    const MEDIUM_MASK: usize = 0b100;
    const MEDIUM_SHIFT: usize = 2;

    _info_table: ?*anyopaque,

    // precondition: must not be forwarded
    pub inline fn infoTable(self: *Self) *const InfoTable {
        std.debug.assert(!self.isForwarded());
        const ptr: usize = @intFromPtr(self._info_table);
        // clear the least significant three bits
        return @ptrFromInt(ptr & ~BITS_MASK);
    }

    pub inline fn isForwarded(self: *Self) bool {
        const ptr: usize = @intFromPtr(self._info_table);
        return (ptr & FORWARD_MASK) == 1;
    }

    pub inline fn isMarked(self: *Self) bool {
        const ptr: usize = @intFromPtr(self._info_table);
        return ((ptr >> MARK_SHIFT) & 0b1) == 1;
    }

    pub inline fn setMarked(self: *Self, marked: bool) void {
        const ptr: usize = @intFromPtr(self._info_table);
        if (marked) {
            self._info_table = @ptrFromInt(ptr | MARK_MASK);
        } else {
            self._info_table = @ptrFromInt(ptr & ~MARK_MASK);
        }
    }

    pub inline fn getSizeClass(self: *Self) SizeClass {
        const ptr: usize = @intFromPtr(self._info_table);
        return if (((ptr >> MEDIUM_SHIFT) & 0b1) == 1)
            .medium
        else
            .small;
    }

    pub inline fn setSizeClass(self: *Self, size: SizeClass) void {
        const ptr: usize = @intFromPtr(self._info_table);
        if (size == .medium) {
            self._info_table = @ptrFromInt(ptr | MEDIUM_MASK);
        } else {
            self._info_table = @ptrFromInt(ptr & ~MEDIUM_MASK);
        }
    }

    pub inline fn flipMarked(self: *Self) void {
        self.setMarked(!self.isMarked());
    }

    pub inline fn getForwardingAddress(self: *Self) ?*Header {
        if (self.isForwarded()) {
            const ptr: usize = @intFromPtr(self._info_table);
            return @ptrFromInt(ptr & ~FORWARD_MASK);
        } else {
            return null;
        }
    }

    pub inline fn setForwardingAddress(self: *Self, ptr: *Header) void {
        const ptr1: usize = @intFromPtr(ptr);
        self._info_table = @ptrFromInt(ptr1 | FORWARD_MASK);
    }

    pub fn getConstructorTag(self: *Self) usize {
        return self.infoTable().record.constructor_tag;
    }

    pub inline fn getRecordPointers(self: *Self) []*Self {
        const pointers_start = @as([*]Self, @ptrCast(self)) + 1;
        return (@as([*]*Self, @ptrCast(pointers_start)))[0..self.infoTable().record.pointers_num];
    }
};

comptime {
    std.debug.assert(@alignOf(InfoTable) >= @alignOf(u64));
}
