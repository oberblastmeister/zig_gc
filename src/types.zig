const std = @import("std");

const GcConfig = @import("GcConfig.zig");
const object = @import("object.zig");
const Header = object.Header;
const Object = object.Object;
const InfoTable = object.InfoTable;
const semispace = @import("semispace.zig");
const assert = std.debug.assert;

pub const Tag = enum(u8) { record, array };

pub fn processFields(gc: *anyopaque, ref: *Header, processField: fn (gc: *anyopaque, **Header) void) void {
    switch (ref.infoTable().*) {
        .record => |_| {
            const pointers = ref.getRecordPointers();
            for (0..pointers.len) |i| {
                processField(gc, &pointers[i]);
            }
        },
        .array => |_| {
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
    switch (ref.infoTable().*) {
        .record => |_| {
            return ref.infoTable().record.size;
        },
        .array => |_| {
            const array: *Array = @ptrCast(ref);
            // include the info table in the size
            return 2 + array.size;
        },
    }
}

pub const Int = extern struct {
    header: Header,
    value: usize,

    pub const info_table = genRecordInfoTable(@This());
};

pub const Pair = extern struct {
    header: Header,
    first: Object,
    second: Object,

    pub const info_table = genRecordInfoTable(@This());
};

pub const Array = extern struct {
    header: Header,
    // the size of the array not including the header
    size: usize,

    const Self = @This();

    pub const info_table =
        InfoTable{
        .array = {},
    };

    pub fn items(self: *Self) []?*Header {
        const size = self.size;
        var ptr: [*]Self = @ptrCast(self);
        ptr += 1;
        const xs: [*]?*Header = @ptrCast(ptr);
        return xs[0..size];
    }

    pub fn create(gc: anytype, size: usize) *@This() {
        const raw_ptr = gc.allocRaw(2 + size);
        const ptr: *@This() = @ptrCast(raw_ptr);
        ptr.header._info_table = @constCast(&info_table);
        ptr.size = size;
        @memset(ptr.items(), null);
        return ptr;
    }
};

pub const BinaryTree = struct {
    pub const Self = @This();

    pub const Tag = enum(usize) {
        empty,
        node,
    };

    pub const Empty = extern struct {
        header: Header,

        pub const info_table = genRecordInfoTableWithConstructorTag(@This(), @intFromEnum(Self.Tag.empty));
    };

    pub const Node = extern struct {
        header: Header,
        left: Object,
        value: Object,
        right: Object,

        pub const info_table = genRecordInfoTableWithConstructorTag(@This(), @intFromEnum(Self.Tag.node));
    };
};

fn genRecordInfoTable(comptime T: type) InfoTable {
    return genRecordInfoTableWithConstructorTag(T, 0);
}

fn genRecordInfoTableWithConstructorTag(comptime T: type, constructor_tag: usize) InfoTable {
    switch (@typeInfo(T)) {
        .Struct => |info| {
            if (info.layout != .@"extern") {
                @compileError("Struct must be extern");
            }
            if (info.fields.len == 0) {
                @compileError("Need to have at least one field in the struct");
            }
            const header_field_info = info.fields[0];
            if (!std.mem.eql(u8, header_field_info.name, "header")) {
                @compileError("First field of the struct must be named header");
            }
            var found_non_object = false;
            var pointers_num: usize = 0;
            inline for (info.fields[1..]) |field_info| {
                if (found_non_object) {
                    if (field_info.type == Object) {
                        @compileError("Must follow pointers first layout");
                    }
                    break;
                }

                if (field_info.type == Object) {
                    pointers_num += 1;
                } else {
                    if (@alignOf(field_info.type) > @alignOf(Header)) {
                        @compileError("First non-object field must have alignment less than an object");
                    }
                    found_non_object = true;
                }
            }
            assert(@sizeOf(T) % 8 == 0);
            return InfoTable{ .record = .{
                .size = @sizeOf(T) / 8,
                .pointers_num = pointers_num,
                .constructor_tag = constructor_tag,
            } };
        },
        else => @compileError("cannot generate record info table for non-struct type " ++ @typeName(T)),
    }
}

pub fn write(gc: anytype, lhs: anytype, comptime field_name: []const u8, value: anytype) void {
    const self = gc;
    if (@TypeOf(@field(lhs, field_name)) != Object) {
        @compileError("Field type must be Object");
    }
    self.writeBarrier(toObject(lhs), &@field(lhs, field_name), value);
    @field(lhs, field_name) = value;
}

pub fn read(gc: anytype, lhs: anytype, comptime field_name: []const u8) Object {
    const self = gc;
    if (@TypeOf(@field(lhs, field_name)) != Object) {
        @compileError("Field type must be Object");
    }
    self.readBarrier(toObject(lhs), &@field(lhs, field_name));
    return @field(lhs, field_name);
}

// does the type look like an object
pub fn isObjectPtr(ty: type) bool {
    return isObjectType(@typeInfo(ty).Pointer.child);
}

pub fn isObjectType(ty: type) bool {
    if (ty == Header) {
        return true;
    }

    return @hasDecl(ty, "info_table") and @hasField(ty, "header");
}

pub fn toObject(ptr: anytype) Object {
    assert(isObjectPtr(@TypeOf(ptr)));
    return @ptrCast(ptr);
}

pub fn createRecord(gc: anytype, comptime T: type, args: anytype) *T {
    assert(isObjectType(T));

    const ptr: *T = @ptrCast(gc.allocRecord(&T.info_table));
    const fields = @typeInfo(@TypeOf(args)).Struct.fields;

    // make sure all the fields were initialized
    inline for (@typeInfo(T).Struct.fields) |field| {
        if (comptime !std.mem.eql(u8, field.name, "header")) {
            const found = found: {
                inline for (fields) |f| {
                    if (comptime std.mem.eql(u8, f.name, field.name)) {
                        break :found true;
                    }
                }
                break :found false;
            };
            if (!found) {
                @compileError("Field " ++ field.name ++ " not found in the arguments");
            }
        }
    }

    // now set the fields
    inline for (fields) |field| {
        if (@TypeOf(@field(ptr, field.name)) == Object) {
            assert(isObjectPtr(@TypeOf(@field(args, field.name))));
            @field(ptr, field.name) = @ptrCast(@field(args, field.name));
        } else {
            @field(ptr, field.name) = @field(args, field.name);
        }
    }
    return ptr;
}
