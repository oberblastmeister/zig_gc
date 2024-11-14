const std = @import("std");

const object = @import("object.zig");
const Header = object.Header;
const types = @import("types.zig");

pub fn Make(comptime GC: type) type {
    return struct {
        pub const Int = struct {
            pub fn create(gc: *GC, value: usize) *types.Int {
                const ptr: *types.Int = @ptrCast(gc.allocRecord(&types.int_info_table));
                ptr.value = value;
                return ptr;
            }
        };

        pub const Pair = struct {
            pub fn create(gc: *GC, first: *Header, second: *Header) *types.Pair {
                const ptr: *types.Pair = @ptrCast(gc.allocRecord(&types.pair_info_table));
                ptr.first = first;
                ptr.second = second;
                return ptr;
            }
        };

        pub const Array = struct {
            pub fn create(gc: *GC, size: usize) *types.Array {
                const raw_ptr = gc.allocRaw(1 + size);
                @memset(raw_ptr[0..(1 + size)], 0);
                const ptr: *types.Array = @ptrCast(raw_ptr);
                ptr._info_table = @constCast(&types.array_info_table);
                ptr.size = size;
                return ptr;
            }
        };
    };
}
