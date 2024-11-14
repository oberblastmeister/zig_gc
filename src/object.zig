const std = @import("std");

pub const RecordInfoTable = struct {
    // number of words that the object takes up
    size: usize,
    pointers_num: usize,
};

pub const InfoTable = struct {
    const Self = @This();

    // use a pointers-first layout
    // `pointers_num` pointers come first, and then data is after.
    // the total size in words of the object including the pointers and data is `size`.
    tag: usize,
    body: union {
        record: RecordInfoTable,
        custom: void,
    },
};

pub const Header = extern struct {
    const Self = @This();

    const FORWARD_MASK: usize = 0b1;

    _info_table: ?*anyopaque,

    // precondition: must not be forwarded
    pub inline fn infoTable(self: *Self) *InfoTable {
        std.debug.assert(!self.isForwarded());
        const ptr: *align(@alignOf(InfoTable)) anyopaque = @alignCast(self._info_table.?);
        return @ptrCast(ptr);
    }

    pub inline fn isForwarded(self: *Self) bool {
        const ptr: usize = @intFromPtr(self._info_table);
        return (ptr & FORWARD_MASK) == 1;
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

    pub fn getInfoTableRecord(self: *Self) *RecordInfoTable {
        return &self.infoTable().body.record;
    }

    pub inline fn getRecordPointers(self: *Self) []*Self {
        const pointers_start = @as([*]Self, @ptrCast(self)) + 1;
        return (@as([*]*Self, @ptrCast(pointers_start)))[0..self.infoTable().body.record.pointers_num];
    }
};

comptime {
    std.debug.assert(@alignOf(usize) >= @alignOf(usize));
    std.debug.assert(@alignOf(InfoTable) >= @alignOf(usize));
}
