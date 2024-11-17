const std = @import("std");

const GcConfig = @import("GcConfig.zig");
const lisp2_hash = @import("lisp2_hash.zig");
const object = @import("object.zig");
const Header = object.Header;
const Object = object.Object;
const InfoTable = object.InfoTable;
const RecordInfoTable = object.InfoTable;
const shadow_stack = @import("shadow_stack.zig");
const Stack = shadow_stack.Stack;
const types = @import("types.zig");

const GC = lisp2_hash;

test "simple" {
    var gc = try GC.init(std.heap.c_allocator);

    var roots = [_]?*Object{null} ** 100;
    var frame = shadow_stack.Frame{ .pointers = &roots };
    gc.stack.push(&frame);
    defer gc.stack.pop();
    defer gc.deinit();

    var n1 = types.createRecord(&gc, types.Int, .{ .value = 10 });
    roots[0] = @ptrCast(&n1);

    var n2 = types.createRecord(&gc, types.Int, .{ .value = 1234 });
    roots[1] = @ptrCast(&n2);

    var p1 = types.createRecord(&gc, types.Pair, .{ .first = n1, .second = n2 });
    roots[2] = @ptrCast(&p1);

    var a1 = types.Array.create(&gc, 100);
    roots[3] = @ptrCast(&a1);

    for (0..10) |i| {
        const int = types.createRecord(&gc, types.Int, .{ .value = 10 });
        a1.items()[i] = @ptrCast(int);
    }

    gc.collect();

    roots[3] = null;
    roots[1] = null;
    gc.collect();
    gc.collect();

    roots[2] = null;
    roots[0] = null;
    gc.collect();
}
