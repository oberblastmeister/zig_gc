const std = @import("std");
const debug = std.debug;
const assert = debug.assert;

pub fn castSlice(comptime T: type, comptime U: type, slice: []T) []U {
    assert((slice.len * @sizeOf(T)) % @sizeOf(U) == 0);
    const ptr: [*]U = @ptrCast(@alignCast(slice.ptr));
    return ptr[0..((slice.len * @sizeOf(T)) / @sizeOf(U))];
}

pub fn ptrSub(p: anytype, q: anytype) usize {
    const P = @TypeOf(p);
    const Q = @TypeOf(q);
    assert(@typeInfo(P).Pointer.child == @typeInfo(Q).Pointer.child);
    const T = @typeInfo(P).Pointer.child;
    const pu: usize = @intFromPtr(p);
    const qu: usize = @intFromPtr(q);
    const off = (pu - qu) / @sizeOf(T);
    return off;
}
