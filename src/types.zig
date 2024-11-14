const std = @import("std");

const GcConfig = @import("GcConfig.zig");
const object = @import("object.zig");
const Header = object.Header;
const InfoTable = object.InfoTable;
const semispace = @import("semispace.zig");

pub const Tag = enum(u8) { int, pair, array };

pub fn processFields(gc: *anyopaque, ref: *Header, processField: fn (gc: *anyopaque, **Header) void) void {
    const tag: Tag = @enumFromInt(ref.infoTable().tag);
    switch (tag) {
        Tag.int, Tag.pair => {
            const pointers = ref.getRecordPointers();
            for (0..pointers.len) |i| {
                processField(gc, &pointers[i]);
            }
        },
        Tag.array => {
            const array: *Array = @ptrCast(ref);
            const items = array.items();
            for (0..items.len) |i| {
                if (items[i]) |*ptr| {
                    processField(gc, ptr);
                }
            }
        },
    }
}

pub fn objectSize(ref: *Header) usize {
    const tag: Tag = @enumFromInt(ref.infoTable().tag);
    switch (tag) {
        Tag.int, Tag.pair => {
            return ref.getInfoTableRecord().size;
        },
        Tag.array => {
            const array: *Array = @ptrCast(ref);
            // include the info table in the size
            return 1 + array.size;
        },
    }
}

pub const gc_config = GcConfig{
    .objectSize = objectSize,
    .processFields = processFields,
};

pub const pair_info_table = InfoTable{ .tag = @intFromEnum(Tag.pair), .body = .{ .record = .{
    .size = 3,
    .pointers_num = 2,
} } };

pub const int_info_table = InfoTable{
    .tag = @intFromEnum(Tag.int),
    .body = .{ .record = .{
        .size = 2,
        .pointers_num = 0,
    } },
};

pub const array_info_table = InfoTable{
    .tag = @intFromEnum(Tag.array),
    .body = .{ .custom = {} },
};

pub const Int = extern struct {
    _info_table: *InfoTable,
    value: usize,

    const Self = @This();
};

pub const Pair = extern struct {
    _info_table: *InfoTable,
    first: *Header,
    second: *Header,

    const Self = @This();
};

pub const Array = extern struct {
    _info_table: *InfoTable,
    // the size of the array not including the header
    size: usize,

    const Self = @This();

    pub fn items(self: *Self) []?*Header {
        const size = self.size;
        var ptr: [*]Self = @ptrCast(self);
        ptr += 1;
        const xs: [*]?*Header = @ptrCast(ptr);
        return xs[0..size];
    }
};
