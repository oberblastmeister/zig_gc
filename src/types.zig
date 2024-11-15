const std = @import("std");

const GcConfig = @import("GcConfig.zig");
const object = @import("object.zig");
const Object = object.Object;
const Header = object.Header;
const InfoTable = object.InfoTable;
const semispace = @import("semispace.zig");

pub fn processFields(comptime GC: type, gc: *GC, ref: Object, comptime processField: fn (gc: *GC, *Object) void) void {
    const pointers = switch (ref.infoTable().*) {
        .record => @as([]?Object, @ptrCast(ref.getRecordPointers())),
        .array => @as(*Array, @ptrCast(ref)).items(),
        .bytes => @as([]?Object, &[0]?Object{}),
    };
    for (0..pointers.len) |i| {
        if (pointers[i]) |*p| {
            processField(gc, p);
        }
    }
}

pub fn objectSize(ref: Object) usize {
    switch (ref.infoTable().*) {
        .record => |infoTable| return infoTable.size,
        .array => {
            const array: *Array = @ptrCast(ref);
            // include the info table in the size
            return 2 + array.size;
        },
        .bytes => {
            const bytes: *Bytes = @ptrCast(ref);
            // round up to 8 bytes, divide by 8, then include header
            return (bytes.size + (bytes.size & 7)) / 8 + 1;
        },
    }
}

pub const gc_config = GcConfig{
    .objectSize = objectSize,
    .processFields = processFields,
};

pub const pair_info_table = InfoTable{ .record = .{
    .size = 3,
    .pointers_num = 2,
} };

pub const int_info_table = InfoTable{ .record = .{
    .size = 2,
    .pointers_num = 0,
} };

pub const bytes_info_table = InfoTable{ .bytes = {} };

pub const array_info_table = InfoTable{ .array = {} };

pub const Int = extern struct {
    header: Header,
    value: usize,

    const Self = @This();
};

pub const Pair = extern struct {
    header: Header,
    first: Object,
    second: Object,

    const Self = @This();
};

pub const Array = extern struct {
    header: Header,
    // the size of the array not including the header
    size: usize,
    elements: [0]?Object,

    const Self = @This();

    pub fn items(self: *Self) []?Object {
        return @as([*]?Object, &self.elements)[0..self.size];
    }
};

pub const Bytes = extern struct {
    header: Header,
    // number of bytes, not including header
    size: usize,
    elements: [0]u8,

    const Self = @This();

    pub fn items(self: *Self) []u8 {
        return @as([*]u8, &self.elements)[0..self.size];
    }
};
