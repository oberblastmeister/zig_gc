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
                const raw_ptr = gc.allocRaw(2 + size);
                const ptr: *types.Array = @ptrCast(raw_ptr);
                ptr.header = .{ .info_table = &types.array_info_table };
                ptr.size = size;
                @memset(ptr.items(), null);
                return ptr;
            }
        };

        pub const Bytes = struct {
            pub fn create(gc: *GC, size: usize) *types.Bytes {
                const bytes_size = size + (size & 0b111);
                const ptr: *types.Bytes = @ptrCast(gc.allocRaw(bytes_size / 8 + 2));
                ptr.header = .{ .info_table = &types.bytes_info_table };
                ptr.size = size;
                @memset(ptr.items(), 0);
                return ptr;
            }
        };
    };
}
