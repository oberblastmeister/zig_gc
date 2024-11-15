const std = @import("std");

pub const RecordInfoTable = struct {
    // number of words that the object takes up
    size: usize,
    pointers_num: usize,
};

pub const InfoTable = union(enum) {
    const Self = @This();

    // use a pointers-first layout
    // `pointers_num` pointers come first, and then data is after.
    // the total size in words of the object including the pointers and data is `size`.
    record: RecordInfoTable,
    array: void,
    bytes: void,
};

pub const Header = extern union {
    const Self = @This();

    const FORWARD_MASK: usize = 0b1;

    info_table: *const InfoTable,
    forwarded: usize,

    // precondition: must not be forwarded
    pub inline fn infoTable(self: Self) *const InfoTable {
        std.debug.assert(!self.isForwarded());
        return self.info_table;
    }

    pub inline fn isForwarded(self: Self) bool {
        return (self.forwarded & FORWARD_MASK) == 1;
    }

    pub inline fn getForwardingAddress(self: Self) ?Object {
        if (self.isForwarded()) {
            return @ptrFromInt(self.forwarded & ~FORWARD_MASK);
        } else {
            return null;
        }
    }

    pub inline fn setForwardingAddress(self: *Self, ptr: *Header) void {
        self.forwarded = @intFromPtr(ptr) | FORWARD_MASK;
    }

    pub fn getInfoTableRecord(self: Self) *RecordInfoTable {
        return &self.infoTable().record;
    }

    pub inline fn getRecordPointers(self: *Self) []*Self {
        // skip the header
        return (@as([*]*Self, @ptrCast(self)))[1 .. self.infoTable().record.pointers_num + 1];
    }
};

pub const Object = *Header;

comptime {
    std.debug.assert(@alignOf(usize) >= @alignOf(usize));
    std.debug.assert(@alignOf(InfoTable) >= @alignOf(usize));
}
